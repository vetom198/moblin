import Foundation

struct AtemDiscoveredDevice: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let host: String
}

protocol AtemDiscoveryDelegate: AnyObject {
    func atemDiscoveryUpdate(devices: [AtemDiscoveredDevice])
}

// Bonjour scanner for ATEM. Blackmagic switchers advertise on a few possible
// service types depending on firmware:
//   _blackmagic._tcp.       (newer ATEM Mini family)
//   _blackmagic-cmd._tcp.   (some HyperDeck-adjacent builds)
//   _blackmagic-rest._tcp.
// We listen on all of them and merge by host.
//
// If Bonjour produces nothing the user can always enter the IP manually.
final class AtemDiscovery: NSObject {
    private static let bonjourTypes = [
        "_blackmagic._tcp.",
        "_blackmagic-cmd._tcp.",
        "_blackmagic-rest._tcp.",
    ]
    private var browsers: [NetServiceBrowser] = []
    private var resolving: [NetService] = []
    private var found: [String: AtemDiscoveredDevice] = [:]   // keyed by host
    weak var delegate: AtemDiscoveryDelegate?

    override init() {
        super.init()
    }

    func start() {
        stop()
        for type in Self.bonjourTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "")
            browsers.append(browser)
        }
    }

    func stop() {
        for browser in browsers {
            browser.stop()
        }
        browsers.removeAll()
        for service in resolving {
            service.stop()
        }
        resolving.removeAll()
        found.removeAll()
    }

    fileprivate func notify() {
        let snapshot = Array(found.values).sorted(by: { $0.name < $1.name })
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.atemDiscoveryUpdate(devices: snapshot)
        }
    }
}

extension AtemDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_: NetServiceBrowser, didFind service: NetService, moreComing _: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 5)
        resolving.append(service)
    }

    func netServiceBrowser(_: NetServiceBrowser, didRemove service: NetService, moreComing _: Bool) {
        let host = AtemDiscovery.serviceHost(service: service)
        if let host {
            found.removeValue(forKey: host)
            notify()
        }
    }
}

extension AtemDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ service: NetService) {
        guard let host = AtemDiscovery.serviceHost(service: service) else { return }
        let device = AtemDiscoveredDevice(name: service.name, host: host)
        found[host] = device
        notify()
    }

    func netService(_ service: NetService, didNotResolve _: [String: NSNumber]) {
        resolving.removeAll(where: { $0 === service })
    }

    private static func serviceHost(service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for data in addresses {
            if let host = AtemDiscovery.ipString(from: data) {
                return host
            }
        }
        return nil
    }

    private static func ipString(from sockaddrData: Data) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = sockaddrData.withUnsafeBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return -1 }
            return getnameinfo(base,
                               socklen_t(sockaddrData.count),
                               &host, socklen_t(host.count),
                               nil, 0,
                               NI_NUMERICHOST)
        }
        guard result == 0 else { return nil }
        return String(cString: host)
    }
}
