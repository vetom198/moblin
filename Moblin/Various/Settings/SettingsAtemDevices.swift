import Foundation

enum SettingsAtemRtmpSource: String, Codable, CaseIterable {
    case savedRtmpStream
    case custom
}

// Per-device run-time auto-sync status. Not persisted — pure UI state.
enum AtemSyncStatus: Equatable {
    case never
    case scanning
    case notFound
    case pushing
    case succeeded
    case failed(String)

    var description: String {
        switch self {
        case .never: String(localized: "Never synced")
        case .scanning: String(localized: "Scanning...")
        case .notFound: String(localized: "Not found on LAN")
        case .pushing: String(localized: "Pushing...")
        case .succeeded: String(localized: "Synced")
        case let .failed(reason): String(localized: "Failed: \(reason)")
        }
    }
}

class SettingsAtemDevice: Codable, Identifiable, ObservableObject, Named {
    static let baseName = String(localized: "My ATEM")
    var id: UUID = .init()
    @Published var name: String = baseName
    @Published var host: String = ""
    @Published var enabled: Bool = false
    @Published var rtmpSource: SettingsAtemRtmpSource = .savedRtmpStream
    @Published var rtmpStreamId: UUID?
    @Published var customRtmpUrl: String = ""
    @Published var customStreamKey: String = ""
    @Published var serviceName: String = "Moblin"
    // Bonjour service name captured at pair time. Survives ATEM reboots and
    // DHCP lease changes — set in flash via Blackmagic ATEM Setup. Used as
    // the stable key for auto-resync.
    @Published var bonjourName: String = ""
    // When true, CTLiveGo re-discovers this ATEM on the LAN after the RTMP
    // server reloads (or app foregrounds) and re-pushes the current RTMP
    // destination. Lets the streamer move between Wi-Fi networks without
    // manually re-pointing the switcher each time.
    @Published var autoSync: Bool = true

    // Run-time only — last auto-sync outcome and when it happened. Not
    // persisted across app launches; @Published so the device editor
    // updates live as scans happen.
    @Published var lastSyncStatus: AtemSyncStatus = .never
    @Published var lastSyncAt: Date?

    // Run-time only — latest streaming service settings read back from
    // the ATEM (via SRSU). Lets the user see "what ATEM thinks the dest
    // is right now" so a successful push is obvious without opening
    // ATEM Software Control. Not persisted.
    @Published var lastReadServiceName: String?
    @Published var lastReadUrl: String?
    @Published var lastReadAt: Date?

    enum CodingKeys: CodingKey {
        case id, name, host, enabled, rtmpSource, rtmpStreamId,
             customRtmpUrl, customStreamKey, serviceName,
             bonjourName, autoSync
    }

    init() {}

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(.id, id)
        try container.encode(.name, name)
        try container.encode(.host, host)
        try container.encode(.enabled, enabled)
        try container.encode(.rtmpSource, rtmpSource)
        try container.encode(.rtmpStreamId, rtmpStreamId)
        try container.encode(.customRtmpUrl, customRtmpUrl)
        try container.encode(.customStreamKey, customStreamKey)
        try container.encode(.serviceName, serviceName)
        try container.encode(.bonjourName, bonjourName)
        try container.encode(.autoSync, autoSync)
    }

    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decode(.id, UUID.self, .init())
        name = container.decode(.name, String.self, Self.baseName)
        host = container.decode(.host, String.self, "")
        enabled = container.decode(.enabled, Bool.self, false)
        rtmpSource = container.decode(.rtmpSource, SettingsAtemRtmpSource.self, .savedRtmpStream)
        rtmpStreamId = try? container.decode(UUID?.self, forKey: .rtmpStreamId)
        customRtmpUrl = container.decode(.customRtmpUrl, String.self, "")
        customStreamKey = container.decode(.customStreamKey, String.self, "")
        serviceName = container.decode(.serviceName, String.self, "Moblin")
        bonjourName = container.decode(.bonjourName, String.self, "")
        autoSync = container.decode(.autoSync, Bool.self, true)
    }

    func clone() -> SettingsAtemDevice {
        let new = SettingsAtemDevice()
        new.id = id
        new.name = name
        new.host = host
        new.enabled = enabled
        new.rtmpSource = rtmpSource
        new.rtmpStreamId = rtmpStreamId
        new.customRtmpUrl = customRtmpUrl
        new.customStreamKey = customStreamKey
        new.serviceName = serviceName
        new.bonjourName = bonjourName
        new.autoSync = autoSync
        return new
    }
}

class SettingsAtemDevices: Codable, ObservableObject {
    @Published var devices: [SettingsAtemDevice] = []
    // Master kill switch. When false, no auto-sync cycles run regardless of
    // per-device autoSync settings. Manual Push / "Sync now" still works.
    @Published var autoSyncEnabled: Bool = true

    enum CodingKeys: CodingKey {
        case devices, autoSyncEnabled
    }

    init() {}

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(.devices, devices)
        try container.encode(.autoSyncEnabled, autoSyncEnabled)
    }

    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = container.decode(.devices, [SettingsAtemDevice].self, [])
        autoSyncEnabled = container.decode(.autoSyncEnabled, Bool.self, true)
    }

    func clone() -> SettingsAtemDevices {
        let new = SettingsAtemDevices()
        new.autoSyncEnabled = autoSyncEnabled
        for device in devices {
            new.devices.append(device.clone())
        }
        return new
    }
}
