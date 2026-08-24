import Foundation
import Network
import WebKit

/// 网络层：候选 URL 探测 + 统一基址。
/// 家里直连局域网（不用开 Tailscale），出门走 Tailscale；第三槽 Cloudflare Tunnel。
@MainActor
final class APIClient: ObservableObject {
    static let shared = APIClient()

    /// 非隔离镜像（2026-08-25）：AionSchemeHandler 在 WebKit 任意线程读基址/token，
    /// @MainActor 隔离成员不可访问；adopt/init 时同步更新。
    nonisolated(unsafe) static var sharedBaseURL: URL = URL(string: "http://192.168.3.218:8080")!
    nonisolated(unsafe) static var sharedToken: String?

    struct Candidate {
        let url: URL
        var token: String?  // 走外网时需要 X-Aion-Token（CF Tunnel 槽位用）
    }

    /// 当前采纳的基址（WebView/健康/定位/监管共用）
    @Published private(set) var baseURL: URL
    /// 当前候选的凭证（隧道槽位才有；上传器拼 X-Aion-Token 头用）
    private(set) var currentToken: String?
    /// 基址切换回调（WebView 用它 reload）
    var onBaseURLChanged: ((URL) -> Void)?

    private static let cacheKey = "aion_base_url"
    private static let probeThrottle: TimeInterval = 30
    private static let verifyWindow: TimeInterval = 30 * 60

    /// 家里优先：局域网直连。Tailscale 兜底出门，Cloudflare Tunnel 收尾。
    /// 隧道 token 经 CI Secrets 注入（Info.plist AION_TUNNEL_TOKEN 构建设置展开，
    /// signed job 用 AION_TUNNEL_TOKEN="${{ secrets... }}" xcodebuild 前缀传入）——
    /// 2026-08-25 仓库转公开脱敏：代码与历史不再落任何凭证。
    /// static 计算属性：init 里要用 candidates[0] 定基址，不能是 lazy/实例属性
    /// （初始化阶段访问 self 会报「all stored properties are initialized 之前」）
    private static var candidates: [Candidate] {
        [
            Candidate(url: URL(string: "http://192.168.3.218:8080")!),
            Candidate(url: URL(string: "http://100.73.222.35:8080")!),
            Candidate(url: URL(string: "https://api-5d158ee9.kuriyu.love")!,
                      token: tunnelTokenFromBundle()),
        ]
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
    private var probeTask: Task<Void, Never>?

    private init() {
        if let cached = UserDefaults.standard.string(forKey: Self.cacheKey),
           let url = URL(string: cached) {
            baseURL = url
        } else {
            baseURL = Self.candidates[0].url
        }
        Self.sharedBaseURL = baseURL
        // cached 恢复时找回候选 token：冷启动 cached=CF 时不再走 adopt 全路径，
        // token 不能丢（2026-08-25 白屏根因之一：sharedToken=nil → 兜底请求 403）
        if let cand = Self.candidates.first(where: { $0.url == baseURL }) {
            currentToken = cand.token
            Self.sharedToken = cand.token
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
        if let cand = Self.candidates.first(where: { $0.url == baseURL }) {
            installTunnelCookie(cand) {}
        }
        probeIfNeeded(bypassVerifyWindow: false)
    }

    /// 任一请求成功后调用：固化当前基址、刷新验证时钟
    func markVerified() { lastVerifiedAt = Date() }

    /// 请求失败时调用：触发一次探测（30 秒节流保护）
    func noteFailure() { probeIfNeeded(bypassVerifyWindow: true) }

    /// WebView 加载失败：跳过当前候选，探测其余候选，返回可用 URL（全不通返回 nil）
    func retryAfterFailure() async -> URL? {
        probeTask?.cancel()
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

    private func probeIfNeeded(bypassVerifyWindow: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastProbeAt) >= Self.probeThrottle else { return }
        if !bypassVerifyWindow, now.timeIntervalSince(lastVerifiedAt) < Self.verifyWindow { return }
        lastProbeAt = now
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            guard let self else { return }
            let ordered = self.orderedCandidatesForCurrentPath()
            if !ordered.isEmpty {
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
                if Task.isCancelled { return }
                if let hit = results.first(where: { $0.1 }) {
                    self.adopt(hit.0)
                }
            }
        }
    }

    /// 蜂窝网络下跳过局域网候选（流量时 LAN 必不通，省 3 秒串行超时）
    private func orderedCandidatesForCurrentPath() -> [Candidate] {
        var list = Self.candidates
        if monitor.currentPath.usesInterfaceType(.cellular) {
            list.removeAll { $0.url.absoluteString.hasPrefix("http://192.168.") }
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
        AionLogger.shared.log("apiclient adopt base=\(candidate.url.absoluteString) (prev=\(baseURL.absoluteString))")
        currentToken = candidate.token
        Self.sharedToken = candidate.token
        lastVerifiedAt = Date()
        if candidate.url == baseURL {
            // 同候选：不 reload，但 Cookie 可能已过期/未种（冷启动 cached=CF）——
            // 补种一次（2026-08-25 白屏根因之二）
            installTunnelCookie(candidate) {}
            return
        }
        baseURL = candidate.url
        Self.sharedBaseURL = candidate.url
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
        let props: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .name: "AionToken",
            .value: token,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(30 * 24 * 3600),
        ]
        guard let cookie = HTTPCookie(properties: props) else {
            completion()
            return
        }
        WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) {
            completion()
        }
    }
}
