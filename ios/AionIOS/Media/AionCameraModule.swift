import Foundation
import AVFoundation
import UIKit

/// 帧缓存状态：非隔离类（NSLock 保护）——encodeQueue 写、主线程读，
/// 避免 @MainActor 隔离在数据竞态上的误伤（Swift 6 严格模式兼容）
final class CameraSharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _latestFrame = ""
    private var _lastFrameAt: Double = 0
    private var _rotatedW = 0
    private var _rotatedH = 0
    private var _lastEncodeAt: Double = 0
    private var consumers: [Int: (CVPixelBuffer, CMTime) -> Void] = [:]
    private var nextConsumerId = 0

    /// 15fps 节流判定 + 当前帧消费者快照（一次加锁取齐）
    func snapshotForEncode() -> (shouldEncode: Bool, consumers: [(CVPixelBuffer, CMTime) -> Void]) {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let should = now - _lastEncodeAt >= 0.066
        if should { _lastEncodeAt = now }
        return (should, Array(consumers.values))
    }

    func storeFrame(b64: String, rotatedW: Int, rotatedH: Int) {
        lock.lock(); defer { lock.unlock() }
        _latestFrame = b64
        _lastFrameAt = CACurrentMediaTime() * 1000
        _rotatedW = rotatedW
        _rotatedH = rotatedH
    }

    var frame: (b64: String, at: Double, w: Int, h: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_latestFrame, _lastFrameAt, _rotatedW, _rotatedH)
    }

    func addConsumer(_ c: @escaping (CVPixelBuffer, CMTime) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextConsumerId += 1
        consumers[nextConsumerId] = c
        return nextConsumerId
    }

    func removeConsumer(id: Int) {
        lock.lock(); defer { lock.unlock() }
        consumers.removeValue(forKey: id)
    }
}

/// 网页摄像头桥（对齐安卓 CameraBridge 契约）：预览帧 pull + 拍照 + 翻转 + 变焦
/// 帧编码走 encodeQueue（15fps 节流），读侧经 CameraSharedState 同步读，不卡主线程。
/// 预览帧/拍照在锁屏或后台不可用（iOS 限制），桥只在 App 前台时被网页调用。
@MainActor
final class AionCameraModule: NSObject {
    static let shared = AionCameraModule()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let encodeQueue = DispatchQueue(label: "aion.camera.encode")
    /// 与全局 Holder 同一实例：主线程读侧 / encodeQueue 写侧共享一份状态
    private var state: CameraSharedState { CameraSharedStateHolder.shared.state }

    private(set) var facing = "user"
    private(set) var running = false

    private var pendingPhotoDelegate: PhotoCaptureDelegate?

    override private init() { super.init() }

    // MARK: - 网页动作（async 桥）

    func handle(action: String, args: [String: Any]) async -> Any? {
        switch action {
        case "start":
            return await start(String(args["facing"] as? String ?? "user"))
        case "stop":
            stop()
            return true
        case "flip":
            return await start(facing == "user" ? "environment" : "user")
        case "setZoom":
            setZoom(Double(args["zoom"] as? Double ?? 1.0))
            return true
        default:
            return nil
        }
    }

    func start(_ facingIn: String) async -> Bool {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        if auth == .denied || auth == .restricted { return false }
        if auth == .notDetermined {
            guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        }
        do {
            try configure(facingIn: facingIn)
            AionLogger.shared.log("camera started facing=\(facing)")
            AionJSBridge.shared.pushCachePartial(["cameraRunning": true, "cameraFacing": facing])
            return true
        } catch {
            AionLogger.shared.log("camera start failed: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        guard running else { return }
        session.stopRunning()
        running = false
        AionJSBridge.shared.pushCachePartial(["cameraRunning": false])
    }

    func setZoom(_ z: Double) {
        guard let device = currentDevice() else { return }
        try? device.lockForConfiguration()
        device.videoZoomFactor = CGFloat(max(1.0, min(z, device.activeFormat.videoMaxZoomFactor)))
        device.unlockForConfiguration()
    }

    // MARK: - 同步读（prompt 通道；读侧不阻塞）

    func getFrame() -> String {
        state.frame.b64
    }

    var lastFrameAt: Double {
        state.frame.at
    }

    var rotatedWidth: Int {
        state.frame.w
    }

    var rotatedHeight: Int {
        state.frame.h
    }

    /// 同步拍照：阻塞主线程等拍照完成（一次性动作，对齐安卓 sync 语义）
    func captureSync() -> String {
        guard running else { return "" }
        let sem = DispatchSemaphore(value: 0)
        var result = ""
        let settings = AVCapturePhotoSettings()
        let delegate = PhotoCaptureDelegate { b64 in
            result = b64
            sem.signal()
        }
        pendingPhotoDelegate = delegate  // 强持有到回调完成
        photoOutput.capturePhoto(with: settings, delegate: delegate)
        _ = sem.wait(timeout: .now() + 2.5)
        pendingPhotoDelegate = nil
        return result
    }

    // MARK: - 会话配置

    private func currentDevice() -> AVCaptureDevice? {
        let pos: AVCaptureDevice.Position = facing == "environment" ? .back : .front
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos)
    }

    private func configure(facingIn: String) throws {
        if running, facingIn == facing {
            return  // 已在跑且朝向一致
        }
        if running { session.stopRunning() }
        session.beginConfiguration()
        session.sessionPreset = .medium  // 480p：预览帧省带宽，够用
        for input in session.inputs { session.removeInput(input) }
        guard let device = currentDevice() else {
            session.commitConfiguration()
            throw CameraError.noDevice
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.inputRejected
        }
        session.addInput(input)
        if session.outputs.isEmpty {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: encodeQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        }
        session.commitConfiguration()
        facing = facingIn
        if let conn = videoOutput.connection(with: .video) {
            // App 竖屏锁定，帧转正（videoRotationAngle 是 iOS 17+ API，16 用旧接口）
            if #available(iOS 17.0, *) {
                conn.videoRotationAngle = 90
            } else {
                conn.videoOrientation = .portrait
            }
        }
        session.startRunning()
        running = true
    }

    enum CameraError: Error { case noDevice, inputRejected }

    // MARK: - 录像模块帧扇出

    func addFrameConsumer(_ consumer: @escaping (CVPixelBuffer, CMTime) -> Void) -> Int {
        state.addConsumer(consumer)
    }

    func removeFrameConsumer(id: Int) {
        state.removeConsumer(id: id)
    }
}

// MARK: - 帧回调（encodeQueue 线程）

extension AionCameraModule: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let snap = AionCameraModule.sharedStateForEncode()
        for consumer in snap.consumers {
            consumer(pixelBuffer, pts)
        }
        guard snap.shouldEncode else { return }
        guard let b64 = Self.encodeJPEG(pixelBuffer) else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        AionCameraModule.sharedStateStoreFrame(b64: b64, rotatedW: h, rotatedH: w)
    }

    nonisolated static func sharedStateForEncode() -> (shouldEncode: Bool, consumers: [(CVPixelBuffer, CMTime) -> Void]) {
        CameraSharedStateHolder.shared.state.snapshotForEncode()
    }

    nonisolated static func sharedStateStoreFrame(b64: String, rotatedW: Int, rotatedH: Int) {
        CameraSharedStateHolder.shared.state.storeFrame(b64: b64, rotatedW: rotatedW, rotatedH: rotatedH)
    }

    /// 像素缓冲 → 竖转 90° → JPEG base64（无 data: 前缀，对齐网页契约）
    nonisolated static func encodeJPEG(_ pixelBuffer: CVPixelBuffer) -> String? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rotated = ci.oriented(.right)  // 竖转
        let extent = CGRect(x: 0, y: 0, width: height, height: width)
        guard let cg = context.createCGImage(rotated, from: extent) else { return nil }
        let image = UIImage(cgImage: cg)
        guard let data = image.jpegData(compressionQuality: 0.55) else { return nil }
        return data.base64EncodedString()
    }
}

/// 全局单例共享帧状态（避免非隔离回调访问 @MainActor 模块的单例）
final class CameraSharedStateHolder: @unchecked Sendable {
    static let shared = CameraSharedStateHolder()
    let state = CameraSharedState()
}

/// 拍照回调委托（callback 在 AVFoundation 内部队列，signal 不阻塞主线程）
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onDone: (String) -> Void

    init(onDone: @escaping (String) -> Void) {
        self.onDone = onDone
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            onDone("")
            return
        }
        onDone(data.base64EncodedString())
    }
}
