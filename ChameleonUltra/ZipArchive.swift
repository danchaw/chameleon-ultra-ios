import Foundation
import Compression

/// Minimal ZIP reader (stored + deflate) for unpacking firmware packages
/// (`application.dat` + `application.bin`) without third-party dependencies.
enum ZipArchive {

    struct Entry {
        let name: String
        let data: Data
        /// central-directory CRC32 matches the decompressed content
        let crcValid: Bool
    }

    enum ZipError: LocalizedError {
        case badArchive(String)
        var errorDescription: String? {
            if case .badArchive(let why) = self { return "Bad zip archive: \(why)" }
            return nil
        }
    }

    static func extract(_ archive: Data) throws -> [Entry] {
        // locate End Of Central Directory record
        guard archive.count >= 22 else { throw ZipError.badArchive("too small") }
        var eocdOffset = -1
        let lowerBound = max(0, archive.count - 22 - 65536)
        var i = archive.count - 22
        while i >= lowerBound {
            if archive[i] == 0x50, archive[i + 1] == 0x4B, archive[i + 2] == 0x05, archive[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.badArchive("EOCD not found") }

        func u16(_ o: Int) -> Int { Int(archive[o]) | Int(archive[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        let entryCount = u16(eocdOffset + 10)
        var cdOffset = u32(eocdOffset + 16)
        var entries: [Entry] = []

        for _ in 0..<entryCount {
            guard cdOffset + 46 <= archive.count,
                  archive[cdOffset] == 0x50, archive[cdOffset + 1] == 0x4B,
                  archive[cdOffset + 2] == 0x01, archive[cdOffset + 3] == 0x02 else { break }

            let method = u16(cdOffset + 10)
            let storedCrc = UInt32(u32(cdOffset + 16))
            let compressedSize = u32(cdOffset + 20)
            let uncompressedSize = u32(cdOffset + 24)
            let nameLength = u16(cdOffset + 28)
            let extraLength = u16(cdOffset + 30)
            let commentLength = u16(cdOffset + 32)
            let localOffset = u32(cdOffset + 42)

            let nameStart = cdOffset + 46
            guard nameStart + nameLength <= archive.count else { break }
            let name = String(data: archive[nameStart..<(nameStart + nameLength)], encoding: .utf8) ?? ""

            // local file header: skip its own name/extra lengths
            guard localOffset + 30 <= archive.count,
                  archive[localOffset] == 0x50, archive[localOffset + 1] == 0x4B,
                  archive[localOffset + 2] == 0x03, archive[localOffset + 3] == 0x04 else {
                cdOffset += 46 + nameLength + extraLength + commentLength
                continue
            }
            let localNameLength = u16(localOffset + 26)
            let localExtraLength = u16(localOffset + 28)
            let dataStart = localOffset + 30 + localNameLength + localExtraLength

            if name.hasSuffix("/") {
                // directory entry
            } else if dataStart + compressedSize <= archive.count {
                let rawData = archive[dataStart..<dataStart + compressedSize]
                var content = Data()
                switch method {
                case 0:
                    content = rawData
                case 8:
                    content = inflate(rawData, expectedSize: uncompressedSize)
                default:
                    break
                }
                let computedCrc = content.isEmpty ? 0 : CRC32.update(0, with: content)
                entries.append(Entry(name: name, data: content, crcValid: computedCrc == storedCrc))
            }

            cdOffset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data {
        guard !data.isEmpty else { return Data() }
        let dstCapacity = max(expectedSize, data.count * 8)
        var dst = Data(count: dstCapacity)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                guard let src = srcPtr.bindMemory(to: UInt8.self).baseAddress,
                      let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, dstCapacity, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? dst.prefix(written) : Data()
    }
}
