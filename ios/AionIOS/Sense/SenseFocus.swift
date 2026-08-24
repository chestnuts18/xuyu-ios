import Foundation
import Intents

/// 专注模式（INFocusStatusCenter，iOS 15+）
/// ⚠️ 双重开关：弹窗授权后还须 设置→专注→分享专注状态（弹窗文案要讲清）
@MainActor
final class SenseFocus {
    static let shared = SenseFocus()

    private let center = INFocusStatusCenter.default

    private init() {}

    /// 启动时请求一次；被拒后不再骚扰
    func requestAuthIfNeeded() {
        guard center.authorizationStatus == .notDetermined else { return }
        center.requestAuthorization { status in
            AionLogger.shared.log("sense focus auth requested -> \(status.rawValue)")
        }
    }

    /// 授权才读；on = 专注模式开启中
    func read() -> String? {
        guard center.authorizationStatus == .authorized else { return nil }
        guard let focused = center.focusStatus.isFocused else { return nil }
        return focused ? "on" : "off"
    }
}
