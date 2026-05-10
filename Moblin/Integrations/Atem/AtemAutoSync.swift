import Foundation

// Coordinator that re-discovers paired ATEM switchers on the LAN by
// Bonjour service name (set in flash via ATEM Setup → stable across IP /
// network changes) and re-pushes the current RTMP destination to each.
//
// Triggered when:
//   - The RTMP server reloads (new local IP / new stream key / port change).
//   - The app returns to the foreground.
//
// Behaviour:
//   - Only acts on devices that are .enabled, have .autoSync = true, and
//     have a non-empty .bonjourName captured at pair time.
//   - Runs at most one cycle at a time. New triggers while a cycle is in
//     flight set a "dirty" flag so we run again once the current cycle
//     finishes.
//   - Each cycle: scan for atemAutoSyncScanWindow seconds, for each match
//     update host (in case it moved) then push the resolved RTMP URL/key.

private let atemAutoSyncScanWindow: TimeInterval = 6.0

protocol AtemAutoSyncDelegate: AnyObject {
    // Asks the host (Model) to compute the current RTMP destination for
    // the given device. Returns nil if not pushable (RTMP server off,
    // missing stream, etc.).
    func atemAutoSyncResolveDestination(for device: SettingsAtemDevice) -> (url: String, key: String)?
}

@MainActor
final class AtemAutoSync {
    private let atemDevices: SettingsAtemDevices
    weak var delegate: AtemAutoSyncDelegate?

    private var discovery: AtemDiscovery?
    private var inFlight = false
    private var dirty = false
    private var pushControllers: [UUID: AtemController] = [:]
    private var endTimer: DispatchSourceTimer?

    init(atemDevices: SettingsAtemDevices) {
        self.atemDevices = atemDevices
    }

    func trigger(reason: String) {
        guard hasEligibleDevice() else { return }
        if inFlight {
            dirty = true
            logger.info("atem-autosync: trigger (\(reason)) — already in flight, queued")
            return
        }
        startCycle(reason: reason)
    }

    private func hasEligibleDevice() -> Bool {
        atemDevices.devices.contains { $0.enabled && $0.autoSync && !$0.bonjourName.isEmpty }
    }

    private func startCycle(reason: String) {
        inFlight = true
        dirty = false
        logger.info("atem-autosync: cycle start (\(reason))")
        let scanner = AtemDiscovery()
        scanner.delegate = self
        discovery = scanner
        scanner.start()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + atemAutoSyncScanWindow)
        timer.setEventHandler { [weak self] in
            self?.endCycle()
        }
        timer.resume()
        endTimer = timer
    }

    private func endCycle() {
        endTimer?.cancel()
        endTimer = nil
        discovery?.stop()
        discovery = nil
        inFlight = false
        logger.info("atem-autosync: cycle end")
        if dirty {
            dirty = false
            startCycle(reason: "queued")
        }
    }

    private func handle(found: [AtemDiscoveredDevice]) {
        for device in atemDevices.devices
            where device.enabled && device.autoSync && !device.bonjourName.isEmpty
        {
            guard let match = found.first(where: { $0.name == device.bonjourName }) else {
                continue
            }
            if device.host != match.host {
                logger.info("atem-autosync: \(device.name) host \(device.host) -> \(match.host)")
                device.host = match.host
            }
            push(device: device)
        }
    }

    private func push(device: SettingsAtemDevice) {
        guard let dest = delegate?.atemAutoSyncResolveDestination(for: device) else {
            logger.info("atem-autosync: \(device.name) skip — no resolved destination")
            return
        }
        let id = device.id
        let controller = AtemController(host: device.host)
        controller.delegate = self
        pushControllers[id] = controller
        controller.pushStream(serviceName: device.serviceName, url: dest.url, key: dest.key)
        logger.info("atem-autosync: \(device.name) push -> \(dest.url) key=\(dest.key.isEmpty ? "(empty)" : "***")")
    }
}

extension AtemAutoSync: AtemDiscoveryDelegate {
    func atemDiscoveryUpdate(devices: [AtemDiscoveredDevice]) {
        handle(found: devices)
    }
}

extension AtemAutoSync: AtemControllerDelegate {
    nonisolated func atemControllerStatusChanged(status: AtemControllerStatus) {
        Task { @MainActor in
            switch status {
            case .succeeded, .failed, .idle:
                self.pushControllers = self.pushControllers.filter { $0.value.status.isBusy }
            default:
                break
            }
        }
    }
}
