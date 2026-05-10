import Foundation

extension Model {
    // Lazily set up the auto-sync coordinator on first use, then trigger it.
    // Cheap when there's nothing eligible (the coordinator returns early).
    func triggerAtemAutoSync(reason: String) {
        ensureAtemAutoSync().trigger(reason: reason)
    }

    // User-initiated rediscover-and-push for every paired ATEM. Bypasses the
    // master toggle and the per-device autoSync flag — if the user pressed
    // the button they want it to happen.
    func runManualAtemSync(reason: String = "user-tap") {
        ensureAtemAutoSync().runManualCycle(reason: reason)
    }

    private func ensureAtemAutoSync() -> AtemAutoSync {
        if let existing = atemAutoSync { return existing }
        let coordinator = AtemAutoSync(atemDevices: database.atemDevices)
        coordinator.delegate = self
        atemAutoSync = coordinator
        return coordinator
    }
}

extension Model: AtemAutoSyncDelegate {
    func atemAutoSyncResolveDestination(for device: SettingsAtemDevice)
        -> (url: String, key: String)?
    {
        guard database.rtmpServer.enabled else { return nil }
        guard let dest = atemResolveDestination(device: device, rtmpServer: database.rtmpServer)
        else { return nil }
        return (dest.url, dest.key)
    }
}
