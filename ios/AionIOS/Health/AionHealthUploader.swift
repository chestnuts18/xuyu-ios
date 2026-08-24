import Foundation

/// POST /api/health/auto-export —— Aion 后端零改动的健康接收通道
@MainActor
final class AionHealthUploader {
    static let shared = AionHealthUploader()

    private init() {}

    // auto-export 走 nginx LAN/TS 白名单，无需 token；基址由 APIClient 探测（家里局域网优先）
    private var endpoint: URL {
        APIClient.shared.url(for: "/api/health/auto-export")
    }

    func upload(metrics: [[String: Any]]) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = APIClient.shared.currentToken {  // 隧道候选时带 X-Aion-Token
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 20
        do {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["metrics": metrics]
            )
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = code == 200
            if ok {
                APIClient.shared.markVerified()
            } else {
                APIClient.shared.noteFailure()
            }
            AionLogger.shared.log("hk upload http=\(code) metrics=\(metrics.count)")
            return ok
        } catch {
            APIClient.shared.noteFailure()
            AionLogger.shared.log("hk upload failed: \(error.localizedDescription)")
            return false
        }
    }

    /// POST /api/health/workouts —— HKWorkout 落库（运动教练链路 2026-08-25）
    func uploadWorkout(entry: [String: Any]) async -> Bool {
        var request = URLRequest(
            url: APIClient.shared.url(for: "/api/health/workouts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = APIClient.shared.currentToken {
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 20
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: entry)
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = code == 200
            if ok {
                APIClient.shared.markVerified()
            } else {
                APIClient.shared.noteFailure()
            }
            AionLogger.shared.log("hk workout upload http=\(code)")
            return ok
        } catch {
            APIClient.shared.noteFailure()
            AionLogger.shared.log("hk workout upload failed: \(error.localizedDescription)")
            return false
        }
    }
}
