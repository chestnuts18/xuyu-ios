import Foundation
import Network
import WebKit

/// 线路偏好（2026-09-21 念宝拍板）：自动 / 固定走某一条。
/// 固定 = 用户说了算，App 绝不自己变心；那条不通由重试页让用户自己扳道岔。
enum RoutePreference: String, CaseIterable, Identifiable {
    case auto
    case lan
    case ts
    case cf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .lan:  return "在家"
        case .ts:   return "Tailscale"
        case .cf:   return "隧道"
        }
    }
}

/// 网络层：候选 URL 探测 + 统一基址。
/// 家里直连局域网（不用开 Tailscale），出门走 Tailscale；第三槽 Cloudflare Tunnel。
@MainActor
final class APIClient: ObservableObject {
    static let shared = APIClient()

    struct Candidate {
        let key: String        // "lan" / "ts" / "cf"（与 RoutePreference.rawValue 同串）
        let url: URL
        var token: String?     // 走外网时需要 X-Aion-Token（CF Tunnel 槽位用）
    }

    /// 当前采纳的基址（WebView/健康/定位/监管共用）
    @Published private(set) var baseURL: URL
    /// 当前候选的凭证（隧道槽位才有；上传器拼 X-Aion-Token 头用）
    private(set) var currentToken: String?
    /// 基址切换回调（WebView 用它重载；保留当前路径，见 urlPreservingPath）
    var onBaseURLChanged: ((URL) -> Void)?

    private static let cacheKey = "aion_base_url"
    private static let prefKey = "aion_route_preference"
    private static let probeThrottle: TimeInterval = 30
    private static let verifyWindow: TimeInterval = 30 * 60
    /// 自动模式「升回局域网」节流：WiFi 抖一下不要来回切（切一次 = 页面重载一次）
    private static let lanUpgradeThrottle: TimeInterval = 120

    /// 家里优先：局域网直连。Tailscale 兜底出门，Cloudflare Tunnel 收尾。
    /// 隧道 token 经 CI Secrets 注入（Info.plist AION_TUNNEL_TOKEN 构建设置展开，
    /// signed job 用 AION_TUNNEL_TOKEN="${{ secrets... }}" xcodebuild 前缀传入）——
    /// 2026-08-25 仓库转公开脱敏：代码与历史不再落任何凭证。
    /// static 计算属性：init 里要用 candidates[0] 定基址，不能是 lazy/实例属性
    /// （初始化阶段访问 self 会报「all stored properties are initialized 之前」）
    private static var allCandidates: [Candidate] {
        [
            Candidate(key: "lan", url: URL(string: "http://192.168.3.218:8080")!),
            Candidate(key: "ts",  url: URL(string: "http://100.73.222.35:8080")!),
            Candidate(key: "cf",  url: URL(string: "https://api-5d158ee9.kuriyu.love")!,
                      token: tunnelTokenFromBundle()),
        ]
    }

    /// 生效候选：固定偏好只留那一条（探测/采纳都绕不出它）；自动返回全部
    static var candidates: [Candidate] {
        let pref = preference
        guard pref != .auto else { return allCandidates }
        let picked = allCandidates.filter { $0.key == pref.rawValue }
        return picked.isEmpty ? allCandidates : picked
    }

    /// 用户选的线路（持久化，重启不丢）
    static var preference: RoutePreference {
        get { RoutePreference(rawValue: UserDefaults.standard.string(forKey: prefKey) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: prefKey) }
    }

    private static func tunnelTokenFromBundle() -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "AION_TUNNEL_TOKEN") as? String,
              !v.isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
    }

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "aion.apiclient.path")
    private var lastProbeAt: Date = .distantPast
    private var lastVerifiedAt: Date = .distantPast
    private var lastSwitchAt: Date = .distantPast
    private var probeTask: Task<Void, Never>?

    private init() {
        let pref = Self.preference
        if pref != .auto, let fixed = Self.allCandidates.first(where: { $0.key == pref.rawValue }) {
            // 固定线路：基址就是它，App 重启也不漂
            baseURL = fixed.url
            currentToken = fixed.token
        } else if let cached = UserDefaults.standard.string(forKey: Self.cacheKey),
                  let url = URL(string: cached) {
            baseURL = url
            // cached 恢复时找回候选 token：冷启动 cached=CF 时不能丢
            if let cand = Self.allCandidates.first(where: { $0.url == url }) {
                currentToken = cand.token
            }
        } else {
            baseURL = Self.candidates[0].url
            currentToken = Self.candidates[0].token
        }
        // 网络路径变化（切 WiFi/开关 VPN）→ 重探，自动跟住
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeIfNeeded(bypassVerifyWindow: true)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    /// App 启动时调用：探测并采纳第一个可达的候选；
    /// 同时给当前候选种好隧道 Cookie（冷启动 cached=CF 时页面首请求就有凭据）
    func start() {
        if let cand = Self.allCandidates.first(where: { $0.url == baseURL }) {
            installTunnelCookie(cand) {}
        }
        probeIfNeeded(bypassVerifyWindow: false)
    }

    /// 任一请求成功后调用：固化当前基址、刷新验证时钟
    func markVerified() {
        lastVerifiedAt = Date()
        // 2026-09-17 自愈：挂在非最优候选（如 CF）时，请求成功不再代表选路正确——
        // 让后续成功请求成为重探契机（probeIfNeeded 内 30s 节流），TS 一恢复就切回。
        // 2026-09-21 收口：重探归重探，但 adoptIfAllowed 只在「当前线路本轮探不通」
        // 或「升回局域网」时才真的换——不会再把页面来回重载。
        if let best = orderedCandidatesForCurrentPath().first, best.url != baseURL {
            probeIfNeeded(bypassVerifyWindow: true)
        }
    }

    /// 请求失败时调用：触发一次探测（30 秒节流保护）
    func noteFailure() { probeIfNeeded(bypassVerifyWindow: true) }

    /// 切换线路（设置页 / 重试页调用）：**先探路再切**。
    /// 2026-09-21 念宝实测反馈：切「在家」秒切，切没开的 Tailscale 会卡——
    /// 那条路 WebView 会干等加载超时（最长 60 秒）。所以先 3 秒探一下：
    /// 通了才切；不通原地不动 + 回话说明，偏好也不记（免得下次启动还卡）。
    /// 返回 {ok, preference, message}，网页据此给反馈。
    func requestPreference(_ pref: RoutePreference) async -> [String: Any] {
        let previous = Self.preference
        if pref == .auto {
            Self.preference = .auto
            lastProbeAt = .distantPast
            probeTask?.cancel()
            let switched = await probeAndAdopt()
            if !switched {
                // 没换线路也要重载一次：给设置页按钮一个明确的「切好了」反馈
                //（旧行为：什么都不做 → 按钮永远停在「正在切换…」）
                onBaseURLChanged?(baseURL)
            }
            return ["ok": true, "preference": RoutePreference.auto.rawValue, "message": ""]
        }
        guard let candidate = Self.allCandidates.first(where: { $0.key == pref.rawValue }) else {
            return ["ok": false, "preference": previous.rawValue, "message": "未知线路"]
        }
        let reachable = await probe(candidate)
        guard reachable else {
            Self.preference = previous
            let hint = (pref == .ts) ? "（Tailscale 开没开？）" : ""
            AionLogger.shared.log("apiclient routeReject \(pref.rawValue) unreachable")
            return ["ok": false, "preference": previous.rawValue,
                    "message": "「\(pref.displayName)」现在连不上\(hint)，没切过去"]
        }
        Self.preference = pref
        lastProbeAt = .distantPast
        probeTask?.cancel()
        AionLogger.shared.log("apiclient setPreference \(pref.rawValue) reachable=1 base=\(baseURL.absoluteString)")
        if candidate.url == baseURL {
            // 已在目标线路上：补种 Cookie 后重载一次，让用户看到切生效
            installTunnelCookie(candidate) { [weak self] in
                Task { @MainActor [weak self] in self?.onBaseURLChanged?(candidate.url) }
            }
        } else {
            adopt(candidate)
        }
        return ["ok": true, "preference": pref.rawValue, "message": ""]
    }

    /// 给网页设置页读的线路状态
    func routeInfo() -> [String: Any] {
        [
            "preference": Self.preference.rawValue,
            "base": baseURL.absoluteString,
            "options": RoutePreference.allCases.map {
                ["value": $0.rawValue, "name": $0.displayName]
            },
        ]
    }

    /// WebView 加载失败：跳过当前候选，探测其余候选，返回可用 URL（全不通返回 nil）
    func retryAfterFailure() async -> URL? {
        probeTask?.cancel()
        // 固定线路：不偷偷换线（2026-09-21）——交给重试页，用户自己扳道岔
        guard Self.preference == .auto else { return nil }
        let startIdx = Self.candidates.firstIndex { $0.url == baseURL } ?? 0
        var order: [Candidate] = []
        for i in 1...Self.candidates.count {
            let c = Self.candidates[(startIdx + i) % Self.candidates.count]
            if c.url != baseURL { order.append(c) }
        }
        for candidate in order {
            if await probe(candidate) {
                adopt(candidate)
                return candidate.url
            }
        }
        return nil
    }

    /// 各上传器拼 endpoint 用（基址切换后自动跟新）
    func url(for path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    /// 换基址时保留当前页面路径（/chat 换路后还在 /chat，不踢回桌面）。
    /// 2026-09-21 念宝实锤：旧行为 load 根地址 = 换一次线就从聊天页踢回图标主界面；
    /// 9/20 晚上 28 分钟被踢 12 次。页面状态由服务器兜（消息都在），但位置不能丢。
    func urlPreservingPath(from current: URL?, base: URL) -> URL {
        guard let current,
              let scheme = current.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let cur = URLComponents(url: current, resolvingAgainstBaseURL: false) else {
            return base
        }
        comps.path = cur.path.isEmpty ? "/" : cur.path
        comps.query = cur.query
        comps.fragment = cur.fragment
        return comps.url ?? base
    }

    private func probeIfNeeded(bypassVerifyWindow: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastProbeAt) >= Self.probeThrottle else { return }
        if !bypassVerifyWindow, now.timeIntervalSince(lastVerifiedAt) < Self.verifyWindow { return }
        lastProbeAt = now
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            await self?.probeAndAdopt()
        }
    }

    /// 探一轮并按采纳规则决定是否换线；返回「是否真的换了」
    /// 2026-09-17：并行探测只为省时间，采纳必须按候选优先级（LAN → TS → CF）。
    /// 原实现取 results.first(where:){...}，而 TaskGroup 是按完成顺序吐结果的，
    /// 等于「谁先响应谁赢」——CF 边缘握手常快过 TS 打洞，出门时会抢走 Tailscale 的位
    /// （挂 CF 后传图绕 LAX 边缘，慢；大文件还曾在 nginx 撞 1m 子请求上限 500）。
    @discardableResult
    private func probeAndAdopt() async -> Bool {
        let ordered = orderedCandidatesForCurrentPath()
        guard !ordered.isEmpty else { return false }
        // 并行探测：总耗时 = 最慢一个候选（3s），蜂窝下不再串行等 LAN 超时
        let results = await withTaskGroup(
            of: (Candidate, Bool).self, returning: [(Candidate, Bool)].self
        ) { group in
            for c in ordered {
                group.addTask { (c, await self.probe(c)) }
            }
            var out: [(Candidate, Bool)] = []
            for await r in group { out.append(r) }
            return out
        }
        if Task.isCancelled { return false }
        let okURLs = Set(results.filter { $0.1 }.map { $0.0.url })
        guard let hit = ordered.first(where: { okURLs.contains($0.url) }) else { return false }
        AionLogger.shared.log("apiclient probe ok=[\(okURLs.map { $0.absoluteString }.joined(separator: " "))] hit=\(hit.url.absoluteString) base=\(baseURL.absoluteString) pref=\(Self.preference.rawValue)")
        if hit.url == baseURL { return false }
        let currentOK = results.first { $0.0.url == baseURL }?.1 ?? false
        return adoptIfAllowed(hit, currentOK: currentOK)
    }

    /// 采纳裁决（2026-09-21 念宝拍板，治「聊着聊着被踢回主界面」）：
    /// ① 固定线路：用户说了算，探到就切（那条不通就保持 + 重试页兜底）
    /// ② 自动：当前这条本轮探通 → 不换。旧行为是「谁优先谁赢」，TS/CF 一翻一换，
    ///    每换一次整页重载一次——9/20 晚上 28 分钟被踢 12 次就是这么来的
    /// ③ 自动例外：探到「在家」通而当前不是在家 → 升回局域网（2 分钟节流）
    /// ④ 当前这条探不通 → 换到优先级最高的可用候选（真断了才换）
    @discardableResult
    private func adoptIfAllowed(_ hit: Candidate, currentOK: Bool) -> Bool {
        if Self.preference != .auto {
            adopt(hit)
            return true
        }
        if currentOK {
            guard hit.key == "lan",
                  Date().timeIntervalSince(lastSwitchAt) >= Self.lanUpgradeThrottle else { return false }
        }
        adopt(hit)
        return true
    }

    /// 蜂窝网络下跳过局域网候选（流量时 LAN 必不通，省 3 秒串行超时）；
    /// 固定线路时不剔除（用户选的就得试，不通也是他自己选的）
    private func orderedCandidatesForCurrentPath() -> [Candidate] {
        var list = Self.candidates
        if Self.preference == .auto, monitor.currentPath.usesInterfaceType(.cellular) {
            list.removeAll { $0.key == "lan" }
        }
        return list
    }

    /// GET /api/health/injection：读内存缓存摘要，最轻、无副作用，2xx 即胜出
    private func probe(_ candidate: Candidate) async -> Bool {
        let url = candidate.url.appendingPathComponent("/api/health/injection")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        if let token = candidate.token {
            request.setValue(token, forHTTPHeaderField: "X-Aion-Token")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private func adopt(_ candidate: Candidate) {
        AionLogger.shared.log("apiclient adopt base=\(candidate.url.absoluteString) (prev=\(baseURL.absoluteString)) pref=\(Self.preference.rawValue)")
        currentToken = candidate.token
        lastVerifiedAt = Date()
        if candidate.url == baseURL {
            // 同候选：不 reload，但 Cookie 可能已过期/未种（冷启动 cached=CF）——
            // 补种一次（2026-08-25 白屏根因之二）
            installTunnelCookie(candidate) {}
            return
        }
        lastSwitchAt = Date()
        baseURL = candidate.url
        UserDefaults.standard.set(candidate.url.absoluteString, forKey: Self.cacheKey)
        // 隧道候选：先给 WebView 种下 AionToken Cookie 再 reload——
        // WKWebView 主 frame 加不了自定义 header，Cookie 是唯一干净路径，
        // 顺序反了会 401（鉴权竞态）。
        installTunnelCookie(candidate) { [weak self] in
            Task { @MainActor [weak self] in
                self?.onBaseURLChanged?(candidate.url)
            }
        }
    }

    /// 采纳隧道候选后种 Cookie：secure、根路径、30 天（auth_request 认 AionToken）
    private func installTunnelCookie(_ candidate: Candidate, completion: @escaping () -> Void) {
        guard candidate.url.scheme == "https",
              let host = candidate.url.host,
              let token = candidate.token else {
            completion()
            return
        }
        // SameSite=None：http→https 跨基址切换时部分 iOS 版本仍按跨站扣 Cookie，
        // 显式 None 最稳（同源时浏览器也正常发，无害）。
        let props: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .name: "AionToken",
            .value: token,
            .secure: "TRUE",
            HTTPCookiePropertyKey(rawValue: "SameSite"): "None",
            .expires: Date().addingTimeInterval(30 * 24 * 3600),
        ]
        guard let cookie = HTTPCookie(properties: props) else {
            completion()
            return
        }
        // 双存储：WKWebView 读 WKWebsiteDataStore；部分 iOS 版本 WKWebView 的
        // fetch/XHR 走 NSURLSession 层（GitHub 实测：iOS 14+ credentials
        // include 由原生 cookie 策略决定）——两边都种。
        HTTPCookieStorage.shared.setCookie(cookie)
        WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) {
            completion()
        }
    }
}
