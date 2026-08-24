import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation

/// 阈值自动锁：
/// - eventDidReachThreshold：系统累计该组应用使用时长到阈值 → 施盾（named store）
/// - intervalDidStart（每天 0 点）：解除昨天的阈值盾（AI 手动锁的组不动，由其到期逻辑管理）
/// 组配置从 App Group UserDefaults 读（主 App 每次组变化时写入）。
class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    /// 扩展进程日志上报（无法共享主 App 单例，独立实现；LAN 优先 TS 兜底）
    static func sendLog(_ tag: String, _ message: String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) \(message)"
        let payload: [String: Any] = ["device": "ios-nianbao", "tag": "ext." + tag, "lines": [line]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        for base in ["http://192.168.3.218:8080", "http://100.73.222.35:8080"] {
            guard let url = URL(string: base + "/api/ios-logs") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 6
            request.httpBody = body
            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
            _ = semaphore.wait(timeout: .now() + 6)
        }
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        Self.sendLog("intervalDidStart", "activity=\(activity.rawValue)")
        var config = SharedGroupConfig.load()
        var changed = false
        for index in config.groups.indices where config.groups[index].thresholdLocked {
            let group = config.groups[index]
            // AI 手动锁仍有效 → 保留盾（AI 锁到期由主 App reconcile 管理）
            if group.aiLocked, let deadline = group.lockDeadlineMs,
               deadline > Date().timeIntervalSince1970 * 1000 {
                continue
            }
            let store = Self.shieldStore(for: group.id)
            store.shield.applications = nil
            store.shield.applicationCategories = nil
            config.groups[index].thresholdLocked = false
            changed = true
        }
        if changed { SharedGroupConfig.save(config) }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        Self.sendLog("intervalDidEnd", "activity=\(activity.rawValue)")
        // 探针验证：只要这条日志出现在服务器，就证明 iOS 26.6 上 interval 回调活着
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        Self.sendLog("threshold", "FIRED activity=\(activity.rawValue) event=\(event.rawValue)")
        var config = SharedGroupConfig.load()
        guard let index = config.groups.firstIndex(where: { $0.id == activity.rawValue })
        else { return }
        let group = config.groups[index]
        // AI 手动锁期间：不施阈值盾、不动 AI 盾
        if group.aiLocked, let deadline = group.lockDeadlineMs,
           deadline > Date().timeIntervalSince1970 * 1000 {
            return
        }
        var selection = FamilyActivitySelection()
        if let data = group.selectionRaw,
           let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selection = decoded
        }
        guard !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty else { return }
        let store = Self.shieldStore(for: group.id)
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil : .specific(selection.categoryTokens)
        config.groups[index].thresholdLocked = true
        SharedGroupConfig.save(config)
        Self.sendLog("shield", "applied for \(group.id) tokens=\(selection.applicationTokens.count)")
    }

    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
    }

    override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventWillReachThresholdWarning(event, activity: activity)
    }

    private static func shieldStore(for groupId: String) -> ManagedSettingsStore {
        ManagedSettingsStore(named: .init("aion." + groupId))
    }
}
