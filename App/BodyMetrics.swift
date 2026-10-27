import Foundation

enum Sex {
    case male
    case female
}

/// 身体成分计算：BMI、体脂率、水分率、肌肉率、基础代谢、去脂体重。
///
/// BMI 与体脂率公式沿用 Fatpandac/AFUScale（含 calibration 校正值），
/// 水分/肌肉/BMR/去脂体重公式移植自 Aoko-Aozaki/ant-afu-scale（ha-miscale2 算法）。
/// 两者共用同一套 Sex / heightCm / age / weightKg 入参，合并后不再二选一。
enum BodyMetrics {
    static func bmi(weightKg: Double, heightCm: Double) -> Double {
        let h = heightCm / 100
        return weightKg / (h * h)
    }

    /// 体脂率：沿用 AFUScale 的线性公式，保留 calibration 校正值。
    /// calibration 默认 1.5，可按实际体脂秤微调。
    static func bodyFatPercent(weightKg: Double, heightCm: Double, age: Int, sex: Sex,
                                calibration: Double = 1.5) -> Double {
        let sexValue = sex == .male ? 1.0 : 0.0
        return 1.20 * bmi(weightKg: weightKg, heightCm: heightCm)
            + 0.23 * Double(age)
            - 10.8 * sexValue
            - 5.4
            + calibration
    }

    /// 完整身体成分（BIA 估算），移植自 ant-afu-scale 的 ha-miscale2 算法。
    /// - Parameters:
    ///   - weightKg: 体重（kg）
    ///   - impedance: 阻抗（Ω），须在 100~1500 的人体有效区间内
    ///   - heightCm: 身高（cm）
    ///   - age: 年龄
    ///   - isMale: 性别
    static func bodyComposition(weightKg: Double, impedance: Double,
                                heightCm: Double, age: Int, isMale: Bool) -> BodyComposition {
        let h = heightCm
        let ageD = Double(age)
        let impedance = impedance > 0 ? impedance : 500.0

        let bmi = weightKg / pow(h / 100.0, 2)

        // 瘦体重系数 (LBM coefficient)
        let lbmCoeff = (h * 9.058 / 100.0) * (h / 100.0)
            + weightKg * 0.32 + 12.226
            - impedance * 0.0068
            - ageD * 0.0542

        // 体脂率
        var fatConst: Double
        var fatCoeff: Double = 1.0
        if isMale {
            fatConst = 0.8
            if weightKg < 61 { fatCoeff = 0.98 }
            if h > 160 { fatCoeff *= 1.03 }
        } else {
            fatConst = ageD <= 49 ? 9.25 : 7.25
            if weightKg > 60 { fatCoeff = 0.96 }
            else if weightKg < 50 { fatCoeff = 1.02 }
            if h > 160 { fatCoeff *= 1.03 }
        }
        var fatPct = (1.0 - (((lbmCoeff - fatConst) * fatCoeff) / weightKg)) * 100.0
        fatPct = min(60.0, max(3.0, fatPct))

        // 水分率
        var waterPct = (100.0 - fatPct) * 0.7
        let waterCoeff = waterPct <= 50 ? 1.02 : 0.98
        waterPct = min(75.0, max(35.0, waterPct * waterCoeff))

        // 骨量
        var boneMass: Double
        if isMale {
            boneMass = (0.18016894 - (lbmCoeff * 0.05158)) * -1
        } else {
            boneMass = (0.245691014 - (lbmCoeff * 0.07158)) * -1
        }
        boneMass += boneMass > 2.2 ? 0.1 : -0.1
        boneMass = max(0.5, boneMass)

        // 肌肉率
        let fatMass = fatPct * 0.01 * weightKg
        let muscleMass = weightKg - fatMass - boneMass * 0.85
        let muscleRate = muscleMass / weightKg * 100.0

        // 基础代谢 (Mifflin-St Jeor)
        let bmr: Int
        if isMale {
            bmr = Int((10 * weightKg + 6.25 * h - 5 * ageD + 5).rounded())
        } else {
            bmr = Int((10 * weightKg + 6.25 * h - 5 * ageD - 161).rounded())
        }

        let leanBodyMass = weightKg - fatMass

        return BodyComposition(
            weightKg: (weightKg * 100).rounded() / 100,
            impedance: (impedance * 10).rounded() / 10,
            bmi: (bmi * 10).rounded() / 10,
            bodyFatPercent: (fatPct * 10).rounded() / 10,
            waterPercent: (waterPct * 10).rounded() / 10,
            muscleRate: (muscleRate * 10).rounded() / 10,
            bmr: bmr,
            leanBodyMassKg: (leanBodyMass * 10).rounded() / 10
        )
    }
}

/// 完整身体成分结果。
struct BodyComposition: Identifiable {
    let id = UUID()
    let weightKg: Double
    let impedance: Double
    let bmi: Double
    let bodyFatPercent: Double
    let waterPercent: Double
    let muscleRate: Double
    let bmr: Int
    let leanBodyMassKg: Double
}
