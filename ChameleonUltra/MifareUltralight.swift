import Foundation

/// Mifare Ultralight / NTAG helpers ported from `helpers/mifare_ultralight/general.dart`.
enum MifareUltralight {

    static func type(via communicator: ChameleonCommunicator) async throws -> TagType {
        var options = ChameleonCommunicator.Raw14AOptions()
        options.checkResponseCrc = false
        options.respTimeoutMs = 100

        if try await communicator.send14ARaw(Data([0x30, 15]), options: options).isEmpty {
            return .unknown
        }
        if try await communicator.send14ARaw(Data([0x30, 230]), options: options).count != 1 { return .ntag216 }
        if try await communicator.send14ARaw(Data([0x30, 134]), options: options).count != 1 { return .ntag215 }
        if try await communicator.send14ARaw(Data([0x30, 44]), options: options).count != 1 { return .ntag213 }
        if try await communicator.send14ARaw(Data([0x30, 40]), options: options).count != 1 { return .ntag212 }
        if try await communicator.send14ARaw(Data([0x30, 19]), options: options).count != 1 { return .ntag210 }
        return .ultralight
    }

    static func getVersion(via communicator: ChameleonCommunicator) async throws -> Data {
        var options = ChameleonCommunicator.Raw14AOptions()
        options.checkResponseCrc = true
        return try await communicator.send14ARaw(Data([0x60]), options: options)
    }

    static func isUlc(via communicator: ChameleonCommunicator) async -> Bool {
        guard let resp = try? await communicator.send14ARaw(Data([0x1A, 0x00])) else { return false }
        return resp.count >= 9 && resp.first == 0xAF
    }

    /// Read the full dump: returns 4-byte pages.
    static func readDump(via communicator: ChameleonCommunicator, type: TagType) async throws -> [[UInt8]] {
        var options = ChameleonCommunicator.Raw14AOptions()
        options.checkResponseCrc = false
        options.respTimeoutMs = 100

        let pageCount = type.blockCount
        var pages: [[UInt8]] = []
        var page = 0
        while page < pageCount {
            let resp = try await communicator.send14ARaw(Data([0x30, UInt8(page)]), options: options)
            guard resp.count == 16 else { break }
            for i in 0..<4 {
                let start = resp.startIndex + i * 4
                pages.append(Array(resp[start..<start + 4]))
            }
            page += 4
        }
        // trim to exact page count (last read always returns 4 pages)
        if pages.count > pageCount {
            pages = Array(pages[0..<pageCount])
        }
        return pages
    }

    /// WRITE page command (0xA2) – standard for UL EV1 / NTAG.
    @discardableResult
    static func writePage(via communicator: ChameleonCommunicator, page: Int, data: Data) async throws -> Bool {
        var options = ChameleonCommunicator.Raw14AOptions()
        options.appendCrc = true
        options.respTimeoutMs = 200
        guard data.count == 4 else { return false }
        let resp = try await communicator.send14ARaw(Data([0xA2, UInt8(page)]) + data, options: options)
        return !resp.isEmpty && resp.first == 0x0A
    }

    /// Build the first 3 pages (12 bytes) from a 7-byte UID.
    static func firstPages(uid: Data) -> [[UInt8]] {
        guard uid.count == 7 else { return [] }
        let bcc1 = 0x88 ^ uid[uid.startIndex] ^ uid[uid.startIndex + 1] ^ uid[uid.startIndex + 2]
        let bcc2 = uid[uid.startIndex + 3] ^ uid[uid.startIndex + 4] ^ uid[uid.startIndex + 5] ^ uid[uid.startIndex + 6]
        return [
            [uid[uid.startIndex], uid[uid.startIndex + 1], uid[uid.startIndex + 2], bcc1],
            [uid[uid.startIndex + 3], uid[uid.startIndex + 4], uid[uid.startIndex + 5], uid[uid.startIndex + 6]],
            [bcc2, 0x48, 0x00, 0x00],
        ]
    }
}
