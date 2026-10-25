import Foundation
import CoreBluetooth

/// BLE device discovered during a scan.
struct DiscoveredDevice: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var isDFU: Bool
    var deviceType: ChameleonDevice

    var displayName: String { name.isEmpty ? "Unknown" : name }
}

/// Service/characteristic UUIDs (nonisolated so delegates can match on them).
enum BLEUUIDs {
    static let nusService     = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nusRXChar      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // app writes here
    static let nusTXChar      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notifications
    static let dfuService     = CBUUID(string: "FE59")
    static let dfuControlChar = CBUUID(string: "8EC90001-F315-4F60-9FB8-838830DAEA50")
    static let dfuDataChar    = CBUUID(string: "8EC90002-F315-4F60-9FB8-838830DAEA50")
}

/// CoreBluetooth bridge for the Chameleon Ultra / Lite.
/// Application protocol runs on the Nordic UART Service (NUS); firmware
/// flashing uses the Nordic Secure DFU service (FE59).
@MainActor
final class BLEManager: NSObject, ObservableObject {

    enum ConnectionState: Equatable {
        case idle, scanning, connecting, connected
    }

    @Published var state: ConnectionState = .idle
    @Published var bluetoothReady = false
    @Published var devices: [DiscoveredDevice] = []

    /// Application-protocol bytes (NUS notifications). Delivered on the main thread.
    var onData: ((Data) -> Void)?
    /// DFU control point notifications. Delivered on the main thread.
    var onDFUData: ((Data) -> Void)?
    var onDisconnected: (() -> Void)?

    private var central: CBCentralManager!
    private(set) var peripheral: CBPeripheral?
    private var currentDevice: DiscoveredDevice?

    private var nusRX: CBCharacteristic?
    private var nusTX: CBCharacteristic?
    private var dfuControl: CBCharacteristic?
    private var dfuData: CBCharacteristic?

    private var connectContinuation: CheckedContinuation<Bool, Never>?
    private var servicesContinuation: CheckedContinuation<CBService?, Never>?
    private var characteristicsContinuation: CheckedContinuation<Bool, Never>?
    private var notifyContinuation: CheckedContinuation<Bool, Never>?
    private var writeContinuations: [CheckedContinuation<Void, Error>] = []
    private var readyToSendContinuation: CheckedContinuation<Void, Never>?

    private var knownPeripherals: [UUID: CBPeripheral] = [:]

    private(set) var isDFUConnection = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Scanning

    func startScan() {
        guard bluetoothReady, state != .scanning else { return }
        devices = []
        state = .scanning
        central.scanForPeripherals(withServices: [BLEUUIDs.nusService, BLEUUIDs.dfuService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    // MARK: - Connection

    /// Connect with the same retry policy as the original app (5 attempts).
    func connect(to device: DiscoveredDevice) async -> Bool {
        guard bluetoothReady else { return false }
        for _ in 0..<5 {
            if await connectOnce(device) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        state = .idle
        return false
    }

    private func connectOnce(_ device: DiscoveredDevice) async -> Bool {
        stopScan()
        guard let target = knownPeripherals[device.id]
                ?? central.retrievePeripherals(withIdentifiers: [device.id]).first else {
            return false
        }
        state = .connecting
        currentDevice = device
        isDFUConnection = device.isDFU

        let connected = await withCheckedContinuation { continuation in
            connectContinuation = continuation
            central.connect(target, options: nil)
        }
        guard connected else {
            state = .idle
            return false
        }

        let service = await withCheckedContinuation { continuation in
            servicesContinuation = continuation
            peripheral?.discoverServices([BLEUUIDs.nusService, BLEUUIDs.dfuService])
        }
        guard let service else { disconnect(); return false }

        let charsReady = await withCheckedContinuation { continuation in
            characteristicsContinuation = continuation
            peripheral?.discoverCharacteristics(nil, for: service)
        }
        guard charsReady else { disconnect(); return false }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case BLEUUIDs.nusRXChar: nusRX = characteristic
            case BLEUUIDs.nusTXChar: nusTX = characteristic
            case BLEUUIDs.dfuControlChar: dfuControl = characteristic
            case BLEUUIDs.dfuDataChar: dfuData = characteristic
            default: break
            }
        }

        let notifyChar = device.isDFU ? dfuControl : nusTX
        guard let notifyChar else { disconnect(); return false }

        let notified = await withCheckedContinuation { continuation in
            notifyContinuation = continuation
            peripheral?.setNotifyValue(true, for: notifyChar)
        }
        guard notified else { disconnect(); return false }

        if !device.isDFU {
            // keep-alive test frame, same bytes the original app writes after connecting
            let testFrame = Data([0x11, 0xef, 0x03, 0xfb, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00])
            do {
                try await write(testFrame)
            } catch {
                disconnect()
                return false
            }
        }

        state = .connected
        return true
    }

    func disconnect() {
        connectContinuation?.resume(returning: false); connectContinuation = nil
        servicesContinuation?.resume(returning: nil); servicesContinuation = nil
        characteristicsContinuation?.resume(returning: false); characteristicsContinuation = nil
        notifyContinuation?.resume(returning: false); notifyContinuation = nil
        readyToSendContinuation?.resume(); readyToSendContinuation = nil
        failPendingWrites(NSError(domain: "BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: "Disconnected"]))
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        self.peripheral = nil
        nusRX = nil; nusTX = nil; dfuControl = nil; dfuData = nil
        currentDevice = nil
        state = .idle
    }

    // MARK: - Writes

    /// Write application protocol data (NUS RX), chunked to the negotiated MTU.
    func write(_ data: Data) async throws {
        guard let peripheral, let nusRX else {
            throw NSError(domain: "BLE", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        let payload = Data(data) // normalize slice indices to zero-based
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            try await writeChunk(payload.subdata(in: offset..<end), to: nusRX)
            offset = end
        }
    }

    private func writeChunk(_ chunk: Data, to characteristic: CBCharacteristic) async throws {
        guard let peripheral else {
            throw NSError(domain: "BLE", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeContinuations.append(continuation)
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        }
    }

    /// DFU data endpoint: write without response in 20-byte slices with
    /// flow control — mirroring the original iOS behaviour.
    func writeDFU(_ data: Data) async throws {
        guard let peripheral, let dfuData else {
            throw NSError(domain: "BLE", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        let payload = Data(data) // normalize slice indices
        var offset = 0
        while offset < payload.count {
            if !peripheral.canSendWriteWithoutResponse {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    readyToSendContinuation = continuation
                }
                continue
            }
            let end = min(offset + 20, payload.count)
            peripheral.writeValue(payload.subdata(in: offset..<end), for: dfuData, type: .withoutResponse)
            offset = end
        }
    }

    /// DFU control point write (with response).
    func writeDFUControl(_ data: Data) async throws {
        guard let dfuControl else {
            throw NSError(domain: "BLE", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        try await writeChunk(Data(data), to: dfuControl)
    }

    private func failPendingWrites(_ error: Error) {
        let pending = writeContinuations
        writeContinuations = []
        pending.forEach { $0.resume(throwing: error) }
    }
}

// MARK: - Delegate forwarding (CBCentralManager delegate queue is .main)

extension BLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let ready = central.state == .poweredOn
        Task { @MainActor in
            self.bluetoothReady = ready
            if !ready { self.state = .idle }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let rssi = RSSI.intValue
        Task { @MainActor in self.handleDiscover(peripheral, name: name, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.peripheral = peripheral
            peripheral.delegate = self
            self.connectContinuation?.resume(returning: true)
            self.connectContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.connectContinuation?.resume(returning: false)
            self.connectContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in self.handleDisconnected(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let dfuWanted = peripheral.services?.contains { $0.uuid == BLEUUIDs.dfuService } ?? false
        let service = peripheral.services?.first {
            $0.uuid == (dfuWanted ? BLEUUIDs.dfuService : BLEUUIDs.nusService)
        }
        Task { @MainActor in
            self.servicesContinuation?.resume(returning: error == nil ? service : nil)
            self.servicesContinuation = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let ok = error == nil
        Task { @MainActor in
            self.characteristicsContinuation?.resume(returning: ok)
            self.characteristicsContinuation = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let ok = error == nil && characteristic.isNotifying
        Task { @MainActor in
            self.notifyContinuation?.resume(returning: ok)
            self.notifyContinuation = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case BLEUUIDs.nusTXChar:
            Task { @MainActor in self.onData?(data) }
        case BLEUUIDs.dfuControlChar:
            Task { @MainActor in self.onDFUData?(data) }
        default:
            break
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard !self.writeContinuations.isEmpty else { return }
            let continuation = self.writeContinuations.removeFirst()
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            self.readyToSendContinuation?.resume()
            self.readyToSendContinuation = nil
        }
    }

    // MARK: MainActor handlers

    private func handleDiscover(_ peripheral: CBPeripheral, name: String, rssi: Int) {
        knownPeripherals[peripheral.identifier] = peripheral

        var deviceType = ChameleonDevice.ultra
        var dfuMode = false
        if name.hasPrefix("ChameleonUltra") {
            deviceType = .ultra
        } else if name.hasPrefix("ChameleonLite") {
            deviceType = .lite
        } else if name.hasPrefix("CU-") {
            deviceType = .ultra; dfuMode = true
        } else if name.hasPrefix("CL-") {
            deviceType = .lite; dfuMode = true
        } else if peripheral.identifier == self.peripheral?.identifier {
            deviceType = currentDevice?.deviceType ?? .ultra
            dfuMode = currentDevice?.isDFU ?? false
        } else {
            return
        }

        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[index].rssi = rssi
            devices[index].name = name.isEmpty ? devices[index].name : name
        } else {
            devices.append(DiscoveredDevice(id: peripheral.identifier,
                                            name: name.isEmpty ? "Chameleon" : name,
                                            rssi: rssi, isDFU: dfuMode, deviceType: deviceType))
        }
    }

    private func handleDisconnected(_ peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        self.peripheral = nil
        nusRX = nil; nusTX = nil; dfuControl = nil; dfuData = nil
        state = .idle
        failPendingWrites(NSError(domain: "BLE", code: -3, userInfo: [NSLocalizedDescriptionKey: "Peripheral disconnected"]))
        onDisconnected?()
    }
}
