import Foundation
import WebKit

/// 桥消息：网页 → 原生 {id, bridge, action, args}（注入脚本 __aionCall 发出）
struct BridgeRequest {
    let id: Int
    let bridge: String
    let action: String
    let args: [String: Any]

    init?(message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? Int,
              let bridge = body["bridge"] as? String,
              let action = body["action"] as? String else { return nil }
        self.id = id
        self.bridge = bridge
        self.action = action
        self.args = body["args"] as? [String: Any] ?? [:]
    }
}
