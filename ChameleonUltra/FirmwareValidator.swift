import Foundation
import CryptoKit

enum FirmwareValidationError: LocalizedError {
    case badProtobuf(String)
    case notSigned
    case noInit
    case unsupportedHash(Int)

    var errorDescription: String? {
        switch self {
        case .badProtobuf(let why): return "malformed init packet (\(why))"
        case .notSigned: return "package isn't signed"
        case .noInit: return "package command doesn't have init"
        case .unsupportedHash(let type): return "unsupported hash type \(type)"
        }
    }
}

/// Result of validating a firmware zip before flashing.
struct FirmwareValidationReport: Identifiable {
    let id = UUID()
    var sourceName = ""
    var zipBytes = 0
    var entriesFound: [String] = []
    var zipCrcValid = true
    /// SHA-256 of the whole zip compared against the GitHub asset digest (online download only).
    var downloadDigestValid: Bool? = nil
    var hasApplicationDat = false
    var hasApplicationBin = false
    var signedPackage = false
    var hashTypeName = ""
    var firmwareHashMatches = false
    var fwVersion: UInt32? = nil
    var declaredAppSize: UInt32? = nil
    var actualBinSize = 0
    var fatal: String? = nil

    var sizeMatches: Bool? {
        declaredAppSize.map { Int($0) == actualBinSize }
    }

    var isValid: Bool {
        fatal == nil
            && zipCrcValid
            && (downloadDigestValid ?? true)
            && hasApplicationDat
            && hasApplicationBin
            && signedPackage
            && firmwareHashMatches
            && (sizeMatches ?? true)
    }
}

/// Validates firmware packages the same way the original app does
/// (`validateFiles` in `helpers/flash.dart`), plus zip CRC and download
/// digest checks:
///  * zip archive parses, every entry's CRC32 matches
///  * (online) SHA-256 of the zip equals the GitHub asset digest
///  * contains application.dat (Nordic dfu-cc init packet) + application.bin
///  * init packet is signed and carries an init command
///  * byte-reversed hash in the manifest equals SHA-1/256/512 of the .bin
///  * declared app size matches the actual .bin size
enum FirmwareValidator {

    static func validate(zip: Data, expectedDigestSHA256: String? = nil,
                         sourceName: String = "") -> FirmwareValidationReport {
        var report = FirmwareValidationReport()
        report.sourceName = sourceName
        report.zipBytes = zip.count

        if let expected = expectedDigestSHA256 {
            let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
            report.downloadDigestValid = actual.lowercased() == expected.lowercased()
        }

        let entries: [ZipArchive.Entry]
        do {
            entries = try ZipArchive.extract(zip)
        } catch {
            report.fatal = "Bad zip archive: \(error.localizedDescription)"
            return report
        }

        report.entriesFound = entries.map { entry in
            let mark = entry.crcValid ? "" : " (CRC failed)"
            return entry.name + mark
        }
        report.zipCrcValid = entries.allSatisfy(\.crcValid)

        guard let dat = entries.first(where: { $0.name == "application.dat" })?.data,
              let bin = entries.first(where: { $0.name == "application.bin" })?.data else {
            report.hasApplicationDat = entries.contains { $0.name == "application.dat" }
            report.hasApplicationBin = entries.contains { $0.name == "application.bin" }
            report.fatal = "application.dat / application.bin missing"
            return report
        }
        report.hasApplicationDat = true
        report.hasApplicationBin = true
        report.actualBinSize = bin.count

        do {
            let packet = try parseInitPacket(dat)
            report.signedPackage = packet.signed
            report.fwVersion = packet.fwVersion
            report.declaredAppSize = packet.appSize

            let expectedReversed = Data(packet.hash.reversed())
            let actual: Data
            switch packet.hashType {
            case 2:
                actual = Data(Insecure.SHA1.hash(data: bin))
                report.hashTypeName = "SHA-1"
            case 3:
                actual = Data(SHA256.hash(data: bin))
                report.hashTypeName = "SHA-256"
            case 4:
                actual = Data(SHA512.hash(data: bin))
                report.hashTypeName = "SHA-512"
            default:
                throw FirmwareValidationError.unsupportedHash(packet.hashType)
            }
            report.firmwareHashMatches = expectedReversed == actual
        } catch {
            report.fatal = "Invalid firmware format: \(error.localizedDescription)"
        }
        return report
    }

    // MARK: - Minimal protobuf (dfu-cc) parsing
    //
    // Field numbers verified against the original app's generated
    // `dfu-cc.pb.dart` and a real release package:
    //   Packet        { Command command = 1; SignedCommand signed_command = 2; }
    //   SignedCommand { Command command = 1; SignatureType type = 2; bytes signature = 3; }
    //   Command       { OpCode op_code = 1; InitCommand init = 2; ResetCommand reset = 3; }
    //   InitCommand   { uint32 fw_version = 1; hw_version = 2; sd_req = 3; type = 4;
    //                   sd_size = 5; bl_size = 6; uint32 app_size = 7; Hash hash = 8; }
    //   Hash          { HashType hash_type = 1; bytes hash = 2; }
    //   HashType: 0 none, 1 CRC, 2 SHA128(SHA-1), 3 SHA256, 4 SHA512

    struct InitPacket {
        var signed: Bool
        var fwVersion: UInt32
        var deviceType: UInt32
        var appSize: UInt32
        var hash: [UInt8]
        var hashType: Int
    }

    static func parseInitPacket(_ dat: Data) throws -> InitPacket {
        let packetBytes = [UInt8](dat)
        var topLevel = PBReader(bytes: packetBytes)
        var commandBytes: [UInt8]? = nil
        var signed = false

        while let (field, wireType) = try topLevel.readFieldHeader() {
            switch (field, wireType) {
            case (1, 2):
                // unsigned Command (still parsed as a fallback)
                commandBytes = try Array(topLevel.readLengthDelimited())
            case (2, 2):
                let signedBytes = try Array(topLevel.readLengthDelimited())
                signed = true
                var signedReader = PBReader(bytes: signedBytes)
                while let (f, w) = try signedReader.readFieldHeader() {
                    if f == 1 && w == 2 {
                        commandBytes = try Array(signedReader.readLengthDelimited())
                    } else {
                        try signedReader.skip(wireType: w)
                    }
                }
            default:
                try topLevel.skip(wireType: wireType)
            }
        }

        guard signed else { throw FirmwareValidationError.notSigned }
        guard let commandBytes else { throw FirmwareValidationError.notSigned }

        // Command.init is field 2
        var commandReader = PBReader(bytes: commandBytes)
        var initBytes: [UInt8]? = nil
        while let (f, w) = try commandReader.readFieldHeader() {
            if f == 2 && w == 2 {
                initBytes = try Array(commandReader.readLengthDelimited())
            } else {
                try commandReader.skip(wireType: w)
            }
        }
        guard let initBytes else { throw FirmwareValidationError.noInit }

        var fwVersion: UInt32 = 0
        var deviceType: UInt32 = 0
        var appSize: UInt32 = 0
        var hash: [UInt8] = []
        var hashType = 0

        var initReader = PBReader(bytes: initBytes)
        while let (f, w) = try initReader.readFieldHeader() {
            switch (f, w) {
            case (1, 0): fwVersion = UInt32(try initReader.readVarint())
            case (2, 0): deviceType = UInt32(try initReader.readVarint())
            case (7, 0): appSize = UInt32(try initReader.readVarint())
            case (8, 2):
                let hashBytes = try Array(initReader.readLengthDelimited())
                var hashReader = PBReader(bytes: hashBytes)
                while let (hf, hw) = try hashReader.readFieldHeader() {
                    if hf == 1 && hw == 0 {
                        hashType = Int(try hashReader.readVarint())
                    } else if hf == 2 && hw == 2 {
                        hash = try Array(hashReader.readLengthDelimited())
                    } else {
                        try hashReader.skip(wireType: hw)
                    }
                }
            default:
                try initReader.skip(wireType: w)
            }
        }

        return InitPacket(signed: signed, fwVersion: fwVersion, deviceType: deviceType,
                          appSize: appSize, hash: hash, hashType: hashType)
    }
}

/// Minimal protobuf wire-format reader.
private struct PBReader {
    let bytes: [UInt8]
    var index = 0

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift = 0
        while true {
            guard index < bytes.count else {
                throw FirmwareValidationError.badProtobuf("truncated varint")
            }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw FirmwareValidationError.badProtobuf("varint too long") }
        }
    }

    mutating func readFieldHeader() throws -> (field: Int, wireType: Int)? {
        guard index < bytes.count else { return nil }
        let key = try readVarint()
        return (Int(key >> 3), Int(key & 0x7))
    }

    mutating func readLengthDelimited() throws -> ArraySlice<UInt8> {
        let length = Int(try readVarint())
        guard length >= 0, index + length <= bytes.count else {
            throw FirmwareValidationError.badProtobuf("length out of bounds")
        }
        defer { index += length }
        return bytes[index..<(index + length)]
    }

    mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0: _ = try readVarint()
        case 1: index = min(index + 8, bytes.count)
        case 2: let length = Int(try readVarint()); index = min(index + length, bytes.count)
        case 5: index = min(index + 4, bytes.count)
        default: throw FirmwareValidationError.badProtobuf("unsupported wire type \(wireType)")
        }
    }
}
