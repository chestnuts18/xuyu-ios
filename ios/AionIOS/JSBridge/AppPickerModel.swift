import Foundation
import FamilyControls

/// FamilyActivityPicker 弹层状态：ContentView 挂 .familyActivityPicker modifier 用。
/// 不用 UIHostingController 套娃 present——iOS 18.4+ 回归会让 picker 连容器一起崩。
@MainActor
final class AppPickerModel: ObservableObject {
    static let shared = AppPickerModel()

    @Published var isPresented = false
    // 用户在 picker 里点选时 binding 实时更新——didSet 立即落盘，
    // 不依赖弹层关闭的 isPresented 写回（iOS 18.4 回归下该写回可能不来）
    @Published var selection = FamilyActivitySelection() {
        didSet { persistSelectionIfNeeded() }
    }

    private var pendingGroupId: String?
    private var onDone: (() -> Void)?

    private init() {}

    private func persistSelectionIfNeeded() {
        guard let groupId = pendingGroupId, !groupId.isEmpty else { return }
        var groups = CommandExecutor.shared.loadGroups()
        if let index = groups.firstIndex(where: { $0.id == groupId }) {
            groups[index].selection = selection
            CommandExecutor.shared.saveGroups(groups)
        }
    }

    /// 打开选择器：回填该组已选应用；完成/取消都走 onDone
    func present(groupId: String?, existing: FamilyActivitySelection, onDone: @escaping () -> Void) {
        pendingGroupId = groupId
        selection = existing
        self.onDone = onDone
        isPresented = true
    }

    /// sheet 关闭收尾：等 picker 销毁时的 binding 写回完成，再落盘 + resume 桥调用
    func finish() {
        guard let done = onDone else { return }
        onDone = nil
        isPresented = false
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)   // 等 picker 销毁写回
            persistSelectionIfNeeded()                        // 用最新 selection 再落盘
            done()
        }
    }

    var groupId: String? { pendingGroupId }
}
