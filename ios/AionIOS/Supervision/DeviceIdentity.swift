import Foundation

/// 设备身份：对齐安卓 "android-<id前8>" 的 "ios-xxx" 前缀。
/// 自用场景（一台 iPhone 一个用户）：写死稳定 ID——
/// UserDefaults 每次重装被清、Keychain 在这台真机上不工作（实测每 15s 漂移一个
/// 新 ID，服务器堆积僵尸设备条目），写死一劳永逸。
enum DeviceIdentity {
    static var deviceId: String { "ios-nianbao" }

    static let deviceName = "iPhone"
}
