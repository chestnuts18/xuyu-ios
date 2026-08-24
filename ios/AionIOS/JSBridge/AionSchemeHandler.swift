import Foundation
import WebKit

/// aionres:// 本地资源 handler（2026-08-25 网页资源打包）
/// URL 形如 aionres://aion/<path>：WebAssets bundle 优先；未命中时远程兜底（带隧道 token 可过 CF WAF）。
/// 裸页面路径 /health → WebAssets/static/health.html（对齐 FastAPI FileResponse 映射）。
final class AionSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "aionres"
    static let host = "aion"

    private let fileManager = FileManager.default

    /// 进行中的 urlSchemeTask（ObjectIdentifier 集合 + 锁）。
    /// WebKit 在页面 reload/导航时调用 stop()；之后迟到的远程兜底回调再打
    /// didReceive/didFinish 会 raise NSException（2026-08-25 流量下闪退嫌疑）。
    private var activeTasks = Set<ObjectIdentifier>()
    private let taskLock = NSLock()

    private var assetsRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("WebAssets")
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "aionres", code: 1))
            return
        }
        let path = url.path
        var rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if rel.isEmpty {
            rel = "static/chat.html"  // 首页
        } else if !rel.contains(".") {
            rel = "static/" + rel + ".html"  // 裸页面路径
        }

        if let root = assetsRoot {
            let file = root.appendingPathComponent(rel)
            if fileManager.fileExists(atPath: file.path),
               let data = try? Data(contentsOf: file) {
                finish(task: urlSchemeTask, url: url, data: data, mime: Self.mime(for: file.pathExtension), cors: false)
                return
            }
        }

        // 兜底：远程代理（带隧道 token 头，CF WAF 无凭证 403 也能过）
        guard let remote = URL(string: url.path, relativeTo: APIClient.sharedBaseURL) else {
            urlSchemeTask.didFailWithError(NSError(domain: "aionres", code: 2))
            return
        }
        AionLogger.shared.log("aionres miss \(rel) -> \(remote.absoluteString)")
        var req = URLRequest(url: remote)
        req.timeoutInterval = 15
        if let t = APIClient.sharedToken {
            req.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        let taskID = ObjectIdentifier(urlSchemeTask)
        taskLock.lock()
        activeTasks.insert(taskID)
        taskLock.unlock()
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            // stop() 已移除 → 页面已导航走，静默丢弃（绝不打已停止的 task）
            self.taskLock.lock()
            let stillActive = self.activeTasks.remove(taskID) != nil
            self.taskLock.unlock()
            guard stillActive else { return }
            if let data, let resp, resp.mimeType != nil || data.count > 0 {
                self.finish(task: urlSchemeTask, url: url, data: data,
                            mime: resp.mimeType ?? Self.mime(for: remote.pathExtension), cors: true)
            } else {
                AionLogger.shared.log("aionres remote fail \(rel): \(String(describing: error))")
                urlSchemeTask.didFailWithError(error ?? NSError(domain: "aionres", code: 3))
            }
        }.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        taskLock.lock()
        let wasActive = activeTasks.remove(id) != nil
        taskLock.unlock()
        // 只记「进行中被打断」的：验证 WebKit 是否在兜底响应前就 stop 任务
        if wasActive {
            AionLogger.shared.log("aionres task stopped early path=\(urlSchemeTask.request.url?.path ?? "?")")
        }
    }

    private func finish(task: WKURLSchemeTask, url: URL, data: Data, mime: String, cors: Bool) {
        let resp: URLResponse
        if cors {
            // 兜底远程响应：aionres:// 源下的 fetch/XHR 经 handler 拿数据时，
            // 无 CORS 头会被 WebKit 拒绝（2026-08-25 白屏根因之三）——
            // 响应是服务器真实 body，非导航文档，ACAO * 安全。
            let headers = [
                "Content-Type": mime,
                "Access-Control-Allow-Origin": "*",
            ]
            resp = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) ?? URLResponse(url: url, mimeType: mime,
                             expectedContentLength: data.count, textEncodingName: nil)
        } else {
            resp = URLResponse(url: url, mimeType: mime,
                               expectedContentLength: data.count, textEncodingName: nil)
        }
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "mp3": return "audio/mpeg"
        case "ico": return "image/x-icon"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }
}
