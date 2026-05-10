import Foundation

private let preferredInterfacePrefixes = ["en", "pdp_ip"]

struct AtemRtmpDestination {
    let url: String
    let key: String

    var fullUrl: String {
        if key.isEmpty { return url }
        return "\(url)/\(key)"
    }
}

// Resolve the RTMP destination CTLiveGo wants to push to a given ATEM,
// using either a saved RTMP server stream (host derived from this device's
// active IPv4) or a fully custom URL/key the user typed in.
//
// Returns nil when the configuration is incomplete or the saved stream is
// missing — caller treats this as "skip push".
func atemResolveDestination(device: SettingsAtemDevice,
                            rtmpServer: SettingsRtmpServer) -> AtemRtmpDestination?
{
    switch device.rtmpSource {
    case .savedRtmpStream:
        guard let id = device.rtmpStreamId,
              let stream = rtmpServer.streams.first(where: { $0.id == id })
        else { return nil }
        guard let ip = atemPreferredLocalIPv4() else { return nil }
        let url = "rtmp://\(ip):\(rtmpServer.port)/live"
        return AtemRtmpDestination(url: url, key: stream.streamKey)
    case .custom:
        guard !device.customRtmpUrl.isEmpty else { return nil }
        return AtemRtmpDestination(url: device.customRtmpUrl, key: device.customStreamKey)
    }
}

// Best-effort: prefer en* (Ethernet / Wi-Fi) over pdp_ip* (cellular) so the
// pushed RTMP URL is reachable from a switcher on the same LAN. Returns
// the first non-loopback IPv4 we find on a preferred interface, or any
// non-loopback IPv4 from a fallback interface, or nil.
func atemPreferredLocalIPv4() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    var fallback: String?
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = ptr {
        let interface = cur.pointee
        if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            if preferredInterfacePrefixes.contains(where: { name.hasPrefix($0) }) {
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr,
                               socklen_t(addr.pointee.sa_len),
                               &hostBuf, socklen_t(hostBuf.count),
                               nil, 0,
                               NI_NUMERICHOST) == 0
                {
                    let ip = String(cString: hostBuf)
                    if !ip.hasPrefix("127.") {
                        if name.hasPrefix("en") {
                            return ip
                        }
                        fallback = fallback ?? ip
                    }
                }
            }
        }
        ptr = interface.ifa_next
    }
    return fallback
}
