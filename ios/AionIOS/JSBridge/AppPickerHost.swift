import Foundation
import SwiftUI
import FamilyControls

/// 网页「选应用」→ 桥 → 触发 ContentView 的 SwiftUI sheet 弹层。
/// 用 sheet 内嵌 FamilyActivityPicker + 本地 @State（旧版原生页验证过的模式）——
/// 不用 .familyActivityPicker modifier（iOS 18.4+ 回归：isPresented/selection 绑定都不回写）。
@MainActor
final class AppPickerHost {
    static let shared = AppPickerHost()
    private init() {}

    func present(groupId: String?) async {
        let model = AppPickerModel.shared
        guard !model.isPresented else { return }   // 防重入
        let existing = groupId.flatMap { id in
            CommandExecutor.shared.loadGroups().first { $0.id == id }?.selection
        } ?? FamilyActivitySelection()
        await withCheckedContinuation { continuation in
            model.present(groupId: groupId, existing: existing) {
                // 完成/取消：把选择写回对应组（selection didSet 已实时落盘，这里双保险）
                if let groupId, !groupId.isEmpty {
                    var groups = CommandExecutor.shared.loadGroups()
                    if let index = groups.firstIndex(where: { $0.id == groupId }) {
                        groups[index].selection = AppPickerModel.shared.selection
                        CommandExecutor.shared.saveGroups(groups)
                    }
                }
                continuation.resume()
            }
        }
        AionJSBridge.shared.pushCache()
    }
}

/// 内嵌全屏覆盖层：FamilyActivityPicker 直接绑 model.selection。
/// 不经过 sheet/fullScreenCover 弹层容器（实测弹层里 selection 绑定不写回；
/// 内嵌形态 = 今天白天 LockView 验证过的可用模式）。
struct AppPickerOverlayView: View {
    @ObservedObject private var model = AppPickerModel.shared

    var body: some View {
        NavigationStack {
            FamilyActivityPicker(selection: $model.selection)
                .navigationTitle("选择要锁的应用")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { model.isPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { model.isPresented = false }
                    }
                }
        }
        .background(Color(.systemBackground))
    }
}
