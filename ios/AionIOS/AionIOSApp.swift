import SwiftUI
import BackgroundTasks

/// APNs 回调：拿到 device token 后经 PushRegistrar 上报 Aion
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistrar.shared.handleToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushRegistrar.shared.handleTokenFailure(error)
    }
}

@main
struct AionIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // BGTask 注册：后台兜底轮询（iOS 按系统调度，预期 15 分钟~数小时一次）
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AionSupervisionPoller.bgTaskIdentifier,
            using: nil
        ) { task in
            AionSupervisionPoller.shared.handleBackgroundTask(task)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // 网络层：探测家里局域网/出门 Tailscale
                    APIClient.shared.start()
                    // 基址切换后 WebView 跟随重载
                    APIClient.shared.onBaseURLChanged = { url in
                        guard let webView = AionJSBridge.shared.webView else { return }
                        webView.load(URLRequest(url: url))
                    }
                    // 后台能力：监管轮询 + 健康上报循环 + 定位心跳（不依赖网页打开）
                    PushRegistrar.shared.start()
                    AionSupervisionPoller.shared.start()
                    AionSupervisionPoller.shared.scheduleBackgroundRefresh()
                    // 回前台重读 HealthKit 授权（用户在系统设置改开关后缓存不刷新）
                    AionHealthKit.shared.refreshAuthStatus()
                    AionHealthKit.shared.startForegroundLoop()
                    AionLocation.shared.start()
                    // 设备感知层：姿态/运动/光线/屏态 + 状态槽位（蹭上述唤醒源 tick）
                    DeviceSense.shared.start()
                    // 屏幕使用时间授权检查：重装 App 可能重置授权，丢失时自动弹申请
                    // （授权丢失时 FamilyActivityPicker 能看到能勾但选择不写回）
                    AionLogger.shared.log("app started, familyAuth=\(LockModel.shared.authorizationStatus)")
                    if LockModel.shared.authorizationStatus != .approved {
                        Task { await LockModel.shared.requestAuthorization() }
                    }
                    Task { await AionLogger.shared.flush() }
                }
        }
    }
}
