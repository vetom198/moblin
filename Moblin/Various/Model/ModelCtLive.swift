import Foundation

extension Model {
    func setupCtLive() {
        ctLive.onPairingChanged = { [weak self] in
            // A fresh pairing hands us new control credentials, and losing the
            // binding takes them away. Either way the control connection has to
            // be rebuilt.
            self?.reloadRemoteControlStreamer()
            self?.reloadLocation()
            // The credential has to survive a restart or the operator would be
            // re-pairing before every race.
            self?.storeSettings()
        }
        ctLive.setup(settings: database.ctLive)
    }

    func ctLiveSetEnabled(_ enabled: Bool) {
        database.ctLive.enabled = enabled
        // Turning CTLive on is exactly when the operator wants to know whether
        // this device is still bound, and it is what fetches the control
        // credential.
        ctLive.handleEnabledChanged()
        if !enabled {
            ctLiveStopUploading()
        }
        reloadRemoteControlStreamer()
        reloadLocation()
        storeSettings()
    }

    func ctLiveSetRemoteControlEnabled(_ enabled: Bool) {
        database.ctLive.remoteControlEnabled = enabled
        reloadRemoteControlStreamer()
        updateRemoteControlStatus()
        // Location updates are what keep the app running once the screen goes
        // off, so the control connection depends on them.
        reloadLocation()
        storeSettings()
    }

    // Rebuilds the control connection if it has been down for a while. Stream
    // switching, going live, backgrounding and plain network loss all tear the
    // streamer down through different paths, and the operator must never have to
    // notice that the director went away. Rather than trying to hook every path,
    // watch the outcome.
    func updateCtLiveRemoteControl(now: ContinuousClock.Instant) {
        guard ctLiveIsRemoteControlActive() else {
            ctLiveControlDisconnectedSince = nil
            return
        }
        if let ctLiveControlRetryNotBefore, now < ctLiveControlRetryNotBefore {
            return
        }
        guard !isRemoteControlStreamerConnected() else {
            ctLiveControlDisconnectedSince = nil
            return
        }
        guard let disconnectedSince = ctLiveControlDisconnectedSince else {
            ctLiveControlDisconnectedSince = now
            return
        }
        // The websocket does its own backoff, so only step in once that has
        // clearly failed rather than cutting a healthy retry short.
        guard disconnectedSince.duration(to: now) > .seconds(30) else {
            return
        }
        logger.info("ct-live: Remote control down for 30 s, rebuilding")
        ctLiveControlDisconnectedSince = nil
        reloadRemoteControlStreamer()
    }

    // True once the director can actually reach this device. Used to keep the
    // app alive in the background.
    func ctLiveIsRemoteControlActive() -> Bool {
        database.ctLive.enabled && database.ctLive.remoteControlEnabled && ctLiveCanRemoteControl()
    }

    func ctLiveCanRemoteControl() -> Bool {
        let ctLiveSettings = database.ctLive
        return !ctLiveSettings.controlToken.isEmpty && !ctLiveSettings.controlUrl.isEmpty
    }

    // The start line. Zeroes distance and elapsed time, then starts uploading,
    // so the moment the button is pressed is time zero on the broadcast.
    func ctLiveStartRace() {
        guard ctLiveCanStart() else {
            return
        }
        if database.ctLive.resetOverlayDataOnStart {
            resetLocationData()
        }
        ctLive.startRace()
        reloadLocation()
        // Settings normally only reach disk when the app backgrounds. A race
        // has to survive a crash, so flush it now.
        storeSettings()
        makeToast(title: String(localized: "CTLive race started"),
                  subTitle: String(localized: "Distance and time reset to zero"),
                  vibrate: true)
    }

    func ctLiveStartUploading() {
        guard ctLiveCanStart() else {
            return
        }
        ctLive.startUploading()
        reloadLocation()
        storeSettings()
    }

    func ctLiveStopUploading() {
        ctLive.stopUploading()
        reloadLocation()
        storeSettings()
    }

    func ctLiveTogglePaused() {
        if ctLive.rideStatus == .paused {
            ctLive.resume()
        } else {
            ctLive.pause()
        }
    }

    func ctLiveResetData() {
        if database.ctLive.resetOverlayDataOnStart {
            resetLocationData()
        }
        ctLive.resetData()
    }

    private func ctLiveCanStart() -> Bool {
        guard database.ctLive.enabled else {
            makeErrorToast(title: String(localized: "CTLive is not enabled"),
                           subTitle: String(localized: "Enable it in Settings → CTLive"))
            return false
        }
        return true
    }
}
