import Foundation

// Settings for uploading live ride data to the CTLive broadcast backend.
// The device id itself is not here, it lives in the keychain so it survives a
// reinstall. See CtLiveDeviceId.
class SettingsCtLive: Codable, ObservableObject {
    @Published var enabled: Bool = false
    @Published var baseUrl: String = ctLiveDefaultBaseUrl
    @Published var apiKey: String = ""
    // Shown in the CTLive device list. Falls back to the device name.
    @Published var profileName: String = ""
    // Seconds. The backend wants one sample every 1 to 5 seconds.
    @Published var uploadInterval: Double = 2.0
    // Pressing the start line button is also a natural moment to zero the
    // distance, average speed and slope shown on the stream overlay.
    @Published var resetOverlayDataOnStart: Bool = true
    @Published var startWhenGoingLive: Bool = false
    // Cached from the pairing endpoints. Display only, the uploads are keyed on
    // the device id.
    @Published var ownerUsername: String = ""
    @Published var deviceInternalId: String = ""
    // Lets the race director control this device from the CTLive dashboard.
    // Off by default, remote control of a camera is not something to enable
    // behind the operator's back.
    @Published var remoteControlEnabled: Bool = false
    // Issued by the backend at pairing time. Used as the remote control
    // password. Only present once the device is bound.
    @Published var controlToken: String = ""
    // Absolute wss URL from the backend. Never assembled locally, so the
    // backend can move the endpoint without an app update.
    @Published var controlUrl: String = ""
    // Whether this device may be configured by hand. CTLive owns the stream
    // setup on a managed device, and an operator changing it there would be
    // silently overwritten by the next profile push, so those controls are out
    // of sight unless an administrator opens them on the dashboard.
    @Published var manualSetupEnabled: Bool = false
    // A ride survives an app restart. The broadcast must not rewind to zero
    // because the phone ran out of memory mid race, so the session is stored
    // and picked up again on the next launch unless the operator stopped it.
    @Published var uploadingWasActive: Bool = false
    @Published var sessionPaused: Bool = false
    @Published var sessionDistance: Double = 0
    @Published var sessionElevationGain: Double = 0
    // Seconds accumulated before the currently running segment.
    @Published var sessionElapsedTime: Double = 0
    // Wall clock start of the running segment. Wall clock rather than a
    // monotonic instant, so the race clock keeps running while the app is dead.
    @Published var sessionRunningSince: Date?

    enum CodingKeys: CodingKey {
        case enabled,
             baseUrl,
             apiKey,
             profileName,
             uploadInterval,
             resetOverlayDataOnStart,
             startWhenGoingLive,
             ownerUsername,
             deviceInternalId,
             remoteControlEnabled,
             controlToken,
             controlUrl,
             manualSetupEnabled,
             uploadingWasActive,
             sessionPaused,
             sessionDistance,
             sessionElevationGain,
             sessionElapsedTime,
             sessionRunningSince
    }

    init() {}

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(.enabled, enabled)
        try container.encode(.baseUrl, baseUrl)
        try container.encode(.apiKey, apiKey)
        try container.encode(.profileName, profileName)
        try container.encode(.uploadInterval, uploadInterval)
        try container.encode(.resetOverlayDataOnStart, resetOverlayDataOnStart)
        try container.encode(.startWhenGoingLive, startWhenGoingLive)
        try container.encode(.ownerUsername, ownerUsername)
        try container.encode(.deviceInternalId, deviceInternalId)
        try container.encode(.remoteControlEnabled, remoteControlEnabled)
        try container.encode(.controlToken, controlToken)
        try container.encode(.controlUrl, controlUrl)
        try container.encode(.manualSetupEnabled, manualSetupEnabled)
        try container.encode(.uploadingWasActive, uploadingWasActive)
        try container.encode(.sessionPaused, sessionPaused)
        try container.encode(.sessionDistance, sessionDistance)
        try container.encode(.sessionElevationGain, sessionElevationGain)
        try container.encode(.sessionElapsedTime, sessionElapsedTime)
        try container.encode(.sessionRunningSince, sessionRunningSince)
    }

    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.decode(.enabled, Bool.self, false)
        baseUrl = container.decode(.baseUrl, String.self, ctLiveDefaultBaseUrl)
        apiKey = container.decode(.apiKey, String.self, "")
        profileName = container.decode(.profileName, String.self, "")
        uploadInterval = container.decode(.uploadInterval, Double.self, 2.0)
        resetOverlayDataOnStart = container.decode(.resetOverlayDataOnStart, Bool.self, true)
        startWhenGoingLive = container.decode(.startWhenGoingLive, Bool.self, false)
        ownerUsername = container.decode(.ownerUsername, String.self, "")
        deviceInternalId = container.decode(.deviceInternalId, String.self, "")
        remoteControlEnabled = container.decode(.remoteControlEnabled, Bool.self, false)
        controlToken = container.decode(.controlToken, String.self, "")
        controlUrl = container.decode(.controlUrl, String.self, "")
        manualSetupEnabled = container.decode(.manualSetupEnabled, Bool.self, false)
        uploadingWasActive = container.decode(.uploadingWasActive, Bool.self, false)
        sessionPaused = container.decode(.sessionPaused, Bool.self, false)
        sessionDistance = container.decode(.sessionDistance, Double.self, 0)
        sessionElevationGain = container.decode(.sessionElevationGain, Double.self, 0)
        sessionElapsedTime = container.decode(.sessionElapsedTime, Double.self, 0)
        sessionRunningSince = try? container.decode(Date?.self, forKey: .sessionRunningSince)
    }
}
