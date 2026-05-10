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

// Lives on main thread — all triggers come from notification handlers and
// view callbacks which are main-isolated. We use main async hops only for
// the cross-actor delegate callbacks from AtemController.
final class AtemAutoSync {
    private let atemDevices: SettingsAtemDevices
    weak var delegate: AtemAutoSyncDelegate?

    private var discovery: AtemDiscovery?
    private var inFlight = false
    private var dirty = false
    private var currentCycleManual = false
    private var pushControllers: [UUID: AtemController] = [:]
    private var pushDeviceIds: [ObjectIdentifier: UUID] = [:]
    private var endTimer: DispatchSourceTimer?

    init(atemDevices: SettingsAtemDevices) {
        self.atemDevices = atemDevices
    }

    func trigger(reason: String) {
        guard atemDevices.autoSyncEnabled else { return }
        guard hasEligibleDevice() else { return }
        if inFlight {
            dirty = true
            logger.info("atem-autosync: trigger (\(reason)) — already in flight, queued")
            return
        }
        startCycle(reason: reason, manual: false)
    }

    // Manual one-shot — bypasses the master toggle so the user can always
    // force a re-discover-and-push from the UI.
    func runManualCycle(reason: String) {
        if inFlight {
            dirty = true
            logger.info("atem-autosync: manual (\(reason)) — already in flight, queued")
            return
        }
        startCycle(reason: reason, manual: true)
    }

    private func hasEligibleDevice() -> Bool {
        atemDevices.devices.contains { $0.enabled && $0.autoSync && !$0.bonjourName.isEmpty }
    }

    private func startCycle(reason: String, manual: Bool) {
        inFlight = true
        dirty = false
        currentCycleManual = manual
        logger.info("atem-autosync: cycle start (\(reason)) manual=\(manual)")
        for device in eligibleDevices(manual: manual) {
            device.lastSyncStatus = .scanning
        }
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
        let manual = currentCycleManual
        // Any device still in .scanning at this point was not found.
        for device in eligibleDevices(manual: manual)
            where device.lastSyncStatus == .scanning
        {
            device.lastSyncStatus = .notFound
            device.lastSyncAt = Date()
        }
        inFlight = false
        currentCycleManual = false
        logger.info("atem-autosync: cycle end")
        if dirty {
            dirty = false
            startCycle(reason: "queued", manual: false)
        }
    }

    private func eligibleDevices(manual: Bool) -> [SettingsAtemDevice] {
        atemDevices.devices.filter {
            $0.enabled
                && !$0.bonjourName.isEmpty
                && (manual || $0.autoSync)
        }
    }

    private func handle(found: [AtemDiscoveredDevice]) {
        let manual = currentCycleManual
        for device in eligibleDevices(manual: manual) {
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
            device.lastSyncStatus = .failed(String(localized: "No RTMP destination"))
            device.lastSyncAt = Date()
            return
        }
        let id = device.id
        device.lastSyncStatus = .pushing
        let controller = AtemController(host: device.host)
        controller.delegate = self
        pushControllers[id] = controller
        pushDeviceIds[ObjectIdentifier(controller)] = id
        controller.pushStream(serviceName: device.serviceName, url: dest.url, key: dest.key)
        logger.info("atem-autosync: \(device.name) push -> \(dest.url) key=\(dest.key.isEmpty ? "(empty)" : "***")")
    }

    private func updateDeviceStatus(controllerId: ObjectIdentifier, status: AtemControllerStatus) {
        guard let deviceId = pushDeviceIds[controllerId],
              let device = atemDevices.devices.first(where: { $0.id == deviceId })
        else { return }
        switch status {
        case .succeeded:
            device.lastSyncStatus = .succeeded
            device.lastSyncAt = Date()
        case let .failed(reason):
            device.lastSyncStatus = .failed(reason)
            device.lastSyncAt = Date()
        default:
            break
        }
    }
}

extension AtemAutoSync: AtemDiscoveryDelegate {
    func atemDiscoveryUpdate(devices: [AtemDiscoveredDevice]) {
        handle(found: devices)
    }
}

extension AtemAutoSync: AtemControllerDelegate {
    func atemControllerStatusChanged(status: AtemControllerStatus) {
        // AtemController already dispatches delegate callbacks on main.
        for (deviceId, controller) in pushControllers where controller.status == status {
            updateDeviceStatus(controllerId: ObjectIdentifier(controller), status: status)
            if !controller.status.isBusy {
                pushControllers.removeValue(forKey: deviceId)
                pushDeviceIds.removeValue(forKey: ObjectIdentifier(controller))
            }
        }
    }

    func atemControllerDidReadStreamingService(serviceName: String, url: String) {
        // We don't know which controller fired this exactly, but the only
        // controllers active during a sync cycle are auto-sync ones. Update
        // any device whose controller is currently in flight; multiple
        // ATEMs in one cycle is rare and they all see their own SRSU.
        for (deviceId, _) in pushControllers {
            if let device = atemDevices.devices.first(where: { $0.id == deviceId }) {
                device.lastReadServiceName = serviceName
                device.lastReadUrl = url
                device.lastReadAt = Date()
            }
        }
    }
}
