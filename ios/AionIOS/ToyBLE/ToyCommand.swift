import Foundation

/// 玩具命令协议（照抄 chat.js 的字节格式）
enum ToyCommand {
    /// 双电机命令：'02'+s1+'11'+hex2(v1)+s2+'11'+hex2(v2)
    /// s1/s2 = 4 字符规格（modeSpec/gearsSpec），v1/v2 = 0-255 数值
    static func dual(modeSpec: String, mode: Int, gearsSpec: String, speed: Int) -> String {
        func hex2(_ n: Int) -> String { String(format: "%02X", n) }
        return "02\(modeSpec)11\(hex2(mode))\(gearsSpec)11\(hex2(speed))"
    }

    /// 停止命令（chat.js toyBuildStopCmd）
    static let stop = "03000111000003110000071100"

    /// 分包规则（照抄 chat.js toySendData2 的 Web Bluetooth 路径）：
    /// '00'+hexCmd → 18 字节/块 → 每包 [随机字节, 序号, ...块数据]
    /// 末块恰满 18 字节则补一个 [随机字节, 序号] 空尾包
    static func packets(forHexCmd hexCmd: String) -> [[UInt8]] {
        let full = "00" + hexCmd
        var data: [UInt8] = []
        var idx = full.startIndex
        while idx < full.endIndex {
            let end = full.index(idx, offsetBy: 2, limitedBy: full.endIndex) ?? full.endIndex
            data.append(UInt8(full[idx..<end], radix: 16) ?? 0)
            idx = end
        }
        var chunks: [[UInt8]] = []
        for i in stride(from: 0, to: data.count, by: 18) {
            chunks.append(Array(data[i..<min(i + 18, data.count)]))
        }
        let rnd = UInt8.random(in: 0...254)
        var pkts = chunks.enumerated().map { i, chunk in
            [rnd, UInt8(i + 1)] + chunk
        }
        if let last = chunks.last, last.count == 18 {
            pkts.append([rnd, UInt8(chunks.count + 1)])
        }
        return pkts
    }
}
