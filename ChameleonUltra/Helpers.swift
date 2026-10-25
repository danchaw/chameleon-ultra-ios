import Foundation

// MARK: - Hex helpers (port of helpers/general.dart byte utilities)

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    var hexSpaced: String { map { String(format: "%02X", $0) }.joined(separator: " ") }

    init(hex string: String) {
        let clean = string.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "")
        var data = Data()
        data.reserveCapacity(clean.count / 2)
        var iterator = clean.makeIterator()
        var high: UInt8? = nil
        while let ch = iterator.next() {
            guard let digit = ch.hexDigitValue else {
                high = nil
                continue
            }
            if let h = high {
                data.append(h << 4 | UInt8(digit))
                high = nil
            } else {
                high = UInt8(digit)
            }
        }
        self = data
    }

    func readU16(at index: Int) -> UInt16 {
        UInt16(self[startIndex + index]) << 8 | UInt16(self[startIndex + index + 1])
    }

    func readU32(at index: Int) -> UInt32 {
        UInt32(self[startIndex + index]) << 24 | UInt32(self[startIndex + index + 1]) << 16
            | UInt32(self[startIndex + index + 2]) << 8 | UInt32(self[startIndex + index + 3])
    }

    var isValidHex: Bool {
        allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

func hexToData(_ hex: String) -> Data { Data(hex: hex) }

extension UInt16 {
    var bytesBE: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}

extension UInt32 {
    var bytesBE: [UInt8] {
        [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}

func numToVersionCode(_ versionCode: Int) -> String {
    let major = (versionCode >> 8) & 0xFF
    let minor = versionCode & 0xFF
    return "\(major).\(minor)"
}

func calculateBCC(_ data: Data) -> UInt8 {
    data.reduce(0) { $0 ^ $1 }
}

// MARK: - CRC32 (zlib style, used by Nordic DFU)

enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }()

    /// Incremental CRC32 with the semantics of the original Dart
    /// `calculateCRC32(bytes, crc)`: cumulative across chunks.
    static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        var c = ~crc
        for byte in data {
            c = (c >> 8) ^ table[Int((c ^ UInt32(byte)) & 0xFF)]
        }
        return ~c
    }
}
