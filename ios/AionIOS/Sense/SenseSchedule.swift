import Foundation

/// 采集调度：夜间窗口 + tick 合并节流 + 心跳间隔（全部可配）
/// 念宝拍板：白天低频蹭唤醒，夜间 22:00-02:00 连续采样（2026-08-24）
@MainActor
final class SenseSchedule {
    static let shared = SenseSchedule()

    private init() {}

    var nightStartHour: Int {
        UserDefaults.standard.object(forKey: "sense.nightStartHour") as? Int ?? 22
    }
    var nightEndHour: Int {
        UserDefaults.standard.object(forKey: "sense.nightEndHour") as? Int ?? 2
    }

    var isNight: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        if nightStartHour < nightEndHour {
            return h >= nightStartHour && h < nightEndHour
        }
        return h >= nightStartHour || h < nightEndHour  // 跨零点窗口（22-02）
    }

    /// tick 最小间隔 30s：事件触发也受此约束，防传感器风暴
    private var lastTickAt: Date = .distantPast
    func allowTick() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= 30 else { return false }
        lastTickAt = now
        return true
    }

    /// 心跳间隔：白天 10 分钟 / 夜间 5 分钟 / 低电量 15 分钟
    /// 心跳 = 无条件重发未变值，维持服务器 30 分钟新鲜度窗口
    func heartbeatInterval(lowPower: Bool) -> TimeInterval {
        if lowPower { return 15 * 60 }
        return isNight ? 5 * 60 : 10 * 60
    }
}
