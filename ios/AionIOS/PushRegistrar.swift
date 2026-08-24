import Foundation
import UIKit
import UserNotifications

/// APNs 注册：通知权限 + device token → 上报 Aion（/api/ios-push/register）
/// 徐聿主动发消息/夜间哨兵告警时，服务器经 APNs 推通知到 iPhone 通知栏。
@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()
    private var lastToken = ""

    private init() {}

    /// App 启动时调用：请求通知权限 → 注册 APNs
    func start() {
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
