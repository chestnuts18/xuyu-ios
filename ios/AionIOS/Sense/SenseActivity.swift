import Foundation
import CoreMotion

/// 运动状态权威档：运动协处理器 24h 自记账，回查最近 10 分钟窗口
/// （零常驻耗电，抄 HA ActivitySensor；需 NSMotionUsageDescription）
@MainActor
final class SenseActivity {
    static let shared = SenseActivity()

    private let activityManager = CMMotionActivityManager()

    private init() {}

    /// 返回 (motion, confidence)；未授权/不可用 → nil（调用方降级纯 RMS）
    /// iOS 26.6 authorizationStatus 读值有 bug（HealthKit 同款坑）——
    /// 不信任读值，直接查询，报错即视为不可用
    func queryMotion() async -> (motion: String, confidence: Double)? {
        guard CMMotionActivityManager.isActivityAvailable() else { return nil }
        let from = Date().addingTimeInterval(-600)
        let to = Date()
        return await withCheckedContinuation { cont in
            activityManager.queryActivityStarting(
                from: from, to: to, to: .main
            ) { activities, error in
                guard error == nil, let last = activities?.last else {
                    cont.resume(returning: nil)
                    return
                }
                let motion: String
                if last.stationary {
                    motion = "still"
                } else if last.walking || last.cycling {
                    motion = "slight"
                } else if last.running || last.automotive {
                    motion = "moving"
                } else {
                    motion = "still"  // unknown：默认 still，低置信
                }
                let conf: Double
                switch last.confidence {
                case .high: conf = 0.9
                case .medium: conf = 0.7
                default: conf = 0.5
                }
                cont.resume(returning: (motion, conf))
            }
        }
    }
}
