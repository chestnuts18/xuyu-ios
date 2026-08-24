import Foundation
import Network

/// 网络类型：wifi/cellular/none（SSID 需 entitlement，留 Phase 3）
@MainActor
final class SenseNetwork {
    static let shared = SenseNetwork()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "aion.sense.network")
    private var cached = "unknown"

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let type: String
            if path.status != .satisfied {
                type = "none"
            } else if path.usesInterfaceType(.wifi) {
                type = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                type = "cellular"
            } else {
                type = "none"
            }
            Task { @MainActor in
                self?.cached = type
            }
        }
        monitor.start(queue: queue)
    }

    func read() -> String { cached }
}
