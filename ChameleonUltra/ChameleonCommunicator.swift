import Foundation

enum ChameleonError: LocalizedError {
    case timeout(String)
    case invalidResponse(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .timeout(let what): return "Timeout waiting for response (\(what))"
        case .invalidResponse(let what): return "Invalid response: \(what)"
        case .notConnected: return "Not connected to a Chameleon device"
        }
    }
}

/// Full application-protocol layer, ported from `lib/bridge/chameleon.dart`
/// of the original ChameleonUltraGUI. All commands are serialized (FIFO) and
/// matched against the frame parser output.
@MainActor
final class ChameleonCommunicator {

    private let ble: BLEManager
    private var parser = ChameleonFrameParser()
    private let logger: (String) -> Void

    private var pending: [UInt16: CheckedContinuation<ChameleonMessage, Error>] = [:]

    // FIFO gate – one command in flight at a time (BLE is half duplex anyway)
    private var busy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    init(ble: BLEManager, logger: @escaping (String) -> Void = { _ in }) {
        self.ble = ble
        self.logger = logger
        ble.onData = { [weak self] data in
            // BLEManager delivers on the main thread
            self?.handleData(data)
        }
    }

    private func handleData(_ data: Data) {
        let messages = parser.feed([UInt8](data))
        for message in messages {
            logger("⇐ cmd=\(message.command) status=\(message.status) len=\(message.data.count)")
            if let continuation = pending.removeValue(forKey: message.command) {
                continuation.resume(returning: message)
            }
        }
    }

    // MARK: - Gate

    private func acquire() async {
        if busy {
            await withCheckedContinuation { gateWaiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if !gateWaiters.isEmpty {
            gateWaiters.removeFirst().resume()
        } else {
            busy = false
        }
    }

    // MARK: - Core send

    @discardableResult
    func sendCmd(_ cmd: ChameleonCommand, data: Data? = nil, timeout: TimeInterval = 5,
                 skipReceive: Bool = false, retryOnTimeout: Bool = true) async throws -> ChameleonMessage {

        await acquire()
        do {
            let frame = ChameleonFrameParser.makeFrame(cmd: cmd, status: 0, data: data)
            let dataHex = data?.hex ?? ""
            logger("⇒ cmd=\(cmd.rawValue) data=\(dataHex)")

            if skipReceive {
                try? await ble.write(frame)
                release()
                return ChameleonMessage(command: cmd.rawValue, status: 0, data: Data())
            }

            let message: ChameleonMessage
            do {
                message = try await awaitResponse(for: cmd, frame: frame, timeout: timeout)
            } catch let error as ChameleonError {
                if case .timeout = error, retryOnTimeout {
                    release()
                    return try await sendCmd(cmd, data: data, timeout: timeout,
                                             skipReceive: skipReceive, retryOnTimeout: false)
                }
                throw error
            }
            release()
            return message
        } catch {
            release()
            throw error
        }
    }

    /// Registers the response continuation synchronously (on the main actor)
    /// BEFORE the frame goes out, then writes in a child task and arms a
    /// timeout watchdog — race free by construction.
    private func awaitResponse(for cmd: ChameleonCommand, frame: Data, timeout: TimeInterval) async throws -> ChameleonMessage {
        try await withCheckedThrowingContinuation { continuation in
            guard pending[cmd.rawValue] == nil else {
                continuation.resume(throwing: ChameleonError.invalidResponse("duplicate command \(cmd.rawValue)"))
                return
            }
            pending[cmd.rawValue] = continuation

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.ble.write(frame)
                } catch {
                    self.failPending(cmd, error: error)
                }
            }

            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.timeoutPending(cmd)
            }
        }
    }

    private func timeoutPending(_ cmd: ChameleonCommand) {
        if let continuation = pending.removeValue(forKey: cmd.rawValue) {
            continuation.resume(throwing: ChameleonError.timeout("\(cmd.rawValue)"))
        }
    }

    private func failPending(_ cmd: ChameleonCommand, error: Error) {
        if let continuation = pending.removeValue(forKey: cmd.rawValue) {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Device commands (ported 1:1)

    func getFirmwareVersion() async throws -> FirmwareVersion {
        let resp = try await sendCmd(.getAppVersion)
        let data = resp.data
        guard data.count >= 2 else { throw ChameleonError.invalidResponse("getAppVersion") }
        if data[0] == 0 && data[1] == 1 {
            return FirmwareVersion(legacyProtocol: true, version: 256)
        }
        return FirmwareVersion(legacyProtocol: false, version: Int(data.readU16(at: 0)))
    }

    func getDeviceChipID() async throws -> String {
        try await sendCmd(.getDeviceChipID).data.hex.uppercased()
    }

    func getDeviceBLEAddress() async throws -> String {
        try await sendCmd(.getDeviceBLEAddress).data.hexSpaced.replacingOccurrences(of: " ", with: ":")
    }

    func getDeviceType() async throws -> ChameleonDevice {
        try await sendCmd(.getDeviceType).data.first == 0 ? .ultra : .lite
    }

    func isReaderDeviceMode() async throws -> Bool {
        try await sendCmd(.getDeviceMode).data.first == 1
    }

    func setReaderDeviceMode(_ readerMode: Bool) async throws {
        try await sendCmd(.changeDeviceMode, data: Data([readerMode ? 1 : 0]))
    }

    func getBatteryCharge() async throws -> BatteryCharge {
        let data = try await sendCmd(.getBatteryCharge).data
        return BatteryCharge(voltage: Int(data.readU16(at: 0)), percent: Int(data[2]))
    }

    func getGitCommitHash() async throws -> String {
        String(data: try await sendCmd(.getGitVersion).data, encoding: .utf8) ?? ""
    }

    // MARK: - Slots

    func activateSlot(_ slot: Int) async throws {
        try await sendCmd(.setActiveSlot, data: Data([UInt8(slot)]))
    }

    func getActiveSlot() async throws -> Int {
        Int(try await sendCmd(.getActiveSlot).data.first ?? 0)
    }

    func setSlotType(_ slot: Int, type: TagType) async throws {
        try await sendCmd(.setSlotTagType, data: Data([UInt8(slot)] + type.rawValue.bytesBE))
    }

    func setDefaultDataToSlot(_ slot: Int, type: TagType) async throws {
        try await sendCmd(.setSlotDataDefault, data: Data([UInt8(slot)] + type.rawValue.bytesBE))
    }

    func enableSlot(_ slot: Int, frequency: TagFrequency, status: Bool) async throws {
        try await sendCmd(.setSlotEnable, data: Data([UInt8(slot), frequency.rawValue, status ? 1 : 0]))
    }

    func setSlotTagName(_ index: Int, name: String, frequency: TagFrequency) async throws {
        try await sendCmd(.setSlotTagNick, data: Data([UInt8(index), frequency.rawValue]) + Data(name.utf8))
    }

    func getSlotTagName(_ index: Int, frequency: TagFrequency) async throws -> String {
        let data = try await sendCmd(.getSlotTagNick, data: Data([UInt8(index), frequency.rawValue])).data
        return String(data: data, encoding: .utf8) ?? ""
    }

    func getSlotTagNames() async throws -> [SlotNames] {
        let data = try await sendCmd(.getAllSlotNicks).data
        var slots = Array(repeating: SlotNames(), count: 8)
        var i = 0
        var index = 0
        while i < data.count && index < 8 {
            let hfLen = Int(data[data.startIndex + i]); i += 1
            if hfLen > 0 && i + hfLen <= data.count {
                slots[index].hf = String(data: data[Range(NSRange(location: i, length: hfLen), in: data)!], encoding: .utf8) ?? ""
                i += hfLen
            }
            guard i < data.count else { break }
            let lfLen = Int(data[data.startIndex + i]); i += 1
            if lfLen > 0 && i + lfLen <= data.count {
                slots[index].lf = String(data: data[Range(NSRange(location: i, length: lfLen), in: data)!], encoding: .utf8) ?? ""
                i += lfLen
            }
            index += 1
        }
        return slots
    }

    func deleteSlotInfo(_ index: Int, frequency: TagFrequency) async throws {
        try await sendCmd(.deleteSlotInfo, data: Data([UInt8(index), frequency.rawValue]))
    }

    func deleteSlotTagNick(_ index: Int, frequency: TagFrequency) async throws {
        try await sendCmd(.deleteSlotTagNick, data: Data([UInt8(index), frequency.rawValue]))
    }

    func saveSlotData() async throws {
        try await sendCmd(.saveSlotNicks)
    }

    func getSlotTagTypes() async throws -> [SlotTypes] {
        let data = try await sendCmd(.getSlotInfo).data
        var tags: [SlotTypes] = []
        var index = 0
        for _ in 0..<8 {
            guard index + 4 <= data.count else { break }
            tags.append(SlotTypes(hf: TagType(rawValue: data.readU16(at: index)) ?? .unknown,
                                  lf: TagType(rawValue: data.readU16(at: index + 2)) ?? .unknown))
            index += 4
        }
        return tags
    }

    func getEnabledSlots() async throws -> [EnabledSlotInfo] {
        let data = try await sendCmd(.getEnabledSlots).data
        var slots: [EnabledSlotInfo] = []
        for slot in 0..<8 {
            slots.append(EnabledSlotInfo(hf: slot * 2 < data.count && data[data.startIndex + slot * 2] != 0,
                                         lf: slot * 2 + 1 < data.count && data[data.startIndex + slot * 2 + 1] != 0))
        }
        return slots
    }

    // MARK: - Device settings

    func getAnimationMode() async throws -> AnimationSetting {
        let value = try await sendCmd(.getAnimationMode).data.first ?? 2
        return AnimationSetting(rawValue: value) ?? .none
    }

    func setAnimationMode(_ animation: AnimationSetting) async throws {
        try await sendCmd(.setAnimationMode, data: Data([animation.rawValue]))
    }

    func getButtonConfig(_ type: ButtonType, long: Bool = false) async throws -> ButtonConfig {
        let cmd: ChameleonCommand = long ? .getLongButtonPressConfig : .getButtonPressConfig
        let value = try await sendCmd(cmd, data: Data([type.rawValue])).data.first ?? 0
        return ButtonConfig.fromValue(value)
    }

    func setButtonConfig(_ type: ButtonType, mode: ButtonConfig, long: Bool = false) async throws {
        let cmd: ChameleonCommand = long ? .setLongButtonPressConfig : .setButtonPressConfig
        try await sendCmd(cmd, data: Data([type.rawValue, mode.rawValue]))
    }

    func getSleepTimeout() async throws -> Int {
        Int(try await sendCmd(.getSleepTimeout).data.first ?? 0)
    }

    func setSleepTimeout(_ seconds: Int) async throws {
        try await sendCmd(.setSleepTimeout, data: Data([UInt8(seconds)]))
    }

    func getBLEConnectionKey() async throws -> String {
        String(data: try await sendCmd(.bleGetConnectKey).data, encoding: .utf8) ?? ""
    }

    func setBLEConnectKey(_ key: String) async throws {
        try await sendCmd(.bleSetConnectKey, data: Data(key.utf8))
    }

    func isBLEPairEnabled() async throws -> Bool {
        try await sendCmd(.bleGetPairEnable).data.first == 1
    }

    func setBLEPairEnabled(_ status: Bool) async throws {
        try await sendCmd(.bleSetPairEnable, data: Data([status ? 1 : 0]))
    }

    func clearBLEBoundedDevices() async throws {
        try await sendCmd(.bleClearBondedDevices, skipReceive: true)
    }

    func saveSettings() async throws {
        try await sendCmd(.saveSettings)
    }

    func resetSettings() async throws {
        try await sendCmd(.resetSettings)
    }

    func factoryReset() async throws {
        try await sendCmd(.factoryReset, skipReceive: true)
    }

    func enterDFUMode() async throws {
        try await sendCmd(.enterBootloader, skipReceive: true)
    }

    // MARK: - HF reader

    func scan14443aTag() async throws -> CardData? {
        let data = try await sendCmd(.scan14ATag).data
        guard !data.isEmpty else { return nil }
        return Self.parseCardData(data)
    }

    static func parseCardData(_ data: Data) -> CardData? {
        guard let uidLength = data.first, data.count >= uidLength + 5 else { return nil }
        let base = data.startIndex
        let atsLength = Int(data[base + uidLength + 4])
        let atqaRaw = data.subdata(in: (base + uidLength + 1)..<(base + uidLength + 3))
        let atqa = Data(atqaRaw.reversed())
        let atsStart = base + uidLength + 5
        let ats = atsStart + atsLength <= data.count ? data.subdata(in: atsStart..<(atsStart + atsLength)) : Data()
        return CardData(uid: data.subdata(in: (base + 1)..<(base + 1 + uidLength)),
                        sak: data[base + uidLength + 3],
                        atqa: atqa,
                        ats: ats)
    }

    func detectMf1Support() async throws -> Bool {
        try await sendCmd(.mf1SupportDetect).status == 0
    }

    func getMf1NTLevel() async throws -> NTLevel {
        switch try await sendCmd(.mf1NTLevelDetect).data.first {
        case 0: return .statik
        case 1: return .weak
        case 2: return .hard
        default: return .unknown
        }
    }

    func mf1Auth(block: Int, keyType: UInt8, key: Data) async throws -> Bool {
        try await sendCmd(.mf1CheckKey, data: Data([keyType, UInt8(block)]) + key).status == 0
    }

    /// Returns the matching key (6 bytes) or nil.
    func mf1AuthMultipleKeys(block: Int, keyType: UInt8, keys: [Data]) async throws -> Data? {
        guard !keys.isEmpty else { return nil }
        var payload = Data([UInt8(block), keyType, UInt8(keys.count)])
        keys.forEach { payload.append($0) }
        let resp = try await sendCmd(.mf1CheckKeysOnBlock, data: payload, timeout: TimeInterval(5 + Double(keys.count) / 32))
        guard resp.status == 0, resp.data.count >= 7 else { return nil }
        return resp.data.subdata(in: 1..<7)
    }

    func mf1ReadBlock(block: Int, keyType: UInt8, key: Data) async throws -> Data {
        try await sendCmd(.mf1ReadBlock, data: Data([keyType, UInt8(block)]) + key).data
    }

    func mf1WriteBlock(block: Int, keyType: UInt8, key: Data, blockData: Data) async throws -> Bool {
        try await sendCmd(.mf1WriteBlock, data: Data([keyType, UInt8(block)]) + key + blockData).status == 0
    }

    func setMf1BlockData(startBlock: Int, blocks: Data) async throws {
        try await sendCmd(.mf1LoadBlockData, data: Data([UInt8(startBlock & 0xFF)]) + blocks, timeout: 10)
    }

    func setMf1AntiCollision(_ card: CardData) async throws {
        var payload = Data([UInt8(card.uid.count)])
        payload.append(card.uid)
        payload.append(Data(card.atqa.reversed()))
        payload.append(card.sak)
        payload.append(UInt8(card.ats.count))
        payload.append(card.ats)
        try await sendCmd(.mf1SetAntiCollision, data: payload)
    }

    func mf1GetBlockData(startBlock: Int, blockCount: Int) async throws -> Data {
        try await sendCmd(.mf1GetBlockData, data: Data([UInt8(startBlock), UInt8(blockCount)])).data
    }

    func mf1GetAntiCollData() async throws -> CardData {
        let data = try await sendCmd(.mf1GetAntiCollData).data
        return Self.parseCardData(data) ?? CardData(uid: Data(), sak: 0, atqa: Data(), ats: Data())
    }

    func getMf1DetectionCount() async throws -> Int {
        let data = try await sendCmd(.mf1GetDetectionCount).data
        guard data.count >= 4 else { return 0 }
        return Int(bitPattern: data.readU32(at: 0))
    }

    func getMf1DetectionResults(count: Int) async throws -> [DetectionResult] {
        var results: [DetectionResult] = []
        while results.count < count {
            let resp = try await sendCmd(.mf1GetDetectionResult,
                                         data: Data(UInt32(results.count).bytesBE)).data
            guard !resp.isEmpty else { break }
            var pos = 0
            while pos + 18 <= resp.count {
                results.append(DetectionResult(block: Int(resp[resp.startIndex + pos]),
                                               type: 0x60 + (Int(resp[resp.startIndex + pos + 1]) & 0x01),
                                               isNested: ((resp[resp.startIndex + pos + 1] >> 1) & 0x01) == 0x01,
                                               uid: resp.readU32(at: pos + 2),
                                               nt: resp.readU32(at: pos + 6),
                                               nr: resp.readU32(at: pos + 10),
                                               ar: resp.readU32(at: pos + 14)))
                pos += 18
            }
        }
        return results
    }

    // MARK: - 14A raw

    struct Raw14AOptions {
        var respTimeoutMs: Int = 100
        var bitLen: Int? = nil
        var activateRfField = true
        var waitResponse = true
        var appendCrc = true
        var autoSelect = true
        var keepRfField = false
        var checkResponseCrc = true
    }

    func send14ARaw(_ raw: Data, options: Raw14AOptions = Raw14AOptions()) async throws -> Data {
        let bitLen = options.bitLen ?? raw.count * 8
        var optionBits = 0
        if options.activateRfField { optionBits += 128 }
        if options.waitResponse { optionBits += 64 }
        if options.appendCrc { optionBits += 32 }
        if options.autoSelect { optionBits += 16 }
        if options.keepRfField { optionBits += 8 }
        if options.checkResponseCrc { optionBits += 4 }

        let timeoutMs = UInt16(clamping: options.respTimeoutMs)
        var payload = Data([UInt8(optionBits)])
        payload.append(contentsOf: timeoutMs.bytesBE)
        payload.append(contentsOf: UInt16(bitLen).bytesBE)
        payload.append(raw)
        return try await sendCmd(.hf14ARawCommand, data: payload).data
    }

    // MARK: - Emulator settings

    func getMf1EmulatorSettings() async throws -> EmulatorSettings {
        let data = try await sendCmd(.mf1GetEmulatorConfig).data
        var mode = MifareWriteMode.normal
        if data.count > 4 {
            switch data[data.startIndex + 4] {
            case 1: mode = .denied
            case 2: mode = .deceive
            case 3, 4: mode = .shadow
            default: break
            }
        }
        return EmulatorSettings(isDetectionEnabled: data.first == 1,
                                isGen1a: data.count > 1 && data[data.startIndex + 1] == 1,
                                isGen2: data.count > 2 && data[data.startIndex + 2] == 1,
                                isAntiColl: data.count > 3 && data[data.startIndex + 3] == 1,
                                writeMode: mode)
    }

    func setMf1Gen1aMode(_ enabled: Bool) async throws {
        try await sendCmd(.mf1SetGen1aMode, data: Data([enabled ? 1 : 0]))
    }

    func setMf1Gen2Mode(_ enabled: Bool) async throws {
        try await sendCmd(.mf1SetGen2Mode, data: Data([enabled ? 1 : 0]))
    }

    func setMf1UseFirstBlockColl(_ enabled: Bool) async throws {
        try await sendCmd(.mf1SetFirstBlockColl, data: Data([enabled ? 1 : 0]))
    }

    func setMf1WriteMode(_ mode: MifareWriteMode) async throws {
        try await sendCmd(.mf1SetWriteMode, data: Data([mode.rawValue]))
    }

    func setMf1DetectionStatus(_ enabled: Bool) async throws {
        try await sendCmd(.mf1SetDetectionEnable, data: Data([enabled ? 1 : 0]))
    }

    func isMf1DetectionMode() async throws -> Bool {
        try await sendCmd(.mf1GetDetectionStatus).data.first == 1
    }

    // MARK: - LF

    func readEM410X() async throws -> EM410XCard? {
        let data = try await sendCmd(.scanEM410Xtag).data
        return data.isEmpty ? nil : EM410XCard.fromBytes(data)
    }

    func readHIDProx() async throws -> HIDCard? {
        let data = try await sendCmd(.scanHIDProxTag).data
        return data.isEmpty ? nil : HIDCard.fromBytes(data)
    }

    func readViking() async throws -> GenericLFCard? {
        let data = try await sendCmd(.scanVikingTag).data
        return data.isEmpty ? nil : GenericLFCard(type: .viking, uid: data)
    }

    func readPac() async throws -> GenericLFCard? {
        let data = try await sendCmd(.scanPacTag).data
        return data.isEmpty ? nil : GenericLFCard(type: .pac, uid: data)
    }

    func readIoProx() async throws -> GenericLFCard? {
        let data = try await sendCmd(.scanIoProxTag).data
        return data.isEmpty ? nil : GenericLFCard(type: .ioProx, uid: data)
    }

    func setEM410XEmulatorID(_ uid: Data) async throws {
        try await sendCmd(.setEM410XemulatorID, data: uid)
    }

    func setHIDProxEmulatorID(_ uid: Data) async throws {
        try await sendCmd(.setHIDProxEmulatorID, data: uid)
    }

    func setVikingEmulatorID(_ uid: Data) async throws {
        try await sendCmd(.setVikingEmulatorID, data: uid)
    }

    func setPacEmulatorID(_ uid: Data) async throws {
        try await sendCmd(.setPacEmulatorID, data: uid)
    }

    func setIoProxEmulatorID(_ uid: Data) async throws {
        try await sendCmd(.setIoProxEmulatorID, data: uid)
    }

    func setIdteckEmulatorID(_ uid: Data) async throws {
        try await sendCmd(.setIdteckEmulatorID, data: uid)
    }

    func writeEM410XtoT55XX(uid: Data, newKey: Data, oldKeys: [Data]) async throws {
        if uid.count == 5 {
            try await sendCmd(.writeEM410XtoT5577, data: uid + newKey + newKey + oldKeys.reduce(Data(), +))
        } else if uid.count == 13 {
            try await sendCmd(.writeEM410XElectraToT5577, data: uid + newKey + newKey + oldKeys.reduce(Data(), +))
        } else {
            throw ChameleonError.invalidResponse("Invalid EM410X UID length")
        }
    }

    func writeLFToT55XX(command: ChameleonCommand, uid: Data, newKey: Data, oldKeys: [Data]) async throws {
        try await sendCmd(command, data: uid + newKey + newKey + oldKeys.reduce(Data(), +))
    }

    func writeT55XX(block: Int, word: Data, password: Data? = nil, page1: Bool = false) async throws {
        let pwd = password ?? Data(repeating: 0, count: 4)
        try await sendCmd(.writeT55XX, data: Data([UInt8(block)]) + word + Data([password != nil ? 1 : 0]) + pwd + Data([page1 ? 1 : 0]))
    }

    func lfSniff(timeoutMs: Int = 2000) async throws -> Data {
        let clamped = min(max(timeoutMs, 1), 10000)
        let resp = try await sendCmd(.lfSniff, data: Data([UInt8((clamped >> 8) & 0xFF), UInt8(clamped & 0xFF)]),
                                     timeout: TimeInterval(clamped / 1000 + 2))
        if resp.status == 0x40 { return resp.data }
        if resp.status == 0x41 { return Data() }
        throw ChameleonError.invalidResponse("LF sniff failed with status \(resp.status)")
    }

    func hf14aSniff(timeoutMs: Int = 5000) async throws -> Data {
        let clamped = min(max(timeoutMs, 1), 30000)
        let resp = try await sendCmd(.hf14aSniff, data: Data([UInt8((clamped >> 8) & 0xFF), UInt8(clamped & 0xFF)]),
                                     timeout: TimeInterval(clamped / 1000 + 5))
        if resp.status == 0x68 || resp.status == 0x00 { return resp.data }
        if resp.status == 0x01 { return Data() }
        throw ChameleonError.invalidResponse("HF sniff failed with status \(resp.status)")
    }

    // MARK: - Mifare Ultralight C

    func mf0UlcAuth(key: Data) async throws -> Bool {
        try await sendCmd(.mf0UlcAuth, data: key).status == 0
    }

    func mf0UlcReadPages(key: Data, page: Int, count: Int) async throws -> Data {
        try await sendCmd(.mf0UlcRead, data: key + Data([UInt8(page), UInt8(count)])).data
    }

    func mf0UlcWritePage(key: Data, page: Int, data: Data) async throws -> Bool {
        try await sendCmd(.mf0UlcWrite, data: key + Data([UInt8(page)]) + data).status == 0
    }
}
