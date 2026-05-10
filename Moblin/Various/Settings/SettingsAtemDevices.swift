import Foundation

enum SettingsAtemRtmpSource: String, Codable, CaseIterable {
    case savedRtmpStream
    case custom
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

    enum CodingKeys: CodingKey {
        case id, name, host, enabled, rtmpSource, rtmpStreamId,
             customRtmpUrl, customStreamKey, serviceName
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
        return new
    }
}

class SettingsAtemDevices: Codable, ObservableObject {
    @Published var devices: [SettingsAtemDevice] = []

    enum CodingKeys: CodingKey {
        case devices
    }

    init() {}

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(.devices, devices)
    }

    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = container.decode(.devices, [SettingsAtemDevice].self, [])
    }

    func clone() -> SettingsAtemDevices {
        let new = SettingsAtemDevices()
        for device in devices {
            new.devices.append(device.clone())
        }
        return new
    }
}
