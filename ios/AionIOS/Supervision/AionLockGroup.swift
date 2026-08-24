import Foundation
import FamilyControls

/// 锁指令（对齐安卓 directiveJson：roleId/message/deadlineWallMs）
struct LockDirective: Codable, Equatable {
    var roleId: String
    var message: String
    var deadlineWallMs: Double
}

/// 应用组：FamilyActivitySelection + 锁状态，存 App Group（主 App 与 MonitorExtension 共享）
struct AionLockGroup: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var roleId: String = "aion"
    var thresholdMinutes: Int? = nil
    var selectionRaw: Data? = nil
    var lock: LockDirective? = nil
    var temporaryUnlock: LockDirective? = nil
    var effectiveState: String = "NORMAL"
    var roundUsageMs: Int = 0

    var selection: FamilyActivitySelection {
        get {
            guard let data = selectionRaw,
                  let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
            else { return FamilyActivitySelection() }
            return decoded
        }
        set {
            selectionRaw = try? JSONEncoder().encode(newValue)
        }
    }

    init(id: String = UUID().uuidString.lowercased(), displayName: String, selection: FamilyActivitySelection = FamilyActivitySelection()) {
        self.id = id
        self.displayName = displayName
        self.selection = selection
    }
}

/// 整机锁状态（存 App Group，主 App 与扩展共享）
struct DeviceLockState: Codable {
    var effectiveState: String = "NORMAL"
    var lock: LockDirective? = nil
    var temporaryUnlock: LockDirective? = nil
}
