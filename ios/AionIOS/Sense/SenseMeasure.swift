import Foundation
import CoreMotion

/// 气压 + 配速（低频测量，DeviceSense 30 分钟门控后调用）
/// 气压走 CMAltimeter（kPa×10=hPa），配速走 CMPedometer 近 5 分钟平均（m/s）
/// 上报复用 AionHealthUploader（auto-export 通道，无 token，LAN 白名单）
@MainActor
final class SenseMeasure {
    static let shared = SenseMeasure()

    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private var lastPressure: Double?

    private init() {}

    /// 返回 (气压 hPa, 配速 m/s)；不可用为 nil
    func oneShot() async -> (pressure: Double?, pace: Double?) {
        var pressure: Double?
        var pace: Double?

        if CMAltimeter.isRelativeAltitudeAvailable() {
            pressure = await withCheckedContinuation { cont in
                altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                    self?.altimeter.stopRelativeAltitudeUpdates()
                    let kpa = data?.pressure.doubleValue
                    cont.resume(returning: kpa.map { $0 * 10 })  // kPa → hPa
                }
            }
        }
        if CMPedometer.isPaceAvailable() {
            pace = await withCheckedContinuation { cont in
                pedometer.queryPedometerData(
                    from: Date().addingTimeInterval(-300), to: Date()
                ) { data, _ in
                    cont.resume(returning: data?.averageActivePace?.doubleValue)
                }
            }
        }
        return (pressure, pace)
    }

    /// 气压弱信号门控（抄 HA BarometerObserver）：变化 <0.1 hPa 不报
    func shouldReportPressure(_ pressure: Double) -> Bool {
        defer { lastPressure = pressure }
        guard let last = lastPressure else { return true }
        return abs(pressure - last) >= 0.1
    }
}
