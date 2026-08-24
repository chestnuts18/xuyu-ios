import Foundation

/// 后端监管协议（完全复用安卓 AionPushService 的端点）
struct SupervisionCommand: Decodable {
    let commandId: String
    let action: String
    let groupId: String
    let minutes: Int?
    let message: String?
    let roleId: String?
    let deviceId: String?
    let expiresAt: Double?
}

@MainActor
final class AionSupervisionAPI {
    static let shared = AionSupervisionAPI()

    private init() {}

    /// 基址由 APIClient 探测（家里局域网优先）
    private var base: URL { APIClient.shared.baseURL }

    func fetchPending(device: String) async -> [SupervisionCommand]? {
        var components = URLComponents(
            url: base.appendingPathComponent("/api/app-supervision/commands/pending"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "device", value: device)]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        if let t = APIClient.shared.currentToken {  // 隧道候选时带 X-Aion-Token
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                APIClient.shared.noteFailure()
                return nil
            }
            APIClient.shared.markVerified()
            let decoded = try JSONDecoder().decode(
                [String: [SupervisionCommand]].self, from: data
            )
            return decoded["commands"]
        } catch {
            APIClient.shared.noteFailure()
            return nil
        }
    }

    func ack(commandId: String, success: Bool, reason: String) async {
        var request = URLRequest(
            url: base.appendingPathComponent("/api/app-supervision/commands/ack")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = APIClient.shared.currentToken {  // 隧道候选时带 X-Aion-Token
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 15
        let payload: [String: Any] = [
            "commandId": commandId,
            "success": success,
            "reason": reason,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                APIClient.shared.markVerified()
            } else {
                APIClient.shared.noteFailure()
            }
        } catch {
            APIClient.shared.noteFailure()
        }
    }

    func reportState(payload: [String: Any]) async {
        var request = URLRequest(
            url: base.appendingPathComponent("/api/app-supervision/state")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = APIClient.shared.currentToken {  // 隧道候选时带 X-Aion-Token
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: request)
    }
}
