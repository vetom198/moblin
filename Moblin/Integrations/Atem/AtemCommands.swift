import Foundation

// CRSS — Streaming Service Set.
// Layout verified against Sofie's libatem-connection — well-tested with
// real ATEM Mini Pro hardware:
// https://github.com/Sofie-Automation/sofie-atem-connection/blob/master/src/commands/Streaming/StreamingServiceCommand.ts
//   offset 0    size 1     mask (u8)
//   offset 1    size 64    service name (UTF-8, null-padded)
//   offset 65   size 512   URL (UTF-8, null-padded)
//   offset 577  size 512   stream key (UTF-8, null-padded)
//   offset 1089 size 4     minimum bitrate (u32 BE, bytes/sec)
//   offset 1093 size 4     maximum bitrate (u32 BE, bytes/sec)
//   total: 1097 bytes
//
// (OpenSwitcher's docs show three extra padding bytes between key and
// bitrates, totalling 1100; ATEM Mini Pro silently rejects the longer
// payload, so we follow Sofie's verified layout.)
//
// Mask bits select which fields are applied; unselected fields are ignored
// by ATEM but still need to be present in the payload at full length.
// Requires ATEM firmware ≥ 8.1.1 (all current ATEM Mini Pro builds).

enum AtemCrssField: UInt8 {
    case serviceName = 0x01
    case url         = 0x02
    case streamKey   = 0x04
    case bitrate     = 0x08
}

enum AtemOpcode {
    static let changeStreamingService = "CRSS"
    static let streamingStateRequest  = "StrR"   // 1 byte enable + 3 bytes pad
    static let initComplete           = "InCm"   // server sends after state dump
    static let version                = "_ver"
    static let productId              = "_pin"
}

// Default bitrate envelope to ship with every CRSS write.
// ATEM Mini Pro firmware ≥ 8.6 has been observed to silently reject CRSS
// payloads where the bitrate fields are zero / unmasked, treating the
// streaming service definition as incomplete. Always mask + send a valid
// envelope so the switcher commits the new RTMP destination.
private let atemDefaultMinBitrateBps: UInt32 = 3_000_000
private let atemDefaultMaxBitrateBps: UInt32 = 6_000_000

func atemSetStreamingServiceCommand(serviceName: String,
                                    url: String,
                                    streamKey: String) -> AtemCommand
{
    let mask: UInt8 = AtemCrssField.serviceName.rawValue
        | AtemCrssField.url.rawValue
        | AtemCrssField.streamKey.rawValue
        | AtemCrssField.bitrate.rawValue
    var payload = Data()
    payload.append(mask)
    payload.append(atemFixedString(serviceName, length: 64))
    payload.append(atemFixedString(url, length: 512))
    payload.append(atemFixedString(streamKey, length: 512))
    payload.append(atemUInt32BE(atemDefaultMinBitrateBps))
    payload.append(atemUInt32BE(atemDefaultMaxBitrateBps))
    return AtemCommand(opcode: AtemOpcode.changeStreamingService, payload: payload)
}

private func atemUInt32BE(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ])
}

// StrR — Streaming State Request.
// 1 byte: 0 = stop, 1 = start. 3 bytes padding for alignment.
func atemStreamingCommand(start: Bool) -> AtemCommand {
    var payload = Data(count: 4)
    payload[0] = start ? 1 : 0
    return AtemCommand(opcode: AtemOpcode.streamingStateRequest, payload: payload)
}
