import Foundation

/// Nordic Secure DFU over BLE, ported from `lib/bridge/dfu.dart` (BLE branch).
@MainActor
final class DFUCommunicator: ObservableObject {

    enum DFUOpcode: UInt8 {
        case createObject = 0x01
        case setPRN = 0x02
        case calcChecSum = 0x03
        case execute = 0x04
        case readError = 0x05
        case readObject = 0x06
        case getSerialMTU = 0x07
        case writeObject = 0x08
        case response = 0x60
    }

    struct DFUError: LocalizedError {
        let code: Int
        var errorDescription: String? { "DFU error code \(code)" }
    }

    struct TransferError: LocalizedError {
        let reason: String
        var errorDescription: String? { "DFU transfer error: \(reason)" }
    }

    @Published var log: [String] = []

    private let ble: BLEManager
    private var responseContinuation: CheckedContinuation<[UInt8], Error>?
    private var generation = 0
    private var mtu = 0
    private var prn = 0

    init(ble: BLEManager) {
        self.ble = ble
        ble.onDFUData = { [weak self] data in
            self?.handleNotification(data)
        }
    }

    private func addLog(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func handleNotification(_ data: Data) {
        guard let continuation = responseContinuation else { return }
        responseContinuation = nil
        continuation.resume(returning: [UInt8](data))
    }

    /// Registers the response continuation synchronously BEFORE writing the
    /// command (race-free), writes in a child task and arms a timeout
    /// watchdog tagged with the current generation.
    private func sendCmd(_ opcode: DFUOpcode, _ payload: Data = Data(), timeout: TimeInterval = 10) async throws -> [UInt8] {
        if let stale = responseContinuation {
            responseContinuation = nil
            stale.resume(returning: [])
        }
        generation += 1
        let currentGeneration = generation

        return try await withCheckedThrowingContinuation { continuation in
            guard responseContinuation == nil else {
                continuation.resume(throwing: TransferError(reason: "concurrent DFU command"))
                return
            }
            responseContinuation = continuation

            let packet = Data([opcode.rawValue]) + payload
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.ble.writeDFUControl(packet)
                } catch {
                    self.failResponse(error)
                }
            }

            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.fireTimeout(generation: currentGeneration, opcode: opcode)
            }
        }
    }

    private func fireTimeout(generation: Int, opcode: DFUOpcode) {
        guard generation == self.generation,
              let continuation = responseContinuation else { return }
        responseContinuation = nil
        continuation.resume(throwing: ChameleonError.timeout("DFU \(opcode.rawValue)"))
    }

    private func failResponse(_ error: Error) {
        if let continuation = responseContinuation {
            responseContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    @discardableResult
    private func checkedCmd(_ opcode: DFUOpcode, _ payload: Data = Data()) async throws -> [UInt8] {
        let response = try await sendCmd(opcode, payload)
        guard response.count >= 3 else { throw TransferError(reason: "short response") }
        guard response[0] == DFUOpcode.response.rawValue else { throw TransferError(reason: "not a response") }
        guard response[1] == opcode.rawValue else { throw TransferError(reason: "unexpected opcode \(response[1])") }
        guard response[2] == 0x01 else {
            if response[2] == 0x0B, response.count >= 4 {
                throw DFUError(code: Int(response[3]))
            }
            throw DFUError(code: Int(response[2]))
        }
        return Array(response[3...])
    }

    // MARK: - Object operations

    private struct ObjectInfo {
        var maxSize: Int
        var offset: Int
        var crc: UInt32
    }

    private func selectObject(_ objectType: UInt8) async throws -> ObjectInfo {
        let response = try await checkedCmd(.readObject, Data([objectType, 0, 0, 0]))
        guard response.count >= 12 else { throw TransferError(reason: "bad select response") }
        let maxSize = Int(response[0]) | Int(response[1]) << 8 | Int(response[2]) << 16 | Int(response[3]) << 24
        let offset = Int(response[4]) | Int(response[5]) << 8 | Int(response[6]) << 16 | Int(response[7]) << 24
        let crc = UInt32(response[8]) | UInt32(response[9]) << 8 | UInt32(response[10]) << 16 | UInt32(response[11]) << 24
        return ObjectInfo(maxSize: maxSize, offset: offset, crc: crc)
    }

    private func createObject(_ objectType: UInt8, size: Int) async throws {
        var payload = Data([objectType])
        payload.append(UInt32(size).littleEndianData)
        try await checkedCmd(.createObject, payload)
    }

    private func executeObject() async throws {
        try await checkedCmd(.execute)
    }

    private func setPRN() async throws {
        try await checkedCmd(.setPRN, Data([0x00]))
    }

    private func calculateChecksum() async throws -> (offset: Int, crc: UInt32) {
        let response = try await checkedCmd(.calcChecSum)
        guard response.count >= 8 else { throw TransferError(reason: "bad checksum response") }
        let offset = Int(response[0]) | Int(response[1]) << 8 | Int(response[2]) << 16 | Int(response[3]) << 24
        let crc = UInt32(response[4]) | UInt32(response[5]) << 8 | UInt32(response[6]) << 16 | UInt32(response[7]) << 24
        return (offset, crc)
    }

    private func getMTU() async -> Int {
        if let response = try? await checkedCmd(.getSerialMTU), response.count >= 2 {
            let value = Int(response[0]) | Int(response[1]) << 8
            if value > 0 { return value }
        }
        return 2051
    }

    // MARK: - Streaming

    private func sendFirmware(_ rawData: Data, crc startCrc: UInt32, offset startOffset: Int) async throws -> UInt32 {
        let data = Data(rawData)   // zero-based guarantee for index math below
        var crc = startCrc
        var offset = startOffset
        let chunkSize = max(64, (mtu - 1) / 2 - 1)

        var index = 0
        while index < data.count {
            let end = min(index + chunkSize, data.count)
            let chunk = data[index..<end]
            try await ble.writeDFU(chunk)
            // iOS needs a pause between packets (same as the original app)
            try await Task.sleep(nanoseconds: 250_000_000)
            offset += chunk.count
            crc = CRC32.update(crc, with: chunk)
            index = end
        }

        let (respOffset, respCrc) = try await calculateChecksum()
        if offset != respOffset {
            addLog("Offset mismatch: expected \(offset) got \(respOffset)")
            throw TransferError(reason: "offset")
        }
        if crc != respCrc {
            addLog("CRC mismatch: expected \(String(format: "%08X", crc)) got \(String(format: "%08X", respCrc))")
            throw TransferError(reason: "CRC")
        }
        return crc
    }

    func flashFirmware(objectType: UInt8, firmware rawFirmware: Data,
                       progress: @escaping (Double) -> Void) async throws {
        // normalize: zip-extracted Data is a slice with a non-zero startIndex,
        // and all index math below assumes a zero-based buffer
        let firmware = Data(rawFirmware)
        mtu = await getMTU()
        try await setPRN()
        addLog("DFU started (object \(objectType), \(firmware.count) bytes, mtu \(mtu))")

        var object = try await selectObject(objectType)
        var crc: UInt32 = 0

        var offset = 0
        let length = max(object.maxSize, 1)
        while offset < firmware.count {
            let crcBackup = crc
            var succeeded = false
            for attempt in 0..<50 {
                do {
                    try await createObject(objectType, size: min(firmware.count - offset, length))
                    let chunk = firmware[offset..<min(offset + length, firmware.count)]
                    crc = try await sendFirmware(chunk, crc: crc, offset: offset)
                    try await Task.sleep(nanoseconds: 10_000_000)
                    try await executeObject()
                    progress(Double(offset) / Double(firmware.count))
                    try await Task.sleep(nanoseconds: 10_000_000)
                    succeeded = true
                    break
                } catch let error as TransferError {
                    addLog("Transfer error (\(error.reason)), retry \(attempt + 1)/50…")
                    object = try await selectObject(objectType)
                    crc = crcBackup
                }
            }
            if !succeeded {
                throw TransferError(reason: "unable to recover")
            }
            offset += length
        }
        progress(1)
        addLog("DFU object \(objectType) done")
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        Data([UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF),
              UInt8((self >> 16) & 0xFF), UInt8((self >> 24) & 0xFF)])
    }
}
