import Foundation
import CoreLocation

/// 定位上报：CoreLocation（WGS84）→ POST /api/location/heartbeat
/// 后端 process_heartbeat 已内置地理编码+天气+POI，iOS 只管发心跳
@MainActor
final class AionLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = AionLocation()

    private let manager = CLLocationManager()
    @Published var authStateText = "未授权"
    @Published var lastUploadInfo = "尚未上报"
    private var lastSentAt: Date = .distantPast

    // 基址由 APIClient 探测（家里局域网优先）；heartbeat 无应用层 token（LAN/TS 白名单）
    private var endpoint: URL {
        APIClient.shared.url(for: "/api/location/heartbeat")
    }

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 200
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        refreshAuthText()
    }

    func refreshAuthText() {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            authStateText = "始终允许 ✅"
        case .authorizedWhenInUse:
            authStateText = "仅使用时（出门守护请改成始终允许）"
        case .denied, .restricted:
            authStateText = "已拒绝（去 设置→隐私与安全性→定位服务 打开）"
        default:
            authStateText = "未授权"
        }
    }

    func start() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            authStateText = "定位运行中 ✅"
        default:
            manager.requestAlwaysAuthorization()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        refreshAuthText()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            let now = Date()
            // 定位回调 = 后台常驻唤醒源，顺带喂设备感知层（内部 30s 合并节流）
            DeviceSense.shared.tick("location")
            guard now.timeIntervalSince(self.lastSentAt) >= 240 else { return }
            self.lastSentAt = now
            await self.sendHeartbeat(loc)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshAuthText()
            if manager.authorizationStatus == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }

    private func sendHeartbeat(_ loc: CLLocation) async {
        let payload: [String: Any] = [
            "lng": loc.coordinate.longitude,
            "lat": loc.coordinate.latitude,
            "accuracy": max(0, loc.horizontalAccuracy),
            "is_gcj02": false,
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = APIClient.shared.currentToken {  // 隧道候选时带 X-Aion-Token
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 15
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok {
                APIClient.shared.markVerified()
                lastUploadInfo = "刚上报成功"
            } else {
                APIClient.shared.noteFailure()
                lastUploadInfo = "上报失败（服务端拒绝）"
            }
        } catch {
            APIClient.shared.noteFailure()
            lastUploadInfo = "上报失败（网络通了吗）"
        }
    }
}
