import Foundation
import CoreBluetooth

/// 玩具 BLE：SOSEXY 三电机 + ANKNI（趴趴猫）多玩具体系（2026-10-05 加）。
/// SOSEXY：服务 EE01 / 写 EE03 / 通知 EE02，18 字节分包（照抄 chat.js）。
/// ANKNI：广播名以 ANKNI 开头；不限定服务，枚举全部服务的可写特征，
///        按优先级 DDD1>FFE1>FEE1>AE01>DD11 选写特征；指令为裸 hex（AA 头+校验和，页面 JS 编码）。
/// 桥复用 window.AionBle 语义，状态回调走网页自建的 window.toyNativeBle（主+子 frame）。
@MainActor
final class ToyBLEManager: NSObject, ObservableObject {
    static let shared = ToyBLEManager()

    // MARK: - 多玩具 profile

    struct ProfileSpec {
        let key: String
        let namePrefix: String
        let serviceUUID: CBUUID?      // nil = 发现全部服务（ANKNI）
        let writeUUIDs: [CBUUID]      // 按优先级（SOSEXY 单元素即限定）
        let notifyUUID: CBUUID?
    }
    static let sosexySpec = ProfileSpec(
        key: "sosexy", namePrefix: "SOSEXY",
        serviceUUID: CBUUID(string: "EE01"),
        writeUUIDs: [CBUUID(string: "EE03")],
        notifyUUID: CBUUID(string: "EE02"))
    static let ankniSpec = ProfileSpec(
        key: "ankni", namePrefix: "ANKNI",
        serviceUUID: nil,
        writeUUIDs: ["DDD1", "FFE1", "FEE1", "AE01", "DD11"].map { CBUUID(string: $0) },
        notifyUUID: nil)

    @Published private(set) var isConnected = false
    private(set) var selectedProfileKey = "sosexy"
    private(set) var deviceName = ""
    private var ankniTargets: [CBCharacteristic] = []
    private var discoveredServices = 0

    var currentSpec: ProfileSpec { selectedProfileKey == "ankni" ? Self.ankniSpec : Self.sosexySpec }

    /// 桥的同步缓存（getAnkniWriteTargets 用；对齐安卓 "服务UUID / 特征UUID" 展示）
    var ankniTargetsJson: String {
        let rows = ankniTargets.map { ch -> String in
            (ch.service?.uuid.uuidString ?? "?") + " / " + ch.uuid.uuidString
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var pendingPackets: [[UInt8]] = []
    private var writing = false

    override private init() { super.init() }

    // MARK: - 网页桥入口（AionBle.connect/disconnect/sendData/isConnected/selectProfile…）

    func handle(action: String, args: [String: Any]) async -> Any? {
        switch action {
        case "connect":
            connect()
            return ["connecting": true]
        case "disconnect":
            disconnect()
            return ["connected": false]
        case "sendData":
            guard let hex = args["hex"] as? String else { return ["ok": false] }
            send(hexCmd: hex)
            return ["ok": true]
        case "isConnected":
            return ["connected": isConnected]
        case "selectProfile":
            let key = ((args["profile"] as? String) ?? "sosexy").lowercased()
            selectedProfileKey = (key == "ankni") ? "ankni" : "sosexy"
            AionJSBridge.shared.pushCache()
            return ["profile": selectedProfileKey]
        case "selectAnkniWriteTarget":
            let index = (args["index"] as? Int) ?? -1
            guard selectedProfileKey == "ankni", index >= 0, index < ankniTargets.count else {
                return ["ok": false]
            }
            writeChar = ankniTargets[index]
            return ["ok": true]
        default:
            return nil
        }
    }

    // MARK: - 连接管理

    func connect() {
        guard central == nil else {
            if central?.state == .poweredOn {
                Self.startScan(central)
            }
            return
        }
        log("开始扫描 \(currentSpec.namePrefix)…")
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// 扫全部设备 + didDiscover 里按名字前缀过滤——很多 BLE 外设广播包不带
    /// service UUID 列表，withServices 过滤会直接漏掉
    private static func startScan(_ central: CBCentralManager?) {
        central?.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func disconnect() {
        guard let peripheral else { return }
        central?.cancelPeripheralConnection(peripheral)
    }

    private func send(hexCmd: String) {
        log("→ \(hexCmd)")
        guard let writeChar else {
            AionJSBridge.shared.callToyNative("onError", arg: "未连接")
            return
        }
        if selectedProfileKey == "ankni" {
            // ANKNI：裸 hex 直写（无 SOSEXY 封包/18 字节分包；协议包 ≤8 字节）
            guard let data = Self.hexToData(hexCmd) else { return }
            let type: CBCharacteristicWriteType =
                writeChar.properties.contains(.write) ? .withResponse : .withoutResponse
            peripheral?.writeValue(data, for: writeChar, type: type)
            return
        }
        let packets = ToyCommand.packets(forHexCmd: hexCmd)
        pendingPackets.append(contentsOf: packets)
        pumpPackets()
    }

    private static func hexToData(_ hex: String) -> Data? {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let end = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[idx..<end], radix: 16) else { return nil }
            data.append(byte)
            idx = end
        }
        return data
    }

    /// 按序写包：withResponse 优先（对齐 chat.js），包间 30ms
    private func pumpPackets() {
        guard !writing, !pendingPackets.isEmpty, let peripheral, let writeChar else { return }
        writing = true
        let packet = pendingPackets.removeFirst()
        let type: CBCharacteristicWriteType =
            writeChar.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(packet), for: writeChar, type: type)
        // withoutResponse 无回执，自己续；withResponse 走 didWriteValueFor
        if type == .withoutResponse {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000)
                await self?.continuePackets()
            }
        }
    }

    private func continuePackets() {
        guard !pendingPackets.isEmpty else {
            writing = false
            return
        }
        // 多包之间 30ms（对齐 chat.js toySleep(30)）
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard let self else { return }
            self.writing = false
            self.pumpPackets()
        }
    }

    private func cleanup() {
        isConnected = false
        writeChar = nil
        pendingPackets.removeAll()
        writing = false
        ankniTargets.removeAll()
        discoveredServices = 0
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        central = nil
        AionJSBridge.shared.pushCache()
    }

    private func log(_ msg: String) {
        AionJSBridge.shared.callToyNative("onLog", arg: msg)
    }

    // MARK: - ANKNI 特征收尾（全部服务的特征发现完成后按优先级选写特征）

    private func finalizeAnkni() {
        guard !ankniTargets.isEmpty else {
            AionJSBridge.shared.callToyNative("onError", arg: "ANKNI 没有可写特征")
            cleanup()
            return
        }
        let order = ["DDD1", "FFE1", "FEE1", "AE01", "DD11"]
        ankniTargets.sort {
            (order.firstIndex(of: $0.uuid.uuidString) ?? 999)
                < (order.firstIndex(of: $1.uuid.uuidString) ?? 999)
        }
        writeChar = ankniTargets[0]
        isConnected = true
        AionJSBridge.shared.pushCache()
        AionJSBridge.shared.callToyNativeArgs("onConnected", args: ["ankni", deviceName])
    }
}

// MARK: - CBCentralManagerDelegate

extension ToyBLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard central.state == .poweredOn else {
                AionJSBridge.shared.callToyNative(
                    "onError", arg: "蓝牙不可用（状态 \(central.state.rawValue)）"
                )
                return
            }
            Self.startScan(central)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let name = peripheral.name
                ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? ""
            guard name.uppercased().hasPrefix(self.currentSpec.namePrefix) else { return }
            self.peripheral = peripheral
            self.deviceName = name
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didConnect peripheral: CBPeripheral
    ) {
        Task { @MainActor in
            if let service = self.currentSpec.serviceUUID {
                peripheral.discoverServices([service])
            } else {
                // ANKNI：不限服务，全部发现后枚举可写特征
                peripheral.discoverServices(nil)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            AionJSBridge.shared.callToyNative(
                "onError", arg: "连接失败：\(error?.localizedDescription ?? "未知")"
            )
            self.cleanup()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.cleanup()
            AionJSBridge.shared.callToyNative("onDisconnected")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ToyBLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverServices error: Error?
    ) {
        Task { @MainActor in
            guard error == nil, let services = peripheral.services, !services.isEmpty else { return }
            if let target = self.currentSpec.serviceUUID {
                // SOSEXY：只看 EE01
                guard let service = services.first(where: { $0.uuid == target }) else { return }
                peripheral.discoverCharacteristics(
                    [Self.sosexySpec.writeUUIDs[0], Self.sosexySpec.notifyUUID!], for: service
                )
            } else {
                // ANKNI：全部服务
                self.ankniTargets.removeAll()
                self.discoveredServices = 0
                for service in services {
                    peripheral.discoverCharacteristics(nil, for: service)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard error == nil, let chars = service.characteristics else { return }
            if self.currentSpec.serviceUUID != nil {
                // SOSEXY 老逻辑
                for ch in chars {
                    if ch.uuid == Self.sosexySpec.writeUUIDs[0] { self.writeChar = ch }
                    if ch.uuid == Self.sosexySpec.notifyUUID { peripheral.setNotifyValue(true, for: ch) }
                }
                self.isConnected = true
                AionJSBridge.shared.pushCache()
                AionJSBridge.shared.callToyNativeArgs("onConnected", args: ["sosexy", self.deviceName])
            } else {
                // ANKNI：累积可写特征，全部服务回调完成后选优
                for ch in chars where ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                    self.ankniTargets.append(ch)
                }
                self.discoveredServices += 1
                if self.discoveredServices >= (peripheral.services?.count ?? 1) {
                    self.finalizeAnkni()
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                AionJSBridge.shared.callToyNative(
                    "onError", arg: "写入失败: \(error.localizedDescription)"
                )
                self.pendingPackets.removeAll()
                self.writing = false
                return
            }
            self.continuePackets()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                AionJSBridge.shared.callToyNative(
                    "onError", arg: "通知错误: \(error.localizedDescription)"
                )
            }
        }
    }
}
