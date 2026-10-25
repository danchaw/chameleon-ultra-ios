import Foundation

/// Chameleon data-frame codec + streaming parser.
/// Frame layout (big endian):
/// `SOF(11 EF) cmd(2) status(2) length(2) headLRC data... fullLRC`
/// Ported from `ChameleonCommunicator` in the original Dart bridge.
struct ChameleonFrameParser {

    private var buffer: [UInt8] = []
    private var position = 0
    private var cmd: UInt16 = 0
    private var status: UInt16 = 0
    private var length = 0

    static let sof: UInt8 = 0x11
    static let maxDataLength = 4096

    static func lrcCalc(_ array: [UInt8]) -> UInt8 {
        var ret: UInt8 = 0
        for b in array {
            ret = (ret &+ b) & 0xFF
        }
        return UInt8((0x100 - Int(ret)) & 0xFF)
    }

    static func lrcCalc(_ array: [UInt8], range: Range<Int>) -> UInt8 {
        var ret: UInt8 = 0
        for i in range {
            ret = (ret &+ array[i]) & 0xFF
        }
        return UInt8((0x100 - Int(ret)) & 0xFF)
    }

    static func makeFrame(cmd: ChameleonCommand, status: UInt16 = 0, data: Data? = nil) -> Data {
        var frame: [UInt8] = [sof]
        frame.append(lrcCalc([sof]))
        frame.append(contentsOf: cmd.rawValue.bytesBE)
        frame.append(contentsOf: status.bytesBE)
        frame.append(contentsOf: UInt16(data?.count ?? 0).bytesBE)
        frame.append(lrcCalc(frame, range: 2..<8))
        if let data {
            frame.append(contentsOf: data)
        }
        frame.append(lrcCalc(frame))
        return Data(frame)
    }

    /// Feed received bytes; returns every complete frame found.
    mutating func feed(_ bytes: [UInt8]) -> [ChameleonMessage] {
        var messages: [ChameleonMessage] = []
        for byte in bytes {
            buffer.append(byte)

            if position < 2 {
                if position == 0 {
                    if buffer[0] != Self.sof { reset(); continue }
                } else {
                    if buffer[1] != Self.lrcCalc([buffer[0]]) { reset(); continue }
                }
            } else if position == 8 {
                if buffer[8] != Self.lrcCalc(buffer, range: 0..<8) {
                    reset()
                    continue
                }
                cmd = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
                status = UInt16(buffer[4]) << 8 | UInt16(buffer[5])
                length = Int(UInt16(buffer[6]) << 8 | UInt16(buffer[7]))
                if length > Self.maxDataLength { reset(); continue }
            } else if position == 8 + length + 1 {
                let fullLrc = buffer[buffer.count - 1]
                let expected = Self.lrcCalc(Array(buffer[0..<(buffer.count - 1)]))
                if fullLrc == expected {
                    let payload = buffer.count >= 9 + length ? Data(buffer[9..<(9 + length)]) : Data()
                    messages.append(ChameleonMessage(command: cmd, status: status, data: payload))
                }
                reset()
                continue
            }

            position += 1
        }
        return messages
    }

    private mutating func reset() {
        buffer = []
        position = 0
    }
}
