import Foundation
import CoreBluetooth

/// 玩具 BLE：SOSEXY 三电机。
/// 协议照抄 chat.js（EE01 服务 / EE03 写 / EE02 通知，18 字节分包）；
/// 桥复用 window.AionBle 语义，状态回调走 chat.js 自建的 window.toyNativeBle。
@MainActor
final class ToyBLEManager: NSObject, ObservableObject {
    static let shared = ToyBLEManager()

    private static let serviceUUID = CBUUID(string: "EE01")
    private static let writeUUID = CBUUID(string: "EE03")
    private static let notifyUUID = CBUUID(string: "EE02")

    @Published private(set) var isConnected = false
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var pendingPackets: [[UInt8]] = []
    private var writing = false

    override private init() { super.init() }

    // MARK: - 网页桥入口（AionBle.connect/disconnect/sendData/isConnected）

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
        log("开始扫描 SOSEXY…")
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
        let packets = ToyCommand.packets(forHexCmd: hexCmd)
        pendingPackets.append(contentsOf: packets)
        pumpPackets()
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
            guard name.uppercased().hasPrefix("SOSEXY") else { return }
            self.peripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didConnect peripheral: CBPeripheral
    ) {
        Task { @MainActor in
            peripheral.discoverServices([Self.serviceUUID])
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
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
            else { return }
            peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard let chars = service.characteristics else { return }
            for ch in chars {
                if ch.uuid == Self.writeUUID { self.writeChar = ch }
                if ch.uuid == Self.notifyUUID { peripheral.setNotifyValue(true, for: ch) }
            }
            self.isConnected = true
            AionJSBridge.shared.pushCache()
            AionJSBridge.shared.callToyNative("onConnected")
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
