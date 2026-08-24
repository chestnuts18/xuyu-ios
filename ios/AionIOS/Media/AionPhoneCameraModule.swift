import Foundation
import AVFoundation
import UIKit

/// 远程查岗拍照（对齐安卓 AionPhoneCamera 契约）——iOS 降级版：
/// 只能 App 前台时拍（iOS 不允许后台摄像头）。arm 后由 15s 轮询查 pending 命令，
/// 徐聿的拍照请求会排队，下次念宝打开 XuYu 即补拍。
/// 上传契约与安卓一致：POST /api/phone-camera/upload（JPEG body +
/// x-phone-camera-request-id / x-phone-camera-metadata 头），失败走 /failure。
@MainActor
final class AionPhoneCameraModule: NSObject {
    static let shared = AionPhoneCameraModule()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let encodeQueue = DispatchQueue(label: "aion.phonecam.encode")

    private(set) var armed = false
    private var facing = "back"   // 网页契约：front/back
    private var previewOn = false
    private var lastPreviewPushAt: Double = 0
    private var pendingPhotoDelegate: PhotoCaptureDelegate?

    override private init() {
        super.init()
        armed = UserDefaults.standard.bool(forKey: "phonecam.armed")
    }

    // MARK: - 网页动作

    func handle(action: String, args: [String: Any]) async -> Any? {
        switch action {
        case "arm":
            let f = String(args["facing"] as? String ?? "back")
            let z = Double(args["zoom"] as? Double ?? 1.0)
            return await arm(facing: f, zoom: z)
        case "disarm":
            disarm()
            return true
        case "requestPreview":
            let f = String(args["facing"] as? String ?? "back")
            let z = Double(args["zoom"] as? Double ?? 1.0)
            return await requestPreview(facing: f, zoom: z)
        case "setPreviewVisible":
            previewOn = (args["visible"] as? Bool) ?? false
            return true
        case "stopPreview":
            stopPreview()
            return true
        default:
            return nil
        }
    }

    func arm(facing: String, zoom: Double) async -> Bool {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        if auth == .denied || auth == .restricted { return false }
        if auth == .notDetermined {
            guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        }
        self.facing = (facing == "front") ? "front" : "back"
        armed = true
        UserDefaults.standard.set(true, forKey: "phonecam.armed")
        AionJSBridge.shared.pushCachePartial(["phoneCamCaps": capabilitiesJSON()])
        AionLogger.shared.log("phonecam armed facing=\(self.facing)")
        return true
    }

    func disarm() {
        armed = false
        UserDefaults.standard.set(false, forKey: "phonecam.armed")
        stopPreview()
        AionLogger.shared.log("phonecam disarmed")
    }

    func requestPreview(facing: String, zoom: Double) async -> Bool {
        self.facing = (facing == "front") ? "front" : "back"
        let ok = await startSession()
        if ok {
            previewOn = true
            AionJSBridge.shared.pushCachePartial(["phoneCamCaps": capabilitiesJSON()])
        }
        return ok
    }

    func stopPreview() {
        previewOn = false
        session.stopRunning()
    }

    private func startSession() async -> Bool {
        guard session.inputs.isEmpty else {
            if !session.isRunning { session.startRunning() }
            return true
        }
        let pos: AVCaptureDevice.Position = (facing == "front") ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos) else {
            return false
        }
        do {
            session.beginConfiguration()
            session.sessionPreset = .medium
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return false
            }
            session.addInput(input)
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: encodeQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            session.commitConfiguration()
            if let conn = videoOutput.connection(with: .video) {
                // videoRotationAngle 是 iOS 17+ API，部署目标 16 用旧接口
                if #available(iOS 17.0, *) {
                    conn.videoRotationAngle = 90
                } else {
                    conn.videoOrientation = .portrait
                }
            }
            session.startRunning()
            return true
        } catch {
            AionLogger.shared.log("phonecam session failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 能力 JSON（对齐安卓 getCapabilities 返回字符串语义）
    func capabilitiesJSON() -> String {
        var caps: [String: Any] = [:]
        for (key, pos) in [("front", AVCaptureDevice.Position.front),
                           ("back", AVCaptureDevice.Position.back)] {
            if let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos) {
                caps[key] = [
                    "presets": [1.0, 2.0, 4.0],
                    "minZoom": 1.0,
                    "maxZoom": Double(min(d.activeFormat.videoMaxZoomFactor, 8.0)),
                ]
            } else {
                caps[key] = ["presets": [1.0], "minZoom": 1.0, "maxZoom": 1.0]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: caps),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - pending 命令轮询（AionSupervisionPoller 15s 携带，仅前台）

    func pollIfArmed() async {
        guard armed, UIApplication.shared.applicationState == .active else { return }
        var components = URLComponents(
            url: APIClient.shared.url(for: "/api/phone-camera/commands/pending"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "client_id", value: DeviceIdentity.deviceId)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let t = APIClient.shared.currentToken {
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let commands = obj["commands"] as? [[String: Any]],
                  let first = commands.first,
                  let requestId = first["request_id"] as? String else { return }
            let cmdFacing = first["facing"] as? String ?? "back"
            let cmdZoom = Double(first["zoom"] as? Double ?? 1.0)
            let reason = first["reason"] as? String ?? ""
            AionLogger.shared.log("phonecam pending cmd id=\(requestId) reason=\(reason)")
            await captureForEvent(requestId: requestId, facing: cmdFacing, zoom: cmdZoom)
        } catch {
            AionLogger.shared.log("phonecam poll failed: \(error.localizedDescription)")
        }
    }

    private func captureForEvent(requestId: String, facing: String, zoom: Double) async {
        AionJSBridge.shared.callWebFunction("onAionPhoneCameraCaptureState", arg: "true")
        defer {
            AionJSBridge.shared.callWebFunction("onAionPhoneCameraCaptureState", arg: "false")
        }
        // 命令指定朝向（与 arm 时不同则重建会话）
        if facing != self.facing {
            self.facing = facing
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }
        }
        guard await startSession() else {
            await reportFailure(requestId: requestId, error: "camera_unavailable")
            return
        }
        guard let jpeg = captureSync() else {
            await reportFailure(requestId: requestId, error: "capture_failed")
            return
        }
        await uploadJPEG(requestId: requestId, jpeg: jpeg, facing: facing, zoom: zoom)
    }

    private func captureSync() -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        let delegate = PhotoCaptureDelegate { b64 in
            if !b64.isEmpty, let data = Data(base64Encoded: b64) {
                result = Self.fitUploadLimit(data)
            }
            sem.signal()
        }
        pendingPhotoDelegate = delegate
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        _ = sem.wait(timeout: .now() + 2.5)
        pendingPhotoDelegate = nil
        return result
    }

    /// 服务器上限 800KB：超限降采样重压（1080p → 720p → 更低质量）
    nonisolated static func fitUploadLimit(_ data: Data) -> Data {
        guard data.count > 800_000, let image = UIImage(data: data) else { return data }
        var scale: CGFloat = 0.5
        var out = data
        for quality in [0.5, 0.35, 0.25] {
            let size = CGSize(width: image.size.width * scale,
                              height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let d = resized.jpegData(compressionQuality: quality) {
                out = d
                if d.count <= 800_000 { break }
            }
            scale *= 0.6
        }
        return out
    }

    private func uploadJPEG(requestId: String, jpeg: Data, facing: String, zoom: Double) async {
        var request = URLRequest(url: APIClient.shared.url(for: "/api/phone-camera/upload"))
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(requestId, forHTTPHeaderField: "x-phone-camera-request-id")
        let meta: [String: Any] = [
            "facing": facing, "zoom": zoom,
            "device": DeviceIdentity.deviceId, "source": "ios",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta),
           let json = String(data: data, encoding: .utf8) {
            request.setValue(json, forHTTPHeaderField: "x-phone-camera-metadata")
        }
        if let t = APIClient.shared.currentToken {
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 20
        request.httpBody = jpeg
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            AionLogger.shared.log("phonecam upload id=\(requestId) http=\(code)")
            if code != 200 {
                await reportFailure(requestId: requestId, error: "upload_http_\(code)")
            }
        } catch {
            AionLogger.shared.log("phonecam upload error: \(error.localizedDescription)")
            await reportFailure(requestId: requestId, error: "upload_error")
        }
    }

    private func reportFailure(requestId: String, error: String) async {
        var request = URLRequest(url: APIClient.shared.url(for: "/api/phone-camera/failure"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = APIClient.shared.currentToken {
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "request_id": requestId, "error": error,
            "metadata": ["device": DeviceIdentity.deviceId],
        ])
        _ = try? await URLSession.shared.data(for: request)
    }
}

// MARK: - 预览帧（1200ms 节流，预览帧不上传服务器，纯本地显示）

extension AionPhoneCameraModule: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task { @MainActor in
            let shared = AionPhoneCameraModule.shared
            let now = CACurrentMediaTime()
            guard shared.previewOn, now - shared.lastPreviewPushAt >= 1.2 else { return }
            shared.lastPreviewPushAt = now
            guard let b64 = AionCameraModule.encodeJPEG(pixelBuffer) else { return }
            AionJSBridge.shared.pushCachePartial(["phonePreviewFrame": b64])
        }
    }
}
