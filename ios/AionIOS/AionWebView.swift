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
        // 本地资源 scheme（2026-08-25 网页资源打包）：aionres://aion/<path> → WebAssets bundle
        config.setURLSchemeHandler(AionSchemeHandler(), forURLScheme: AionSchemeHandler.scheme)
        // 解锁语音/视频：内联播放 + 不要求用户手势 + 画中画
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        // JS 桥：全 frame 注入（健康/定位/监管是聊天页 iframe 子页，也要桥）
        // {{API_BASE}} 占位替换为当前基址（探测切换后经 cache 推送更新）
        config.userContentController.addUserScript(
            WKUserScript(
                source: AionJSBridge.injectScript.replacingOccurrences(
                    of: "{{API_BASE}}", with: APIClient.shared.baseURL.absoluteString),
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
        // 候选切换后：重新注册注入脚本（新基址）+ 重载本地页面。
        // makeUIView 时静态替换的 {{API_BASE}} 会随 reload 原样重新注入旧基址——
        // 流量下切到 TS/CF 后页面仍打旧 LAN → 全失败空白（2026-08-25 实测根因）。
        // ⚠️ 不在这里 pushCache：evaluateJavaScript 与 reload 并发会撞 WebKit 竞态
        //（空白+闪退的另一半根因），reload 后新文档自会从注入脚本拿到新基址。
        // ⚠️ reload 冷却 5s：探测在 CF/LAN 之间抖动时 adopt 反复切换，
        // 无条件 reload 与 WebKit 自带恢复机制形成重载循环 = 频闪。
        APIClient.shared.onBaseURLChanged = { [weak webView] _ in
            let now = Date()
            guard now.timeIntervalSince(model.lastReloadAt) >= 5 else { return }
            model.lastReloadAt = now
            guard let controller = webView?.configuration.userContentController else { return }
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(
                source: AionJSBridge.injectScript.replacingOccurrences(
                    of: "{{API_BASE}}", with: APIClient.shared.baseURL.absoluteString),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            webView?.reload()
        }
        // 页面走本地 aionres（秒开）；API/WS 仍走 APIClient 探测的网络基址
        webView.load(URLRequest(url: URL(string: "\(AionSchemeHandler.scheme)://\(AionSchemeHandler.host)/chat")!))
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
              var fn = localStorage.getItem('aion_fetch_n') || '0';
              var fl = localStorage.getItem('aion_fetch_last') || '';
              return {
                base: (window.AION_API_BASE !== undefined) ? String(window.AION_API_BASE).slice(0,100) : 'UNDEFINED',
                hasBridge: typeof window.__aionBridgeDispatch === 'function',
                hasAionBle: typeof window.AionBle === 'object',
                msgHandler: mb,
                fetchN: fn,
                fetchLast: fl
              };
            })()
            """) { result, _ in
                if let d = result as? [String: Any] {
                    AionLogger.shared.log("page state: base=\(d["base"] ?? "?") bridge=\(d["hasBridge"] ?? "?") ble=\(d["hasAionBle"] ?? "?") mb=\(d["msgHandler"] ?? "?") fetchN=\(d["fetchN"] ?? "?") fetchLast=\(d["fetchLast"] ?? "?")")
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
            // 冷却 10s：WebKit 对 provisional 失败自带 reload-frame 恢复，
            // 无条件 load 会与之形成重载循环（2026-08-25 频闪根因二）
            let now = Date()
            guard now.timeIntervalSince(self.parent.model.lastRecoverAt) >= 10 else { return }
            self.parent.model.lastRecoverAt = now
            Task { @MainActor in
                // 基址挂了：跳过当前候选，探测下一个（家里 LAN → 出门 TS 自动切换）。
                // ⚠️ 主文档永远回本地 aionres 页（2026-08-25 频闪根因一：失败后
                // load 远程候选 URL，页面在本地/远程之间反复横跳；基址切换
                // 由 adopt → onBaseURLChanged → 重注册脚本 + 本地 reload 完成）
                if await APIClient.shared.retryAfterFailure() != nil {
                    webView.load(URLRequest(url: URL(string: "\(AionSchemeHandler.scheme)://\(AionSchemeHandler.host)/chat")!))
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

        // 主文档绝不允许离开本地 aionres（2026-08-25 空白/横跳根因：
        // target=_blank 的绝对基址链接把主 frame 导航到远程页——远程页
        // 在流量下数据链失效；且远程导航与本地 handler 反复横跳）
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame == true,
               let url = navigationAction.request.url,
               url.scheme != AionSchemeHandler.scheme {
                AionLogger.shared.log("blocked remote nav: \(url.absoluteString)")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // target=_blank 链接：仅本地 aionres 在当前页打开，外链忽略
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, url.scheme == AionSchemeHandler.scheme {
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
