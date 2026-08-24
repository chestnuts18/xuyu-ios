import Foundation

/// 紧急解锁状态机（对齐安卓监管页语义）：
/// HOLDING（长按 8 秒）→ REASON_REQUIRED（填理由）→ WAITING（等待 5 秒）→ READY → confirm → COMPLETED
/// 网页每 500ms 读缓存 gate（getEmergencyGate），WAITING 倒计时由 ticker 推缓存。
@MainActor
final class EmergencyGate {
    static let shared = EmergencyGate()

    private(set) var gate: [String: Any] = [
        "phase": "IDLE", "heldMs": 0.0, "remainingDelayMs": 0.0, "error": "",
    ]

    private var holdStart: Date?
    private var targetGroupId: String = ""
    private var waitTask: Task<Void, Never>?
    private static let holdRequiredMs: Double = 8000
    private static let waitMs: Double = 5000

    private init() {}

    func handle(action: String, args: [String: Any]) -> [String: Any] {
        switch action {
        case "begin":
            guard phase == "IDLE" || phase == "CANCELLED" else { break }
            holdStart = Date()
            targetGroupId = args["targetGroupId"] as? String ?? args["groupId"] as? String ?? ""
            set(phase: "HOLDING", heldMs: 0, remainingDelayMs: 0, error: "")

        case "hold":
            let holding = args["holding"] as? Bool ?? true
            if !holding {
                // 松手：不足 8 秒取消；已到 REASON_REQUIRED 保持
                if phase == "HOLDING" {
                    set(phase: "IDLE", heldMs: 0, remainingDelayMs: 0, error: "")
                }
                break
            }
            guard phase == "HOLDING" else { break }
            let held = holdStart.map { Date().timeIntervalSince($0) * 1000 } ?? 0
            if held >= Self.holdRequiredMs {
                set(phase: "REASON_REQUIRED", heldMs: Self.holdRequiredMs, remainingDelayMs: 0, error: "")
            } else {
                set(phase: "HOLDING", heldMs: held, remainingDelayMs: 0, error: "")
            }

        case "reason":
            guard phase == "REASON_REQUIRED" else { break }
            set(phase: "WAITING", heldMs: Self.holdRequiredMs, remainingDelayMs: Self.waitMs, error: "")
            startWaitTicker()

        case "status":
            break  // 页面读缓存；WAITING 倒计时由 ticker 推

        case "confirm":
            guard phase == "READY" else { break }
            waitTask?.cancel()
            performUnlock()
            set(phase: "COMPLETED", heldMs: Self.holdRequiredMs, remainingDelayMs: 0, error: "")

        case "cancel":
            waitTask?.cancel()
            set(phase: "IDLE", heldMs: 0, remainingDelayMs: 0, error: "")

        default:
            break
        }
        AionJSBridge.shared.pushCache()
        return ["gate": gate]
    }

    private var phase: String { gate["phase"] as? String ?? "IDLE" }

    private func set(phase: String, heldMs: Double, remainingDelayMs: Double, error: String) {
        gate = ["phase": phase, "heldMs": heldMs, "remainingDelayMs": remainingDelayMs, "error": error]
    }

    /// WAITING 期间每秒递减 remainingDelayMs 并推缓存，到 0 转 READY
    private func startWaitTicker() {
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            var remaining = Self.waitMs
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.phase == "WAITING" else { return }
                remaining -= 1000
                self.gate["remainingDelayMs"] = max(0, remaining)
                AionJSBridge.shared.pushCache()
            }
            guard let self, self.phase == "WAITING" else { return }
            self.set(phase: "READY", heldMs: Self.holdRequiredMs, remainingDelayMs: 0, error: "")
            AionJSBridge.shared.pushCache()
        }
    }

    /// 全解锁（所有组 + 整机）
    private func performUnlock() {
        var groups = CommandExecutor.shared.loadGroups()
        for index in groups.indices {
            groups[index].lock = nil
            groups[index].temporaryUnlock = nil
            groups[index].effectiveState = "NORMAL"
            AionShieldStore.shared.removeLock(for: groups[index])
            // 阈值盾标记一并清（2026-08-19）：否则 loadGroups 合并逻辑会把它
            // 又渲染成 THRESHOLD_LOCKED，快照和真实盾状态不符
            CommandExecutor.shared.clearThresholdLock(groupId: groups[index].id)
        }
        _ = CommandExecutor.shared.apply(
            SupervisionCommand(
                commandId: UUID().uuidString,
                action: "device_unlock",
                groupId: "",
                minutes: nil,
                message: "",
                roleId: "aion",
                deviceId: nil,
                expiresAt: nil
            ),
            groups: &groups
        )
        CommandExecutor.shared.saveGroups(groups)
    }
}
