import Foundation
import AVFoundation
import UIKit

/// 网页摄像头桥（对齐安卓 CameraBridge 契约）：预览帧 pull + 拍照 + 翻转 + 变焦
/// 帧编码走 encodeQueue（15fps 节流），读侧经 stateLock 同步读，不卡主线程。
/// 预览帧/拍照在锁屏或后台不可用（iOS 限制），桥只在 App 前台时被网页调用。
@MainActor
final class AionCameraModule: NSObject {
    static let shared = AionCameraModule()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let encodeQueue = DispatchQueue(label: "aion.camera.encode")
    private let stateLock = NSLock()

    private(set) var facing = "user"
    private(set) var running = false

    // 帧缓存（stateLock 保护，getFrame/同步通道读）
    private var _latestFrame = ""
    private var _lastFrameAt: Double = 0
    private var _rotatedW = 0
    private var _rotatedH = 0
    private var lastEncodeAt: Double = 0

    /// 录像模块挂这里（同一 session 的帧扇出，stateLock 保护）
    private var frameConsumers: [(CVPixelBuffer, CMTime) -> Void] = []
    private var pendingPhotoDelegate: PhotoCaptureDelegate?

    func addFrameConsumer(_ consumer: @escaping (CVPixelBuffer, CMTime) -> Void) -> Int {
        stateLock.lock()
        frameConsumers.append(consumer)
        let id = frameConsumers.count - 1
        stateLock.unlock()
        return id
    }

    func removeFrameConsumer(id: Int) {
        stateLock.lock()
        if id >= 0 && id < frameConsumers.count {
            frameConsumers.remove(at: id)
        }
        stateLock.unlock()
    }

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
            try configure(facing: facingIn)
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
        stateLock.lock(); defer { stateLock.unlock() }
        return _latestFrame
    }

    var lastFrameAt: Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastFrameAt
    }

    var rotatedWidth: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _rotatedW
    }

    var rotatedHeight: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _rotatedH
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
            conn.videoRotationAngle = 90  // App 竖屏锁定，帧转正
        }
        session.startRunning()
        running = true
    }

    enum CameraError: Error { case noDevice, inputRejected }
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
        let now = CACurrentMediaTime()
        // 15fps 节流 + 扇出给录像模块（encodeQueue 串行，consumer 顺序执行）
        stateLock.lock()
        let consumers = frameConsumers
        let shouldEncode = now - lastEncodeAt >= 0.066
        if shouldEncode { lastEncodeAt = now }
        stateLock.unlock()
        for consumer in consumers {
            consumer(pixelBuffer, pts)
        }
        guard shouldEncode else { return }
        guard let b64 = Self.encodeJPEG(pixelBuffer) else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        stateLock.lock()
        _latestFrame = b64
        _lastFrameAt = now * 1000
        _rotatedW = h  // 90° 旋转后宽高互换
        _rotatedH = w
        stateLock.unlock()
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
