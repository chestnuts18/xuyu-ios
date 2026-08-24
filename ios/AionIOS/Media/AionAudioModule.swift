import Foundation
import AVFoundation

/// 麦克风桥（对齐安卓 AudioBridge 契约）：
/// 16kHz 单声道 Int16 小端，640 samples/帧（40ms）→ base64 → 推给网页
/// window.onAionAudioChunk（视频通话分发点）+ window._voiceNativeOnChunk（语音消息）
/// 两个回调同时推（网页侧不 active 的回调自然没人听）
@MainActor
final class AionAudioModule {
    static let shared = AionAudioModule()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pendingData = Data()  // Int16 LE 字节攒帧
    private(set) var recording = false

    private init() {}

    func handle(action: String, args: [String: Any]) async -> Any? {
        switch action {
        case "start":
            let ok = await start()
            AionJSBridge.shared.pushCachePartial(["audioRecording": ok])
            return ok
        case "stop":
            stop()
            AionJSBridge.shared.pushCachePartial(["audioRecording": false])
            return true
        default:
            return nil
        }
    }

    func start() async -> Bool {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        if auth == .denied || auth == .restricted { return false }
        if auth == .notDetermined {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return false }
        }
        // 麦克风需要 playAndRecord 会话；蓝牙耳机兼容
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth])
        try? AVAudioSession.sharedInstance().setActive(true)

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)  // 硬件格式（48k Float32）
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000,
            channels: 1, interleaved: true),
            let conv = AVAudioConverter(from: hwFormat, to: target)
        else { return false }
        converter = conv
        pendingData.removeAll()
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buf, _ in
            self?.handleBuffer(buf)
        }
        engine.prepare()
        do {
            try engine.start()
            recording = true
            AionLogger.shared.log("audio capture started")
            return true
        } catch {
            AionLogger.shared.log("audio start failed: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        guard recording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recording = false
        AionLogger.shared.log("audio capture stopped")
    }

    // 音频线程：转 16k Int16 → 攒 640 samples → base64 → 主线程推网页
    private func handleBuffer(_ buf: AVAudioPCMBuffer) {
        guard let converter, let target = converter.outputFormat as AVAudioFormat? else { return }
        let ratio = target.sampleRate / (buf.format.sampleRate > 0 ? buf.format.sampleRate : 1)
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(
            pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let channel = out.int16ChannelData?[0] else { return }
        var bytes = Data()
        bytes.reserveCapacity(Int(out.frameLength) * 2)
        for i in 0..<Int(out.frameLength) {
            var v = channel[i].littleEndian
            withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
        }
        pendingData.append(bytes)
        // 640 samples = 1280 字节一帧
        var chunks: [String] = []
        while pendingData.count >= 1280 {
            let chunk = pendingData.prefix(1280)
            chunks.append(chunk.base64EncodedString())
            pendingData.removeFirst(1280)
        }
        for b64 in chunks {
            Task { @MainActor in
                AionJSBridge.shared.pushAudioChunk(b64)
            }
        }
    }
}
