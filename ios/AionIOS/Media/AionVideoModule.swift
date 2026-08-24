import Foundation
import AVFoundation

/// 录视频桥（对齐安卓 VideoBridge 契约）：startRecord/stopRecord/cancel
/// stopRecord 同步返回整段 MP4 的 base64（网页 atob → Blob 上传）
/// ⚠️ 契约如此，长视频 base64 会很大；录像帧扇出复用摄像头模块的 session
@MainActor
final class AionVideoModule {
    static let shared = AionVideoModule()

    private let writerQueue = DispatchQueue(label: "aion.video.writer")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var consumerId: Int = -1
    private var sessionStarted = false
    private var recordStartTime: CMTime = .zero
    private(set) var recording = false

    private init() {}

    func handle(action: String, args: [String: Any]) async -> Any? {
        switch action {
        case "startRecord":
            let w = Int(args["w"] as? Double ?? 480)
            let h = Int(args["h"] as? Double ?? 640)
            return startRecord(width: w, height: h)
        case "cancel":
            cancel()
            return true
        default:
            return nil
        }
    }

    func startRecord(width: Int, height: Int) -> Bool {
        guard !recording else { return false }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aion_rec_\(UUID().uuidString).mp4")
        do {
            let w = AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: max(160, width),
                AVVideoHeightKey: max(160, height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1_200_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: max(160, width),
                    kCVPixelBufferHeightKey as String: max(160, height),
                ])
            w.add(input)
            writer = w
            videoInput = input
            self.adaptor = adaptor
            recordURL = outputURL
            sessionStarted = false
            recording = true
            consumerId = AionCameraModule.shared.addFrameConsumer { [weak self] buffer, pts in
                self?.appendFrame(buffer, pts: pts)
            }
            AionLogger.shared.log("video record started w=\(width) h=\(height)")
            return true
        } catch {
            AionLogger.shared.log("video record start failed: \(error.localizedDescription)")
            return false
        }
    }

    private var recordURL: URL?

    /// 同步停止：等写完（后台队列 signal），读文件 → base64（对齐安卓一次性返回语义）
    func stopRecordSync() -> String {
        guard recording, let writer else { return "" }
        recording = false
        AionCameraModule.shared.removeFrameConsumer(id: consumerId)
        consumerId = -1
        let sem = DispatchSemaphore(value: 0)
        writerQueue.async {
            if self.sessionStarted {
                self.videoInput?.markAsFinished()
            }
            writer.finishWriting { [weak self] in
                self?.sessionStarted = false
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + 10) == .timedOut {
            AionLogger.shared.log("video finish timeout")
            return ""
        }
        defer {
            self.writer = nil
            self.videoInput = nil
            self.adaptor = nil
        }
        guard let url = recordURL,
              let data = try? Data(contentsOf: url) else {
            AionLogger.shared.log("video file read failed")
            return ""
        }
        try? FileManager.default.removeItem(at: url)
        AionLogger.shared.log("video record done bytes=\(data.count)")
        return data.base64EncodedString()
    }

    func cancel() {
        guard recording else { return }
        recording = false
        AionCameraModule.shared.removeFrameConsumer(id: consumerId)
        consumerId = -1
        writerQueue.async { [weak self] in
            guard let self else { return }
            if self.sessionStarted {
                self.videoInput?.markAsFinished()
            }
            self.writer?.cancelWriting()
            if let url = self.recordURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        writer = nil
        videoInput = nil
        adaptor = nil
        AionLogger.shared.log("video record cancelled")
    }

    /// encodeQueue 串行回调：首帧起 session，逐帧 append
    private func appendFrame(_ buffer: CVPixelBuffer, pts: CMTime) {
        guard recording else { return }
        writerQueue.async { [weak self] in
            guard let self, let writer = self.writer, let input = self.videoInput,
                  let adaptor = self.adaptor else { return }
            if !self.sessionStarted {
                if writer.status == .unknown {
                    writer.startWriting()
                    writer.startSession(atSourceTime: pts)
                }
                self.sessionStarted = true
            }
            guard input.isReadyForMoreMediaData else { return }
            adaptor.append(buffer, withPresentationTime: pts)
        }
    }
}
