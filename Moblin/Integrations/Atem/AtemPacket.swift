import Foundation

// ATEM control protocol — UDP port 9910.
//
// Packet layout:
//   12-byte header:
//     [0..1]  bits 0..4 = flags (5 bits), bits 5..15 = length (11 bits, includes header)
//     [2..3]  session id (UInt16 BE)
//     [4..5]  acknowledged packet id  (when this packet ACKs another)
//     [6..7]  unused
//     [8..9]  retransmit packet id     (when flag .resend or .requestNextAfter)
//     [10..11] this packet id          (when flag .ackRequest)
//   Variable payload — zero or more commands.
//
// Each command:
//     [0..1]  command length (UInt16 BE), includes the 8-byte command header
//     [2..3]  zero
//     [4..7]  4-char ASCII opcode
//     [8...]  command-specific payload

let atemUdpPort: UInt16 = 9910

struct AtemPacketFlags: OptionSet {
    let rawValue: UInt8
    static let ackRequest = AtemPacketFlags(rawValue: 1 << 0)
    static let helloPacket = AtemPacketFlags(rawValue: 1 << 1)
    static let resend = AtemPacketFlags(rawValue: 1 << 2)
    static let requestNextAfter = AtemPacketFlags(rawValue: 1 << 3)
    static let ack = AtemPacketFlags(rawValue: 1 << 4)
}

struct AtemPacket {
    var flags: AtemPacketFlags
    var sessionId: UInt16
    var ackPacketId: UInt16
    var retransmitPacketId: UInt16
    var packetId: UInt16
    var payload: Data

    init(flags: AtemPacketFlags = [],
         sessionId: UInt16 = 0,
         ackPacketId: UInt16 = 0,
         retransmitPacketId: UInt16 = 0,
         packetId: UInt16 = 0,
         payload: Data = Data())
    {
        self.flags = flags
        self.sessionId = sessionId
        self.ackPacketId = ackPacketId
        self.retransmitPacketId = retransmitPacketId
        self.packetId = packetId
        self.payload = payload
    }

    func serialize() -> Data {
        let totalLength = UInt16(12 + payload.count)
        var data = Data(count: 12)
        // bits 5..15 = length, bits 0..4 = flags
        let header = (UInt16(flags.rawValue) << 11) | (totalLength & 0x07FF)
        data[0] = UInt8(header >> 8)
        data[1] = UInt8(header & 0xFF)
        data[2] = UInt8(sessionId >> 8)
        data[3] = UInt8(sessionId & 0xFF)
        data[4] = UInt8(ackPacketId >> 8)
        data[5] = UInt8(ackPacketId & 0xFF)
        data[6] = 0
        data[7] = 0
        data[8] = UInt8(retransmitPacketId >> 8)
        data[9] = UInt8(retransmitPacketId & 0xFF)
        data[10] = UInt8(packetId >> 8)
        data[11] = UInt8(packetId & 0xFF)
        data.append(payload)
        return data
    }

    static func parse(_ data: Data) -> AtemPacket? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data)
        let header = (UInt16(b[0]) << 8) | UInt16(b[1])
        let length = Int(header & 0x07FF)
        let rawFlags = UInt8(header >> 11)
        guard length >= 12, length <= data.count else { return nil }
        return AtemPacket(
            flags: AtemPacketFlags(rawValue: rawFlags),
            sessionId: (UInt16(b[2]) << 8) | UInt16(b[3]),
            ackPacketId: (UInt16(b[4]) << 8) | UInt16(b[5]),
            retransmitPacketId: (UInt16(b[8]) << 8) | UInt16(b[9]),
            packetId: (UInt16(b[10]) << 8) | UInt16(b[11]),
            payload: data.subdata(in: 12 ..< length)
        )
    }
}

struct AtemCommand {
    var opcode: String // 4 ASCII chars
    var payload: Data

    func serialize() -> Data {
        precondition(opcode.utf8.count == 4, "ATEM command opcode must be 4 ASCII chars")
        let totalLength = UInt16(8 + payload.count)
        var data = Data(count: 8)
        data[0] = UInt8(totalLength >> 8)
        data[1] = UInt8(totalLength & 0xFF)
        data[2] = 0
        data[3] = 0
        let opBytes = [UInt8](opcode.utf8)
        data[4] = opBytes[0]
        data[5] = opBytes[1]
        data[6] = opBytes[2]
        data[7] = opBytes[3]
        data.append(payload)
        return data
    }

    static func parseAll(_ payload: Data) -> [AtemCommand] {
        var result: [AtemCommand] = []
        var offset = 0
        let bytes = [UInt8](payload)
        while offset + 8 <= bytes.count {
            let length = Int(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
            guard length >= 8, offset + length <= bytes.count else { break }
            let opcode = String(bytes: bytes[(offset + 4) ..< (offset + 8)], encoding: .ascii) ?? "????"
            let cmdPayload = payload.subdata(in: (offset + 8) ..< (offset + length))
            result.append(AtemCommand(opcode: opcode, payload: cmdPayload))
            offset += length
        }
        return result
    }
}

// Helper: pad a string to fixed-byte length, null-padded, ASCII.
func atemFixedString(_ value: String, length: Int) -> Data {
    var out = Data(count: length)
    let bytes = [UInt8](value.utf8.prefix(length))
    for i in 0 ..< bytes.count {
        out[i] = bytes[i]
    }
    return out
}
