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
            case 1:
                actual = Data(Insecure.SHA1.hash(data: bin))
                report.hashTypeName = "SHA-1"
            case 2:
                actual = Data(SHA256.hash(data: bin))
                report.hashTypeName = "SHA-256"
            case 3:
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

    struct InitPacket {
        var signed: Bool
        var fwVersion: UInt32
        var deviceType: UInt32
        var appSize: UInt32
        var hash: [UInt8]
        var hashType: Int
    }

    /// Packet { Command command = 1; SignedCommand signed_command = 2; }
    /// SignedCommand { bytes signature = 1; Command command = 2; }
    /// Command { Init init = 1; ... }
    /// Init { uint32 fw_version = 1; device_type = 2; sd_size = 3; bl_size = 4;
    ///        uint32 app_size = 5; Hash hash = 8; }
    /// Hash { bytes hash = 1; HashType hash_type = 2; }
    static func parseInitPacket(_ dat: Data) throws -> InitPacket {
        let packetBytes = [UInt8](dat)
        var topLevel = PBReader(bytes: packetBytes)
        var commandBytes: [UInt8]? = nil
        var signed = false

        while let (field, wireType) = try topLevel.readFieldHeader() {
            switch (field, wireType) {
            case (1, 2):
                commandBytes = try Array(topLevel.readLengthDelimited())
            case (2, 2):
                let signedBytes = try Array(topLevel.readLengthDelimited())
                signed = true
                // SignedCommand.command is field 2
                var signedReader = PBReader(bytes: signedBytes)
                var innerCommand: [UInt8]? = nil
                while let (f, w) = try signedReader.readFieldHeader() {
                    if f == 2 && w == 2 {
                        innerCommand = try Array(signedReader.readLengthDelimited())
                    } else {
                        try signedReader.skip(wireType: w)
                    }
                }
                if let innerCommand { commandBytes = innerCommand }
            default:
                try topLevel.skip(wireType: wireType)
            }
        }

        guard signed else { throw FirmwareValidationError.notSigned }
        guard var commandBytes else { throw FirmwareValidationError.notSigned }

        // Command.init is field 1
        var commandReader = PBReader(bytes: commandBytes)
        var initBytes: [UInt8]? = nil
        while let (f, w) = try commandReader.readFieldHeader() {
            if f == 1 && w == 2 {
                initBytes = try Array(commandReader.readLengthDelimited())
            } else {
                try commandReader.skip(wireType: w)
            }
        }
        commandBytes = []
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
            case (5, 0): appSize = UInt32(try initReader.readVarint())
            case (8, 2):
                let hashBytes = try Array(initReader.readLengthDelimited())
                var hashReader = PBReader(bytes: hashBytes)
                while let (hf, hw) = try hashReader.readFieldHeader() {
                    if hf == 1 && hw == 2 {
                        hash = try Array(hashReader.readLengthDelimited())
                    } else if hf == 2 && hw == 0 {
                        hashType = Int(try hashReader.readVarint())
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
