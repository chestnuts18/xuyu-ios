import Foundation
import FamilyControls
import ManagedSettings

/// 施盾/解盾：每组一个 named store（阈值锁与手动锁互不覆盖）
@MainActor
final class AionShieldStore {
    static let shared = AionShieldStore()
    private init() {}

    private func store(for groupId: String) -> ManagedSettingsStore {
        ManagedSettingsStore(named: ManagedSettingsStore.Name("aion." + groupId))
    }

    private var deviceStore: ManagedSettingsStore {
        ManagedSettingsStore(named: ManagedSettingsStore.Name("aion.device"))
    }

    func applyLock(for group: AionLockGroup) {
        let store = store(for: group.id)
        store.shield.applications = group.selection.applicationTokens.isEmpty
            ? nil : group.selection.applicationTokens
        store.shield.applicationCategories = group.selection.categoryTokens.isEmpty
            ? nil : .specific(group.selection.categoryTokens)
    }

    func removeLock(for group: AionLockGroup) {
        let store = store(for: group.id)
        store.shield.applications = nil
        store.shield.applicationCategories = nil
    }

    /// 整机锁 = 所有组的 selection 并集
    func applyDeviceLock(groups: [AionLockGroup]) {
        var tokens = Set<ApplicationToken>()
        var categories = Set<ActivityCategoryToken>()
        for group in groups {
            tokens.formUnion(group.selection.applicationTokens)
            categories.formUnion(group.selection.categoryTokens)
        }
        deviceStore.shield.applications = tokens.isEmpty ? nil : tokens
        deviceStore.shield.applicationCategories = categories.isEmpty
            ? nil : .specific(categories)
    }

    func removeDeviceLock() {
        deviceStore.shield.applications = nil
        deviceStore.shield.applicationCategories = nil
    }
}
