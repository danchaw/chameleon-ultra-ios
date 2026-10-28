/// Chameleon protocol definitions ported 1:1 from the original
/// ChameleonUltraGUI (Dart) `lib/helpers/definitions.dart`.
/// Licensed under GPL-3.0 together with the whole project.

import Foundation

// MARK: - Commands

enum ChameleonCommand: UInt16 {
    // basic commands
    case getAppVersion = 1000
    case changeDeviceMode = 1001
    case getDeviceMode = 1002
    case setActiveSlot = 1003
    case setSlotTagType = 1004
    case setSlotDataDefault = 1005
    case setSlotEnable = 1006
    case setSlotTagNick = 1007
    case getSlotTagNick = 1008
    case saveSlotNicks = 1009
    case enterBootloader = 1010
    case getDeviceChipID = 1011
    case getDeviceBLEAddress = 1012
    case saveSettings = 1013
    case resetSettings = 1014
    case setAnimationMode = 1015
    case getAnimationMode = 1016
    case getGitVersion = 1017
    case getActiveSlot = 1018
    case getSlotInfo = 1019
    case factoryReset = 1020
    case deleteSlotTagNick = 1021
    case getEnabledSlots = 1023
    case deleteSlotInfo = 1024
    case getBatteryCharge = 1025
    case getButtonPressConfig = 1026
    case setButtonPressConfig = 1027
    case getLongButtonPressConfig = 1028
    case setLongButtonPressConfig = 1029
    case bleSetConnectKey = 1030
    case bleGetConnectKey = 1031
    case bleClearBondedDevices = 1032
    case getDeviceType = 1033
    case getDeviceSettings = 1034
    case getDeviceCapabilities = 1035
    case bleGetPairEnable = 1036
    case bleSetPairEnable = 1037
    case getAllSlotNicks = 1038
    case getSleepTimeout = 1039
    case setSleepTimeout = 1040
    case getLongPressThreshold = 1041
    case setLongPressThreshold = 1042

    // hf reader commands
    case scan14ATag = 2000
    case mf1SupportDetect = 2001
    case mf1NTLevelDetect = 2002
    case mf1StaticNestedAcquire = 2003
    case mf1DarksideAcquire = 2004
    case mf1NTDistanceDetect = 2005
    case mf1NestedAcquire = 2006
    case mf1CheckKey = 2007
    case mf1ReadBlock = 2008
    case mf1WriteBlock = 2009
    case hf14ARawCommand = 2010
    case mf1ManipulateValueBlock = 2011
    case mf1CheckKeysOfSectors = 2012
    case mf1HardNestedAcquire = 2013
    case mf1StaticEncryptedNestedAcquire = 2014
    case mf1CheckKeysOnBlock = 2015
    case hf14aScanKeep = 2016
    case hf14aAuthTrace = 2017
    case mf0UlcAuth = 2018
    case mf0UlcRead = 2019
    case hf14aSniff = 2020
    case mf0UlcWrite = 2021
    case mf0UlcSetKey = 2022
    case hf14aSetFieldOn = 2100
    case hf14aSetFieldOff = 2101
    case hf14aGetConfig = 2200
    case hf14aSetConfig = 2201

    // hf 14a-4 (T=CL)
    case hf14a4ApduRecv = 6000
    case hf14a4ApduSend = 6001
    case hf14a4SetAntiColl = 6002
    case hf14a4StaticResp = 6003
    case hf14a4ReaderApdu = 6004
    case hf14a4EmvScan = 6005

    // lf commands
    case scanEM410Xtag = 3000
    case writeEM410XtoT5577 = 3001
    case scanHIDProxTag = 3002
    case writeHIDProxToT5577 = 3003
    case scanVikingTag = 3004
    case writeVikingToT5577 = 3005
    case writeEM410XElectraToT5577 = 3006
    case scanIoProxTag = 3010
    case writeIoProxToT5577 = 3011
    case ioProxDecodeRaw = 3012
    case ioProxComposeID = 3013
    case scanPacTag = 3014
    case writePacToT5577 = 3015
    case writeT55XX = 3016
    case writeIdteckToT5577 = 3018
    case adcGenericRead = 3009
    case scanEM4X05Tag = 3030
    case lfSniff = 3031

    case mf1LoadBlockData = 4000
    case mf1SetAntiCollision = 4001
    case mf1SetDetectionEnable = 4004
    case mf1GetDetectionCount = 4005
    case mf1GetDetectionResult = 4006
    case mf1GetDetectionStatus = 4007
    case mf1GetBlockData = 4008
    case mf1GetEmulatorConfig = 4009
    case mf1GetGen1aMode = 4010
    case mf1SetGen1aMode = 4011
    case mf1GetGen2Mode = 4012
    case mf1SetGen2Mode = 4013
    case mf1GetFirstBlockColl = 4014
    case mf1SetFirstBlockColl = 4015
    case mf1GetWriteMode = 4016
    case mf1SetWriteMode = 4017
    case mf1GetAntiCollData = 4018
    case mf0NtagGetUidMagicMode = 4019
    case mf0NtagSetUidMagicMode = 4020
    case mf0NtagReadEmuPageData = 4021
    case mf0NtagWriteEmuPageData = 4022
    case mf0NtagGetVersionData = 4023
    case mf0NtagSetVersionData = 4024
    case mf0NtagGetSignatureData = 4025
    case mf0NtagSetSignatureData = 4026
    case mf0NtagGetCounterData = 4027
    case mf0NtagSetCounterData = 4028
    case mf0NtagResetAuthCount = 4029
    case mf0NtagGetPageCount = 4030
    case mf0NtagGetWriteMode = 4031
    case mf0NtagSetWriteMode = 4032
    case mf0NtagSetDetectionEnable = 4033
    case mf0NtagGetDetectionCount = 4034
    case mf0NtagGetDetectionLog = 4035
    case mf0NtagGetDetectionEnable = 4036
    case mf0NtagGetEmulatorConfig = 4037
    case mf1SetFieldOffDoReset = 4038
    case mf1GetFieldOffDoReset = 4039
    case mf1GetPrngType = 4040
    case mf1SetPrngType = 4041

    // device-side auto slot polling — custom firmware only
    case setAutoPoll = 4045
    case getAutoPoll = 4046

    // lf emulator
    case setEM410XemulatorID = 5000
    case getEM410XemulatorID = 5001
    case setHIDProxEmulatorID = 5002
    case getHIDProxEmulatorID = 5003
    case setVikingEmulatorID = 5004
    case getVikingEmulatorID = 5005
    case setPacEmulatorID = 5006
    case getPacEmulatorID = 5007
    case setIoProxEmulatorID = 5008
    case getIoProxEmulatorID = 5009
    case setIdteckEmulatorID = 5012
    case getIdteckEmulatorID = 5013
}

// MARK: - Tag types

enum TagType: UInt16, CaseIterable, Codable, Identifiable {
    case unknown = 0
    case em410X = 100
    case em410X16 = 101
    case em410X32 = 102
    case em410X64 = 103
    case em410XElectra = 104
    case pac = 150
    case viking = 170
    case hidProx = 200
    case ioProx = 201
    case idteck = 310
    case mifareMini = 1000
    case mifare1K = 1001
    case mifare2K = 1002
    case mifare4K = 1003
    case ntag210 = 1107
    case ntag212 = 1108
    case ntag213 = 1100
    case ntag215 = 1101
    case ntag216 = 1102
    case ultralight = 1103
    case ultralightC = 1104
    case ultralight11 = 1105
    case ultralight21 = 1106
    case hf14a4 = 3000

    var id: UInt16 { rawValue }

    var displayName: String {
        switch self {
        case .mifareMini: return "Mifare Mini"
        case .mifare1K: return "Mifare Classic 1K"
        case .mifare2K: return "Mifare Classic 2K"
        case .mifare4K: return "Mifare Classic 4K"
        case .em410X: return "EM410X"
        case .em410X16: return "EM410X (16)"
        case .em410X32: return "EM410X (32)"
        case .em410X64: return "EM410X (64)"
        case .em410XElectra: return "EM410X Electra"
        case .hidProx: return "HID Prox"
        case .viking: return "Viking"
        case .pac: return "PAC/Stanley"
        case .ioProx: return "ioProx"
        case .idteck: return "IDTECK"
        case .ntag210: return "NTAG210"
        case .ntag212: return "NTAG212"
        case .ntag213: return "NTAG213"
        case .ntag215: return "NTAG215"
        case .ntag216: return "NTAG216"
        case .ultralight: return "Ultralight"
        case .ultralightC: return "Ultralight C"
        case .ultralight11: return "Ultralight EV1 (20)"
        case .ultralight21: return "Ultralight EV1 (41)"
        case .hf14a4: return "ISO14443-4 (T=CL)"
        case .unknown: return "Unknown"
        }
    }

    var frequency: TagFrequency {
        TagType.lfTypes.contains(self) ? .lf : .hf
    }

    static let hfTypes: [TagType] = [.mifare1K, .mifare2K, .mifare4K, .mifareMini,
                                     .ntag210, .ntag212, .ntag213, .ntag215, .ntag216,
                                     .ultralight, .ultralightC, .ultralight11, .ultralight21,
                                     .hf14a4]
    static let lfTypes: [TagType] = [.em410X, .em410X16, .em410X32, .em410X64, .em410XElectra,
                                     .hidProx, .viking, .pac, .ioProx, .idteck]

    var isMifareClassic: Bool {
        [.mifareMini, .mifare1K, .mifare2K, .mifare4K].contains(self)
    }

    var isEM410X: Bool {
        [.em410X, .em410X16, .em410X32, .em410X64, .em410XElectra].contains(self)
    }

    var lfUIDSize: Int {
        switch self {
        case .em410XElectra: return 13
        case .em410X, .em410X16, .em410X32, .em410X64, .hidProx: return 5
        case .viking: return 4
        case .pac, .idteck: return 8
        case .ioProx: return 16
        default: return 0
        }
    }

    var blockCount: Int {
        switch self {
        case .mifareMini: return 20
        case .mifare1K: return 64
        case .mifare2K: return 128
        case .mifare4K: return 256
        case .ultralight, .ultralightC, .ntag210: return 16
        case .ultralight11, .ultralight21: return 20
        case .ntag212: return 41
        case .ntag213: return 45
        case .ntag215: return 135
        case .ntag216: return 231
        default: return 64
        }
    }
}

enum TagFrequency: UInt8, Codable {
    case unknown = 0
    case lf = 1
    case hf = 2
}

enum AnimationSetting: UInt8, CaseIterable, Identifiable {
    case full = 0, minimal = 1, none = 2, symmetric = 3
    var id: UInt8 { rawValue }
    var displayName: String {
        switch self {
        case .full: return "Full"
        case .minimal: return "Minimal"
        case .none: return "None"
        case .symmetric: return "Symmetric"
        }
    }
}

enum MifareWriteMode: UInt8, CaseIterable, Identifiable {
    case normal = 0, denied = 1, deceive = 2, shadow = 3
    var id: UInt8 { rawValue }
    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .denied: return "Denied"
        case .deceive: return "Deceive"
        case .shadow: return "Shadow"
        }
    }
}

enum ButtonType: UInt8 {
    case a = 65
    case b = 66
}

enum ButtonConfig: UInt8, CaseIterable, Identifiable {
    case disable = 0, cycleForward = 1, cycleBackward = 2, cloneUID = 3, chargeStatus = 4
    var id: UInt8 { rawValue }
    var displayName: String {
        switch self {
        case .disable: return "Disable"
        case .cycleForward: return "Cycle slot forward"
        case .cycleBackward: return "Cycle slot backward"
        case .cloneUID: return "Clone UID"
        case .chargeStatus: return "Charge status"
        }
    }

    static func fromValue(_ value: UInt8) -> ButtonConfig {
        ButtonConfig.allCases.first { $0.rawValue == value } ?? .disable
    }
}

enum NTLevel: String {
    case statik = "static", weak, hard, backdoor, unknown
}

enum MifareClassicType: String {
    case none, mini, m1k, m2k, m4k

    var displayName: String {
        switch self {
        case .mini: return "Mini"
        case .m1k: return "1K"
        case .m2k: return "2K"
        case .m4k: return "4K"
        default: return "Unknown"
        }
    }

    var sectorCount: Int {
        switch self {
        case .m1k: return 16
        case .m2k: return 32
        case .m4k: return 40
        case .mini: return 5
        case .none: return 0
        }
    }

    var blockCount: Int {
        switch self {
        case .m1k: return 64
        case .m2k: return 128
        case .m4k: return 256
        case .mini: return 20
        case .none: return 0
        }
    }

    var chameleonTagType: TagType {
        switch self {
        case .m1k: return .mifare1K
        case .m2k: return .mifare2K
        case .m4k: return .mifare4K
        case .mini: return .mifareMini
        case .none: return .unknown
        }
    }

    static func from(tagType: TagType) -> MifareClassicType {
        switch tagType {
        case .mifare1K: return .m1k
        case .mifare2K: return .m2k
        case .mifare4K: return .m4k
        case .mifareMini: return .mini
        default: return .none
        }
    }
}

enum ChameleonDevice: String {
    case ultra, lite

    var displayName: String { self == .ultra ? "Ultra" : "Lite" }

    /// Emulated card slots the device exposes: Ultra has 8, Lite 2.
    var slotCount: Int { self == .ultra ? 8 : 2 }
}

// MARK: - Message structs

struct ChameleonMessage {
    let command: UInt16
    let status: UInt16
    let data: Data
}

struct CardData {
    var uid: Data
    var sak: UInt8
    var atqa: Data   // 2 bytes, already byte-swapped to display order by parser
    var ats: Data
}

struct FirmwareVersion {
    var legacyProtocol: Bool
    var version: Int
}

struct SlotTypes {
    var hf: TagType = .unknown
    var lf: TagType = .unknown
}

struct EnabledSlotInfo {
    var hf: Bool = false
    var lf: Bool = false
    var any: Bool { hf || lf }
}

struct SlotNames {
    var hf: String = ""
    var lf: String = ""
}

struct BatteryCharge {
    var voltage: Int
    var percent: Int
}

struct EmulatorSettings {
    var isDetectionEnabled: Bool
    var isGen1a: Bool
    var isGen2: Bool
    var isAntiColl: Bool
    var writeMode: MifareWriteMode
}

struct DeviceSettings {
    var animation: AnimationSetting = .none
    var aPress: ButtonConfig = .disable
    var bPress: ButtonConfig = .disable
    var aLongPress: ButtonConfig = .disable
    var bLongPress: ButtonConfig = .disable
    var pairingEnabled: Bool = false
    var key: String = ""
    var wakeTimeSeconds: Int? = nil
}


// MARK: - LF cards

protocol LFCard {
    var type: TagType { get }
    var uid: Data { get }
}

struct EM410XCard: LFCard {
    var type: TagType = .em410X
    var uid: Data

    static func fromBytes(_ bytes: Data) -> EM410XCard {
        if bytes.isEmpty { return EM410XCard(uid: Data()) }
        if bytes.count == 5 { return EM410XCard(type: .em410X, uid: bytes) }
        if bytes.count == 13 { return EM410XCard(type: .em410XElectra, uid: bytes) }
        var type = TagType.em410X
        var uid = bytes
        if bytes.count >= 2 {
            let raw = UInt16(bytes[bytes.startIndex]) << 8 | UInt16(bytes[bytes.startIndex + 1])
            type = TagType(rawValue: raw) ?? .em410X
            let uidLength = type.lfUIDSize
            if uidLength > 0 && bytes.count >= uidLength + 2 {
                uid = bytes.subdata(in: (bytes.startIndex + 2)..<(bytes.startIndex + 2 + uidLength))
            } else {
                uid = bytes.prefix(5)
                type = .em410X
            }
        }
        return EM410XCard(type: type, uid: uid)
    }
}

struct HIDCard: LFCard {
    var type: TagType = .hidProx
    var uid: Data
    var hidType: UInt8
    var facilityCode: UInt32
    var issueLevel: UInt8
    var oem: UInt16

    static func fromBytes(_ bytes: Data) -> HIDCard {
        guard bytes.count >= 13 else { return HIDCard(uid: bytes, hidType: 0, facilityCode: 0, issueLevel: 0, oem: 0) }
        let i = bytes.startIndex
        return HIDCard(uid: bytes.subdata(in: (i + 5)..<(i + 10)),
                       hidType: bytes[i],
                       facilityCode: bytes.readU32(at: i + 1),
                       issueLevel: bytes[i + 10],
                       oem: UInt16(bytes[i + 11]) << 8 | UInt16(bytes[i + 12]))
    }

    var viewableString: String {
        guard uid.count == 5 else { return uid.hexSpaced }
        let cnHigh = UInt64(uid[uid.startIndex])
        let cnLow = (UInt64(uid[uid.startIndex + 1]) << 24) | (UInt64(uid[uid.startIndex + 2]) << 16)
            | (UInt64(uid[uid.startIndex + 3]) << 8) | UInt64(uid[uid.startIndex + 4])
        let uidNumber = (cnHigh << 32) | cnLow
        var out = "\(uidNumber) (\(uid.hexSpaced)"
        if hidType >= 1 && hidType <= 30 { out += ", \(hidTypeName)" }
        if facilityCode != 0 { out += ", FC: \(facilityCode)" }
        if issueLevel != 0 { out += ", IL: \(issueLevel)" }
        if oem != 0 { out += ", OEM: \(oem)" }
        out += ")"
        return out
    }

    var hidTypeName: String {
        let names = ["HID H10301 26-bit", "Indala 26-bit", "Indala 27-bit", "Indala ASC 27-bit",
                     "Tecom 27-bit", "2804 Wiegand 28-bit", "Indala 29-bit", "ATS Wiegand 30-bit",
                     "HID ADT 31-bit", "HID Check Point 32-bit", "HID Hewlett-Packard 32-bit",
                     "Kastle 32-bit", "Indala/Kantech KFS 32-bit", "Wiegand 32-bit",
                     "HID D10202 33-bit", "HID H10306 34-bit", "Honeywell/Northern N10002 34-bit",
                     "Indala Optus 34-bit", "Cardkey Smartpass 34-bit", "BQT 34-bit",
                     "HID Corporate 1000 35-bit Std", "HID KeyScan 36-bit", "HID Simplex 36-bit",
                     "HID 36-bit Siemens", "HID H10320 37-bit BCD", "HID H10302 37-bit huge ID",
                     "HID H10304 37-bit", "HID P10004 37-bit PCSC", "HID Generic 37-bit",
                     "PointGuard MDI 37-bit"]
        let idx = Int(hidType) - 1
        guard idx >= 0 && idx < names.count else { return "type \(hidType)" }
        return names[idx]
    }
}

struct GenericLFCard: LFCard {
    var type: TagType
    var uid: Data
}
