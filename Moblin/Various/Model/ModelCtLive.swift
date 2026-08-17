import Foundation

extension Model {
    // iOS terminates a long running camera app under memory pressure and then
    // relaunches it in the background through the location background mode. No
    // scene appears in that case, so MainView's onAppear never fires and
    // Model.setup() never runs: the process is alive but the control
    // connection is never built and the location updates that keep the app
    // running are never restarted. From the director's side the camera is
    // simply gone, with no way back until somebody physically opens the app.
    //
    // Bring up only the two things that matter here. The camera and the media
    // pipeline are deliberately left alone, they belong to setup() and have no
    // business starting in the background.
    //
    // UNVERIFIED: written from the observed symptom (process relaunched by iOS,
    // no handshake for minutes) and from the fact that setup() is reachable
    // only through onAppear. Needs a real background relaunch to confirm, both
    // that this runs at all and that globalModel exists this early.
    func ctLiveResumeAfterBackgroundLaunch() {
        guard ctLiveIsRemoteControlActive() else {
            return
        }
        logger.info("ct-live: Background relaunch, restoring the control connection")
        setupCtLive()
        reloadRemoteControlStreamer()
        reloadLocation()
    }

    func setupCtLive() {
        // Both the background relaunch path and setup() call this, and the
        // tracker restores a running race session, which must not happen twice.
        guard !isCtLiveSetup else {
            return
        }
        isCtLiveSetup = true
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

    // Whether the settings CTLive owns are the operator's to change.
    //
    // A managed device is locked down: the dashboard decides the ingest and the
    // platforms, and anything the operator changed by hand would be silently
    // overwritten by the next profile push, which is worse than not offering it.
    // Only an administrator can open this, on the dashboard.
    //
    // Locked whether or not the device is paired. This build exists to be handed
    // to a race crew, and a phone that has not been paired yet is one on its way
    // to being managed, not a general purpose streaming app.
    //
    // Pairing itself stays reachable under Settings -> CTLive, so a locked
    // device can always be brought under management and thereby be given the
    // key. Nothing here can strand a phone.
    func ctLiveIsManualSetupEnabled() -> Bool {
        database.ctLive.manualSetupEnabled
    }

    // The pairing check carries this too, so the app would pick it up on its
    // own eventually. This is what makes an administrator flipping the switch
    // take effect while the operator is holding the phone, rather than at the
    // next launch, which is the difference between "it works" and "restart it
    // and try again" over the radio.
    func ctLiveSetManualSetupEnabled(_ enabled: Bool) {
        guard database.ctLive.manualSetupEnabled != enabled else {
            return
        }
        database.ctLive.manualSetupEnabled = enabled
        storeSettings()
        logger.info("ct-live: Manual setup \(enabled ? "unlocked" : "locked") by the dashboard")
        makeToast(title: enabled
            ? String(localized: "CTLive unlocked the settings")
            : String(localized: "CTLive locked the settings"))
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

    // Everything that earns this app background execution, released in one
    // action. Until all of it is off, iOS keeps the process alive for location
    // updates and relaunches it after a swipe away, so the operator taps the
    // app closed and watches it come straight back.
    //
    // Deliberately not a "quit": an app cannot close itself on iOS, and one that
    // tried would look broken. This puts the phone in a state where closing it
    // sticks, and says so.
    func ctLiveEndSession() {
        _ = stopStream()
        stopRecording()
        ctLiveStopUploading()
        // The director's link is the last thing keeping the app awake once the
        // ride has stopped. Turning it off is what the operator is asking for
        // by ending the session, and toggling it back on restores it.
        database.ctLive.remoteControlEnabled = false
        reloadRemoteControlStreamer()
        // Stops the location updates. Without this the app stays resident and
        // iOS brings it back.
        reloadLocation()
        stopLiveActivity()
        storeSettings()
        updateQuickButtonStates()
        makeToast(title: String(localized: "Session ended"),
                  subTitle: String(localized: "Safe to close the app now"),
                  vibrate: true)
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
