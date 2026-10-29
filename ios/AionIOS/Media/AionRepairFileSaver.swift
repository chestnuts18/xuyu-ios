import Foundation
import UIKit

/// 维修室附件下载 —— 对齐安卓 `RepairFileBridge.java:22` 的 `AionRepairFiles` 桥。
///
/// 网页侧 `repair.js:37` 先探 `window.AionRepairFiles.save(url, filename)`；
/// 探不到就退到 `AionImageSaver`（只吃图片）；再探不到就退到裸 `<a download>`
/// （WKWebView 不落地）→ 附件拿不到。2026-10-29 补这一层。
///
/// 与安卓的差异（平台不同，不是降级）：安卓 DownloadManager 直接落「下载」目录 + 通知栏；
/// iOS 没有公共下载目录，下载到临时目录后弹系统分享面板，用户可以「存储到文件」、
/// 发到微信、AirDrop 等。文件本身和服务器鉴权行为一致。
@MainActor
final class AionRepairFileSaver {
    static let shared = AionRepairFileSaver()
    private init() {}

    func save(urlString: String, filename: String) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            AionPhotoSaver.showToast("不是有效的下载地址")
            return
        }
        let name = Self.sanitize(filename)
        Task {
            AionPhotoSaver.showToast("正在下载 \(name)…")
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 90
                // 隧道候选下文件也要带 token（nginx/access_gate 同一套裁决）
                if let token = APIClient.shared.currentToken, !token.isEmpty {
                    request.setValue(token, forHTTPHeaderField: "X-Aion-Token")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    throw NSError(
                        domain: "AionRepairFileSaver", code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "服务器返回 \(http.statusCode)"]
                    )
                }
                guard !data.isEmpty else {
                    throw NSError(
                        domain: "AionRepairFileSaver", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "文件是空的"]
                    )
                }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try data.write(to: dest, options: .atomic)
                AionLogger.shared.log("repair file downloaded name=\(name) bytes=\(data.count)")
                presentShareSheet(fileURL: dest)
            } catch {
                AionLogger.shared.log("repair file failed name=\(name) err=\(error.localizedDescription)")
                AionPhotoSaver.showToast("下载失败：\(error.localizedDescription)")
            }
        }
    }

    private func presentShareSheet(fileURL: URL) {
        guard let top = Self.topViewController() else {
            AionPhotoSaver.showToast("找不到可用的界面，文件已下到临时目录")
            return
        }
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = top.view
        top.present(activity, animated: true)
    }

    static func topViewController() -> UIViewController? {
        guard var top = AionPhotoSaver.keyWindow()?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    /// 安卓那边是 `replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_")`，这里同义
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "attachment" }
        return cleaned
    }
}
