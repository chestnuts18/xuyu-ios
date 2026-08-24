import SwiftUI
import WebKit
import AVFoundation

/// Aion 壳状态：连接失败时显示重试页
final class WebModel: ObservableObject {
    @Published var failed = false
    weak var webView: WKWebView?
    // 重载冷却（2026-08-25 频闪修复）：WebKit 在 provisional 导航失败后
    // 自带 reload-frame 恢复，delegate 再无条件 load/reload 会形成无限重载
    // 循环（Apple 论坛确认的经典模式）——两次恢复/重载之间至少间隔数秒。
    var lastRecoverAt: Date = .distantPast
    var lastReloadAt: Date = .distantPast

    func retry() {
        failed = false
        webView?.reload()
    }
}

struct AionWebView: UIViewRepresentable {
    @ObservedObject var model: WebModel

    func makeUIView(context: Context) -> WKWebView {
        // 音频会话：播放类，静音开关不挡音乐（对齐安卓 USAGE_ALARM 精神）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let config = WKWebViewConfiguration()
        // 解锁语音/视频：内联播放 + 不要求用户手势 + 画中画
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        // JS 桥：全 frame 注入（健康/定位/监管是聊天页 iframe 子页，也要桥）
        config.userContentController.addUserScript(
            WKUserScript(
                source: AionJSBridge.injectScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        config.userContentController.add(context.coordinator, name: AionJSBridge.handlerName)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        model.webView = webView
        AionJSBridge.shared.webView = webView
        // 基址切换回调在 App 层（AionIOSApp.swift）注册：候选切换 → load 新基址。
        // 页面直接加载远程基址（2026-08-25 回滚网页打包：aionres 本地 scheme
        // 在 iOS 26 上平台坑太多，恢复远程加载 + 网络层缓存提速）
        webView.load(URLRequest(url: APIClient.shared.baseURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: AionWebView

        init(parent: AionWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            AionLogger.shared.log("webview didFinish url=\(webView.url?.absoluteString ?? "nil")")
            // 白屏排查：原生直接读页面运行时状态（不依赖注入脚本自报）
            webView.evaluateJavaScript("""
            (function(){
              var mb = '?';
              try { mb = typeof window.webkit.messageHandlers.aionBridge; } catch(e) { mb = 'err'; }
              return {
                hasBridge: typeof window.__aionBridgeDispatch === 'function',
                hasAionBle: typeof window.AionBle === 'object',
                msgHandler: mb
              };
            })()
            """) { result, _ in
                if let d = result as? [String: Any] {
                    AionLogger.shared.log("page state: bridge=\(d["hasBridge"] ?? "?") ble=\(d["hasAionBle"] ?? "?") mb=\(d["msgHandler"] ?? "?")")
                } else {
                    AionLogger.shared.log("page state read failed: \(String(describing: result))")
                }
            }
            Task { @MainActor in
                self.parent.model.failed = false
                APIClient.shared.markVerified()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // 用户主动点链接造成的取消不算失败
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            AionLogger.shared.log("webview didFail url=\(webView.url?.absoluteString ?? "nil") err=\((error as NSError).code)")
            DispatchQueue.main.async { self.parent.model.failed = true }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            AionLogger.shared.log("webview didFailProvisional url=\(webView.url?.absoluteString ?? "nil") err=\((error as NSError).code)")
            Task { @MainActor in
                // 基址挂了：跳过当前候选，探测下一个（家里 LAN → 出门 TS → CF 自动切换）
                if let url = await APIClient.shared.retryAfterFailure() {
                    webView.load(URLRequest(url: url))
                } else {
                    self.parent.model.failed = true
                }
            }
        }

        // 网页里的 alert/confirm 弹窗
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            Self.present(alert, on: webView)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            Self.present(alert, on: webView)
        }

        // 同步桥通道：网页 prompt('__aion_sync:...') → 原生同步返回
        // （WKWebView 无原生同步 JS 桥，getFrame/capture/stopRecord 契约要求同步字符串）
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            if prompt.hasPrefix("__aion_sync:") {
                completionHandler(AionSyncChannel.handle(prompt))
                return
            }
            completionHandler(nil)
        }

        // target=_blank 链接：在当前页打开（不另开新窗口）
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        static func present(_ alert: UIAlertController, on webView: WKWebView) {
            var responder: UIResponder? = webView
            while let next = responder?.next {
                responder = next
                if let vc = responder as? UIViewController {
                    vc.present(alert, animated: true)
                    return
                }
            }
        }
    }
}

// 网页 → 原生消息入口（注入脚本 postMessage 到这里）
extension AionWebView.Coordinator: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == AionJSBridge.handlerName else { return }
        Task { @MainActor in
            AionJSBridge.shared.handle(message)
        }
    }
}
