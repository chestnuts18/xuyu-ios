import Foundation
import UIKit
import UserNotifications

/// APNs 注册：通知权限 + device token → 上报 Aion（/api/ios-push/register）
/// 徐聿主动发消息/夜间哨兵告警时，服务器经 APNs 推通知到 iPhone 通知栏。
/// 2026-08-31 补 UNUserNotificationCenterDelegate：App 前台时也弹横幅（默认只进通知中心，
/// XuYu 单 Tab 壳前台概率高，不补等于收不到告警）。
@MainActor
final class PushRegistrar: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushRegistrar()
    private var lastToken = ""

    private override init() {}

    /// App 启动时调用：挂代理 + 请求通知权限 → 注册 APNs
    func start() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                AionLogger.shared.log("apns auth denied: \(error.localizedDescription)")
            } else {
                AionLogger.shared.log("apns auth granted=\(granted)")
            }
            // 无论批不批都注册：token 先拿到，横幅显示与否由系统决定
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// 前台收到通知也弹横幅+声音（默认行为是只静默进通知中心）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// 点按通知横幅：App 已在台时打日志留痕
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        AionLogger.shared.log("apns tapped: \(response.notification.request.identifier)")
    }

    /// AppDelegate didRegisterForRemoteNotificationsWithDeviceToken 回调
    func handleToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty, token != lastToken else { return }
        lastToken = token
        AionLogger.shared.log("apns token received len=\(token.count)")
        Task { @MainActor in
            await upload(token)
        }
    }

    func handleTokenFailure(_ error: Error) {
        AionLogger.shared.log("apns register failed: \(error.localizedDescription)")
    }

    private func upload(_ token: String) async {
        let endpoint = APIClient.shared.url(for: "/api/ios-push/register")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = APIClient.shared.currentToken {  // 隧道候选时带 X-Aion-Token
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 10
        let body: [String: Any] = [
            "device": "ios-nianbao",
            "token": token,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            AionLogger.shared.log("apns token upload http=\(code)")
        } catch {
            AionLogger.shared.log("apns token upload failed: \(error.localizedDescription)")
        }
    }
}
