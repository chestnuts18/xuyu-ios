import Foundation

/// 客户端日志：关键事件/错误批量上报服务器（/api/ios-logs），舟宝 ssh 直查
@MainActor
final class AionLogger {
    static let shared = AionLogger()

    private var buffer: [String] = []
    private var lastFlushAt: Date = .distantPast

    private init() {}

    func log(_ message: String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) \(message)"
        buffer.append(line)
        if buffer.count > 80 { buffer.removeFirst(buffer.count - 80) }
        Task { await flushIfNeeded() }
    }

    /// 立即上报（App 关键节点调用）
    func flush() async {
        guard !buffer.isEmpty else { return }
        let lines = buffer
        buffer.removeAll()
        lastFlushAt = Date()
        let payload: [String: Any] = [
            "device": DeviceIdentity.deviceId,
            "tag": "main",
            "lines": lines,
        ]
        var request = URLRequest(url: APIClient.shared.url(for: "/api/ios-logs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = APIClient.shared.currentToken {  // 隧道候选时带 X-Aion-Token
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 8
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func flushIfNeeded() async {
        // 10 秒节流批量
        guard Date().timeIntervalSince(lastFlushAt) >= 10 else { return }
        await flush()
    }
}
