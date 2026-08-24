import Foundation
import DeviceActivity
import FamilyControls

/// 阈值监控注册：每组一个 DeviceActivityName + 阈值事件（每日 schedule）。
/// 系统累计该组应用的使用时长，到阈值唤醒 MonitorExtension 施盾。
@MainActor
final class DeviceActivityRegistrar {
    static let shared = DeviceActivityRegistrar()
    private let center = DeviceActivityCenter()
    private init() {}

    private static var localCalendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = .current
        return calendar
    }

    // 显式带本地时区的 schedule/阈值组件——iOS 26 上不带时区会被按 UTC 解释，
    // 监控窗口整个偏移，eventDidReachThreshold 永不触发（社区实测根因）
    private static let schedule = DeviceActivitySchedule(
        intervalStart: DateComponents(calendar: Calendar.current, hour: 0, minute: 0),
        intervalEnd: DateComponents(calendar: Calendar.current, hour: 23, minute: 59),
        repeats: true
    )

    /// 组变化后全量重建监控（组数少，全量最稳）
    func sync(groups: [AionLockGroup]) {
        for activity in center.activities {
            center.stopMonitoring([activity])
        }
        for group in groups {
            let minutes = group.thresholdMinutes ?? 20
            guard minutes > 0 else { continue }   // 0 = 仅手动锁，不注册监控
            let selection = group.selection
            guard !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty
            else { continue }
            let events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [
                .init("threshold"): DeviceActivityEvent(
                    applications: selection.applicationTokens,
                    categories: selection.categoryTokens,
                    threshold: DateComponents(calendar: Self.localCalendar, minute: minutes)
                ),
            ]
            do {
                try center.startMonitoring(
                    .init(group.id), during: Self.schedule, events: events
                )
                AionLogger.shared.log(
                    "monitor registered: \(group.id) threshold=\(minutes)min apps=\(selection.applicationTokens.count)"
                )
            } catch {
                CommandExecutor.shared.lastStorageError =
                    "startMonitoring[\(group.displayName)]: \(error.localizedDescription)"
                AionLogger.shared.log("monitor FAILED for \(group.id): \(error.localizedDescription)")
            }
        }
        // 诊断：已注册的监控列表（网页诊断面板可见）
        CommandExecutor.shared.monitoredActivities =
            center.activities.map { $0.rawValue }.sorted()
        AionLogger.shared.log(
            "monitor sync done: groups=\(groups.count) registered=[\(CommandExecutor.shared.monitoredActivities.joined(separator: ","))]"
        )
    }

    /// 一次性探针监控：注册「下一分钟起、15 分钟止」的短 interval（repeats: false），
    /// 验证 iOS 26.6 上 intervalDidStart/DidEnd 回调是否被系统唤醒
    /// （threshold 事件线已实锤撞系统 bug，interval 线从未测过——正式 schedule 全天窗口要 0 点才回调）
    func registerProbe() {
        let probeName = DeviceActivityName("interval-probe")
        center.stopMonitoring([probeName])   // 幂等：先清掉旧的
        let cal = Self.localCalendar
        guard let start = cal.date(byAdding: .minute, value: 1, to: Date()),
              let end = cal.date(byAdding: .minute, value: 16, to: Date()) else { return }
        let startComp = cal.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: start)
        let endComp = cal.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: end)
        let probeSchedule = DeviceActivitySchedule(
            intervalStart: startComp, intervalEnd: endComp, repeats: false)
        do {
            try center.startMonitoring(probeName, during: probeSchedule)
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            AionLogger.shared.log(
                "probe registered: \(fmt.string(from: start))-\(fmt.string(from: end))"
            )
        } catch {
            AionLogger.shared.log("probe FAILED: \(error.localizedDescription)")
        }
    }
}
