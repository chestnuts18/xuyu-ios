import Foundation
import BackgroundTasks

/// 命令通道：前台 15s HTTP 轮询 + BGTask 后台兜底 + 启动 reconcile
@MainActor
final class AionSupervisionPoller: ObservableObject {
    static let shared = AionSupervisionPoller()

    @Published var lastPollInfo = "未启动"
    private var timer: Timer?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        CommandExecutor.shared.reconcile()
        // 阈值监控跟随当前组注册（App 升级/重装后重建）
        DeviceActivityRegistrar.shared.sync(groups: CommandExecutor.shared.loadGroups())
        // 探针监控（interval 回调验证，一次性）
        DeviceActivityRegistrar.shared.registerProbe()
        startTimer()
        Task { await tick() }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.tick()
            }
        }
    }

    func tick() async {
        // 15s 轮询 = 前台最高频唤醒源，顺带喂设备感知层（内部 30s 合并节流）
        DeviceSense.shared.tick("poller")
        // 远程查岗拍照：arm 后轮询徐聿的拍照命令（iOS 只能前台拍）
        await AionPhoneCameraModule.shared.pollIfArmed()
        // 锁到期自动解（2026-08-19）：reconcile 原来只在进程启动跑一次，锁到期后
        // 无人检查 deadline → 盾一直挂着（「只能锁不会解」bug）。15s 轮询内复检，
        // 对齐安卓 2s lock guard 语义；后台挂起时由 BGTask tick 兜底（≤15min）。
        CommandExecutor.shared.reconcile()
        let device = DeviceIdentity.deviceId
        if let commands = await AionSupervisionAPI.shared.fetchPending(device: device) {
            for command in commands {
                await executeAndAck(command)
            }
            lastPollInfo = "轮询正常 \(Date.now.formatted(date: .omitted, time: .standard))"
        } else {
            lastPollInfo = "连不上 Aion（网络通了吗）"
        }
        await reportState()
        // 快照推给网页监管页（同步读缓存）
        AionJSBridge.shared.pushCache()
    }

    private func executeAndAck(_ command: SupervisionCommand) async {
        // 幂等：本机已执行过同 commandId 直接回成功
        let executedKey = "executed_commands"
        var executed = UserDefaults.standard.stringArray(forKey: executedKey) ?? []
        let trimmed = executed.suffix(256)
        if trimmed.contains(command.commandId) {
            await AionSupervisionAPI.shared.ack(
                commandId: command.commandId, success: true, reason: "dup"
            )
            return
        }
        var groups = CommandExecutor.shared.loadGroups()
        let result = CommandExecutor.shared.apply(command, groups: &groups)
        await AionSupervisionAPI.shared.ack(
            commandId: command.commandId,
            success: result.success,
            reason: result.reason
        )
        executed = Array(trimmed) + [command.commandId]
        UserDefaults.standard.set(Array(executed.suffix(256)), forKey: executedKey)
    }

    private func reportState() async {
        let groups = CommandExecutor.shared.loadGroups()
        let payload = CommandExecutor.shared.buildSnapshotPayload(groups: groups)
        await AionSupervisionAPI.shared.reportState(payload: payload)
    }

    /// BGTask 注册（AionIOSApp 调用）
    static let bgTaskIdentifier = "com.chestnuts.aionios.refresh"

    func handleBackgroundTask(_ task: BGTask) {
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        Task { @MainActor in
            await tick()
            task.setTaskCompleted(success: true)
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
