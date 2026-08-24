import Foundation
import UIKit
import FamilyControls

/// 监管桥：网页 ↔ 本地监管能力（镜像安卓 app-supervision 页 nativeCall 语义）
@MainActor
final class SupervisionBridge {
    static let shared = SupervisionBridge()
    private init() {}

    func handle(action: String, args: [String: Any]) async -> Any? {
        switch action {
        case "createGroupWithPicker":
            // 对齐安卓逻辑：直接选应用一步建组。iOS 拿不到 App 名（token 无名称 API），
            // 默认「应用组 N」+ 选完弹组名输入（徐聿靠这个名字知道锁的是什么 App）
            let groupId = UUID().uuidString.lowercased()
            var groups = CommandExecutor.shared.loadGroups()
            let autoName = "应用组 \(groups.count + 1)"
            groups.append(AionLockGroup(id: groupId, displayName: autoName))
            CommandExecutor.shared.saveGroups(groups)
            await AppPickerHost.shared.present(groupId: groupId)
            let displayName = await Self.askGroupName(defaultValue: autoName)
            var updated = CommandExecutor.shared.loadGroups()
            if let index = updated.firstIndex(where: { $0.id == groupId }) {
                updated[index].displayName = displayName
                CommandExecutor.shared.saveGroups(updated)
            }
            AionJSBridge.shared.pushCache()
            return ["ok": true, "groupId": groupId, "displayName": displayName]

        case "getSnapshotFresh":
            // 网页打开瞬间缓存可能还没推——原生立即构建快照并推缓存
            let snapshot = CommandExecutor.shared.buildSnapshotPayload(
                groups: CommandExecutor.shared.loadGroups()
            )
            AionJSBridge.shared.pushCache()
            return snapshot

        case "requestAuth":
            await LockModel.shared.requestAuthorization()
            return ["approved": LockModel.shared.authorizationStatus == .approved]

        case "upsertGroup":
            let groupId = args["groupId"] as? String ?? UUID().uuidString.lowercased()
            let displayName = args["displayName"] as? String ?? "应用组"
            var groups = CommandExecutor.shared.loadGroups()
            if let index = groups.firstIndex(where: { $0.id == groupId }) {
                groups[index].displayName = displayName
                // JS 数字经 WKScriptMessage 到 Swift 是 NSNumber——as? Int 会失败
                if let thresholdNum = args["thresholdMinutes"] as? NSNumber {
                    groups[index].thresholdMinutes = max(0, thresholdNum.intValue)
                }
            } else {
                var group = AionLockGroup(id: groupId, displayName: displayName)
                if let thresholdNum = args["thresholdMinutes"] as? NSNumber {
                    let threshold = thresholdNum.intValue
                    if threshold > 0 { group.thresholdMinutes = threshold }
                }
                groups.append(group)
            }
            CommandExecutor.shared.saveGroups(groups)
            AionJSBridge.shared.pushCache()
            // 诊断返回：桥收到什么、存下什么（阈值保存问题的定位）
            let saved = CommandExecutor.shared.loadGroups().first(where: { $0.id == groupId })
            AionLogger.shared.log(
                "upsertGroup: rawThreshold=\(String(describing: args["thresholdMinutes"])) saved=\(saved?.thresholdMinutes ?? -1)"
            )
            return [
                "ok": true, "groupId": groupId,
                "thresholdMinutes": saved?.thresholdMinutes ?? 0,
                "rawThreshold": args["thresholdMinutes"] ?? "missing",
            ]

        case "setThreshold":
            // 卡片按钮直接改阈值（绕开 WKWebView 输入框 value 不同步的坑）
            guard let groupId = args["groupId"] as? String,
                  let minutesNum = args["minutes"] as? NSNumber else {
                return ["ok": false, "reason": "missing_args"]
            }
            var groups = CommandExecutor.shared.loadGroups()
            guard let index = groups.firstIndex(where: { $0.id == groupId }) else {
                return ["ok": false, "reason": "unknown_group"]
            }
            let minutes = max(0, min(120, minutesNum.intValue))
            groups[index].thresholdMinutes = minutes
            CommandExecutor.shared.saveGroups(groups)
            AionJSBridge.shared.pushCache()
            return ["ok": true, "thresholdMinutes": groups[index].thresholdMinutes ?? 0]

        case "removeGroup":
            guard let groupId = args["groupId"] as? String else {
                return ["ok": false, "reason": "missing_groupId"]
            }
            var groups = CommandExecutor.shared.loadGroups()
            groups.removeAll { $0.id == groupId }
            CommandExecutor.shared.saveGroups(groups)
            AionJSBridge.shared.pushCache()
            return ["ok": true]

        case "pickApps":
            let groupId = args["groupId"] as? String
            await AppPickerHost.shared.present(groupId: groupId)
            return ["ok": true, "groupId": groupId as Any]

        case "debugSetLock", "debugSetTemporaryUnlock", "debugRemoveLock":
            guard let groupId = args["groupId"] as? String else {
                return ["ok": false, "reason": "missing_groupId"]
            }
            let cmdAction: String
            switch action {
            case "debugSetLock": cmdAction = "lock"
            case "debugSetTemporaryUnlock": cmdAction = "temp_unlock"
            default: cmdAction = "unlock"
            }
            var groups = CommandExecutor.shared.loadGroups()
            let result = CommandExecutor.shared.apply(
                SupervisionCommand(
                    commandId: UUID().uuidString,
                    action: cmdAction,
                    groupId: groupId,
                    minutes: (args["minutes"] as? NSNumber)?.intValue,
                    message: args["message"] as? String ?? "",
                    roleId: args["roleId"] as? String ?? "aion",
                    deviceId: nil,
                    expiresAt: nil
                ),
                groups: &groups
            )
            AionJSBridge.shared.pushCache()
            return ["ok": result.success, "reason": result.reason]

        case "emergencyAction":
            // 紧急解锁状态机（对齐安卓语义：长按→理由→等待→确认）
            let innerAction = args["action"] as? String ?? "status"
            return EmergencyGate.shared.handle(action: innerAction, args: args)

        case "setFeatureEnabled":
            UserDefaults.standard.set(
                args["enabled"] as? Bool ?? false,
                forKey: "supervision_feature_enabled"
            )
            AionJSBridge.shared.pushCache()
            return ["ok": true]

        default:
            return nil
        }
    }

    /// 选完应用后弹组名输入——iOS 拿不到 App 名，徐聿靠组名知道锁的是什么
    private static func askGroupName(defaultValue: String) async -> String {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "给这个组起个名字",
                message: "徐聿会看到这个名字，建议写应用名（如：抖音）",
                preferredStyle: .alert
            )
            alert.addTextField { field in
                field.placeholder = defaultValue
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                continuation.resume(returning: defaultValue)
            })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
                let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
                continuation.resume(returning: name.isEmpty ? defaultValue : name)
            })
            var topVC = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first?.rootViewController
            while let presented = topVC?.presentedViewController { topVC = presented }
            if let topVC {
                topVC.present(alert, animated: true)
            } else {
                continuation.resume(returning: defaultValue)
            }
        }
    }
}
