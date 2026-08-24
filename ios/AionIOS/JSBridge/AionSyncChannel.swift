import Foundation

/// prompt 同步通道：网页 prompt('__aion_sync:<module>:<method>[:arg]') → 原生同步字符串返回。
/// 只放必须同步的方法（摄像头帧 pull / 拍照 / 录像停止），其余走异步 __aionCall。
/// ⚠️ capture/stopRecord 会短暂阻塞主线程（一次性动作，对齐安卓 sync 语义）；
/// 底层信号量等待的后台完成回调不依赖主线程，无死锁。
@MainActor
enum AionSyncChannel {
    static func handle(_ prompt: String) -> String {
        let body = String(prompt.dropFirst("__aion_sync:".count))
        let parts = body.split(separator: ":", maxSplits: 2).map(String.init)
        let module = parts.count > 0 ? parts[0] : ""
        let method = parts.count > 1 ? parts[1] : ""
        let arg = parts.count > 2 ? parts[2] : ""

        switch (module, method) {
        case ("camera", "getFrame"):
            return AionCameraModule.shared.getFrame()
        case ("camera", "capture"):
            return AionCameraModule.shared.captureSync()
        case ("camera", "isRunning"):
            return AionCameraModule.shared.running ? "1" : "0"
        case ("camera", "getFacing"):
            return AionCameraModule.shared.facing
        case ("camera", "getLastFrameAt"):
            return String(AionCameraModule.shared.lastFrameAt)
        case ("camera", "getRotatedWidth"):
            return String(AionCameraModule.shared.rotatedWidth)
        case ("camera", "getRotatedHeight"):
            return String(AionCameraModule.shared.rotatedHeight)
        case ("video", "stopRecord"):
            return AionVideoModule.shared.stopRecordSync()
        default:
            _ = arg
            return ""
        }
    }
}
