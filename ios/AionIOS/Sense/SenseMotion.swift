import Foundation
import CoreMotion

/// 姿态（重力向量）+ 运动强度（userAcceleration RMS）
/// 裸 CMMotionManager 免权限；夜间 1Hz 连续采样复用同一实例
///
/// 重力约定（CMDeviceMotion）：手机平放正面朝上 → gravity ≈ (0,0,-1)；
/// 竖握（portrait）→ (0,-1,0)。主导轴阈值 0.6g。
@MainActor
final class SenseMotion {
    static let shared = SenseMotion()

    private let manager = CMMotionManager()
    private(set) var isContinuous = false
    private var continuousSamples: [(posture: String, rms: Double)] = []
    private let windowSize = 30  // 1Hz × 30s 滑动窗

    /// 连续采样事件：姿态跳变（翻身/扣桌）或每样本；DeviceSense 挂
    var onContinuousSample: ((_ posture: String, _ rms: Double, _ postureChanged: Bool) -> Void)?

    private init() {}

    /// 连续模式最近一窗（tick 复用，避免一次性采样与连续采样打架）
    var lastWindowSample: (posture: String, rms: Double)? {
        guard isContinuous, let last = continuousSamples.last else { return nil }
        return last
    }

    // MARK: - 一次性采样（白天低频 tick 用，约 2.4s 后返回）

    func oneShot() async -> (posture: String, rms: Double) {
        if isContinuous {
            if let last = continuousSamples.last { return last }
            return ("tilted", 0)
        }
        guard manager.isDeviceMotionAvailable else { return ("tilted", 0) }
        return await withCheckedContinuation { cont in
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            var gravities: [(Double, Double, Double)] = []
            var rmsValues: [Double] = []
            manager.deviceMotionUpdateInterval = 0.2
            manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
                guard let motion else { return }
                gravities.append((motion.gravity.x, motion.gravity.y, motion.gravity.z))
                let a = motion.userAcceleration
                rmsValues.append((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
                if gravities.count >= 12 {
                    Task { @MainActor in
                        self?.manager.stopDeviceMotionUpdates()
                        let g = Self.medianVector(gravities)
                        let rms = rmsValues.reduce(0, +) / Double(rmsValues.count)
                        cont.resume(returning: (Self.classifyPosture(g), rms))
                    }
                }
            }
        }
    }

    // MARK: - 夜间连续采样（1Hz，进程由常驻定位保活）

    func startContinuous() {
        guard manager.isDeviceMotionAvailable, !isContinuous else { return }
        isContinuous = true
        continuousSamples.removeAll()
        manager.deviceMotionUpdateInterval = 1.0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let motion else { return }
            let posture = Self.classifyPosture(
                (motion.gravity.x, motion.gravity.y, motion.gravity.z))
            let a = motion.userAcceleration
            let rms = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            Task { @MainActor in
                self?.handleContinuous(posture: posture, rms: rms)
            }
        }
    }

    func stopContinuous() {
        guard isContinuous else { return }
        manager.stopDeviceMotionUpdates()
        isContinuous = false
        continuousSamples.removeAll()
    }

    private func handleContinuous(posture: String, rms: Double) {
        // 姿态跳变检测：相邻 2 秒连续同类，之后变类 → 真翻身/扣桌（滤单样本抖动）
        var changed = false
        if let last = continuousSamples.last, last.posture != posture,
           continuousSamples.suffix(2).allSatisfy({ $0.posture == last.posture }) {
            changed = true
        }
        continuousSamples.append((posture, rms))
        if continuousSamples.count > windowSize {
            continuousSamples.removeFirst(continuousSamples.count - windowSize)
        }
        onContinuousSample?(posture, rms, changed)
    }

    // MARK: - 纯函数（队列回调里可直接调）

    /// 3 样本重力取中值，抗单样本毛刺
    nonisolated static func medianVector(
        _ samples: [(Double, Double, Double)]
    ) -> (Double, Double, Double) {
        guard !samples.isEmpty else { return (0, 0, -1) }
        let xs = samples.map { $0.0 }.sorted()
        let ys = samples.map { $0.1 }.sorted()
        let zs = samples.map { $0.2 }.sorted()
        let mid = samples.count / 2
        return (xs[mid], ys[mid], zs[mid])
    }

    /// 重力主导轴 → 服务器 posture 枚举（值域严格对齐 device_context.py）
    /// landscape 左右符号待真机校准（Phase 2），先报通用 landscape
    nonisolated static func classifyPosture(_ g: (Double, Double, Double)) -> String {
        let (x, y, z) = g
        let ax = abs(x), ay = abs(y), az = abs(z)
        if az > 0.6 && az >= ax && az >= ay {
            return z < 0 ? "face_up" : "face_down"
        }
        if ay > 0.6 && ay >= ax && ay >= az {
            return y < 0 ? "portrait" : "portrait_upside_down"
        }
        if ax > 0.6 && ax > ay && ax > az {
            return "landscape"
        }
        return "tilted"
    }

    /// RMS → 服务器 motion 枚举（活动权威档缺席时的兜底）
    nonisolated static func classifyRMS(_ rms: Double) -> String {
        if rms > 0.30 { return "strong" }
        if rms >= 0.10 { return "moving" }
        if rms >= 0.03 { return "slight" }
        return "still"
    }
}
