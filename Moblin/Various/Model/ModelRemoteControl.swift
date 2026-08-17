import AVFoundation
import CoreLocation
import Foundation
import SwiftUI

class RemoteControl: ObservableObject {
    @Published var general: RemoteControlStatusGeneral?
    @Published var topLeft: RemoteControlStatusTopLeft?
    @Published var topRight: RemoteControlStatusTopRight?
    @Published var settings: RemoteControlSettings?
    @Published var scene = UUID()
    @Published var autoSceneSwitcher: UUID?
    @Published var mic = ""
    @Published var bitrate = UUID()
    @Published var zoom = ""
    @Published var zoomPresets: [RemoteControlZoomPreset] = []
    @Published var zoomPreset = UUID()
    @Published var debugLogging = false
    @Published var preview: UIImage?
    @Published var recording: Bool = false
    @Published var streaming: Bool = false
    @Published var muted: Bool = false
    @Published var presentingPreview = true
    @Published var presentingPreviewFullScreen = false
    @Published var presentingStreamers = false
    @Published var pixellate: Bool = false
    @Published var movie: Bool = false
    @Published var grayScale: Bool = false
    @Published var sepia: Bool = false
    @Published var triple: Bool = false
    @Published var twin: Bool = false
    @Published var fourThree: Bool = false
    @Published var crt: Bool = false
    @Published var pinch: Bool = false
    @Published var whirlpool: Bool = false
    @Published var poll: Bool = false
    @Published var blurFaces: Bool = false
    @Published var privacy: Bool = false
    @Published var beauty: Bool = false
    @Published var moblinInMouth: Bool = false
    @Published var cameraMan: Bool = false
}

enum RemoteControlAssistantPreviewUser {
    case panel
    case watch
}

extension Model {
    func isShowingStatusRemoteControl() -> Bool {
        database.show.remoteControl && isAnyRemoteControlConfigured()
    }

    private func isAnyRemoteControlConfigured() -> Bool {
        isRemoteControlStreamerConfigured() || isRemoteControlAssistantConfigured()
    }

    func clearRemoteControlAssistantLog() {
        remoteControlAssistantLog = []
    }

    // The caller is recorded because everything that reloads the app's outgoing
    // connections funnels through here, and when a control connection is rebuilt
    // at a moment it should not be, the only useful question is who asked.
    // A default argument of #function evaluates at the call site.
    func reloadRemoteControlStreamer(reason: String = #function) {
        if let (url, password, _) = ctLiveRemoteControlConnection(),
           let streamer = remoteControlStreamer,
           streamer.isConnected() || streamer.isSettlingIn(),
           streamer.isConfigured(clientUrl: url, password: password)
        {
            // Switching stream, reloading chat and checking the pairing all
            // reload every outgoing connection, and none of them changed where
            // the director is. Rebuilding a live control connection for an
            // unchanged configuration blinds the director for as long as the
            // reconnect takes, right at the moment they acted. The watchdog
            // still rebuilds a connection that is actually down, because that
            // one is not connected.
            return
        }
        remoteControlStreamer?.stop()
        remoteControlStreamer = nil
        if let (url, password, headers) = ctLiveRemoteControlConnection() {
            // CTLive wins over a manually configured assistant. The app only
            // supports one streamer connection, and during a race the director
            // is the one who needs it.
            remoteControlStreamer = RemoteControlStreamer(
                clientUrl: url,
                password: password,
                delegate: self,
                additionalHeaders: headers,
                // A camera in the field drops off the network for minutes at a
                // time. Retrying twice a second on a dead cell just burns
                // battery, so start at 3 s and back off to 30 s.
                reconnectDelaysMs: (shortest: 3000, longest: 30000),
                onTerminalClose: { [weak self] closeCode in
                    self?.handleCtLiveControlClosed(closeCode: closeCode)
                }
            )
            remoteControlStreamer?.start()
            ctLiveControlDisconnectedSince = nil
            logger.info("ct-live: Remote control connecting to \(url) (asked by \(reason))")
            return
        }
        guard isRemoteControlStreamerConfigured() else {
            reloadTwitchEventSub()
            reloadChats()
            return
        }
        guard let url = URL(string: database.remoteControl.streamer.url) else {
            reloadTwitchEventSub()
            reloadChats()
            return
        }
        remoteControlStreamer = RemoteControlStreamer(
            clientUrl: url,
            password: database.remoteControl.password,
            delegate: self
        )
        remoteControlStreamer!.start()
    }

    private func ctLiveRemoteControlConnection() -> (URL, String, [(String, String)])? {
        let ctLiveSettings = database.ctLive
        guard ctLiveSettings.enabled, ctLiveSettings.remoteControlEnabled else {
            return nil
        }
        guard !ctLiveSettings.controlToken.isEmpty,
              let url = URL(string: ctLiveSettings.controlUrl)
        else {
            return nil
        }
        var headers: [(String, String)] = []
        // Django's AllowedHostsOriginValidator rejects a handshake with no
        // Origin, and Network.framework sends none. Derive it from the control
        // URL so dev and production both work without an app change.
        if let origin = webSocketOrigin(of: url) {
            headers.append(("Origin", origin))
        }
        return (url, ctLiveSettings.controlToken, headers)
    }

    private func webSocketOrigin(of url: URL) -> String? {
        guard let host = url.host() else {
            return nil
        }
        let scheme = url.scheme == "ws" ? "http" : "https"
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private func handleCtLiveControlClosed(closeCode: UInt16) {
        if closeCode == remoteControlCredentialRevokedCloseCode {
            // The token is dead. Drop it so we do not keep presenting it, and a
            // pairing check will fetch the new one.
            database.ctLive.controlToken = ""
            makeErrorToast(title: String(localized: "CTLive remote control was revoked"),
                           subTitle: String(localized: "Check the pairing status to get a new credential"))
        } else {
            // The backend refused the device, not the credential. Keep the
            // setting on and retry slowly, so re-enabling control on the
            // dashboard recovers without the operator touching the phone.
            makeErrorToast(title: String(localized: "CTLive refused remote control"),
                           subTitle: String(localized: "The device is unpaired or control is disabled"))
            // The watchdog retries from here, no need for a timer of its own.
            ctLiveControlRetryNotBefore = ContinuousClock.now.advanced(by: .seconds(60))
            ctLiveControlDisconnectedSince = nil
        }
        updateRemoteControlStatus()
    }

    private func remoteControlStreamerSendTwitchStart() {
        remoteControlStreamer?.twitchStart(
            channelName: stream.twitchChannelName,
            channelId: stream.twitchChannelId,
            accessToken: stream.twitchAccessToken
        )
    }

    func updateRemoteControlStatus() {
        let status: String
        if isRemoteControlAssistantConnected(), isRemoteControlStreamerConnected() {
            status = String(localized: "Assistant and streamer")
        } else if isRemoteControlAssistantConnected() {
            status = String(localized: "Assistant")
        } else if isRemoteControlStreamerConnected() {
            status = String(localized: "Streamer")
        } else {
            let assistantError = remoteControlAssistant?.connectionErrorMessage ?? ""
            let streamerError = remoteControlStreamer?.connectionErrorMessage ?? ""
            if isRemoteControlAssistantConfigured(), isRemoteControlStreamerConfigured() {
                status = "\(assistantError), \(streamerError)"
            } else if isRemoteControlAssistantConfigured() {
                status = assistantError
            } else if isRemoteControlStreamerConfigured() {
                status = streamerError
            } else {
                status = noValue
            }
        }
        if status != statusTopRight.remoteControlStatus {
            statusTopRight.remoteControlStatus = status
        }
    }

    func isRemoteControlStreamerConfigured() -> Bool {
        if ctLiveRemoteControlConnection() != nil {
            return true
        }
        let streamer = database.remoteControl.streamer
        return streamer.enabled && !streamer.url.isEmpty && !database.remoteControl.password.isEmpty
    }

    func isRemoteControlStreamerConnected() -> Bool {
        remoteControlStreamer?.isConnected() ?? false
    }

    func stopRemoteControlAssistant() {
        remoteControlAssistant?.stop()
        remoteControlAssistant = nil
    }

    func reloadRemoteControlAssistant() {
        stopRemoteControlAssistant()
        guard isRemoteControlAssistantConfigured() else {
            return
        }
        remoteControlAssistant = RemoteControlAssistant(
            port: database.remoteControl.assistant.port,
            password: database.remoteControl.password,
            delegate: self
        )
        remoteControlAssistant!.start()
    }

    func isRemoteControlAssistantConnected() -> Bool {
        remoteControlAssistant?.isConnected() ?? false
    }

    func updateRemoteControlAssistantStatus() {
        guard showingRemoteControl || isWatchRemoteControl(), isRemoteControlAssistantConnected() else {
            return
        }
        remoteControlAssistant?.getStatus { general, topLeft, topRight in
            self.remoteControl.general = general
            self.remoteControl.topLeft = topLeft
            self.remoteControl.topRight = topRight
            if self.isWatchRemoteControl() {
                self.sendRemoteControlAssistantStatusToWatch()
            }
        }
        remoteControlAssistant?.getSettings { settings in
            self.remoteControl.settings = settings
        }
    }

    func isRemoteControlAssistantConfigured() -> Bool {
        let assistant = database.remoteControl.assistant
        return assistant.enabled && assistant.port > 0 && !database.remoteControl.password.isEmpty
    }

    func remoteControlAssistantSetRemoteSceneSettings() {
        let data = RemoteControlRemoteSceneSettings(
            scenes: database.scenes,
            widgets: database.widgets,
            selectedSceneId: database.remoteSceneId
        )
        remoteControlAssistant?.setRemoteSceneSettings(data: data) {}
    }

    private func shouldSendRemoteScene() -> Bool {
        database.remoteSceneId != nil && remoteControlAssistant?.isConnected() == true
    }

    func remoteControlAssistantSetRemoteSceneDataTextStats(stats: TextEffectStats) {
        guard shouldSendRemoteScene() else {
            return
        }
        let data =
            RemoteControlRemoteSceneData(textStats: RemoteControlRemoteSceneDataTextStats(stats: stats))
        remoteControlAssistant?.setRemoteSceneData(data: data) {}
    }

    func remoteControlAssistantSetRemoteSceneDataLocation(location: CLLocation) {
        guard shouldSendRemoteScene() else {
            return
        }
        let data =
            RemoteControlRemoteSceneData(location: RemoteControlRemoteSceneDataLocation(location: location))
        remoteControlAssistant?.setRemoteSceneData(data: data) {}
    }

    func remoteControlAssistantSetStream(on: Bool) {
        remoteControlAssistant?.setStream(on: on) {
            DispatchQueue.main.async {
                self.updateRemoteControlAssistantStatus()
            }
        }
    }

    func remoteControlAssistantSetRecord(on: Bool) {
        remoteControlAssistant?.setRecord(on: on) {
            DispatchQueue.main.async {
                self.updateRemoteControlAssistantStatus()
            }
        }
    }

    func remoteControlAssistantSetMute(on: Bool) {
        remoteControlAssistant?.setMute(on: on) {
            DispatchQueue.main.async {
                self.updateRemoteControlAssistantStatus()
            }
        }
    }

    func remoteControlAssistantSetScene(id: UUID) {
        remoteControlAssistant?.setScene(id: id) {
            DispatchQueue.main.async {
                self.updateRemoteControlAssistantStatus()
            }
        }
    }

    func remoteControlAssistantSetAutoSceneSwitcher(id: UUID?) {
        remoteControlAssistant?.setAutoSceneSwitcher(id: id) {
            DispatchQueue.main.async {
                self.updateRemoteControlAssistantStatus()
            }
        }
    }

    func remoteControlAssistantSetMic(id: String) {
        remoteControlAssistant?.setMic(id: id) {
            DispatchQueue.main.async {
                self.updateRemoteControlAssistantStatus()
            }
        }
    }

    func remoteControlAssistantSetZoom(x: Float) {
        remoteControlAssistant?.setZoom(x: x) {}
    }

    func remoteControlAssistantSetZoomPreset(id: UUID) {
        remoteControlAssistant?.setZoomPreset(id: id) {}
    }

    func remoteControlAssistantSetBitratePreset(id: UUID) {
        remoteControlAssistant?.setBitratePreset(id: id) {
            DispatchQueue.main.async {
                self.updateRemoteControlAssistantStatus()
            }
        }
    }

    func remoteControlAssistantSetDebugLogging(on: Bool) {
        remoteControlAssistant?.setDebugLogging(on: on) {}
    }

    func remoteControlAssistantReloadBrowserWidgets() {
        remoteControlAssistant?.reloadBrowserWidgets {
            DispatchQueue.main.async {
                self.makeToast(title: String(localized: "Browser widgets reloaded"))
            }
        }
    }

    func remoteControlAssistantSetSrtConnectionPriorityEnabled(enabled: Bool) {
        remoteControlAssistant?.setSrtConnectionPrioritiesEnabled(
            enabled: enabled
        ) {}
    }

    func remoteControlAssistantSetSrtConnectionPriority(priority: RemoteControlSettingsSrtConnectionPriority) {
        remoteControlAssistant?.setSrtConnectionPriority(
            id: priority.id,
            priority: priority.priority,
            enabled: priority.enabled
        ) {}
    }

    func remoteControlAssistantMoveToGimbalPreset(id: UUID) {
        remoteControlAssistant?.moveToGimbalPreset(id: id) {}
    }

    func remoteControlAssistantSetFilter(filter: RemoteControlFilter, on: Bool) {
        remoteControlAssistant?.setFilter(filter: filter, on: on)
    }

    func remoteControlAssistantStartPreview(user: RemoteControlAssistantPreviewUser) {
        remoteControlAssistantPreviewUsers.insert(user)
        remoteControlAssistant?.startPreview()
    }

    func remoteControlAssistantStopPreview(user: RemoteControlAssistantPreviewUser) {
        remoteControlAssistantPreviewUsers.remove(user)
        if remoteControlAssistantPreviewUsers.isEmpty {
            remoteControlAssistant?.stopPreview()
        }
    }

    func remoteControlAssistantStartStatus() {
        remoteControlAssistantStatusRequested = true
        remoteControlAssistant?.startStatus()
    }

    func remoteControlAssistantStopStatus() {
        remoteControlAssistantStatusRequested = false
        remoteControlAssistant?.stopStatus()
    }

    func reloadRemoteControlRelay() {
        remoteControlRelay?.stop()
        remoteControlRelay = nil
        guard isRemoteControlRelayConfigured() else {
            return
        }
        guard let assistantUrl = URL(string: "ws://localhost:\(database.remoteControl.assistant.port)") else {
            return
        }
        remoteControlRelay = RemoteControlRelay(
            baseUrl: database.remoteControl.assistant.relay.baseUrl,
            bridgeId: database.remoteControl.assistant.relay.bridgeId,
            assistantUrl: assistantUrl
        )
        remoteControlRelay?.start()
    }

    func isRemoteControlRelayConfigured() -> Bool {
        let relay = database.remoteControl.assistant.relay
        return relay.enabled && !relay.baseUrl.isEmpty
    }

    func remoteControlStreamerCreateStatus(filter: RemoteControlStartStatusFilter?)
        -> (RemoteControlStatusGeneral?, RemoteControlStatusTopLeft?, RemoteControlStatusTopRight?)
    {
        var general: RemoteControlStatusGeneral?
        var topLeft: RemoteControlStatusTopLeft?
        var topRight: RemoteControlStatusTopRight?
        if let filter {
            // general carries isLive and isRecording. An assistant that gates
            // stream breaking commands on those needs them in every periodic
            // status, not only in an unfiltered getStatus.
            general = remoteControlStreamerCreateStatusGeneral()
            if filter.topRight {
                topRight = remoteControlStreamerCreateStatusTopRight()
            }
        } else {
            general = remoteControlStreamerCreateStatusGeneral()
            topLeft = remoteControlStreamerCreateStatusTopLeft()
            topRight = remoteControlStreamerCreateStatusTopRight()
        }
        return (general, topLeft, topRight)
    }

    private func remoteControlStreamerCreateStatusGeneral() -> RemoteControlStatusGeneral {
        var general = RemoteControlStatusGeneral()
        general.batteryCharging = isBatteryCharging()
        general.batteryLevel = Int(100 * battery.level)
        switch statusOther.thermalState {
        case .nominal:
            general.flame = .white
        case .fair:
            general.flame = .white
        case .serious:
            general.flame = .yellow
        case .critical:
            general.flame = .red
        @unknown default:
            general.flame = .red
        }
        general.wiFiSsid = currentWiFiSsid
        general.isLive = isLive
        general.isRecording = isRecording
        general.isMuted = isMuteOn
        general.canRunInBackground = ctLiveCanRunInBackground()
        return general
    }

    private func remoteControlStreamerCreateStatusTopLeft() -> RemoteControlStatusTopLeft {
        var topLeft = RemoteControlStatusTopLeft()
        if isStreamConfigured() {
            topLeft.stream = RemoteControlStatusItem(message: statusTopLeft.streamText)
        }
        topLeft.camera = RemoteControlStatusItem(message: statusTopLeft.statusCameraText)
        topLeft.mic = RemoteControlStatusItem(message: mic.current.name)
        if zoom.hasZoom {
            topLeft.zoom = RemoteControlStatusItem(message: zoom.statusText())
        }
        if isObsRemoteControlConfigured() {
            topLeft.obs = RemoteControlStatusItem(message: statusTopLeft.statusObsText)
        }
        if isEventsConfigured() {
            topLeft.events = RemoteControlStatusItem(message: statusTopLeft.statusEventsText)
        }
        if isChatConfigured() {
            topLeft.chat = RemoteControlStatusItem(message: statusTopLeft.statusChatText)
        }
        if isViewersConfigured(), isLive {
            topLeft.viewers = RemoteControlStatusItem(message: statusViewersText())
        }
        return topLeft
    }

    private func remoteControlStreamerCreateStatusTopRight() -> RemoteControlStatusTopRight {
        var topRight = RemoteControlStatusTopRight()
        let level = formatAudioLevel(level: audio.level.level) +
            formatAudioLevelChannels(channels: audio.numberOfChannels)
        topRight.audioLevel = RemoteControlStatusItem(message: level)
        topRight.audioInfo = .init(
            audioLevel: .unknown,
            numberOfAudioChannels: audio.numberOfChannels
        )
        if audio.level.level.isNaN {
            topRight.audioInfo!.audioLevel = .muted
        } else if audio.level.level.isInfinite {
            topRight.audioInfo!.audioLevel = .unknown
        } else {
            topRight.audioInfo!.audioLevel = .value(audio.level.level)
        }
        if isIngestsConfigured() {
            topRight.rtmpServer = RemoteControlStatusItem(message: ingests.speedAndTotal)
        }
        if isAnyRemoteControlConfigured() {
            topRight.remoteControl = RemoteControlStatusItem(message: statusTopRight.remoteControlStatus)
        }
        if isGameControllerConnected() {
            topRight.gameController = RemoteControlStatusItem(message: statusTopRight.gameControllersTotal)
        }
        if isLive {
            topRight.bitrate = RemoteControlStatusItem(message: bitrate.speedAndTotal)
        }
        if isLive {
            topRight.uptime = RemoteControlStatusItem(message: streamUptime.uptime)
        }
        if isLocationEnabled() {
            topRight.location = RemoteControlStatusItem(message: statusTopRight.location)
        }
        if isStatusBondingActive() {
            topRight.srtla = RemoteControlStatusItem(message: bonding.statistics)
        }
        if isStatusBondingRttsActive() {
            topRight.srtlaRtts = RemoteControlStatusItem(message: bonding.rtts)
        }
        if isRecording {
            topRight.recording = RemoteControlStatusItem(message: recording.length)
        }
        if stream.replay.enabled {
            topRight.replay = RemoteControlStatusItem(message: String(localized: "Enabled"))
        }
        if isStatusBrowserWidgetsActive() {
            topRight.browserWidgets = RemoteControlStatusItem(message: statusTopRight.browserWidgetsStatus)
        }
        if isAnyMoblinkConfigured() {
            topRight.moblink = RemoteControlStatusItem(message: moblink.status)
        }
        if !statusTopRight.djiDevicesStatus.isEmpty {
            topRight.djiDevices = RemoteControlStatusItem(message: statusTopRight.djiDevicesStatus)
        }
        if database.show.systemMonitor {
            topRight.systemMonitor = RemoteControlStatusItem(message: systemMonitor.format())
        }
        return topRight
    }

    func sendPeriodicRemoteControlStreamerStatus() {
        guard isRemoteControlStreamerConnected(), isRemoteControlAssistantRequestingStatus else {
            remoteControlStatusSecondsSinceSent = 0
            return
        }
        // Called once a second. Honour the interval the assistant asked for
        // rather than reporting as fast as the timer runs.
        remoteControlStatusSecondsSinceSent += 1
        guard remoteControlStatusSecondsSinceSent >= remoteControlAssistantRequestingStatusInterval else {
            return
        }
        remoteControlStatusSecondsSinceSent = 0
        let (general,
             topLeft,
             topRight) =
            remoteControlStreamerCreateStatus(filter: remoteControlAssistantRequestingStatusFilter)
        remoteControlStreamer?.sendStatus(general: general, topLeft: topLeft, topRight: topRight)
    }

    func isRemoteControlStreamerPreviewActive() -> Bool {
        isRemoteControlStreamerConnected()
            && isRemoteControlAssistantRequestingPreview
            && database.remoteControl.streamer.previewFps > 0
    }

    private func createRemoteControlStateChanged() -> RemoteControlAssistantStreamerState {
        var state = RemoteControlAssistantStreamerState()
        if sceneSelector.sceneIndex < enabledScenes.count {
            state.scene = enabledScenes[sceneSelector.sceneIndex].id
        }
        state.autoSceneSwitcher = .init(id: autoSceneSwitcher.currentSwitcherId)
        state.mic = mic.current.id
        if let preset = getBitratePresetByBitrate(bitrate: stream.bitrate) {
            state.bitrate = preset.id
        }
        switch cameraPosition {
        case .front:
            state.zoomPresets = zoom.frontZoomPresets
                .map { RemoteControlZoomPreset(id: $0.id, name: $0.name) }
            state.zoomPreset = zoom.frontPresetId
        case .back:
            state.zoomPresets = zoom.backZoomPresets.map { RemoteControlZoomPreset(id: $0.id, name: $0.name) }
            state.zoomPreset = zoom.backPresetId
        default:
            state.zoomPresets = []
        }
        state.zoom = zoom.x
        state.debugLogging = database.debug.debugLogging
        state.streaming = isLive
        state.recording = isRecording
        state.muted = isMuteOn
        state.torchOn = streamOverlay.isTorchOn
        state.batteryCharging = isBatteryCharging()
        state.filters = [:]
        for filter in RemoteControlFilter.allCases {
            state.filters?[filter] = getQuickButtonState(type: filter.toSettings())?.isOn ?? false
        }
        return state
    }

    func remoteControlStateChanged(state: RemoteControlAssistantStreamerState) {
        remoteControlStreamer?.stateChanged(state: state)
        remoteControlWeb?.stateChanged(state: state)
    }

    func remoteControlLog(entry: String) {
        remoteControlStreamer?.log(entry: entry)
        remoteControlWeb?.log(entry: entry)
    }

    func remoteControlScoreboardUpdate(scoreboard: SettingsWidgetScoreboard) {
        let config = getModularScoreboardConfig(scoreboard: scoreboard)
        remoteControlStreamer?.sendScoreboardUpdate(config: config)
        remoteControlWeb?.sendScoreboardUpdate(config: config)
    }

    func reloadRemoteControlWeb() {
        remoteControlWeb?.stop()
        remoteControlWeb = nil
        guard database.remoteControl.web.enabled else {
            return
        }
        remoteControlWeb = RemoteControlWeb(delegate: self)
        remoteControlWeb?.start(port: database.remoteControl.web.port)
    }

    private func handleRemoteControlSetFilter(filter: RemoteControlFilter, on: Bool) {
        switch filter {
        case .pixellate:
            setPixellateQuickButton(on: on)
        case .movie:
            setFilterQuickButton(type: .movie, on: on)
        case .grayScale:
            setFilterQuickButton(type: .grayScale, on: on)
        case .sepia:
            setFilterQuickButton(type: .sepia, on: on)
        case .triple:
            setFilterQuickButton(type: .triple, on: on)
        case .twin:
            setFilterQuickButton(type: .twin, on: on)
        case .fourThree:
            setFilterQuickButton(type: .fourThree, on: on)
        case .crt:
            setFilterQuickButton(type: .crt, on: on)
        case .pinch:
            setPinchQuickButton(on: on)
        case .whirlpool:
            setWhirlpoolQuickButton(on: on)
        case .poll:
            setPollQuickButton(on: on)
        case .blurFaces:
            setBlurFaces(on: on)
        case .privacy:
            setPrivacy(on: on)
        case .beauty:
            setBeautyQuickButton(on: on)
        case .moblinInMouth:
            setMoblinInMouth(on: on)
        case .cameraMan:
            setCameraManQuickButton(on: on)
        }
    }

    private func handleRemoteControlTriggerReaction(reaction: RemoteControlReaction) {
        guard #available(iOS 17, *) else {
            return
        }
        triggerReaction(reaction: reaction.toSettings())
    }

    private func handleGetSettings() -> RemoteControlSettings {
        let scenes = enabledScenes.map {
            RemoteControlSettingsScene(id: $0.id, name: $0.name)
        }
        let autoSceneSwitchers = database.autoSceneSwitchers.switchers.map {
            RemoteControlSettingsAutoSceneSwitcher(id: $0.id, name: $0.name)
        }
        let mics = database.mics.mics.map {
            RemoteControlSettingsMic(id: $0.id, name: $0.name)
        }
        let bitratePresets = database.bitratePresets.map {
            RemoteControlSettingsBitratePreset(id: $0.id, bitrate: $0.bitrate)
        }
        let connectionPriorities = stream.srt.connectionPriorities.priorities
            .map {
                RemoteControlSettingsSrtConnectionPriority(
                    id: $0.id,
                    name: $0.name,
                    priority: $0.priority,
                    enabled: $0.enabled
                )
            }
        let connectionPrioritiesEnabled = stream.srt.connectionPriorities.enabled
        let gimbalPresets = database.gimbal.presets.map {
            RemoteControlSettingsGimbalPreset(id: $0.id, name: $0.name)
        }
        return RemoteControlSettings(
            scenes: scenes,
            autoSceneSwitchers: autoSceneSwitchers,
            bitratePresets: bitratePresets,
            mics: mics,
            srt: RemoteControlSettingsSrt(
                connectionPrioritiesEnabled: connectionPrioritiesEnabled,
                connectionPriorities: connectionPriorities
            ),
            gimbalPresets: gimbalPresets
        )
    }
}

extension Model: RemoteControlStreamerDelegate {
    func remoteControlStreamerConnected() {
        useRemoteControlForChatAndEvents = database.remoteControl.streamer.reliableChatAndEvents
        let subTitle: String?
        if useRemoteControlForChatAndEvents {
            reloadTwitchEventSub()
            reloadTwitchChat()
            remoteControlStreamerSendTwitchStart()
            subTitle = String(localized: "Reliable alerts and chat messages activated")
        } else {
            subTitle = nil
        }
        makeToast(title: String(localized: "Remote control assistant connected"), subTitle: subTitle)
        isRemoteControlAssistantRequestingPreview = false
        // The CTLive backend decides whether a command would break a running
        // stream by looking at the last reported isLive, and no status at all
        // reads as not live. Start reporting immediately rather than waiting for
        // startStatus to arrive, which also saves a round trip on every weak
        // network reconnect.
        isRemoteControlAssistantRequestingStatus = ctLiveIsRemoteControlActive()
        remoteControlAssistantRequestingStatusFilter = nil
        remoteControlAssistantRequestingStatusInterval = 1
        remoteControlStatusSecondsSinceSent = 0
        setLowFpsImage()
        updateRemoteControlStatus()
        remoteControlStateChanged(state: createRemoteControlStateChanged())
        sendPeriodicRemoteControlStreamerStatus()
    }

    func remoteControlStreamerDisconnected() {
        makeToast(title: String(localized: "Remote control assistant disconnected"))
        isRemoteControlAssistantRequestingPreview = false
        isRemoteControlAssistantRequestingStatus = false
        setLowFpsImage()
        updateRemoteControlStatus()
    }

    func remoteControlStreamerGetStatus()
        -> (RemoteControlStatusGeneral, RemoteControlStatusTopLeft, RemoteControlStatusTopRight)
    {
        let (general, topLeft, topRight) = remoteControlStreamerCreateStatus(filter: nil)
        return (general!, topLeft!, topRight!)
    }

    func remoteControlStreamerGetSettings() -> RemoteControlSettings {
        handleGetSettings()
    }

    // The operator is holding the camera and cannot see the dashboard. Anything
    // a remote director changes has to be visible on the phone, otherwise the
    // stream starts or the scene switches with no explanation.
    private func announceRemoteControl(_ text: String) {
        makeToast(title: text, vibrate: true)
    }

    func remoteControlStreamerSetScene(id: UUID) {
        selectScene(id: id)
        if let scene = findEnabledScene(id: id) {
            announceRemoteControl(String(localized: "Director switched to scene \(scene.name)"))
        }
    }

    func remoteControlStreamerSetAutoSceneSwitcher(id: UUID?) {
        setAutoSceneSwitcher(id: id)
    }

    func remoteControlStreamerSetMic(id: String) {
        manualSelectMicById(id: id)
        announceRemoteControl(String(localized: "Director changed the mic"))
    }

    func remoteControlStreamerSetBitratePreset(id: UUID) {
        guard let preset = database.bitratePresets.first(where: { preset in
            preset.id == id
        }) else {
            return
        }
        setBitrate(bitrate: preset.bitrate)
    }

    func remoteControlStreamerSetRecord(on: Bool) {
        // A target state, not a toggle. If the response to the first command was
        // lost the director may send it again, and starting a second recording
        // would abandon the one already running.
        guard on != isRecording else {
            return
        }
        if on {
            startRecording()
            announceRemoteControl(String(localized: "Director started recording"))
        } else {
            stopRecording()
            announceRemoteControl(String(localized: "Director stopped recording"))
        }
        updateQuickButtonStates()
    }

    func remoteControlStreamerSetStream(on: Bool) {
        guard on != isLive else {
            return
        }
        if on {
            startStream()
            announceRemoteControl(String(localized: "Director went live"))
        } else {
            _ = stopStream()
            announceRemoteControl(String(localized: "Director stopped the stream"))
        }
        updateQuickButtonStates()
    }

    func remoteControlStreamerSetDebugLogging(on: Bool) {
        database.debug.debugLogging = on
        setDebugLogging(on: on)
    }

    func remoteControlStreamerSetZoom(x: Float) {
        setZoomX(x: x, rate: database.zoom.speed)
    }

    func remoteControlStreamerSetZoomPreset(id: UUID) {
        setZoomPreset(id: id)
    }

    func remoteControlStreamerSetMute(on: Bool) {
        setMuteOn(value: on)
        announceRemoteControl(on ? String(localized: "Director muted the mic")
            : String(localized: "Director unmuted the mic"))
    }

    func remoteControlStreamerSetTorch(on: Bool) {
        streamOverlay.isTorchOn = on
        updateTorch()
        toggleQuickButton(type: .torch)
        updateQuickButtonStates()
    }

    func remoteControlStreamerReloadBrowserWidgets() {
        reloadBrowserWidgets()
    }

    func remoteControlStreamerSetSrtConnectionPrioritiesEnabled(enabled: Bool) {
        stream.srt.connectionPriorities.enabled = enabled
        updateSrtlaPriorities()
    }

    func remoteControlStreamerSetSrtConnectionPriority(
        id: UUID,
        priority: Int,
        enabled: Bool
    ) {
        if let entry = stream.srt.connectionPriorities.priorities.first(where: { $0.id == id }) {
            entry.priority = clampConnectionPriority(value: priority)
            entry.enabled = enabled
            updateSrtlaPriorities()
        }
    }

    func sendPreviewToRemoteControlAssistant(preview: Data) {
        guard isRemoteControlStreamerPreviewActive() else {
            return
        }
        remoteControlStreamer?.sendPreview(preview: preview)
    }

    func remoteControlStreamerTwitchEventSubNotification(message: String) {
        twitchEventSub?.handleMessage(messageText: message)
    }

    func remoteControlStreamerChatMessages(history: Bool, messages: [RemoteControlChatMessage]) {
        let live = !history || remoteControlStreamerLatestReceivedChatMessageId != -1
        for message in messages where message.id > remoteControlStreamerLatestReceivedChatMessageId {
            appendChatMessage(platform: message.platform,
                              messageId: message.messageId,
                              displayName: message.displayName,
                              user: message.user,
                              userId: message.userId,
                              userColor: message.userColor,
                              userBadges: message.userBadges,
                              segments: message.segments,
                              timestamp: message.timestamp,
                              timestampTime: .now,
                              isAction: message.isAction,
                              isSubscriber: message.isSubscriber,
                              isModerator: message.isModerator,
                              isOwner: message.isOwner,
                              bits: message.bits,
                              highlight: nil,
                              live: live)
            remoteControlStreamerLatestReceivedChatMessageId = message.id
        }
    }

    func remoteControlStreamerStartPreview() {
        isRemoteControlAssistantRequestingPreview = true
        setLowFpsImage()
    }

    func remoteControlStreamerStopPreview() {
        isRemoteControlAssistantRequestingPreview = false
        setLowFpsImage()
    }

    func remoteControlStreamerSetRemoteSceneSettings(data: RemoteControlRemoteSceneSettings) {
        let (scenes, widgets, selectedSceneId) = data.toSettings()
        if let selectedSceneId {
            let widget = SettingsWidget(name: "")
            widget.type = .scene
            widget.scene.sceneId = selectedSceneId
            remoteSceneScenes = scenes
            remoteSceneWidgets = [widget] + widgets
            resetSelectedScene(changeScene: false)
        } else if !remoteSceneScenes.isEmpty {
            remoteSceneScenes = []
            remoteSceneWidgets = []
            resetSelectedScene(changeScene: false)
        }
    }

    func remoteControlStreamerSetRemoteSceneData(data: RemoteControlRemoteSceneData) {
        if let textStats = data.textStats {
            remoteSceneData.textStats = textStats
        }
        if let location = data.location {
            remoteSceneData.location = location
        }
    }

    func remoteControlStreamerInstantReplay() {
        instantReplay()
    }

    func remoteControlStreamerSaveReplay() {
        _ = saveReplay()
    }

    func clearRemoteSceneSettingsAndData() {
        remoteSceneScenes = []
        remoteSceneWidgets = []
        remoteSceneData.textStats = nil
        remoteSceneData.location = nil
    }

    func remoteControlStreamerStartStatus(interval: Int, filter: RemoteControlStartStatusFilter?) {
        isRemoteControlAssistantRequestingStatus = true
        remoteControlAssistantRequestingStatusFilter = filter
        // A zero or negative interval would either report every tick or never
        // report at all, and neither is what an assistant sending garbage
        // meant. One second is the fastest the status timer runs anyway.
        remoteControlAssistantRequestingStatusInterval = max(1, interval)
        remoteControlStatusSecondsSinceSent = 0
    }

    func remoteControlStreamerStopStatus() {
        isRemoteControlAssistantRequestingStatus = false
        remoteControlAssistantRequestingStatusFilter = nil
        remoteControlAssistantRequestingStatusInterval = 1
    }

    func remoteControlStreamerGetScoreboardSports() -> [String] {
        getScoreboardSports()
    }

    func remoteControlStreamerSetScoreboardSport(sportId: String) {
        handleSportSwitch(sportId: sportId)
    }

    func remoteControlStreamerUpdateScoreboard(config: RemoteControlScoreboardMatchConfig) {
        handleExternalScoreboardUpdate(config: config)
    }

    func remoteControlStreamerToggleScoreboardClock() {
        handleScoreboardToggleClock()
    }

    func remoteControlStreamerSetScoreboardDuration(minutes: Int) {
        handleScoreboardSetDuration(minutes: minutes)
    }

    func remoteControlStreamerSetScoreboardClock(time: String) {
        handleScoreboardSetClockManual(time: time)
    }

    func remoteControlStreamerWhip(url: String,
                                   method: String,
                                   headers _: [SettingsHttpHeader],
                                   body: Data,
                                   onCompleted: @escaping (Int, [SettingsHttpHeader], Data) -> Void)
    {
        guard let whipServer = ingests.whip else {
            onCompleted(500, [], Data())
            return
        }
        switch method {
        case "POST":
            guard let sdpOffer = String(bytes: body, encoding: .utf8),
                  let streamKey = url.split(separator: "/").last
            else {
                onCompleted(400, [], Data())
                return
            }
            whipServer.startClient(streamKey: String(streamKey), sdpOffer: sdpOffer) { sdpAnswer in
                DispatchQueue.main.async {
                    if let sdpAnswer {
                        onCompleted(200, [], sdpAnswer.utf8Data)
                    } else {
                        onCompleted(400, [], Data())
                    }
                }
            }
        case "DELETE":
            onCompleted(200, [], Data())
        default:
            onCompleted(400, [], Data())
        }
    }

    func remoteControlStreamerSetFilter(filter: RemoteControlFilter, on: Bool) {
        handleRemoteControlSetFilter(filter: filter, on: on)
    }

    func remoteControlStreamerTriggerReaction(reaction: RemoteControlReaction) {
        handleRemoteControlTriggerReaction(reaction: reaction)
    }

    func remoteControlStreamerMoveToGimbalPreset(id: UUID) {
        moveToGimbalPreset(id: id)
    }

    func remoteControlStreamerSetStreamProfiles(profiles: [RemoteControlStreamProfile]) -> String? {
        ctLiveSetStreamProfiles(profiles: profiles)
        return ctLiveAppliedStreamProfileId()
    }

    func remoteControlStreamerSetActiveStreamProfile(id: String) -> String? {
        ctLiveSetActiveStreamProfile(id: id)
        return ctLiveAppliedStreamProfileId()
    }

    func remoteControlStreamerSetManualSetupEnabled(enabled: Bool) {
        ctLiveSetManualSetupEnabled(enabled)
    }

    func remoteControlStreamerShowMessage(message: String, durationSeconds: Double?) -> Bool {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return false
        }
        // Clamp rather than reject. A bad number is the dashboard's mistake and
        // the operator should still get the words: too short is a flash nobody
        // can read, too long is a note stuck over the viewfinder.
        let duration = (durationSeconds ?? toastDefaultSeconds).clamped(to: 1 ... 30)
        // Deliberately no vibration. The phone is next to a live microphone.
        makeToast(title: message, durationSeconds: duration)
        // Nobody read it if the screen was off or another app was in front. Say
        // so rather than let the director assume the instruction landed.
        return UIApplication.shared.applicationState == .active
    }
}

extension Model: RemoteControlAssistantDelegate {
    func remoteControlAssistantConnected() {
        makeToast(title: String(localized: "Remote control streamer connected"))
        remoteControlAssistantStreamerState.filters = [:]
        updateRemoteControlStatus()
        updateRemoteControlAssistantStatus()
        remoteControlAssistantSetRemoteSceneSettings()
        if !remoteControlAssistantPreviewUsers.isEmpty {
            remoteControlAssistant?.startPreview()
        }
        if remoteControlAssistantStatusRequested {
            remoteControlAssistant?.startStatus()
        }
    }

    func remoteControlAssistantDisconnected() {
        makeToast(title: String(localized: "Remote control streamer disconnected"))
        remoteControl.topLeft = nil
        remoteControl.topRight = nil
        updateRemoteControlStatus()
    }

    func remoteControlAssistantStateChanged(state: RemoteControlAssistantStreamerState) {
        if let scene = state.scene {
            remoteControlAssistantStreamerState.scene = scene
            remoteControl.scene = scene
        }
        if let autoSceneSwitcher = state.autoSceneSwitcher {
            remoteControlAssistantStreamerState.autoSceneSwitcher = autoSceneSwitcher
            remoteControl.autoSceneSwitcher = autoSceneSwitcher.id
        }
        if let mic = state.mic {
            remoteControlAssistantStreamerState.mic = mic
            remoteControl.mic = mic
        }
        if let bitrate = state.bitrate {
            remoteControlAssistantStreamerState.bitrate = bitrate
            remoteControl.bitrate = bitrate
        }
        if let zoomPresets = state.zoomPresets {
            remoteControlAssistantStreamerState.zoomPresets = zoomPresets
            remoteControl.zoomPresets = zoomPresets
        }
        if let zoomPreset = state.zoomPreset {
            remoteControlAssistantStreamerState.zoomPreset = zoomPreset
            remoteControl.zoomPreset = zoomPreset
        }
        if let zoom = state.zoom {
            remoteControlAssistantStreamerState.zoom = zoom
            remoteControl.zoom = String(zoom)
        }
        if let debugLogging = state.debugLogging {
            remoteControlAssistantStreamerState.debugLogging = debugLogging
            remoteControl.debugLogging = debugLogging
        }
        if let streaming = state.streaming {
            remoteControlAssistantStreamerState.streaming = streaming
            remoteControl.streaming = streaming
        }
        if let recording = state.recording {
            remoteControlAssistantStreamerState.recording = recording
            remoteControl.recording = recording
        }
        if let muted = state.muted {
            remoteControlAssistantStreamerState.muted = muted
            remoteControl.muted = muted
        }
        if let filters = state.filters {
            for (filter, on) in filters {
                remoteControlAssistantStreamerState.filters?[filter] = on
                switch filter {
                case .pixellate:
                    remoteControl.pixellate = on
                case .movie:
                    remoteControl.movie = on
                case .grayScale:
                    remoteControl.grayScale = on
                case .sepia:
                    remoteControl.sepia = on
                case .triple:
                    remoteControl.triple = on
                case .twin:
                    remoteControl.twin = on
                case .fourThree:
                    remoteControl.fourThree = on
                case .crt:
                    remoteControl.crt = on
                case .pinch:
                    remoteControl.pinch = on
                case .whirlpool:
                    remoteControl.whirlpool = on
                case .poll:
                    remoteControl.poll = on
                case .blurFaces:
                    remoteControl.blurFaces = on
                case .privacy:
                    remoteControl.privacy = on
                case .beauty:
                    remoteControl.beauty = on
                case .moblinInMouth:
                    remoteControl.moblinInMouth = on
                case .cameraMan:
                    remoteControl.cameraMan = on
                }
            }
        }
        if isWatchRemoteControl() {
            sendRemoteControlAssistantStatusToWatch()
        }
    }

    func remoteControlAssistantPreview(preview: Data) {
        remoteControl.preview = UIImage(data: preview)
        if isWatchRemoteControl() {
            sendPreviewToWatch(image: preview)
        }
    }

    func remoteControlAssistantLog(entry: String) {
        if remoteControlAssistantLog.count > 100_000 {
            remoteControlAssistantLog.removeFirst()
        }
        logId += 1
        remoteControlAssistantLog.append(LogEntry(id: logId, message: entry))
    }

    func remoteControlAssistantStatus(general _: RemoteControlStatusGeneral?,
                                      topLeft _: RemoteControlStatusTopLeft?,
                                      topRight: RemoteControlStatusTopRight?)
    {
        if let topRight {
            remoteControl.topRight = topRight
        }
    }
}

extension Model: RemoteControlWebDelegate {
    func remoteControlWebConnected() {
        remoteControlWeb?.stateChanged(state: createRemoteControlStateChanged())
        remoteControlWeb?.sendGolfScoreboardUpdate(data: getGolfScoreboardForRemoteControl())
        let scoreboard = getEnabledScoreboardWidgetsInSelectedScene().first?.scoreboard
        remoteControlWeb?.sendScoreboardUpdate(config: getModularScoreboardConfig(scoreboard: scoreboard))
    }

    func remoteControlWebGetStatus()
        -> (RemoteControlStatusGeneral, RemoteControlStatusTopLeft, RemoteControlStatusTopRight)
    {
        remoteControlStreamerGetStatus()
    }

    func remoteControlWebGetSettings() -> RemoteControlSettings {
        handleGetSettings()
    }

    func remoteControlWebSetScene(id: UUID) {
        selectScene(id: id)
    }

    func remoteControlWebSetAutoSceneSwitcher(id: UUID?) {
        remoteControlStreamerSetAutoSceneSwitcher(id: id)
    }

    func remoteControlWebSetMic(id: String) {
        remoteControlStreamerSetMic(id: id)
    }

    func remoteControlWebSetBitratePreset(id: UUID) {
        remoteControlStreamerSetBitratePreset(id: id)
    }

    func remoteControlWebSetRecord(on: Bool) {
        remoteControlStreamerSetRecord(on: on)
    }

    func remoteControlWebSetStream(on: Bool) {
        remoteControlStreamerSetStream(on: on)
    }

    func remoteControlWebSetZoom(x: Float) {
        remoteControlStreamerSetZoom(x: x)
    }

    func remoteControlWebSetZoomPreset(id: UUID) {
        remoteControlStreamerSetZoomPreset(id: id)
    }

    func remoteControlWebSetDebugLogging(on: Bool) {
        remoteControlStreamerSetDebugLogging(on: on)
    }

    func remoteControlWebSetMute(on: Bool) {
        remoteControlStreamerSetMute(on: on)
    }

    func remoteControlWebSetTorch(on: Bool) {
        remoteControlStreamerSetTorch(on: on)
    }

    func remoteControlWebReloadBrowserWidgets() {
        reloadBrowserWidgets()
    }

    func remoteControlWebSetSrtConnectionPrioritiesEnabled(enabled: Bool) {
        remoteControlStreamerSetSrtConnectionPrioritiesEnabled(enabled: enabled)
    }

    func remoteControlWebSetSrtConnectionPriority(id: UUID, priority: Int, enabled: Bool) {
        remoteControlStreamerSetSrtConnectionPriority(id: id, priority: priority, enabled: enabled)
    }

    func remoteControlWebMoveToGimbalPreset(id: UUID) {
        remoteControlStreamerMoveToGimbalPreset(id: id)
    }

    func remoteControlWebGetScoreboardSports() -> [String] {
        getScoreboardSports()
    }

    func remoteControlWebSetScoreboardSport(sportId: String) {
        handleSportSwitch(sportId: sportId)
    }

    func remoteControlWebUpdateScoreboard(config: RemoteControlScoreboardMatchConfig) {
        handleExternalScoreboardUpdate(config: config)
    }

    func remoteControlWebToggleScoreboardClock() {
        handleScoreboardToggleClock()
    }

    func remoteControlWebSetScoreboardDuration(minutes: Int) {
        handleScoreboardSetDuration(minutes: minutes)
    }

    func remoteControlWebSetScoreboardClock(time: String) {
        handleScoreboardSetClockManual(time: time)
    }

    func remoteControlWebGetGolfScoreboard() -> RemoteControlGolfScoreboard {
        getGolfScoreboardForRemoteControl()
    }

    func remoteControlWebUpdateGolfScoreboard(data: RemoteControlGolfScoreboard) {
        handleExternalGolfScoreboardUpdate(remoteScorecard: data)
    }

    func remoteControlWebSetFilter(filter: RemoteControlFilter, on: Bool) {
        handleRemoteControlSetFilter(filter: filter, on: on)
    }

    func remoteControlWebTriggerReaction(reaction: RemoteControlReaction) {
        handleRemoteControlTriggerReaction(reaction: reaction)
    }

    func remoteControlWebGetRecordings() -> [[String: String]] {
        let directory = recordingsStorage.defaultStorageDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path())
        else {
            return []
        }
        return files
            .filter { $0.hasSuffix(".mp4") }
            .sorted(by: >)
            .map { filename in
                let url = directory.appending(component: filename)
                let size = url.fileSize
                return ["name": filename, "size": size.formatBytes()]
            }
    }

    func remoteControlWebGetRecordingThumbnail(filename: String) -> Data? {
        if let thumbnail = recordingThumbnailsCache[filename] {
            return thumbnail
        }
        let url = recordingsStorage.defaultStorageDirectory().appending(component: filename)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }
        guard let thumbnail = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) else {
            return nil
        }
        recordingThumbnailsCache[filename] = thumbnail
        return thumbnail
    }

    func remoteControlWebGetRecordingUrl(filename: String) -> URL? {
        let url = recordingsStorage.defaultStorageDirectory().appending(component: filename)
        guard url.exists() else {
            return nil
        }
        return url
    }

    func remoteControlWebDeleteRecording(filename: String) {
        let url = recordingsStorage.defaultStorageDirectory().appending(component: filename)
        try? FileManager.default.removeItem(at: url)
        recordingThumbnailsCache.removeValue(forKey: filename)
    }
}
