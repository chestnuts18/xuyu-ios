import Foundation
import AVFAudio

/// 音频路由/他应用播放/音量（抄 HA AudioOutputSensor 思路）
/// 被动读：WebView 已有 playback 会话，这里只观察不抢占（setActive 会抢音频焦点）
@MainActor
final class SenseAudio {
    static let shared = SenseAudio()

    private let session = AVAudioSession.sharedInstance()
    var onChange: (() -> Void)?

    struct Snapshot {
        var output: String   // none/speaker/headphones/bluetooth/car/receiver
        var otherAudio: Bool
        var volume: Double
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onChange?()
            }
        }
    }

    func read() -> Snapshot {
        let outputs = session.currentRoute.outputs
        var output = "none"
        for o in outputs {
            switch o.portType {
            case .carAudio: output = "car"
            case .headphones: output = "headphones"
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: output = "bluetooth"
            case .builtInSpeaker: output = "speaker"
            case .builtInReceiver: output = "receiver"
            default: break
            }
            if output == "car" { break }  // 车载优先级最高
        }
        // 优先级：car > headphones/bluetooth > speaker/receiver > none
        if output == "speaker" || output == "receiver" {
            // 多输出时（扬声器+耳机并存）以耳机类优先
            for o in outputs {
                if o.portType == .headphones || o.portType == .bluetoothA2DP
                    || o.portType == .bluetoothHFP || o.portType == .bluetoothLE {
                    output = o.portType == .headphones ? "headphones" : "bluetooth"
                    break
                }
            }
        }
        return Snapshot(
            output: output,
            otherAudio: session.isOtherAudioPlaying,
            volume: Double(session.outputVolume)
        )
    }
}
