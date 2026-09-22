import SwiftUI
import BackgroundTasks
import WebKit

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

    /// 静默推送（2026-09-22）：闹铃到点时服务器把徐聿点的歌直接推过来，
    /// 这里用**原生播放器**放出去 —— 你睡着/锁屏时网页是冻住的，只有原生放得出来。
    /// ⚠️ 远程通知回调在场景化 App 里**是会被调用的**（不同于 applicationDidBecomeActive
    /// 那种激活回调，今晚刚踩过那个坑）。
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if let song = userInfo["aion_play_song"] as? [String: Any],
           let path = song["path"] as? String {
            AionSongPlayer.shared.play(
                path: path,
                title: song["title"] as? String,
                artist: song["artist"] as? String
            )
            completionHandler(.newData)
            return
        }
        completionHandler(.noData)
    }

    // ⚠️ 别在这里写 applicationDidBecomeActive 同步闹钟（2026-09-22 踩过）：
    //    本 App 是场景化（UIScene）的 SwiftUI App，AppDelegate 的这个回调
    //    **不会被调用** —— 装完包打开 App 毫无反应、服务器日志里一条 alarm 都没有。
    //    回前台事件一律走下面 body 里的 scenePhase。
}

@main
struct AionIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// 回前台事件：场景化 App 里只有这个靠得住（见 AppDelegate 里的注释）
    @Environment(\.scenePhase) private var scenePhase

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
                    // 基址切换后 WebView 跟随重载。
                    // 隧道 token 随候选变化（LAN/TS 空、CF 有）→ 重注册注入脚本
                    // （新 token 替换 {{AION_TOKEN}}）再 load 新基址，否则新页面
                    // 拿到的还是旧 token，CF 下 fetch/XHR 补不上头（2026-08-25）
                    APIClient.shared.onBaseURLChanged = { url in
                        guard let webView = AionJSBridge.shared.webView else { return }
                        let controller = webView.configuration.userContentController
                        controller.removeAllUserScripts()
                        controller.addUserScript(WKUserScript(
                            source: AionJSBridge.injectScript
                                .replacingOccurrences(of: "{{AION_TOKEN}}", with: APIClient.shared.currentToken ?? ""),
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: false
                        ))
                        // 2026-09-21：换线路时保留当前页面路径（/chat 换完还在 /chat）。
                        // 旧行为是 load 根地址 = 换一次线就从聊天页踢回图标主界面
                        //（9/20 晚上 28 分钟被踢 12 次，念宝报的「聊着聊着崩回主界面」）。
                        let target = APIClient.shared.urlPreservingPath(from: webView.url, base: url)
                        AionLogger.shared.log("webview routeReload \(target.absoluteString) (from \(webView.url?.absoluteString ?? "nil"))")
                        webView.load(URLRequest(url: target))
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
                    // 启动即同步一次系统闹钟（iOS 26+ 才有实际动作）
                    syncSystemAlarms(reason: "launch")
                    // 前台每 90 秒补一次：徐聿在聊天里设闹钟时 App 正在前台、scenePhase
                    // 压根不变，只靠回前台事件会漏掉（后台时定时器不触发，天然只在
                    // 合适的时候跑）。无变化时不刷日志。
                    Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { _ in
                        syncSystemAlarms(reason: "tick", quiet: true)
                    }
                    Task { await AionLogger.shared.flush() }
                }
                // 回前台再同步（从后台切回来、解锁后回到 App 都会走这里）。
                // ⚠️ iOS 16 兼容写法（单参数闭包）；iOS 17+ 上这个重载已废弃但仍可用。
                .onChange(of: scenePhase) { phase in
                    if phase == .active { syncSystemAlarms(reason: "scene") }
                    // 回前台收掉外出监控的画中画小窗（系统不会自己收，见模块内注释）
                    if phase == .active {
                        AionPhoneCameraModule.shared.dismissPictureInPictureIfActive()
                    }
                    // 网页的「App 在前台」标记 —— 监控页的手机预览靠它决定开不开摄像头
                    // （camera.html `_phoneAppForeground`）。安卓 WebViewActivity 一直在发
                    // （onResume/onPause），iOS 此前**从没发过** → 标记恒 false → 预览永远黑的
                    // （2026-09-22 查实：日志里进过监控页却一条 camera started 都没有）。
                    AionJSBridge.shared.callWebFunctionBool(
                        "onAionAppForegroundChanged", phase == .active)
                }
        }
    }
}
