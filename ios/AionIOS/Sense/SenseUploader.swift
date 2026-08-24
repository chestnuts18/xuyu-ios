import Foundation

/// POST /api/device-context/phone —— 设备槽位上报（范式对齐 AionHealthUploader）
/// 服务器契约：body {"data": {slot: {value, observed_at, since, confidence}}}
/// 值不变重发只刷 received_at、保留 since、不产生事件（device_context.py 已亲验）
@MainActor
final class SenseUploader {
    static let shared = SenseUploader()

    private init() {}

    private var endpoint: URL {
        APIClient.shared.url(for: "/api/device-context/phone")
    }

    func upload(data: [String: [String: Any]]) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = APIClient.shared.currentToken {  // 隧道候选时带 X-Aion-Token
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 20
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["data": data])
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = code == 200
            if ok {
                APIClient.shared.markVerified()
            } else {
                APIClient.shared.noteFailure()
            }
            AionLogger.shared.log("sense upload http=\(code) slots=\(data.count)")
            return ok
        } catch {
            APIClient.shared.noteFailure()
            AionLogger.shared.log("sense upload failed: \(error.localizedDescription)")
            return false
        }
    }
}
