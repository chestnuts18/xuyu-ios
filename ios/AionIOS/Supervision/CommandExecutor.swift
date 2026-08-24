import Foundation

/// 命令执行（对齐安卓 AppSupervisionRuntime.applyAiCommand 语义）
@MainActor
final class CommandExecutor {
    static let shared = CommandExecutor()

    private(set) var deviceLockState = DeviceLockState()
    private var deviceRelockTask: Task<Void, Never>?
    /// 存储错误诊断（编码/解码失败时记录，网页诊断面板显示）
    var lastStorageError: String?
    /// 已注册的 DeviceActivity 监控列表（诊断）
    var monitoredActivities: [String] = []

    private init() {
        loadDeviceLockState()
    }

    // MARK: - 持久化

    private var groupDefaults: UserDefaults {
        // App Groups entitlement 未启用（B0 移除）——suiteName 会返回「无效实例」
        // 且读写不落盘（?? 兜底永不触发），直接标准域。将来启用 App Groups 再改回。
        UserDefaults.standard
    }

    func saveGroups(_ groups: [AionLockGroup]) {
        do {
            let data = try JSONEncoder().encode(groups)
            groupDefaults.set(data, forKey: "groups")
            lastStorageError = nil
        } catch {
            lastStorageError = "saveGroups: \(error.localizedDescription)"
            return
        }
        syncSharedConfig(groups)
        // 阈值监控注册跟随组变化（组数少，全量重建最稳）
        DeviceActivityRegistrar.shared.sync(groups: groups)
    }

    func loadGroups() -> [AionLockGroup] {
        guard let data = groupDefaults.data(forKey: "groups") else { return [] }
        do {
            var decoded = try JSONDecoder().decode([AionLockGroup].self, from: data)
            // 合并扩展写的阈值锁定状态（thresholdLocked && 无 AI 锁 → 计时锁定）
            let flags = loadSharedThresholdFlags()
            for i in decoded.indices
            where flags[decoded[i].id] == true && decoded[i].lock == nil {
                decoded[i].effectiveState = "THRESHOLD_LOCKED"
            }
            return decoded
        } catch {
            lastStorageError = "loadGroups: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - App Group 共享配置（主 App ↔ MonitorExtension）

    private func loadSharedThresholdFlags() -> [String: Bool] {
        var flags: [String: Bool] = [:]
        for group in SharedGroupConfig.load().groups {
            flags[group.id] = group.thresholdLocked
        }
        return flags
    }

    /// 组变化后同步共享配置（保留扩展写的 thresholdLocked 标记）
    private func syncSharedConfig(_ groups: [AionLockGroup]) {
        let flags = loadSharedThresholdFlags()
        let shared: [SharedGroup] = groups.map { group in
            SharedGroup(
                id: group.id,
                selectionRaw: group.selectionRaw,
                thresholdMinutes: group.thresholdMinutes ?? 20,
                aiLocked: group.lock != nil,
                thresholdLocked: flags[group.id] ?? false,
                lockDeadlineMs: group.lock?.deadlineWallMs
            )
        }
        SharedGroupConfig.saveGroups(shared)
    }

    /// 手动解除时清阈值盾标记（扩展第二天 0 点前的当日恢复入口）
    func clearThresholdLock(groupId: String) {
        var config = SharedGroupConfig.load()
        if let index = config.groups.firstIndex(where: { $0.id == groupId }) {
            config.groups[index].thresholdLocked = false
            SharedGroupConfig.save(config)
        }
    }

    private func saveDeviceLockState() {
        do {
            let data = try JSONEncoder().encode(deviceLockState)
            groupDefaults.set(data, forKey: "deviceLockState")
            lastStorageError = nil
        } catch {
            lastStorageError = "saveDeviceLockState: \(error.localizedDescription)"
        }
    }

    private func loadDeviceLockState() {
        guard let data = groupDefaults.data(forKey: "deviceLockState") else { return }
        do {
            deviceLockState = try JSONDecoder().decode(DeviceLockState.self, from: data)
        } catch {
            lastStorageError = "loadDeviceLockState: \(error.localizedDescription)"
        }
    }

    // MARK: - 命令执行

    /// 返回 (success, reason)；groups 原地更新
    func apply(
        _ command: SupervisionCommand,
        groups: inout [AionLockGroup]
    ) -> (success: Bool, reason: String) {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let minutes = max(1, min(120, command.minutes ?? 30))
        let deadline = nowMs + Double(minutes) * 60_000

        switch command.action {
        case "lock":
            guard let index = groups.firstIndex(where: { $0.id == command.groupId }) else {
                return (false, "unknown_group")
            }
            // 空盾保护：组里没选应用时明确反馈，不再「显示锁定但锁不上」
            if groups[index].selection.applicationTokens.isEmpty,
               groups[index].selection.categoryTokens.isEmpty {
                return (false, "empty_selection")
            }
            groups[index].lock = LockDirective(
                roleId: command.roleId ?? "aion",
                message: command.message ?? "",
                deadlineWallMs: deadline
            )
            groups[index].temporaryUnlock = nil
            groups[index].effectiveState = "LOCKED"
            AionShieldStore.shared.applyLock(for: groups[index])
            saveGroups(groups)
            return (true, "")

        case "temp_unlock":
            guard let index = groups.firstIndex(where: { $0.id == command.groupId }) else {
                return (false, "unknown_group")
            }
            if groups[index].selection.applicationTokens.isEmpty,
               groups[index].selection.categoryTokens.isEmpty {
                return (false, "empty_selection")
            }
            groups[index].temporaryUnlock = LockDirective(
                roleId: command.roleId ?? "aion",
                message: command.message ?? "",
                deadlineWallMs: deadline
            )
            groups[index].effectiveState = "TEMPORARILY_UNLOCKED"
            AionShieldStore.shared.removeLock(for: groups[index])
            saveGroups(groups)
            scheduleGroupRelock(groupId: groups[index].id, deadlineMs: deadline)
            return (true, "")

        case "unlock":
            guard let index = groups.firstIndex(where: { $0.id == command.groupId }) else {
                return (false, "unknown_group")
            }
            groups[index].lock = nil
            groups[index].temporaryUnlock = nil
            groups[index].effectiveState = "NORMAL"
            AionShieldStore.shared.removeLock(for: groups[index])
            clearThresholdLock(groupId: command.groupId)   // 阈值盾一并解除
            saveGroups(groups)
            return (true, "")

        case "device_lock":
            deviceLockState = DeviceLockState(
                effectiveState: "LOCKED",
                lock: LockDirective(
                    roleId: command.roleId ?? "aion",
                    message: command.message ?? "",
                    deadlineWallMs: deadline
                ),
                temporaryUnlock: nil
            )
            AionShieldStore.shared.applyDeviceLock(groups: groups)
            saveDeviceLockState()
            return (true, "")

        case "device_temp_unlock":
            deviceLockState = DeviceLockState(
                effectiveState: "TEMPORARILY_UNLOCKED",
                lock: deviceLockState.lock,
                temporaryUnlock: LockDirective(
                    roleId: command.roleId ?? "aion",
                    message: command.message ?? "",
                    deadlineWallMs: deadline
                )
            )
            AionShieldStore.shared.removeDeviceLock()
            saveDeviceLockState()
            scheduleDeviceRelock(deadlineMs: deadline)
            return (true, "")

        case "device_unlock":
            deviceLockState = DeviceLockState()
            AionShieldStore.shared.removeDeviceLock()
            saveDeviceLockState()
            return (true, "")

        default:
            return (false, "unknown_action")
        }
    }

    // MARK: - 到期回锁 / 解盾（前台计时兜底；后台由 reconcile 兜底）

    private func scheduleGroupRelock(groupId: String, deadlineMs: Double) {
        let wait = max(1, deadlineMs - Date().timeIntervalSince1970 * 1000) / 1000
        Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            var groups = loadGroups()
            guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
            let temp = groups[index].temporaryUnlock
            let deadlinePassed = (temp?.deadlineWallMs ?? 0) <= Date().timeIntervalSince1970 * 1000
            if deadlinePassed, groups[index].lock != nil {
                groups[index].temporaryUnlock = nil
                groups[index].effectiveState = "LOCKED"
                AionShieldStore.shared.applyLock(for: groups[index])
                saveGroups(groups)
            }
        }
    }

    private func scheduleDeviceRelock(deadlineMs: Double) {
        let wait = max(1, deadlineMs - Date().timeIntervalSince1970 * 1000) / 1000
        deviceRelockTask?.cancel()
        deviceRelockTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            let temp = deviceLockState.temporaryUnlock
            let deadlinePassed = (temp?.deadlineWallMs ?? 0) <= Date().timeIntervalSince1970 * 1000
            if deadlinePassed, deviceLockState.lock != nil {
                deviceLockState.effectiveState = "LOCKED"
                deviceLockState.temporaryUnlock = nil
                AionShieldStore.shared.applyDeviceLock(groups: loadGroups())
                saveDeviceLockState()
            }
        }
    }

    /// 启动/唤醒时 reconcile：过期锁自动解除、临时解锁到期自动回锁
    func reconcile() {
        let nowMs = Date().timeIntervalSince1970 * 1000
        var groups = loadGroups()
        var changed = false
        for index in groups.indices {
            // 临时解锁到期 → 回锁（lock 还在）
            if groups[index].effectiveState == "TEMPORARILY_UNLOCKED",
               (groups[index].temporaryUnlock?.deadlineWallMs ?? 0) <= nowMs,
               groups[index].lock != nil {
                groups[index].temporaryUnlock = nil
                groups[index].effectiveState = "LOCKED"
                AionShieldStore.shared.applyLock(for: groups[index])
                changed = true
            }
            // 锁过期 → 自动解除
            if groups[index].effectiveState == "LOCKED",
               (groups[index].lock?.deadlineWallMs ?? 0) <= nowMs {
                groups[index].lock = nil
                groups[index].effectiveState = "NORMAL"
                AionShieldStore.shared.removeLock(for: groups[index])
                changed = true
            }
        }
        if changed { saveGroups(groups) }

        // 整机锁 reconcile
        let temp = deviceLockState.temporaryUnlock
        let deadlinePassed = (temp?.deadlineWallMs ?? 0) <= nowMs
        if deviceLockState.effectiveState == "TEMPORARILY_UNLOCKED",
           deadlinePassed, deviceLockState.lock != nil {
            deviceLockState.effectiveState = "LOCKED"
            deviceLockState.temporaryUnlock = nil
            AionShieldStore.shared.applyDeviceLock(groups: groups)
            saveDeviceLockState()
        }
        if deviceLockState.effectiveState == "LOCKED",
           (deviceLockState.lock?.deadlineWallMs ?? 0) <= nowMs {
            deviceLockState = DeviceLockState()
            AionShieldStore.shared.removeDeviceLock()
            saveDeviceLockState()
        }
    }

    /// 构建后端快照（对齐安卓 buildStatePayload；iOS 无计时概念的字段给默认值）
    func buildSnapshotPayload(groups: [AionLockGroup]) -> [String: Any] {
        let groupDicts: [[String: Any]] = groups.map { group in
            [
                "groupId": group.id,
                "displayName": group.displayName,
                "roleId": group.roleId,
                "roundUsageMs": group.roundUsageMs,
                "foregroundOpen": false,
                "effectiveState": group.effectiveState,
                "lock": group.lock.map { ["roleId": $0.roleId, "message": $0.message, "deadlineWallMs": $0.deadlineWallMs] } as Any,
                "temporaryUnlock": group.temporaryUnlock.map { ["roleId": $0.roleId, "message": $0.message, "deadlineWallMs": $0.deadlineWallMs] } as Any,
                // iOS 无计时监管，给网页渲染用的静态值
                "idleMinutes": 30,
                "checkpointsMinutes": [20, 40],
                "monitored": true,
                "packageNames": [] as [String],
                "applicationCount": group.selection.applicationTokens.count + group.selection.categoryTokens.count,
                "thresholdMinutes": group.thresholdMinutes ?? 20,
            ]
        }
        var payload: [String: Any] = [
            "deviceId": DeviceIdentity.deviceId,
            "deviceName": DeviceIdentity.deviceName,
            "eventId": "ios-\(Int(Date().timeIntervalSince1970 * 1000))-snapshot",
            "eventType": "snapshot",
            "triggerGroupId": "",
            "checkpointMinutes": 0,
            "groups": groupDicts,
            "featureEnabled": true,
            "recoveryState": "IDLE",
            "logs": [] as [[String: Any]],
            "storageError": lastStorageError as Any,
            "monitoredActivities": monitoredActivities,
        ]
        if deviceLockState.effectiveState != "NORMAL" || deviceLockState.lock != nil {
            payload["deviceLock"] = [
                "effectiveState": deviceLockState.effectiveState,
                "lock": deviceLockState.lock.map { ["roleId": $0.roleId, "message": $0.message, "deadlineWallMs": $0.deadlineWallMs] } as Any,
                "temporaryUnlock": deviceLockState.temporaryUnlock.map { ["roleId": $0.roleId, "message": $0.message, "deadlineWallMs": $0.deadlineWallMs] } as Any,
            ]
        }
        return payload
    }
}
