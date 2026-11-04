import Foundation

/// AFU-WL-TZ-A1 体脂秤的蓝牙协议解析。
///
/// 逆向自 https://github.com/Fatpandac/AFUScale （专为该型号写的 iOS App）。
/// 与本项目现有的 "Scale27" 协议不同，AFU-WL-TZ-A1 走的是另一套包格式：
///   · 包头固定 0xAC，第 2 字节固定为设备型号 0x29（用来在收到第一包时确认型号）；
///   · 第 3 字节是包类型：0x02 = 最终结算包（含阻抗），其余 = 实时体重包；
///   · 秤自己把体重和阻抗都广播出来，App 端**不需要**像 Scale27 那样先下发用户资料去触发阻抗测量；
///   · 体重编码：(a - 0x68) * 65.536 + (b<<8 | c) / 1000，其中 a 是 65.536kg 翻页字节。
///
/// 解析逻辑与 AFUScale 的 `ScalePacketParser` 逐字节对应，并已用其单元测试中的
/// 真实报文验证（见下方 decode 注释里的 3 组样本）。
enum AfuWLTZA1 {

    /// 该型号在广播包里的本地名称，扫描时按这个名字过滤（它不保证在广告里带上 FFB0 服务）。
    static let targetName = "AFU-WL-TZ-A1"
    /// 数据包固定设备型号字节（第 2 字节）。
    static let deviceType: UInt8 = 0x29

    /// 一包解析结果
    enum Packet {
        case weight(kg: Double, stable: Bool)                    // 实时体重包
        case result(kg: Double, impedanceA: Double?, impedanceB: Double?) // 最终结算包（含阻抗）
    }

    /// 这包数据是不是 AFU-WL-TZ-A1 发的：20 字节、包头 0xAC、型号字节 0x29。
    static func isApplicable(_ d: [UInt8]) -> Bool {
        d.count >= 20 && d[0] == 0xAC && d[1] == deviceType
    }

    /// 解析入口。非本型号包返回 nil。
    ///
    /// 样本验证（hex，来自 AFUScale 的单元测试）：
    ///   live : ac 29 80 69 0f e0 ...              → 体重 69.60kg，稳定，无阻抗
    ///   final: ac 29 02 00 01 e2 01 b0 ... 69 0f e0 ... → 体重 69.60kg，阻抗 482 / 432Ω
    ///   final: ac 29 02 00 00 00 00 00 ... 68 13 ec ... → 体重 5.10kg，无阻抗（未踩电极）
    static func decode(_ d: [UInt8]) -> Packet? {
        guard isApplicable(d) else { return nil }
        let kind = d[2]

        if kind == 0x02 {
            // 最终结算包：阻抗在 [4,5] 与 [6,7]，体重在 [10,11,12]
            let a = Int(d[4]) << 8 | Int(d[5])
            let c = Int(d[6]) << 8 | Int(d[7])
            let (impA, impB): (Double?, Double?)
            if a == 0 && c == 0 {
                impA = nil; impB = nil          // 没踩实电极 / 称的是物体 → 无阻抗
            } else {
                impA = Double(a); impB = Double(c)
            }
            return .result(kg: decodeWeight(d[10], d[11], d[12]),
                           impedanceA: impA, impedanceB: impB)
        }

        // 实时体重包：体重在 [3,4,5]，稳定标志在 byte[2] 的 bit7
        return .weight(kg: decodeWeight(d[3], d[4], d[5]),
                       stable: (Int(kind) & 0x80) != 0)
    }

    /// 在两条阻抗读数里挑一条落在人体合理区间(约 100~1500Ω)的，喂给 BIA 体脂公式。
    /// 优先用 [4,5]（阻抗 A），其次 [6,7]（阻抗 B）；两条都异常则视为无阻抗。
    static func primaryImpedance(_ a: Double?, _ b: Double?) -> Double? {
        if let a, a >= 100, a <= 1500 { return a }
        if let b, b >= 100, b <= 1500 { return b }
        return nil
    }

    /// 体重解码：(翻页字节 - 0x68) * 65.536 + (低 16 位克数) / 1000
    private static func decodeWeight(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Double {
        Double(Int(a) - 0x68) * 65.536 + Double(Int(b) << 8 | Int(c)) / 1000.0
    }
}
