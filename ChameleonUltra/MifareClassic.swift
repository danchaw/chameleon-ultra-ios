import Foundation

/// Mifare Classic helpers ported from `helpers/mifare_classic/general.dart`
/// and the recovery flow from `helpers/mifare_classic/recovery.dart`.
enum MifareClassic {

    /// Default keys from Proxmark3 (same order as the original app).
    static let defaultKeys: [Data] = [
        "FFFFFFFFFFFF", "A0A1A2A3A4A5", "D3F7D3F7D3F7", "4B791BEA7BCC",
        "5C8FF9990DA2", "D01AFEEB890A", "75CCB59C9BED", "6471A5EF2D1A",
        "4E3552426B32", "EF1232AB18A0", "B7BF0C13066E", "135B88A94B8B",
        "2A2C13CC242A", "5A7A52D5E20D", "314B49474956", "564C505F4D41",
        "021209197591", "484558414354", "EC0A9B1A9E06", "66B31E64CA4B",
        "E00000000000", "199404281970", "199404281998", "6A1987C40A21",
        "7F33625BC129", "484944204953", "204752454154", "3B7E4FD575AD",
        "11496F97752A", "000000000000", "B0B1B2B3B4B5", "AABBCCDDEEFF",
        "1A2B3C4D5E6F", "123456789ABC", "010203040506", "123456ABCDEF",
        "ABCDEF123456", "4D3A99C351DD", "1A982C7E459A", "714C5C886E97",
        "587EE5F9350F", "A0478CC39091", "533CB6C723F6", "8FD0A4F256E9",
        "0000014B5C31", "B578F38A5C61", "96A301BCE267",
    ].map { Data(hex: $0) }

    static let ev1SignatureKeys: [Data] = [
        defaultKeys[3], defaultKeys[4], defaultKeys[5], defaultKeys[6],
    ]

    /// Detect Classic capacity exactly like `mfClassicGetType`.
    static func getType(via communicator: ChameleonCommunicator) async throws -> MifareClassicType {
        var options = ChameleonCommunicator.Raw14AOptions()
        options.checkResponseCrc = false
        options.respTimeoutMs = 100

        if try await communicator.send14ARaw(Data([0x60, 255]), options: options).count == 4 { return .m4k }
        if try await communicator.send14ARaw(Data([0x60, 80]), options: options).count == 4 { return .m2k }
        if try await communicator.send14ARaw(Data([0x60, 63]), options: options).count == 4 { return .m1k }
        return .mini
    }

    static func sectorTrailerBlock(sector: Int) -> Int {
        sector < 32 ? sector * 4 + 3 : 32 * 4 + (sector - 32) * 16 + 15
    }

    static func firstBlockOfSector(sector: Int) -> Int {
        sector < 32 ? sector * 4 : 32 * 4 + (sector - 32) * 16
    }

    static func blockCountInSector(sector: Int) -> Int {
        sector < 32 ? 4 : 16
    }

    /// Build a block 0 from UID/SAK/ATQA (reference: proxmark magic_cards_notes).
    static func patchFirstBlock(_ original: Data, uid: Data, sak: UInt8, atqa: Data, vanitySak: Bool) -> Data {
        var block0 = original.count >= 16 ? original : Data(repeating: 0, count: 16)
        let sakToStore = vanitySak ? sak | 0x80 : sak
        if uid.count == 4 {
            for (i, byte) in uid.enumerated() { block0[i] = byte }
            block0[4] = calculateBCC(uid)
            block0[5] = sakToStore
            if atqa.count == 2 {
                block0[6] = atqa[1]; block0[7] = atqa[0]
            }
        } else if uid.count == 7 {
            for (i, byte) in uid.enumerated() { block0[i] = byte }
            block0[7] = sakToStore
            if atqa.count == 2 {
                block0[8] = atqa[1]; block0[9] = atqa[0]
            }
        }
        return block0
    }
}

enum KeyCheckmark: Equatable {
    case none, checking, found, missing, disabled
}

/// Port of `MifareClassicRecovery` – drives the key check + dump flow.
@MainActor
final class MifareClassicRecovery: ObservableObject {

    enum Phase: Equatable {
        case idle, checkingKeys, dumping, done, failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var state: String = ""
    @Published var keyCheckProgress: Double? = nil
    @Published var dumpProgress: Double = 0
    @Published var allKeysExist = false
    @Published var checkMarks: [KeyCheckmark] = Array(repeating: .none, count: 80)
    @Published var validKeys: [Data] = Array(repeating: Data(), count: 80)
    @Published var cardData: [Data] = Array(repeating: Data(), count: 256)
    @Published var isEV1 = false
    @Published var ntLevel: NTLevel = .unknown

    var mifareClassicType: MifareClassicType = .none

    private let communicator: ChameleonCommunicator
    private var selectedDictionary: KeyDictionary?
    private var skipDefaultDictionary = false

    init(communicator: ChameleonCommunicator) {
        self.communicator = communicator
    }

    var sectorCount: Int {
        isEV1 && mifareClassicType == .m1k ? 18 : mifareClassicType.sectorCount
    }

    func mark(sector: Int, keyType: Int) -> KeyCheckmark { checkMarks[sector * 2 + keyType] }
    func key(sector: Int, keyType: Int) -> Data { validKeys[sector * 2 + keyType] }

    private func setMark(_ mark: KeyCheckmark, sector: Int, keyType: Int) {
        checkMarks[sector * 2 + keyType] = mark
    }

    private func setKeyFound(_ key: Data, sector: Int, keyType: Int) {
        validKeys[sector * 2 + keyType] = key
        checkMarks[sector * 2 + keyType] = .found
    }

    func initializeEV1() {
        guard isEV1 else { return }
        setKeyFound(MifareClassic.ev1SignatureKeys[1], sector: 16, keyType: 0)
        setKeyFound(MifareClassic.ev1SignatureKeys[2], sector: 16, keyType: 1)
        setKeyFound(MifareClassic.ev1SignatureKeys[3], sector: 17, keyType: 0)
        setKeyFound(MifareClassic.ev1SignatureKeys[0], sector: 17, keyType: 1)
    }

    func detectCard() async throws {
        if try await !communicator.isReaderDeviceMode() {
            try await communicator.setReaderDeviceMode(true)
        }
        mifareClassicType = try await MifareClassic.getType(via: communicator)
        isEV1 = try await communicator.mf1Auth(block: 0x45, keyType: 0x61, key: MifareClassic.defaultKeys[3])
        initializeEV1()
        ntLevel = (try? await communicator.getMf1NTLevel()) ?? .unknown
    }

    private func checkKeysOnSector(_ keys: [Data], keyType: Int, sector: Int) async throws -> Bool {
        let keyName = keyType == 0 ? "A" : "B"
        state = "Checking \(keys.count) keys (sector \(sector), key \(keyName))"
        var foundKey: Data?
        keyCheckProgress = nil

        if mark(sector: sector, keyType: keyType) != .found && mark(sector: sector, keyType: keyType) != .disabled {
            setMark(.checking, sector: sector, keyType: keyType)
            // 16 keys per chunk: halves the per-command device time so slow
            // cards don't run into the response timeout (cmd 2015)
            let chunkSize = 16
            let chunks = stride(from: 0, to: keys.count, by: chunkSize).map { Array(keys[$0..<min($0 + chunkSize, keys.count)]) }
            let totalChunks = chunks.count

            for chunk in chunks {
                try Task.checkCancellation()
                foundKey = try await communicator.mf1AuthMultipleKeys(
                    block: MifareClassic.sectorTrailerBlock(sector: sector),
                    keyType: UInt8(0x60 + keyType),
                    keys: chunk)
                if let foundKey {
                    setKeyFound(foundKey, sector: sector, keyType: keyType)
                    keyCheckProgress = nil
                    try await recheckKey(foundKey, startingSector: sector)
                    return true
                } else if totalChunks > 10 {
                    keyCheckProgress = (keyCheckProgress ?? 0) + 1.0 / Double(totalChunks)
                }
            }

            if foundKey == nil {
                setMark(.missing, sector: sector, keyType: keyType)
            }
        }

        // try to read B key from the trailer using the A key
        if keyType == 0,
           mark(sector: sector, keyType: 0) == .found,
           mark(sector: sector, keyType: 1) != .found,
           mark(sector: sector, keyType: 1) != .disabled,
           let aKey = key(sector: sector, keyType: 0).isEmpty ? nil : key(sector: sector, keyType: 0) {
            let block = try await communicator.mf1ReadBlock(
                block: MifareClassic.sectorTrailerBlock(sector: sector), keyType: 0x60, key: aKey)
            if block.count == 16 {
                let bKey = block.subdata(in: 10..<16)
                if bKey != Data(repeating: 0, count: 6) {
                    keyCheckProgress = nil
                    setKeyFound(bKey, sector: sector, keyType: 1)
                    try await recheckKey(bKey, startingSector: sector)
                    return true
                }
            }
        }

        setMark(.missing, sector: sector, keyType: keyType)
        keyCheckProgress = nil
        return false
    }

    private func recheckKey(_ key: Data, startingSector: Int) async throws {
        for sector in startingSector..<sectorCount {
            try Task.checkCancellation()
            for keyType in 0..<2 where mark(sector: sector, keyType: keyType) == .none {
                let keyName = keyType == 0 ? "A" : "B"
                state = "Checking found key on sector \(sector), key \(keyName)"
                setMark(.checking, sector: sector, keyType: keyType)
                if try await communicator.mf1Auth(block: MifareClassic.sectorTrailerBlock(sector: sector),
                                                  keyType: UInt8(0x60 + keyType), key: key) {
                    setKeyFound(key, sector: sector, keyType: keyType)
                } else {
                    setMark(.missing, sector: sector, keyType: keyType)
                }
            }
        }
    }

    func checkKeys(dictionary: KeyDictionary?, skipDefaultDictionary: Bool = false) async throws {
        selectedDictionary = dictionary
        self.skipDefaultDictionary = skipDefaultDictionary
        initializeEV1()

        var keyList: [Data] = []
        if let dictionary {
            keyList.append(contentsOf: dictionary.keyData)
        }
        if !skipDefaultDictionary {
            let dictKeys = dictionary?.keyData ?? []
            keyList.append(contentsOf: MifareClassic.defaultKeys.filter { !dictKeys.contains($0) })
        }

        for sector in 0..<sectorCount {
            try Task.checkCancellation()
            for keyType in 0..<2 {
                _ = try await checkKeysOnSector(keyList, keyType: keyType, sector: sector)
            }
        }

        allKeysExist = true
        for sector in 0..<sectorCount {
            for keyType in 0..<2 {
                let mark = mark(sector: sector, keyType: keyType)
                if mark != .found && mark != .disabled { allKeysExist = false }
            }
        }
        state = ""
    }

    func dumpData() async throws {
        cardData = Array(repeating: Data(), count: 256)
        let totalBlocks = isEV1 && mifareClassicType == .m1k ? 72 : mifareClassicType.blockCount

        for sector in 0..<sectorCount {
            try Task.checkCancellation()
            for block in 0..<MifareClassic.blockCountInSector(sector: sector) {
                let absoluteBlock = block + MifareClassic.firstBlockOfSector(sector: sector)
                var blockData = Data()

                for keyType in 0..<2 {
                    let sectorKey = key(sector: sector, keyType: keyType)
                    if sectorKey.isEmpty {
                        blockData = Data(repeating: 0, count: 16)
                        break
                    }
                    var data = try await communicator.mf1ReadBlock(
                        block: absoluteBlock, keyType: UInt8(0x60 + keyType), key: sectorKey)
                    if data.isEmpty {
                        if keyType == 1 { data = Data(repeating: 0, count: 16) } else { continue }
                    }
                    if MifareClassic.sectorTrailerBlock(sector: sector) == absoluteBlock {
                        let keyA = key(sector: sector, keyType: 0)
                        let keyB = key(sector: sector, keyType: 1)
                        if !keyA.isEmpty && data.count == 16 { data.replaceSubrange(0..<6, with: keyA) }
                        if !keyB.isEmpty && data.count == 16 { data.replaceSubrange(10..<16, with: keyB) }
                    }
                    blockData = data
                    break
                }

                if blockData.isEmpty { blockData = Data(repeating: 0, count: 16) }
                cardData[absoluteBlock] = blockData
                dumpProgress = Double(absoluteBlock) / Double(max(totalBlocks, 1))
            }
        }
    }
}
