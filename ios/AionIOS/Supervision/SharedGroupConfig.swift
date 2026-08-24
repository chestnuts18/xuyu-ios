import Foundation

/// 主 App 与 MonitorExtension 的共享配置（App Group UserDefaults）。
/// 主 App 每次组变化时写入；扩展读它施阈值盾/解盾。
struct SharedGroupConfig: Codable {
    var groups: [SharedGroup]

    static let suiteName = "group.com.chestnuts.aionios.lock"
    static let key = "shared_group_config"

    static func load() -> SharedGroupConfig {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(SharedGroupConfig.self, from: data)
        else { return SharedGroupConfig(groups: []) }
        return config
    }

    static func save(_ config: SharedGroupConfig) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: key)
        }
    }

    static func saveGroups(_ groups: [SharedGroup]) {
        save(SharedGroupConfig(groups: groups))
    }
}

/// 扩展可见的组摘要：id + 选择 + 阈值 + 锁状态
struct SharedGroup: Codable {
    var id: String
    var selectionRaw: Data?       // FamilyActivitySelection 的 JSON 编码
    var thresholdMinutes: Int
    var aiLocked: Bool            // AI 手动锁存在 → 扩展不解盾/不施阈值盾
    var thresholdLocked: Bool     // 阈值盾已施（扩展写，主 App 读来显示状态/清除）
    var lockDeadlineMs: Double?   // AI 锁到期时间（扩展判断锁是否仍有效）
}
