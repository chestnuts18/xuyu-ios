import Foundation
import SwiftUI
import AlarmKit

/// AlarmKit 闹钟元数据。
/// AlarmKit 要求 metadata 必须给一个**具体类型**（省不成 Never），哪怕不带任何数据。
/// 不带数据 = 用系统默认闹钟外观 —— 也就意味着**不需要 widget 扩展**。
/// ⚠️ 类型必须是非隔离的（Xcode 26 若开了默认 MainActor 隔离会破坏 AlarmMetadata 一致性）。
struct AionAlarmMetadata: AlarmMetadata {
    var label: String = ""
}

/// AlarmKit 真闹钟（2026-09-22 念宝拍板，iOS 26+）
///
/// **为什么需要**：闹铃此前只有两条路 —— 网页弹窗（要页面活着）+ APNs 通知
/// （一声「叮」、30 秒上限、静音与专注模式下会被压住）。iOS 26 的 AlarmKit 让
/// 第三方 App 也能排**系统闹钟**：穿透静音与专注、锁屏全屏「停止」、**App 被杀
/// 也响**、自动同步到配对手表（手表端无需装任何东西）。
///
/// **数据流**：徐聿 `[ALARM:时间|内容]` → 服务器 schedules 表 →
/// **App 拉 `GET /api/schedules?status=active` 筛 `type == "alarm"`** → 在手机系统里
/// 登记一份。之后到点由**系统自己响**，服务器 / 网络 / App 全都不参与。
///
/// **兜底**：闹钟到点时服务器仍会推一条 APNs 通知（`apns_sender.notify_alarm`）——
/// App 被强杀、闹钟没同步上时，那是最后一层。
///
/// ⚠️ **不要加倒计时**（`secondaryButtonBehavior: .countdown` 或 `.timer`）——
/// 一旦有倒计时就**必须**补一个 Live Activity widget 扩展，那是另一摊工程。
@available(iOS 26.0, *)
@MainActor
final class AionAlarmKit {
    static let shared = AionAlarmKit()
    private init() {}

    private let storeKey = "aion_alarm_scheduled"

    private struct ServerAlarm {
        let id: String
        let triggerAt: String
        let content: String
    }

    // MARK: - 对外入口

    /// 把服务器上的闹铃同步成系统闹钟。
    /// 触发点：App 回前台（含冷启动）、网页桥手动调用。返回同步摘要（回给网页/日志）。
    @discardableResult
    func sync(reason: String = "manual") async -> [String: Any] {
        var out: [String: Any] = ["supported": true, "reason": reason]

        // ① 授权：首次会弹系统询问，说明文字来自 Info.plist 的 NSAlarmKitUsageDescription
        if AlarmManager.shared.authorizationState == .notDetermined {
            do { try await AlarmManager.shared.requestAuthorization() }
            catch { AionLogger.shared.log("alarm auth error: \(error.localizedDescription)") }
        }
        let authorized = AlarmManager.shared.authorizationState == .authorized
        out["authorized"] = authorized
        guard authorized else {
            AionLogger.shared.log("alarm sync(\(reason)) skipped: authorized=false")
            return out
        }

        // ② 拉服务器闹铃
        // ⚠️ nil = 拉取失败（网络问题），此时**绝不能**走第 ③ 步 ——
        //    否则一次网络抖动就会把手机上所有系统闹钟撤掉。
        guard let items = await fetchActiveAlarms() else {
            out["error"] = "fetch failed"
            return out
        }
        out["serverCount"] = items.count
        let activeIds = Set(items.map { $0.id })

        var known = loadScheduled()
        var added = 0
        var removed = 0

        // ③ 服务器上已经没有的（已触发 / 被徐聿取消）→ 撤销手机里的系统闹钟
        for (sid, _) in known where !activeIds.contains(sid) {
            if let s = info["uuid"] as? String, let u = UUID(uuidString: s) {
                try? AlarmManager.shared.cancel(id: u)
                removed += 1
            }
            known.removeValue(forKey: sid)
        }

        // ④ 登记新闹钟；时间改过的先撤旧的再重排
        for item in items {
            guard let date = Self.parseTrigger(item.triggerAt) else { continue }
            // 太近的不排（AlarmKit 对过去时间会报错），交给服务器那条兜底通知
            guard date.timeIntervalSinceNow > 10 else { continue }
            let ts = date.timeIntervalSince1970
            if let prev = known[item.id], let p = prev["ts"] as? Double, abs(p - ts) < 1 {
                continue  // 已登记且时间没变
            }
            if let s = known[item.id]?["uuid"] as? String, let u = UUID(uuidString: s) {
                try? AlarmManager.shared.cancel(id: u)
            }
            let uuid = UUID()
            do {
                try await scheduleSystemAlarm(uuid: uuid, date: date, title: item.content)
                known[item.id] = ["uuid": uuid.uuidString, "ts": ts, "title": item.content]
                added += 1
            } catch {
                AionLogger.shared.log("alarm schedule FAILED id=\(item.id): \(error.localizedDescription)")
            }
        }

        saveScheduled(known)
        out["added"] = added
        out["removed"] = removed
        out["scheduled"] = known.count
        AionLogger.shared.log("alarm sync(\(reason)) ok server=\(items.count) added=\(added) removed=\(removed) total=\(known.count)")
        return out
    }

    /// 状态速查（诊断 / 网页显示用）
    func status() -> [String: Any] {
        var authorized = "unknown"
        switch AlarmManager.shared.authorizationState {
        case .authorized: authorized = "authorized"
        case .denied: authorized = "denied"
        case .notDetermined: authorized = "notDetermined"
        @unknown default: authorized = "unknown"
        }
        return ["supported": true, "authorized": authorized, "scheduled": loadScheduled().count]
    }

    /// 撤销手机上所有由本 App 登记的系统闹钟（调试用）
    @discardableResult
    func cancelAll() -> [String: Any] {
        let known = loadScheduled()
        var n = 0
        for (_, info) in known {
            if let s = info["uuid"] as? String, let u = UUID(uuidString: s) {
                try? AlarmManager.shared.cancel(id: u)
                n += 1
            }
        }
        saveScheduled([:])
        AionLogger.shared.log("alarm cancelAll n=\(n)")
        return ["cancelled": n]
    }

    // MARK: - 系统闹钟

    private func scheduleSystemAlarm(uuid: UUID, date: Date, title: String) async throws {
        // ⚠️ 文案一律走**字符串插值**：AlarmKit 这几个 title/text 参数 Apple 文档没写死
        //    类型（String / LocalizedStringResource / Text 都可能），而三者都能由字符串
        //    插值字面量构造 —— 插值写法三种类型下都能编过，省掉一轮 CI 试错。
        let shown = title.isEmpty ? "闹铃" : title
        let alert = AlarmPresentation.Alert(
            title: "\(shown)",
            stopButton: AlarmButton(
                text: "\("停止")",
                textColor: .white,
                systemImageName: "stop.fill"
            )
        )
        // countdown / paused 传 nil：**不做倒计时**，所以不需要 Live Activity 扩展
        let presentation = AlarmPresentation(alert: alert, countdown: nil, paused: nil)
        let attributes = AlarmAttributes<AionAlarmMetadata>(
            presentation: presentation,
            metadata: nil,
            tintColor: .blue
        )
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(date),
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: .default
        )
        _ = try await AlarmManager.shared.schedule(id: uuid, configuration: configuration)
        AionLogger.shared.log("alarm scheduled at \(Self.describe(date)) title=\(shown.prefix(20))")
    }

    // MARK: - 服务器

    /// 返回 nil = 拉取失败（调用方据此跳过撤销步骤）
    private func fetchActiveAlarms() async -> [ServerAlarm]? {
        var comps = URLComponents(
            url: APIClient.shared.url(for: "/api/schedules"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "status", value: "active")]
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if let token = APIClient.shared.currentToken {  // 隧道候选要带 X-Aion-Token
            request.setValue(token, forHTTPHeaderField: "X-Aion-Token")
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                AionLogger.shared.log("alarm fetch: unexpected payload")
                return nil
            }
            return rows.compactMap { row in
                guard (row["type"] as? String) == "alarm",
                      let id = row["id"] as? String,
                      let at = row["trigger_at"] as? String else { return nil }
                return ServerAlarm(id: id, triggerAt: at, content: (row["content"] as? String) ?? "")
            }
        } catch {
            AionLogger.shared.log("alarm fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 服务器时间格式 = 本地时间字符串 "YYYY-MM-DD HH:mm"（无秒无时区）
    private static func parseTrigger(_ raw: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    private static func describe(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - 本地登记表（scheduleId → 系统闹钟 uuid / 时间）

    private func loadScheduled() -> [String: [String: Any]] {
        guard let raw = UserDefaults.standard.dictionary(forKey: storeKey) else { return [:] }
        var out: [String: [String: Any]] = [:]
        for (key, value) in raw {
            if let dict = value as? [String: Any] { out[key] = dict }
        }
        return out
    }

    private func saveScheduled(_ map: [String: [String: Any]]) {
        UserDefaults.standard.set(map, forKey: storeKey)
    }
}
