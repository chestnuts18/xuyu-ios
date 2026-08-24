import Foundation
import UIKit

/// 设备感知层门面：槽位状态机 + tick 调度 + 上报（契约对齐服务器 device_context.py）
/// 白天：蹭唤醒源低频快照 + 活动回查；夜间 22:00-02:00：1Hz 连续采样；低电量硬降级。
/// 状态槽位（battery/focus/audio/...）服务端 Phase 1b 扩展后生效，未扩展前被静默丢弃。
@MainActor
final class DeviceSense: ObservableObject {
    static let shared = DeviceSense()

    private struct Slot {
        var value: String
        var since: TimeInterval   // 值首次观察到的 epoch（服务器 changed 时采纳）
        var confidence: Double
    }

    private var slots: [String: Slot] = [:]
    private var started = false
    private var lastHeartbeatAt: Date = .distantPast
    private var lastMeasureAt: Double = 0
    private var tickTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastContinuousPosture: String?

    private init() {
        SenseAudio.shared.onChange = { [weak self] in
            self?.tick("audio-route")
        }
        // 夜间连续采样：姿态跳变（翻身/扣桌）→ 立即上报（受 30s tick 合并约束）
        SenseMotion.shared.onContinuousSample = { [weak self] posture, _, changed in
            guard let self, self.started, changed,
                  posture != self.lastContinuousPosture else { return }
            self.lastContinuousPosture = posture
            self.tick("posture-change")
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleForeground() }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        SenseFocus.shared.requestAuthIfNeeded()
        AionLogger.shared.log("sense started, night=\(SenseSchedule.shared.isNight)")
        handleForeground()
        // 前台 60s 心跳 Timer；后台挂起时由定位/健康/Poller 的 tick 携带
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick("timer") }
        }
        updateMode()
    }

    // MARK: - 唤醒源 tick（AionLocation / AionHealthKit / Poller / 前台共用）

    func tick(_ reason: String) {
        guard started, SenseSchedule.shared.allowTick(), tickTask == nil else { return }
        updateMode()
        tickTask = Task { [weak self] in
            await self?.performTick(reason: reason)
            self?.tickTask = nil
        }
    }

    private func handleForeground() {
        guard started else { return }
        SenseSystem.shared.noteAppActive()
        tick("foreground")
    }

    // MARK: - 模式切换（夜间连续采样 / 低电量硬降级）

    private func updateMode() {
        let sys = SenseSystem.shared.read()
        let lowPower = sys.lowPower || (sys.batteryLevel ?? 1.0) < 0.2
        if SenseSchedule.shared.isNight && !lowPower {
            SenseMotion.shared.startContinuous()
        } else {
            SenseMotion.shared.stopContinuous()
        }
    }

    // MARK: - tick 主体

    private func performTick(reason: String) async {
        let sys = SenseSystem.shared.read()
        let lowPower = sys.lowPower || (sys.batteryLevel ?? 1.0) < 0.2
        let now = Date()
        let nowEpoch = now.timeIntervalSince1970
        let dueHeartbeat = now.timeIntervalSince(lastHeartbeatAt)
            >= SenseSchedule.shared.heartbeatInterval(lowPower: lowPower)

        var changed: Set<String> = []

        func setSlot(_ key: String, _ value: String, _ conf: Double) {
            if var old = slots[key] {
                if old.value != value {
                    old = Slot(value: value, since: nowEpoch, confidence: conf)
                    changed.insert(key)
                } else if old.confidence != conf {
                    old.confidence = conf
                }
                slots[key] = old
            } else {
                slots[key] = Slot(value: value, since: nowEpoch, confidence: conf)
                changed.insert(key)
            }
        }

        // posture + RMS：连续模式复用滑动窗样本，否则一次性采样（约 2.4s）
        let sampled: (posture: String, rms: Double)
        if let last = SenseMotion.shared.lastWindowSample {
            sampled = last
        } else {
            sampled = await SenseMotion.shared.oneShot()
        }
        setSlot("posture", sampled.posture, 0.9)
        lastContinuousPosture = sampled.posture

        // motion：活动权威档优先；RMS>0.30 覆盖 strong；无权威档时纯 RMS 降置信
        let activity = await SenseActivity.shared.queryMotion()
        let motion: String
        let mConf: Double
        if sampled.rms > 0.30 {
            motion = "strong"; mConf = 0.9
        } else if let a = activity {
            motion = a.motion; mConf = a.confidence
        } else {
            motion = SenseMotion.classifyRMS(sampled.rms); mConf = 0.7
        }
        setSlot("motion", motion, mConf)

        // light：亮度代理；屏灭停报（残留亮度值是设置值，不反映环境）
        if sys.screen != "off" {
            let (light, lconf) = Self.classifyLight(sys.brightness)
            setSlot("light", light, lconf)
        }
        if let s = sys.screen { setSlot("screen", s, sys.screenConfidence) }

        // 状态槽位（Phase 1b 服务端扩展后生效；未扩展前被 update_phone 静默丢弃）
        if let lvl = sys.batteryLevel {
            setSlot("battery_level", String(Int((lvl * 100).rounded())), 1.0)
        }
        if let st = sys.batteryState { setSlot("battery_state", st, 1.0) }
        setSlot("low_power", sys.lowPower ? "on" : "off", 1.0)
        setSlot("thermal", sys.thermal, 1.0)
        if let f = SenseFocus.shared.read() { setSlot("focus", f, 1.0) }
        let audio = SenseAudio.shared.read()
        setSlot("audio_output", audio.output, 1.0)
        setSlot("audio_other", audio.otherAudio ? "on" : "off", 1.0)
        setSlot("network", SenseNetwork.shared.read(), 1.0)
        if let l = sys.lock { setSlot("lock_state", l, sys.lockConfidence) }

        // 上传：变化立即 / 心跳到点重发全部未变值（维持服务器 30 分钟新鲜度）
        guard !changed.isEmpty || dueHeartbeat else { return }
        lastHeartbeatAt = now
        let payload = slots.mapValues { slot in
            [
                "value": slot.value,
                "observed_at": nowEpoch,
                "since": slot.since,
                "confidence": slot.confidence,
            ] as [String: Any]
        }
        let ok = await SenseUploader.shared.upload(data: payload)
        if ok, !changed.isEmpty {
            AionLogger.shared.log(
                "sense changed=\(changed.sorted().joined(separator: ",")) reason=\(reason)")
        }

        // 气压/配速低频测量（30 分钟一次；气压变化 <0.1 hPa 不报，抄 HA 弱信号门控）
        if nowEpoch - lastMeasureAt >= 1800 {
            lastMeasureAt = nowEpoch
            let m = await SenseMeasure.shared.oneShot()
            var metrics: [[String: Any]] = []
            if let p = m.pressure, SenseMeasure.shared.shouldReportPressure(p) {
                metrics.append([
                    "type": "barometric_pressure", "value": round(p * 100) / 100,
                    "unit": "hPa", "recorded_at": nowEpoch, "source": "aion_ios_sense",
                ])
            }
            if let pace = m.pace {
                metrics.append([
                    "type": "active_pace", "value": round(pace * 100) / 100,
                    "unit": "m/s", "recorded_at": nowEpoch, "source": "aion_ios_sense",
                ])
            }
            if !metrics.isEmpty {
                _ = await AionHealthUploader.shared.upload(metrics: metrics)
            }
        }
    }

    /// 亮度代理 → light 槽位（限位饱和读数失真，降置信）
    nonisolated static func classifyLight(_ b: Double) -> (String, Double) {
        let conf = (b <= 0.01 || b >= 0.99) ? 0.3 : 0.5
        if b < 0.15 { return ("dark", conf) }
        if b < 0.35 { return ("dim", conf) }
        if b < 0.65 { return ("normal", conf) }
        return ("bright", conf)
    }
}
