import Foundation
import UIKit

/// 系统状态：电量/充电/低功耗/热状态/亮度/屏态/锁屏
/// 屏态锁屏双轨：公开 API 打底 + 私有 Darwin 通知增强（自签不上架可用）
/// kill switch：UserDefaults "sense.enablePrivateNotifications" = false 关私有轨
@MainActor
final class SenseSystem {
    static let shared = SenseSystem()

    struct State {
        var batteryLevel: Double?     // 0-1；-1/读不到 = nil
        var batteryState: String?     // charging/full/unplugged
        var lowPower: Bool
        var thermal: String           // nominal/fair/serious/critical
        var brightness: Double        // 0-1
        var screen: String?           // on/off
        var screenConfidence: Double
        var lock: String?             // locked/unlocked
        var lockConfidence: Double
    }

    private var screenOn: String?
    private var screenOnConf: Double = 0.7
    private var lockState: String?
    private var lockConf: Double = 0.5

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                       object: nil, queue: .main) { _ in
            Task { @MainActor in AionLogger.shared.log("sense battery state changed") }
        }
        nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                       object: nil, queue: .main) { _ in
            Task { @MainActor in AionLogger.shared.log("sense battery level changed") }
        }
        // 锁屏/解锁公开轨：仅设了开机密码的设备触发
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleProtectedWillBecomeUnavailable() }
        }
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleProtectedDidBecomeAvailable() }
        }
        installPrivateTrack()
    }

    /// App 回到前台：屏幕必然是亮的，且必然已解锁（打开 App 必经解锁）
    func noteAppActive() {
        screenOn = "on"
        screenOnConf = 0.7
        lockState = "unlocked"
        lockConf = 0.9
    }

    // MARK: - 公开轨

    private func handleProtectedWillBecomeUnavailable() {
        screenOn = "off"
        screenOnConf = 0.7
        lockState = "locked"
        lockConf = 0.7
        AionLogger.shared.log("sense public track: locked (protected unavailable)")
    }

    private func handleProtectedDidBecomeAvailable() {
        lockState = "unlocked"
        lockConf = 0.7
        AionLogger.shared.log("sense public track: unlocked")
    }

    // MARK: - 私有轨（Darwin 通知，iOS 26 投递待 Phase 2 实测）

    private func installPrivateTrack() {
        let enabled = UserDefaults.standard.object(
            forKey: "sense.enablePrivateNotifications") as? Bool ?? true
        guard enabled else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        // hasBlankedScreen：熄屏/点亮各发一次 → 收到即翻转
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in SenseSystem.shared.handleBlankedToggle() }
            },
            "com.apple.springboard.hasBlankedScreen" as CFString, nil,
            .deliverImmediately)
        // lockstate：锁/解锁各发一次 → 收到即翻转
        CFNotificationCenterAddObserver(
            center, nil,
            { _, _, _, _, _ in
                Task { @MainActor in SenseSystem.shared.handleLockToggle() }
            },
            "com.apple.springboard.lockstate" as CFString, nil,
            .deliverImmediately)
    }

    private func handleBlankedToggle() {
        screenOn = (screenOn == "on") ? "off" : "on"
        screenOnConf = 0.95
        AionLogger.shared.log("sense private: blanked -> \(screenOn ?? "nil")")
    }

    private func handleLockToggle() {
        lockState = (lockState == "locked") ? "unlocked" : "locked"
        lockConf = 0.95
        AionLogger.shared.log("sense private: lock -> \(lockState ?? "nil")")
    }

    // MARK: - 读取

    func read() -> State {
        let device = UIDevice.current
        var level: Double?
        if device.batteryLevel > 0 { level = Double(device.batteryLevel) }
        var state: String?
        switch device.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = nil
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "nominal"
        }
        // 实时校准 lock（2026-09-02）：翻转轨在 App 挂起时丢 Darwin 通知会漂移。
        // isProtectedDataAvailable 是绝对真实值——锁定=false、解锁=true；
        // 锁屏界面亮屏（未解锁）=false，恰好保留「亮屏+锁屏」这一真实状态。
        let realLock: String = UIApplication.shared.isProtectedDataAvailable ? "unlocked" : "locked"
        if lockState != realLock {
            lockState = realLock
            lockConf = 0.9
            AionLogger.shared.log("sense lock recalibrated -> \(realLock)")
        }
        return State(
            batteryLevel: level,
            batteryState: state,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: thermal,
            brightness: Double(UIScreen.main.brightness),
            screen: screenOn,
            screenConfidence: screenOnConf,
            lock: lockState,
            lockConfidence: lockConf
        )
    }
}
