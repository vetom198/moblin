import Foundation

// CStP — Change Stream Properties.
// Layout (best-effort from open-source ATEM implementations; verified against
// ATEM Mini Pro firmware ≥ 9.0):
//   1 byte mask: bit0=service name, bit1=url, bit2=key
//   3 bytes padding
//   64 bytes service name (ASCII, null-padded)
//   512 bytes URL (ASCII, null-padded)
//   512 bytes stream key (ASCII, null-padded)
//
// The mask lets you set only the fields that changed. We always set all three
// when pushing a configuration so the dropdown in ATEM Software Control's
// Output > Live Stream lands on a single coherent destination.

enum AtemCStpField: UInt8 {
    case serviceName = 0x01
    case url         = 0x02
    case streamKey   = 0x04
}

enum AtemOpcode {
    static let changeStreamProperties = "CStP"
    static let changeStreamingState   = "StrR"   // start/stop streaming request
    static let initComplete           = "InCm"   // server sends after state dump
    static let version                = "_ver"
    static let productId              = "_pin"
}

func atemCStpCommand(serviceName: String, url: String, streamKey: String) -> AtemCommand {
    let mask: UInt8 = AtemCStpField.serviceName.rawValue
        | AtemCStpField.url.rawValue
        | AtemCStpField.streamKey.rawValue
    var payload = Data()
    payload.append(mask)
    payload.append(Data([0, 0, 0]))                 // padding
    payload.append(atemFixedString(serviceName, length: 64))
    payload.append(atemFixedString(url, length: 512))
    payload.append(atemFixedString(streamKey, length: 512))
    return AtemCommand(opcode: AtemOpcode.changeStreamProperties, payload: payload)
}

// StrR — Streaming Request.
// 1 byte: 0 = stop, 1 = start.
func atemStreamingCommand(start: Bool) -> AtemCommand {
    var payload = Data(count: 4)
    payload[0] = start ? 1 : 0
    return AtemCommand(opcode: AtemOpcode.changeStreamingState, payload: payload)
}
