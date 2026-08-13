import Foundation

// The CTLive backend keys devices on this id (get_or_create), so it must stay
// stable across app restarts and reinstalls. identifierForVendor changes when
// the app is deleted, which would grow a new zombie device in the CTLive
// backend and break the owner binding, so the id lives in the keychain
// instead. Keychain items survive app deletion.
enum CtLiveDeviceId {
    private static let keychain = Keychain(streamId: "ctlive-device-id",
                                           server: "live.ctyeh.com",
                                           logPrefix: "ct-live")

    static func getOrCreate() -> String {
        if let deviceId = keychain.load(), !deviceId.isEmpty {
            return deviceId
        }
        // Format suggested by the backend so device types are recognizable in
        // the CTLive device list.
        let deviceId = "IPHONE-\(UUID().uuidString.prefix(8))"
        keychain.store(value: deviceId)
        logger.info("ct-live: Created device id \(deviceId)")
        return deviceId
    }
}
