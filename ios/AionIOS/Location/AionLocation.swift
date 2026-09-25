import Foundation
import CoreLocation

enum LocationError: Error, LocalizedError {
    case servicesDisabled
    case notAuthorized
    case timeout
    case superseded

    var errorDescription: String? {
        switch self {
        case .servicesDisabled: return "系统定位服务未开启"
        case .notAuthorized: return "定位权限未授予"
        case .timeout: return "定位超时"
        case .superseded: return "已被新的定位请求取代"
        }
    }
}

/// 定位上报：CoreLocation（WGS84）→ POST /api/location/heartbeat
/// 后端 process_heartbeat 已内置地理编码+天气+POI，iOS 只管发心跳
@MainActor
final class AionLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = AionLocation()

    private let manager = CLLocationManager()
    @Published var authStateText = "未授权"
    @Published var lastUploadInfo = "尚未上报"
    private var lastSentAt: Date = .distantPast

    // 单次定位（2026-09-25）：网页「同步位置」要一次实时坐标，绕开 240 秒自动上报节流
    private var onceWaiter: CheckedContinuation<CLLocation, Error>?
    private var onceTimeout: Task<Void, Never>?
    private var lastSyncPollAt: Date = .distantPast

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
            // 单次定位等待者优先：网页「同步位置」等的那一发不受 240 秒节流限制
            if let w = self.onceWaiter {
                self.onceWaiter = nil
                self.onceTimeout?.cancel()
                self.onceTimeout = nil
                w.resume(returning: loc)
            }
            let now = Date()
            // 定位回调 = 后台常驻唤醒源，顺带喂设备感知层（内部 30s 合并节流）
            DeviceSense.shared.tick("location")
            guard now.timeIntervalSince(self.lastSentAt) >= 240 else { return }
            self.lastSentAt = now
            await self.sendHeartbeat(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // 只处理单次定位的失败；常驻 startUpdatingLocation 的瞬时错误沿用系统重试
            guard let w = self.onceWaiter else { return }
            self.onceWaiter = nil
            self.onceTimeout?.cancel()
            self.onceTimeout = nil
            w.resume(throwing: error)
        }
    }

    // MARK: - 单次定位（网页「同步位置」/ 服务端请求）

    /// 立刻要一次当前位置。精度临时提到最高，超时 12 秒。
    func currentPosition(timeout: TimeInterval = 12) async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else { throw LocationError.servicesDisabled }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        default:
            throw LocationError.notAuthorized
        }
        // 上一发还没回来：先让它退出，避免 continuation 泄漏
        if let w = onceWaiter {
            onceWaiter = nil
            onceTimeout?.cancel()
            w.resume(throwing: LocationError.superseded)
        }

        let oldAccuracy = manager.desiredAccuracy
        manager.desiredAccuracy = kCLLocationAccuracyBest
        defer { manager.desiredAccuracy = oldAccuracy }

        return try await withCheckedThrowingContinuation { cont in
            onceWaiter = cont
            manager.requestLocation()
            onceTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self, let w = self.onceWaiter else { return }
                self.onceWaiter = nil
                w.resume(throwing: LocationError.timeout)
            }
        }
    }

    /// 服务端请求的立即同步（AionSupervisionPoller 每 15 秒调一次）：
    /// 命中标记 → 立刻定位 + 上报。网页「同步位置」在 App 外/旧版 App 时靠这条兜底。
    func pollServerSyncRequest() async {
        guard Date().timeIntervalSince(lastSyncPollAt) >= 8 else { return }
        lastSyncPollAt = Date()

        let url = APIClient.shared.url(for: "/api/location/pending-sync")
        var request = URLRequest(url: url)
        if let t = APIClient.shared.currentToken {  // 隧道候选时带 X-Aion-Token
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["pending"] as? Bool) == true else { return }
        } catch {
            return
        }

        do {
            let loc = try await currentPosition()
            lastSentAt = Date()          // 顺带压住自动上报，避免紧接着重复一发
            await sendHeartbeat(loc)
            lastUploadInfo = "已响应同步请求"
        } catch {
            lastUploadInfo = "同步请求失败：\(error.localizedDescription)"
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
