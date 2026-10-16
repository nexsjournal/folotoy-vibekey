import CoreBluetooth
import Foundation

/// InputBetter 固件的 GATT 定义(docs/protocol.md「链路」)。
/// 只在主 actor 上的 BLEClient 里使用(CBUUID 不是 Sendable)。
enum PassportGATT {
    static let service = CBUUID(string: "B5E10001-5A6C-4E8B-9F2D-7C3A1E0B4D21")
    /// 设备 → Mac,JSON 行,Notify。
    static let events = CBUUID(string: "B5E10002-5A6C-4E8B-9F2D-7C3A1E0B4D21")
    /// Mac → 设备,JSON 行,Write / Write Without Response。
    static let commands = CBUUID(string: "B5E10003-5A6C-4E8B-9F2D-7C3A1E0B4D21")
    /// 设备 → Mac,二进制帧(ADPCM),Notify。
    static let audioIn = CBUUID(string: "B5E10004-5A6C-4E8B-9F2D-7C3A1E0B4D21")
}

/// CoreBluetooth central:扫描并连接第一个广播 InputBetter 服务的设备,订阅 Events。
///
/// CBCentralManager 使用主队列,委托回调和所有状态都在主线程;回调闭包也在主线程调用。
/// 只在 `setEnabled(true)` 时才创建 CBCentralManager,避免用户未开启蓝牙时触发系统授权弹窗。
final class BLEClient: NSObject {
    enum State: Equatable {
        case disabled
        case starting
        case poweredOff
        case unauthorized
        case unsupported
        case scanning
        case connecting(String)
        case ready(String)
    }

    private(set) var state: State = .disabled {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }

    var onStateChange: ((State) -> Void)?
    /// Events 通知已开启,可以开始握手。
    var onReady: ((String) -> Void)?
    /// Events 特征的原始字节(可能只是半行)。
    var onData: ((Data) -> Void)?
    /// Audio In 特征的原始字节(二进制帧)。
    var onAudioData: ((Data) -> Void)?
    /// 之前已连接(或正在连接)的外设断开。
    var onDisconnected: (() -> Void)?

    /// Write Without Response 没有流控,发不出去时最多排队的分片数,超出丢最旧的。
    private static let pendingLimit = 64
    private static let rescanDelay: Duration = .seconds(2)

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var peripheralName = ""
    private var commandCharacteristic: CBCharacteristic?
    private var audioInCharacteristic: CBCharacteristic?
    private var pending: [Data] = []
    private var audioInputWanted = false
    private var enabled = false
    private var rescanTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    func setEnabled(_ newValue: Bool) {
        guard newValue != enabled else { return }
        enabled = newValue
        if disconnectTask != nil {
            // disable(after:) 的延迟断开还没执行:现在立即完成,让重新启用从干净状态开始。
            disconnectTask?.cancel()
            disconnectTask = nil
            if let peripheral {
                central?.cancelPeripheralConnection(peripheral)
            }
            endConnection()
            state = .disabled
        }
        if newValue {
            if let central {
                centralManagerDidUpdateState(central)
            } else {
                state = .starting
                // 首次创建 CBCentralManager 时系统会请求蓝牙授权。
                central = CBCentralManager(delegate: self, queue: .main)
            }
        } else {
            rescanTask?.cancel()
            central?.stopScan()
            if let peripheral {
                central?.cancelPeripheralConnection(peripheral)
            }
            endConnection()
            state = .disabled
        }
    }

    /// 停用蓝牙,但先等 `delay` 让已排队的写入(例如 `bye`)发出去再断开。
    func disable(after delay: Duration) {
        guard enabled else { return }
        guard peripheral != nil else {
            setEnabled(false)
            return
        }
        enabled = false
        rescanTask?.cancel()
        central?.stopScan()
        disconnectTask?.cancel()
        disconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.enabled else { return }
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.endConnection()
            self.state = .disabled
        }
    }

    /// 断开当前外设;仍处于启用状态时会稍后重新扫描。
    func disconnect() {
        guard let peripheral else { return }
        central?.cancelPeripheralConnection(peripheral)
    }

    /// 写一行命令到 Commands 特征,按 MTU 分片。
    func send(_ data: Data) {
        guard isReady, let peripheral, let characteristic = commandCharacteristic else { return }
        if characteristic.properties.contains(.writeWithoutResponse) {
            let size = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
            pending.append(contentsOf: Self.chunks(data, size: size))
            if pending.count > Self.pendingLimit {
                pending.removeFirst(pending.count - Self.pendingLimit)
            }
            drainPending()
        } else {
            let size = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
            for chunk in Self.chunks(data, size: size) {
                peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
            }
        }
    }

    /// 订阅或取消 Audio In 通知;外设还没连上时记住期望值,连上后生效。
    func setAudioInputEnabled(_ on: Bool) {
        audioInputWanted = on
        guard isReady, let peripheral, let characteristic = audioInCharacteristic,
              characteristic.isNotifying != on
        else { return }
        peripheral.setNotifyValue(on, for: characteristic)
    }

    private func drainPending() {
        guard let peripheral, let characteristic = commandCharacteristic else {
            pending.removeAll()
            return
        }
        while !pending.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(pending.removeFirst(), for: characteristic, type: .withoutResponse)
        }
    }

    private static func chunks(_ data: Data, size: Int) -> [Data] {
        var result: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + size, data.endIndex)
            result.append(data.subdata(in: offset..<end))
            offset = end
        }
        return result
    }

    private func startScanning() {
        guard enabled, peripheral == nil, let central, central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [PassportGATT.service])
    }

    /// 清理连接;若之前有外设则通知上层。
    private func endConnection() {
        let hadPeripheral = peripheral != nil
        peripheral?.delegate = nil
        peripheral = nil
        commandCharacteristic = nil
        audioInCharacteristic = nil
        pending.removeAll()
        if hadPeripheral {
            onDisconnected?()
        }
    }

    private func connectionLost() {
        endConnection()
        guard enabled else {
            state = .disabled
            return
        }
        state = .scanning
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: Self.rescanDelay)
            guard !Task.isCancelled else { return }
            self?.startScanning()
        }
    }
}

extension BLEClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if enabled {
                startScanning()
            }
        case .poweredOff:
            endConnection()
            state = enabled ? .poweredOff : .disabled
        case .unauthorized:
            endConnection()
            state = enabled ? .unauthorized : .disabled
        case .unsupported:
            state = enabled ? .unsupported : .disabled
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard enabled, self.peripheral == nil else { return }
        central.stopScan()
        peripheralName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "InputBetter"
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting(peripheralName)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        peripheral.discoverServices([PassportGATT.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        connectionLost()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        connectionLost()
    }
}

extension BLEClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == PassportGATT.service }) else {
            disconnect()
            return
        }
        peripheral.discoverCharacteristics(
            [PassportGATT.events, PassportGATT.commands, PassportGATT.audioIn], for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        guard let events = characteristics.first(where: { $0.uuid == PassportGATT.events }),
              let commands = characteristics.first(where: { $0.uuid == PassportGATT.commands })
        else {
            disconnect()
            return
        }
        commandCharacteristic = commands
        audioInCharacteristic = characteristics.first { $0.uuid == PassportGATT.audioIn }
        peripheral.setNotifyValue(true, for: events)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainPending()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == PassportGATT.events else { return }
        guard error == nil, characteristic.isNotifying else {
            disconnect()
            return
        }
        guard !isReady else { return }
        state = .ready(peripheralName)
        if audioInputWanted, let audioIn = audioInCharacteristic {
            peripheral.setNotifyValue(true, for: audioIn)
        }
        onReady?(peripheralName)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value, !value.isEmpty else { return }
        if characteristic.uuid == PassportGATT.events {
            onData?(value)
        } else if characteristic.uuid == PassportGATT.audioIn {
            onAudioData?(value)
        }
    }
}
