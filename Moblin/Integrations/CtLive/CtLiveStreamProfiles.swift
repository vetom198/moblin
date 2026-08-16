import Foundation

// The push targets the CTLive dashboard manages for this device.
//
// The keychain is the store of record rather than the settings file, for the
// same reason the device id lives there: a reinstall must not lose the ingest
// the operator is expected to go live on, and the stream key is a credential.
// The settings file only keeps the mirrored stream entries, without the key.
enum CtLiveStreamProfiles {
    private static let account = "ctlive-stream-profiles"
    private static let server = "live.ctyeh.com"

    static func load() -> [RemoteControlStreamProfile]? {
        guard let data = loadData() else {
            return nil
        }
        do {
            return try JSONDecoder().decode([RemoteControlStreamProfile].self, from: data)
        } catch {
            logger.info("ct-live: Stored stream profiles are unreadable: \(error)")
            return nil
        }
    }

    static func store(profiles: [RemoteControlStreamProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else {
            logger.info("ct-live: Failed to encode stream profiles")
            return
        }
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // The camera is expected to keep streaming with the screen off, and
            // an app relaunch in that state has to be able to read its ingest
            // back. WhenUnlocked, the default, would not.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.info("ct-live: Failed to add stream profiles to keychain")
            }
        } else if status != errSecSuccess {
            logger.info("ct-live: Failed to update stream profiles in keychain")
        }
    }

    private static func loadData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess else {
            logger.info("ct-live: Failed to read stream profiles from keychain")
            return nil
        }
        return item as? Data
    }
}

extension RemoteControlStreamProfile {
    // Moblin keeps the whole ingest in a single url and the stream key is part
    // of it. The dashboard keeps them apart, so put them back together here.
    func toMoblinUrl() -> String? {
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUrl.isEmpty else {
            return nil
        }
        guard !trimmedKey.isEmpty else {
            return trimmedUrl
        }
        switch proto.lowercased() {
        case "rtmp", "rtmps":
            return "\(trimmedUrl.trimmingSuffix("/"))/\(trimmedKey)"
        case "srt", "srtla":
            // A key that is already in the url wins, so a dashboard that puts
            // it there and also fills in the field does not end up with two.
            guard !trimmedUrl.contains("streamid=") else {
                return trimmedUrl
            }
            let separator = trimmedUrl.contains("?") ? "&" : "?"
            return "\(trimmedUrl)\(separator)streamid=\(trimmedKey)"
        default:
            return trimmedUrl
        }
    }

    func isSupportedProtocol() -> Bool {
        ["rtmp", "rtmps", "srt", "srtla"].contains(proto.lowercased())
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var result = self
        while result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
        }
        return result
    }
}
