import Foundation
import FamilyControls
import ManagedSettings

/// 应用锁核心：FamilyControls 授权 + 选 App + 施盾/解盾
@MainActor
final class LockModel: ObservableObject {
    static let shared = LockModel()

    let store = ManagedSettingsStore()

    @Published var selection = FamilyActivitySelection()
    @Published var authorizationStatus: AuthorizationStatus = .notDetermined
    @Published var isLocked = false

    private init() {
        loadSelection()
        refreshStatus()
    }

    func refreshStatus() {
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
    }

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            // 念宝拒绝或系统失败——不强求，不锁就不锁～
        }
        refreshStatus()
    }

    func loadSelection() {
        guard let data = UserDefaults.standard.data(forKey: "selection"),
              let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return }
        selection = decoded
    }

    func saveSelection() {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        UserDefaults.standard.set(data, forKey: "selection")
    }

    func lock() {
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : ShieldSettings.ActivityCategoryPolicy.specific(selection.categoryTokens)
        isLocked = true
    }

    func unlock() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        isLocked = false
    }
}
