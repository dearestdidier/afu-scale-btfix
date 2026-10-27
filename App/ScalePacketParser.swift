import Foundation

struct Impedance: Equatable {
    let a: Int
    let b: Int
}

struct ScaleMeasurement: Equatable {
    let weightKg: Double
    let isStable: Bool
    let isFinal: Bool
    /// 归一化后的阻抗值（Ω）。nil 表示本包没有携带有效阻抗。
    let impedance: Impedance?
    /// Scale27 协议的阻抗包可能带多个阻抗读数，全部保留供有效性筛选。
    let impedances: [Double]

    static func == (l: ScaleMeasurement, r: ScaleMeasurement) -> Bool {
        l.weightKg == r.weightKg && l.isStable == r.isStable
            && l.isFinal == r.isFinal && l.impedance == r.impedance
    }
}

/// AFU-WL-TZ-A1 体脂秤的统一协议解析。
///
/// 两个上游项目对同一台秤的包格式描述不同：
///   - Fatpandac/AFUScale：包头 0xAC 0x29，byte[2]==0x02 为最终结果包，
///     体重在 b[10..12]（65.536kg 翻页 + 克），阻抗在 b[4..7]。
///   - Aoko/ant-afu-scale（Scale27）：包类型在 b[18]（213=体重，214=阻抗），
///     体重是 32 位编码（低 18 位克数 + 3 位刻度 + bit31 稳定），阻抗包带 count+数组。
///
/// 实机上两种包可能混发（不同固件批次/不同测量阶段），这里先按旧格式试，
/// 失败再走 Scale27，保证两种包都能解析，互不干扰。
enum ScalePacketParser {

    static func parse(_ data: Data) -> ScaleMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 20, b[0] == 0xAC else { return nil }

        // —— 旧格式（Fatpandac）：b[1]==0x29 且 b[2] 是状态字节 ——
        if b[1] == 0x29, b[2] == 0x02 {
            let a = Int(b[4]) << 8 | Int(b[5])
            let c = Int(b[6]) << 8 | Int(b[7])
            return ScaleMeasurement(
                weightKg: decodeWeightLegacy(b[10], b[11], b[12]),
                isStable: true,
                isFinal: true,
                impedance: (a == 0 && c == 0) ? nil : Impedance(a: a, b: c),
                impedances: (a == 0 && c == 0) ? [] : [Double(a), Double(c)]
            )
        }
        if b[1] == 0x29 {
            return ScaleMeasurement(
                weightKg: decodeWeightLegacy(b[3], b[4], b[5]),
                isStable: (b[2] & 0x80) != 0,
                isFinal: false,
                impedance: nil,
                impedances: []
            )
        }

        // —— Scale27 格式（Aoko）：213 体重包 / 214 阻抗包 ——
        switch Scale27.decode(b) {
        case .weight(let kg, let stable):
            return ScaleMeasurement(
                weightKg: kg,
                isStable: stable,
                isFinal: false,
                impedance: nil,
                impedances: []
            )
        case .adc(let kg, let impedances):
            // 阻抗包代表测量结束。kg 可能为 0（该包不带体重），沿用最后一次实时体重。
            let weight = kg > 2.0 ? kg : 0
            let valid = impedances.first { $0 >= 100 && $0 <= 1500 }
            return ScaleMeasurement(
                weightKg: weight,
                isStable: true,
                isFinal: true,
                impedance: valid.map { Impedance(a: Int($0), b: Int($0)) },
                impedances: impedances
            )
        case nil:
            return nil
        }
    }

    /// 旧格式体重解码：高字节是 65.536kg 翻页，低 16 位是克。
    private static func decodeWeightLegacy(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Double {
        Double(Int(a) - 0x68) * 65.536 + Double(Int(b) << 8 | Int(c)) / 1000
    }
}
