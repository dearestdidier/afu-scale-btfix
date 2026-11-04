import Foundation
import Combine
import CoreBluetooth

/// 蓝牙连接状态，用于驱动界面。
enum ScaleState: Equatable {
    case idle            // 未开始
    case poweredOff      // 蓝牙没开
    case scanning        // 扫描中
    case connecting      // 连接中
    case measuring       // 已连接，等待/正在读数
    case done            // 本次测量完成
    case bodyFatUnavailable(String)  // 称到体重，但阻抗无效，测不出体脂
    case error(String)
}

/// 连上的秤走哪套协议。第一包数据到达时据包格式判定，之后全程复用，避免每包重新判定。
private enum ScaleModel {
    case unknown
    case scale27      // 沃莱/Welland "Scale27" 协议（现有支持）
    case afuWLTZA1    // AFU-WL-TZ-A1（新增支持，逆向自 Fatpandac/AFUScale）
}

/// 负责：扫描秤 → 连接 → 订阅通知 → 解析 0xAC 数据包 → 稳定判定。
/// 解析逻辑对应 icomon_scale 的简化协议（沃莱/Welland 芯片，服务 FFB0）。
///
/// 全类主 actor 隔离：CoreBluetooth 用 `queue: .main` 回调，所有 `@Published`
/// 状态也都在主线程更新，标 `@MainActor` 后隔离与执行器一致，避免运行时的
/// “unsafeForcedSync”跨上下文强制同步。
@MainActor
final class BluetoothManager: NSObject, ObservableObject {

    // 目标秤的服务 UUID（沃莱系列）。iOS 拿不到 MAC，只能靠服务/名字过滤。
    private let serviceUUID = CBUUID(string: "FFB0")
    /// 改成 true 可在控制台打印每一包原始字节，用于排查协议问题
    private let debugLog = false
    @Published var state: ScaleState = .idle
    @Published var liveWeight: Double? = nil        // 实时体重（未稳定）
    @Published var lastMeasurement: Measurement? = nil

    var profile: UserProfile = .load()
    /// 测量稳定并算完后回调（用来写 HealthKit）
    var onMeasurementReady: ((Measurement) -> Void)?

    private var central: CBCentralManager!
    private var scale: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?

    private var stableBuffer: [Double] = []
    private var locked = false
    private var didSendProfile = false
    /// 第一包数据到达时判定连的是哪种秤，之后全程复用。
    private var currentModel: ScaleModel = .unknown

    // 记住上次连过的秤，下次直连
    private var lastPeripheralID: UUID? {
        get { UserDefaults.standard.string(forKey: "last_peripheral").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "last_peripheral") }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// 开始一次测量：扫描并连接秤。
    func startMeasurement() {
        profile = .load()
        stableBuffer = []
        locked = false
        didSendProfile = false
        currentModel = .unknown
        liveWeight = nil

        guard central.state == .poweredOn else {
            state = .poweredOff
            return
        }
        // 先尝试直连上次的秤
        if let id = lastPeripheralID,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
            return
        }
        state = .scanning
        // 用 nil 扫描所有设备：AFU-WL-TZ-A1 不在广告包里带 FFB0 服务，按服务过滤会漏掉它；
        // 改在 didDiscover 里按「广播名 AFU-WL-TZ-A1 或 带 FFB0 服务」过滤，两种秤都能扫到。
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func cancel() {
        central.stopScan()
        if let scale { central.cancelPeripheralConnection(scale) }
        state = .idle
    }

    private func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        scale = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral, options: nil)
    }

    /// 把用户资料写给秤，触发它做体脂(阻抗)测量。
    private func sendUserProfile(deviceType: Int) {
        guard let scale, let writeChar else {
            print("⚠️ 没有可写特征，无法下发用户资料")
            return
        }
        let packet = Scale27.encodeUserInfo(deviceType: deviceType, profile: profile)
        let type: CBCharacteristicWriteType =
            writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        scale.writeValue(packet, for: writeChar, type: type)
        if debugLog {
            print("📤 已下发用户资料: \(packet.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
    }

    /// 解析一包通知数据。
    /// 第一包到达时先判定连的是哪种秤（AFU-WL-TZ-A1 还是 沃莱 Scale27），
    /// 之后按对应协议解析。两种秤都是 0xAC 开头的包，靠第 2 字节(型号 0x29)区分。
    private func handle(_ data: Data) {
        // 调试：打印每一包原始字节
        if debugLog {
            print("📦 \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        let bytes = [UInt8](data)

        // 第一包：判定型号并做型号相关的初始化。
        //  · AFU-WL-TZ-A1：不下发用户资料（秤自己广播体重+阻抗）；
        //  · 沃莱 Scale27：立刻把用户资料写给秤，否则它称完体重就结束、不测体脂。
        if currentModel == .unknown {
            if AfuWLTZA1.isApplicable(bytes) {
                currentModel = .afuWLTZA1
            } else {
                currentModel = .scale27
                if bytes.count >= 2 {
                    didSendProfile = true
                    sendUserProfile(deviceType: Int(bytes[1]))
                }
            }
        }

        switch currentModel {
        case .afuWLTZA1:  handleAfuWLTZA1(bytes)
        case .scale27:    handleScale27(bytes)
        case .unknown:    break
        }
    }

    /// AFU-WL-TZ-A1 协议：实时体重包只更新体重；收到 0x02 结算包（含阻抗）即锁定并计算。
    private func handleAfuWLTZA1(_ d: [UInt8]) {
        guard let packet = AfuWLTZA1.decode(d) else { return }
        switch packet {
        case .weight(let kg, let stable):
            guard kg > 2.0, !locked else { return }
            liveWeight = (kg * 100).rounded() / 100
            state = .measuring
            if debugLog { print("   ↳ 体重 \(String(format: "%.2f", kg))kg  稳定=\(stable)") }

        case .result(let kg, let impA, let impB):
            guard kg > 2.0, !locked else { return }
            locked = true
            liveWeight = (kg * 100).rounded() / 100

            // 阻抗要落在人体合理区间(约 100~1500Ω)才能算体脂：没踩实电极 / 隔着袜子
            // 时秤回报阻抗 0，算不出体脂，给出提示而不是硬塞一个假的默认值去算。
            guard let impedance = AfuWLTZA1.primaryImpedance(impA, impB) else {
                let hint = "请脱鞋光脚、踩住金属电极再试"
                print("⚠️ AFU-WL-TZ-A1 阻抗无效 \(String(describing: impA))/\(String(describing: impB)) → 无法测体脂：\(hint)")
                state = .bodyFatUnavailable(hint)
                if let scale { central.cancelPeripheralConnection(scale) }
                return
            }

            print("✅ 锁定：体重 \(String(format: "%.2f", kg))kg  阻抗 \(impedance)Ω")
            let m = BodyComposition.calculate(weightKg: kg,
                                              impedance: impedance,
                                              profile: profile)
            lastMeasurement = m
            state = .done
            onMeasurementReady?(m)
            // 测完主动断开
            if let scale { central.cancelPeripheralConnection(scale) }
        }
    }

    /// 沃莱/Welland "Scale27" 协议（现有支持，未改动逻辑）。
    /// 体重包(213)只更新实时体重；收到阻抗包(214)代表测量结束 → 锁定并计算。
    private func handleScale27(_ d: [UInt8]) {
        guard let packet = Scale27.decode(d) else { return }

        switch packet {
        case .weight(let kg, let stable):
            guard kg > 2.0, !locked else { return }
            liveWeight = (kg * 100).rounded() / 100
            state = .measuring
            if debugLog { print("   ↳ 体重 \(String(format: "%.2f", kg))kg  稳定=\(stable)") }

        case .adc(let kg, let impedances):
            let weightKg = kg > 2.0 ? kg : (liveWeight ?? 0)
            guard weightKg > 2.0, !locked else { return }
            locked = true

            // 阻抗要落在人体合理区间(约 100~1500Ω)才能算体脂：
            //  · 穿鞋 / 穿袜 → 电流几乎不导通 → 读数为 0 或异常大；
            //  · 湿脚 / 脚底有水 → 近似短路 → 读数异常小(<100Ω)。
            // 两种情况都测不出体脂，给出对应提示，而不是硬塞一个假的默认值去算。
            guard let impedance = impedances.first(where: { $0 >= 100 && $0 <= 1500 }) else {
                let seemsWet = impedances.contains { $0 > 0 && $0 < 100 }
                let hint = seemsWet ? "脚底可能有水，擦干后再试" : "请脱鞋光脚、踩住金属电极再试"
                print("⚠️ 阻抗无效 \(impedances) → 无法测体脂：\(hint)")
                state = .bodyFatUnavailable(hint)
                if let scale { central.cancelPeripheralConnection(scale) }
                return
            }

            print("✅ 锁定：体重 \(String(format: "%.2f", weightKg))kg  阻抗 \(impedances) → 用 \(impedance)Ω")
            let m = BodyComposition.calculate(weightKg: weightKg,
                                              impedance: impedance,
                                              profile: profile)
            lastMeasurement = m
            state = .done
            onMeasurementReady?(m)
            // 测完主动断开
            if let scale { central.cancelPeripheralConnection(scale) }
        }
    }
}

// MARK: - CBCentralManagerDelegate
// 代理方法在类型上是 nonisolated 的，但 central 用 queue:.main 回调，所以实际
// 都在主线程；用 MainActor.assumeIsolated 显式跳回主 actor，安全且不触发 forced sync。
extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state != .poweredOn, state == .scanning || state == .connecting {
                state = .poweredOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // 按「广播名 AFU-WL-TZ-A1 或 带 FFB0 服务」过滤：
        // 前者覆盖 AFU-WL-TZ-A1（它不一定在广告里带 FFB0），后者覆盖沃莱 Scale27 系列。
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isTargetName = localName == AfuWLTZA1.targetName
        let hasFFB0 = serviceUUIDs.contains(serviceUUID)
        guard isTargetName || hasFFB0 else { return }
        MainActor.assumeIsolated { connect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            lastPeripheralID = peripheral.identifier
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            state = .error("连接失败：\(error?.localizedDescription ?? "未知")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            notifyChar = nil
            writeChar = nil
            if !locked && state != .idle {
                // 非正常结束（还没测到稳定值）
                state = .idle
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                if c.properties.contains(.notify) {
                    notifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                }
                if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                    writeChar = c
                }
            }
            state = .measuring
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        MainActor.assumeIsolated { handle(data) }
    }
}
