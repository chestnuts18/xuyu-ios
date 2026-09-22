import Foundation
import CoreBluetooth

/// ANCS 中继（2026-09-23）：把板子缓存的 iPhone 通知取走、上传服务器。
///
/// 链路：iPhone 通知 → ANCS → ESP32 → [本模块] → POST /api/device-context/notification
///
/// 关键设计：
/// - App 与 iOS 系统**共用同一条 BLE 物理链路**（CoreBluetooth 引用计数共享），
///   所以优先 `retrieveConnectedPeripherals` 依附系统那条 ANCS 连接，不主动抢占。
/// - ACK 语义 = 「已成功上传」，不是「已读到」。先 ACK 再传会真丢件。
/// - 队列落盘：断网时存着，恢复后补传。
/// - 心跳日志走 /api/ios-logs —— 出门后唯一的排障眼睛。
@MainActor
final class AionNotifRelay: NSObject {
    static let shared = AionNotifRelay()

    // 与固件逐字对齐（改一处忘一处 = 永远连不上）
    private static let svcUUID    = CBUUID(string: "0000F1A0-0000-1000-8000-00805F9B34FB")
    private static let ctrlUUID   = CBUUID(string: "0000F1A1-0000-1000-8000-00805F9B34FB")
    private static let dataUUID   = CBUUID(string: "0000F1A2-0000-1000-8000-00805F9B34FB")
    private static let ackUUID    = CBUUID(string: "0000F1A3-0000-1000-8000-00805F9B34FB")
    private static let statusUUID = CBUUID(string: "0000F1A4-0000-1000-8000-00805F9B34FB")

    private static let restoreID = "com.chestnuts.aionios.notifrelay"
    private static let periphIDKey = "aion_relay_peripheral_id"
    private static let scanWindow: TimeInterval = 10
    private static let heartbeatInterval: TimeInterval = 300
    private static let ancsStuckGrace: TimeInterval = 60
    private static let queueLimit = 500

    // MARK: - BLE 状态
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var ctrlChar: CBCharacteristic?
    private var dataChar: CBCharacteristic?
    private var ackChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?

    private var started = false
    private var scanningUntil: Date?
    /// 这条连接是不是我主动发起的（决定出问题时要不要让位给系统）
    private var selfInitiated = false
    private var lastAcked: UInt32 = 0
    private var newestSeq: UInt32 = 0
    private var ancsReady = false
    private var ancsZeroSince: Date?
    private var lastConnectAt: Date = .distantPast
    private var lastHeartbeatAt: Date = .distantPast
    /// 板子当前的 bootId（从 payload 的 key `esp-{bootId}-{seq}` 里取）
    private var currentBootId = ""
    private var lastStatusText = ""

    // MARK: - 待上传队列
    private var queue: [[String: Any]] = []
    private var uploading = false

    private override init() { super.init() }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        loadQueue()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
                CBCentralManagerOptionShowPowerAlertKey: false,
            ]
        )
        AionLogger.shared.log("relay start queued=\(queue.count)")
    }

    /// 15 秒 tick（跟 AionSupervisionPoller 走）
    func tick() {
        guard let central, central.state == .poweredOn else { return }
        ensureLink()
        Task { await flush() }
        maybeHeartbeat()
    }

    // MARK: - 连接管理

    private func ensureLink() {
        guard let central else { return }

        // 1) 已连且特征齐 → 没事
        if let p = peripheral, p.state == .connected, ctrlChar != nil, dataChar != nil { return }

        // 2) 系统已经把板子连着了（ANCS 那条）→ 依附上去，不抢
        if let p = central.retrieveConnectedPeripherals(withServices: [Self.svcUUID]).first {
            adopt(p, initiated: false)
            return
        }

        // 3) 记过身份 → 直接寻呼
        if peripheral == nil,
           let idStr = UserDefaults.standard.string(forKey: Self.periphIDKey),
           let uuid = UUID(uuidString: idStr),
           let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            adopt(p, initiated: true)
            return
        }

        // 4) 兜底扫描（必须带 service 过滤：后台扫描不允许 nil）
        if scanningUntil == nil || Date() > (scanningUntil ?? .distantPast) {
            scanningUntil = Date().addingTimeInterval(Self.scanWindow)
            central.scanForPeripherals(withServices: [Self.svcUUID], options: nil)
            AionLogger.shared.log("relay scan…")
        }
    }

    /// ⚠️ 无论系统是否已经连着板子，都必须**显式 connect()**：
    /// retrieveConnectedPeripherals 返回的设备在 App 侧 state 仍是 disconnected，
    /// 不 connect 就永远等不到服务发现（2026-09-23 实测踩到，relay 干等到超时）。
    /// connect() 只是给同一条物理链路加引用计数，**不会抢系统的 ANCS 连接**。
    private func adopt(_ p: CBPeripheral, initiated: Bool) {
        if peripheral !== p || ctrlChar == nil {
            peripheral = p
            selfInitiated = initiated
            p.delegate = self
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.periphIDKey)
            AionLogger.shared.log("relay adopt \(initiated ? "self" : "attached") state=\(p.state.rawValue)")
        }
        guard ctrlChar == nil, dataChar == nil else { return }
        if p.state == .connected {
            discover(p)
        } else if p.state == .disconnected, Date().timeIntervalSince(lastConnectAt) > 5 {
            lastConnectAt = Date()
            central?.connect(p, options: nil)
        }
    }

    private func discover(_ p: CBPeripheral) {
        guard p.state == .connected else {
            AionLogger.shared.log("relay discover skipped state=\(p.state.rawValue)")
            return
        }
        if ctrlChar != nil, dataChar != nil { return }
        p.discoverServices([Self.svcUUID])
    }

    // MARK: - 数据流

    private func handleCtrl(_ d: Data) {
        guard d.count >= 9 else { return }
        let oldest = Self.readU32(d, 0)
        newestSeq = Self.readU32(d, 4)
        ancsReady = d[8] != 0
        checkAncsHealth()
        if oldest != 0 { pullNext() }
    }

    private func pullNext() {
        guard let p = peripheral, let dataChar else { return }
        p.readValue(for: dataChar)
    }

    private func handleData(_ d: Data) {
        guard d.count >= 5 else { return }
        let seq = Self.readU32(d, 0)
        guard seq != 0 else { return }   // 板子说：没待读的了
        let payload = d.subdata(in: 5..<d.count)
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            // ⚠️ 必须跳过：DATA 读是「最老的未确认」，不 ACK 板子就永远重发这一条，
            // 后面的通知全被堵死（2026-09-23 实测：seq=529 卡了整整一轮）。
            // 宁可丢一条，也不能卡住整条链路。
            AionLogger.shared.log("relay bad payload seq=\(seq) len=\(payload.count) — skipping")
            ackOnly(seq)
            return
        }
        // 板子重启检测（2026-09-23 实测踩到）：key = `esp-{bootId}-{seq}`。
        // 板子一重启，seq 就从 1 重新数，而 App 这头还记着旧的大值 ——
        // 「maxSeq > lastAcked」永远为假 → ACK 一条都发不出去 → 板子无限重发。
        if let k = obj["k"] as? String {
            let boot = k.components(separatedBy: "-").dropLast().joined(separator: "-")
            if !currentBootId.isEmpty, boot != currentBootId {
                AionLogger.shared.log("relay board rebooted \(currentBootId)→\(boot) — reset ack")
                lastAcked = 0
            }
            currentBootId = boot
        }

        let item: [String: Any] = [
            "key":      obj["k"] as? String ?? "esp-\(seq)",
            "title":    obj["t"] as? String ?? "",
            "text":     obj["m"] as? String ?? "",
            "app_name": obj["a"] as? String ?? "",
            "source":   "ancs",
            "seq":      Int(seq),
        ]
        enqueue(item)
        AionLogger.shared.log("relay got seq=\(seq) app=\(item["app_name"] ?? "")")
        Task { await flush() }
    }

    /// 架构防御：我主动连的链路若 60 秒还拿不到 ANCS，就断开让位给系统
    private func checkAncsHealth() {
        if ancsReady { ancsZeroSince = nil; return }
        if ancsZeroSince == nil { ancsZeroSince = Date() }
        guard selfInitiated, let since = ancsZeroSince,
              Date().timeIntervalSince(since) > Self.ancsStuckGrace else { return }
        AionLogger.shared.log("relay ancs stuck 60s on self link — yielding")
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        ancsZeroSince = nil
        selfInitiated = false
    }

    // MARK: - 上传

    private func flush() async {
        guard !uploading, !queue.isEmpty else { return }
        uploading = true
        defer { uploading = false }

        var doneCount = 0
        var maxSeq: UInt32 = 0
        for item in queue {
            guard await uploadOne(item) else { break }   // 网络问题 → 剩下的下轮再来
            doneCount += 1
            if let s = item["seq"] as? Int, s > 0 { maxSeq = max(maxSeq, UInt32(s)) }
        }
        guard doneCount > 0 else { return }
        queue.removeFirst(doneCount)
        saveQueue()
        if maxSeq > lastAcked {
            lastAcked = maxSeq
            writeAck(maxSeq)
        }
    }

    private func uploadOne(_ item: [String: Any]) async -> Bool {
        var request = URLRequest(url: APIClient.shared.url(for: "/api/device-context/notification"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = APIClient.shared.currentToken {
            request.setValue(t, forHTTPHeaderField: "X-Aion-Token")
        }
        request.timeoutInterval = 20
        let body: [String: Any] = [
            "key":      item["key"] ?? "",
            "title":    item["title"] ?? "",
            "text":     item["text"] ?? "",
            "app_name": item["app_name"] ?? "",
            "source":   "ancs",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["data": body])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                APIClient.shared.markVerified()
                return true
            }
            APIClient.shared.noteFailure()
            AionLogger.shared.log("relay upload http=\(code)")
            return false
        } catch {
            APIClient.shared.noteFailure()
            AionLogger.shared.log("relay upload err: \(error.localizedDescription)")
            return false
        }
    }

    /// 只推进 ACK、不进队列 —— 用于丢弃解析失败的通知，防止堵住整条链路
    private func ackOnly(_ seq: UInt32) {
        guard seq > lastAcked else { return }
        lastAcked = seq
        writeAck(seq)
    }

    private func writeAck(_ seq: UInt32) {
        guard let p = peripheral, let ackChar else { return }
        var le = seq.littleEndian
        let d = Data(bytes: &le, count: 4)
        p.writeValue(d, for: ackChar, type: .withResponse)
    }

    // MARK: - 队列落盘（断网补传）

    private var queueURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("aion_notif_pending.json")
    }

    private func loadQueue() {
        guard let d = try? Data(contentsOf: queueURL),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
        queue = Array(arr.suffix(Self.queueLimit))
    }

    private func saveQueue() {
        let arr = Array(queue.suffix(Self.queueLimit))
        guard let d = try? JSONSerialization.data(withJSONObject: arr) else { return }
        try? d.write(to: queueURL, options: .atomic)
    }

    private func enqueue(_ item: [String: Any]) {
        queue.append(item)
        if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
        saveQueue()
    }

    // MARK: - 心跳（出门后唯一的眼睛）

    private func maybeHeartbeat() {
        guard Date().timeIntervalSince(lastHeartbeatAt) >= Self.heartbeatInterval else { return }
        lastHeartbeatAt = Date()
        let conn = peripheral?.state == .connected
        AionLogger.shared.log(
            "relay hb conn=\(conn ? 1 : 0) ancs=\(ancsReady ? 1 : 0) self=\(selfInitiated ? 1 : 0) " +
            "ack=\(lastAcked) new=\(newestSeq) q=\(queue.count) st=[\(lastStatusText)]"
        )
    }

    // MARK: - 工具

    private static func readU32(_ d: Data, _ offset: Int) -> UInt32 {
        guard d.count >= offset + 4 else { return 0 }
        let b = [UInt8](d[offset..<(offset + 4)])
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }
}

// MARK: - CBCentralManagerDelegate

extension AionNotifRelay: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            AionLogger.shared.log("relay central state=\(central.state.rawValue)")
            guard central.state == .poweredOn else {
                // 蓝牙关/飞行模式：清干净半死对象，等 poweredOn 再重来
                self.ctrlChar = nil; self.dataChar = nil; self.ackChar = nil; self.statusChar = nil
                self.peripheral = nil; self.ancsReady = false; self.ancsZeroSince = nil
                return
            }
            self.ensureLink()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let list = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
                  let p = list.first else { return }
            AionLogger.shared.log("relay restored state=\(p.state.rawValue)")
            self.adopt(p, initiated: false)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            central.stopScan()
            self.scanningUntil = nil
            AionLogger.shared.log("relay found \(peripheral.identifier.uuidString.prefix(8))")
            self.adopt(peripheral, initiated: true)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            AionLogger.shared.log("relay connected self=\(self.selfInitiated ? 1 : 0)")
            self.discover(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            AionLogger.shared.log("relay connect failed: \(error?.localizedDescription ?? "-")")
            self.peripheral = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            AionLogger.shared.log("relay disconnected: \(error?.localizedDescription ?? "clean")")
            self.ctrlChar = nil; self.dataChar = nil; self.ackChar = nil; self.statusChar = nil
            self.ancsReady = false
            self.ancsZeroSince = nil
            // 重连交给 CBConnectPeripheralOptionEnableAutoReconnect；这里只留个记号，
            // 下一个 15s tick 会兜底 ensureLink。
        }
    }
}

// MARK: - CBPeripheralDelegate

extension AionNotifRelay: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let svc = peripheral.services?.first(where: { $0.uuid == Self.svcUUID }) else {
                AionLogger.shared.log("relay svc missing: \(error?.localizedDescription ?? "-")")
                return
            }
            peripheral.discoverCharacteristics(
                [Self.ctrlUUID, Self.dataUUID, Self.ackUUID, Self.statusUUID], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for c in service.characteristics ?? [] {
                switch c.uuid {
                case Self.ctrlUUID:
                    self.ctrlChar = c
                    peripheral.setNotifyValue(true, for: c)
                case Self.dataUUID:   self.dataChar = c
                case Self.ackUUID:    self.ackChar = c
                case Self.statusUUID: self.statusChar = c
                default: break
                }
            }
            AionLogger.shared.log("relay chars ctrl=\(self.ctrlChar != nil) data=\(self.dataChar != nil) ack=\(self.ackChar != nil)")
            // 特征齐了：读一次 CTRL 拿窗口、读一次 STATUS 看板子健康
            if let c = self.ctrlChar, let d = c.value { self.handleCtrl(d) }
            if let c = self.statusChar { peripheral.readValue(for: c) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, let d = characteristic.value else { return }
            switch characteristic.uuid {
            case Self.ctrlUUID:
                self.handleCtrl(d)
            case Self.dataUUID:
                self.handleData(d)
            case Self.statusUUID:
                self.lastStatusText = String(data: d, encoding: .utf8) ?? ""
                if self.lastStatusText.contains("ancs=1") {
                    self.ancsReady = true
                    self.ancsZeroSince = nil
                }
            default:
                break
            }
        }
    }
}
