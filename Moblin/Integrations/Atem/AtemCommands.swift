import Foundation

// CRSS — Streaming Service Set.
// Layout (verified against OpenSwitcher's reverse-engineered docs:
// https://docs.openswitcher.org/commands/encoder.html):
//   offset 0    size 1     mask (u8)
//   offset 1    size 64    service name (ASCII, null-padded)
//   offset 65   size 512   URL (ASCII, null-padded)
//   offset 577  size 512   stream key (ASCII, null-padded)
//   offset 1089 size 3     padding
//   offset 1092 size 4     minimum bitrate (u32 BE, bytes/sec)
//   offset 1096 size 4     maximum bitrate (u32 BE, bytes/sec)
//   total: 1100 bytes
//
// Mask bits select which fields are applied; unselected fields are ignored
// by ATEM but still need to be present in the payload at full length.

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

func atemSetStreamingServiceCommand(serviceName: String,
                                    url: String,
                                    streamKey: String) -> AtemCommand
{
    let mask: UInt8 = AtemCrssField.serviceName.rawValue
        | AtemCrssField.url.rawValue
        | AtemCrssField.streamKey.rawValue
    var payload = Data()
    payload.append(mask)
    payload.append(atemFixedString(serviceName, length: 64))
    payload.append(atemFixedString(url, length: 512))
    payload.append(atemFixedString(streamKey, length: 512))
    payload.append(Data([0, 0, 0]))                 // padding
    payload.append(Data(count: 4))                   // min bitrate (mask bit not set)
    payload.append(Data(count: 4))                   // max bitrate (mask bit not set)
    return AtemCommand(opcode: AtemOpcode.changeStreamingService, payload: payload)
}

// StrR — Streaming State Request.
// 1 byte: 0 = stop, 1 = start. 3 bytes padding for alignment.
func atemStreamingCommand(start: Bool) -> AtemCommand {
    var payload = Data(count: 4)
    payload[0] = start ? 1 : 0
    return AtemCommand(opcode: AtemOpcode.streamingStateRequest, payload: payload)
}
