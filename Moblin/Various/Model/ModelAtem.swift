import Foundation

extension Model {
    // Lazily set up the auto-sync coordinator on first use, then trigger it.
    // Cheap when there's nothing eligible (the coordinator returns early).
    func triggerAtemAutoSync(reason: String) {
        if atemAutoSync == nil {
            let coordinator = AtemAutoSync(atemDevices: database.atemDevices)
            coordinator.delegate = self
            atemAutoSync = coordinator
        }
        atemAutoSync?.trigger(reason: reason)
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
