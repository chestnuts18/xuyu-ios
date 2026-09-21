import Foundation
import AVFoundation
import MediaPlayer

/// 原生放歌（2026-09-22 念宝拍板：闹钟响完，歌要自己放出来）
///
/// **要解决什么**：闹铃到点时徐聿会点一首歌（回复里的 `[MUSIC:歌名]`），
/// 但播放一直是**网页**干的（`chat.js` 拿到卡片后 autoplay）—— 而你睡着/锁屏时
/// 网页被 iOS 冻住，歌就放不出来，得等你打开 App。
///
/// **做法**：服务器在闹铃时刻把这首歌**直接推给 App**（静默推送），App 用原生
/// 播放器放。原生播放有后台音频权限（`Info.plist` 的 `UIBackgroundModes: audio`
/// 早就在），**锁屏照放**。
///
/// **边界**（iOS 硬规矩，绕不过）：App 被上滑划掉时静默推送送不到 —— 那时只剩
/// 闹钟响，歌要等打开 App 才放。
@MainActor
final class AionSongPlayer {
    static let shared = AionSongPlayer()
    private init() {}

    private var player: AVAudioPlayer?
    private(set) var playing = false
    private(set) var lastTitle: String?
    private(set) var lastPlayedAt: Date?
    private(set) var lastError: String?

    /// 播放服务器上的一首歌。path 形如 `/api/music/stream/123`。
    func play(path: String, title: String?, artist: String?) {
        lastTitle = title
        lastError = nil
        Task { await load(path: path, title: title, artist: artist) }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        AionLogger.shared.log("song: stopped")
    }

    func status() -> [String: Any] {
        var out: [String: Any] = ["playing": playing]
        if let lastTitle { out["title"] = lastTitle }
        if let lastError { out["lastError"] = lastError }
        if let lastPlayedAt { out["playedAgoSec"] = Int(Date().timeIntervalSince(lastPlayedAt)) }
        return out
    }

    // MARK: - 内部

    private func load(path: String, title: String?, artist: String?) async {
        // 走 APIClient 解析基址（家里 LAN / 出门 TS / 隧道），隧道候选要带 token
        let full = APIClient.shared.url(for: path)
        var request = URLRequest(url: full)
        request.timeoutInterval = 30
        if let token = APIClient.shared.currentToken {
            request.setValue(token, forHTTPHeaderField: "X-Aion-Token")
        }
        AionLogger.shared.log("song: fetching \(path)")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard !data.isEmpty else {
                lastError = "empty response"
                AionLogger.shared.log("song: empty response for \(path)")
                return
            }
            start(data: data, title: title, artist: artist)
        } catch {
            lastError = error.localizedDescription
            AionLogger.shared.log("song: fetch failed \(error.localizedDescription)")
        }
    }

    private func start(data: Data, title: String?, artist: String?) {
        do {
            let session = AVAudioSession.sharedInstance()
            // ⚠️ 用 .playback（保住后台播放）；mixWithOthers 表示不去顶别的 App
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let p = try AVAudioPlayer(data: data)
            p.prepareToPlay()
            p.play()
            player = p
            playing = true
            lastPlayedAt = Date()
            AionLogger.shared.log("song: playing \(title ?? "-") bytes=\(data.count)")
            updateNowPlaying(title: title, artist: artist)
        } catch {
            lastError = error.localizedDescription
            AionLogger.shared.log("song: play failed \(error.localizedDescription)")
        }
    }

    /// 锁屏/控制中心显示歌名（失败无所谓，不影响播放）
    private func updateNowPlaying(title: String?, artist: String?) {
        var info: [String: Any] = [:]
        if let title { info[MPMediaItemPropertyTitle] = title }
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        info[MPMediaItemPropertyPlaybackDuration] = player?.duration ?? 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info.isEmpty ? nil : info
    }
}
