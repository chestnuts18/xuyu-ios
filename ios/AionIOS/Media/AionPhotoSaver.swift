import Foundation
import Photos
import UIKit

/// 存图到相册 —— 对齐安卓 `WebViewActivity.java:302-321` 的 `AionImageSaver` 桥。
///
/// 网页侧早就接好了：`chat.js:4229 saveImage` / `chatroom.js:6227` / `image-viewer.js:173` /
/// `album.js:293` / `theater-studio.js:73` / `repair.js:37` 都探 `window.AionImageSaver`，
/// 探到就调 `save(base64, filename)`，探不到才退回 `<a download>`。
/// WKWebView 没有下载委托，那个回退分支在本壳里等于静默失败（2026-10-29 查明：
/// 「保存图片点了没反应」就是这条）。
///
/// 所以网页一行不用改，把这个对象注入进去即可。
@MainActor
final class AionPhotoSaver {
    static let shared = AionPhotoSaver()
    private init() {}

    /// 返回是否真的落进相册（网页不 await 这个返回值，只作日志）
    func save(base64: String, filename: String) async -> Bool {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              !data.isEmpty else {
            AionLogger.shared.log("photo save: base64 decode failed name=\(filename)")
            Self.showToast("保存失败：图片数据为空")
            return false
        }
        guard await ensureAddPermission() else {
            Self.showToast("没有相册权限：设置 → 隐私与安全性 → 照片 → XuYu，允许「添加照片」")
            return false
        }
        do {
            try await performSave(data: data)
            AionLogger.shared.log("photo save ok name=\(filename) bytes=\(data.count)")
            Self.showToast("图片已保存到相册")
            return true
        } catch {
            AionLogger.shared.log("photo save failed name=\(filename) err=\(error.localizedDescription)")
            Self.showToast("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    private func ensureAddPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            // 首次调用弹系统授权（Info.plist 的 NSPhotoLibraryAddUsageDescription 是必需的，
            // 缺了这条 key 会直接崩，不是静默失败）
            let granted: PHAuthorizationStatus = await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { cont.resume(returning: $0) }
            }
            return granted == .authorized || granted == .limited
        default:
            return false
        }
    }

    private func performSave(data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                // addResource 直接写原始字节：png 还是 png、jpg 还是 jpg，不重编码
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                if let error {
                    cont.resume(throwing: error)
                } else if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: NSError(
                        domain: "AionPhotoSaver", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "相册写入失败"]
                    ))
                }
            }
        }
    }

    // MARK: - 轻提示（对齐安卓原生 Toast；网页不弹任何提示，用户只能靠这个知道结果）

    static func showToast(_ text: String) {
        guard let window = Self.keyWindow() else { return }
        let label = PaddedLabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.backgroundColor = UIColor(white: 0, alpha: 0.82)
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -72),
            label.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, multiplier: 0.82),
        ])
        label.alpha = 0
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            UIView.animate(withDuration: 0.3, animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    static func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) { return key }
            if let first = windowScene.windows.first { return first }
        }
        return nil
    }
}

/// 带内边距的 UILabel（toast 用，纯代码不需要单独文件）
final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(
            top: -insets.top, left: -insets.left,
            bottom: -insets.bottom, right: -insets.right
        ))
    }
}
