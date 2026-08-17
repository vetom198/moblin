import Foundation
import Network
import SwiftUI

protocol RemoteControlStreamerDelegate: AnyObject {
    func remoteControlStreamerConnected()
    func remoteControlStreamerDisconnected()
    func remoteControlStreamerGetStatus()
        -> (RemoteControlStatusGeneral, RemoteControlStatusTopLeft, RemoteControlStatusTopRight)
    func remoteControlStreamerGetSettings() -> RemoteControlSettings
    func remoteControlStreamerSetScene(id: UUID)
    func remoteControlStreamerSetAutoSceneSwitcher(id: UUID?)
    func remoteControlStreamerSetMic(id: String)
    func remoteControlStreamerSetBitratePreset(id: UUID)
    func remoteControlStreamerSetRecord(on: Bool)
    func remoteControlStreamerSetStream(on: Bool)
    func remoteControlStreamerSetDebugLogging(on: Bool)
    func remoteControlStreamerSetZoom(x: Float)
    func remoteControlStreamerSetZoomPreset(id: UUID)
    func remoteControlStreamerSetMute(on: Bool)
    func remoteControlStreamerSetTorch(on: Bool)
    func remoteControlStreamerReloadBrowserWidgets()
    func remoteControlStreamerSetSrtConnectionPriority(id: UUID, priority: Int, enabled: Bool)
    func remoteControlStreamerSetSrtConnectionPrioritiesEnabled(enabled: Bool)
    func remoteControlStreamerTwitchEventSubNotification(message: String)
    func remoteControlStreamerChatMessages(history: Bool, messages: [RemoteControlChatMessage])
    func remoteControlStreamerStartPreview()
    func remoteControlStreamerStopPreview()
    func remoteControlStreamerSetRemoteSceneSettings(data: RemoteControlRemoteSceneSettings)
    func remoteControlStreamerSetRemoteSceneData(data: RemoteControlRemoteSceneData)
    func remoteControlStreamerInstantReplay()
    func remoteControlStreamerSaveReplay()
    func remoteControlStreamerStartStatus(interval: Int, filter: RemoteControlStartStatusFilter?)
    func remoteControlStreamerStopStatus()
    func remoteControlStreamerGetScoreboardSports() -> [String]
    func remoteControlStreamerSetScoreboardSport(sportId: String)
    func remoteControlStreamerUpdateScoreboard(config: RemoteControlScoreboardMatchConfig)
    func remoteControlStreamerToggleScoreboardClock()
    func remoteControlStreamerSetScoreboardDuration(minutes: Int)
    func remoteControlStreamerSetScoreboardClock(time: String)
    func remoteControlStreamerWhip(url: String,
                                   method: String,
                                   headers: [SettingsHttpHeader],
                                   body: Data,
                                   onCompleted: @escaping (Int, [SettingsHttpHeader], Data) -> Void)
    func remoteControlStreamerSetFilter(filter: RemoteControlFilter, on: Bool)
    func remoteControlStreamerTriggerReaction(reaction: RemoteControlReaction)
    func remoteControlStreamerMoveToGimbalPreset(id: UUID)
    // Both return the profile the phone is actually streaming to afterwards.
    func remoteControlStreamerSetStreamProfiles(profiles: [RemoteControlStreamProfile]) -> String?
    func remoteControlStreamerSetActiveStreamProfile(id: String) -> String?
    func remoteControlStreamerSetManualSetupEnabled(enabled: Bool)
    // Returns whether the screen was actually in front of somebody.
    func remoteControlStreamerShowMessage(message: String, durationSeconds: Double?) -> Bool
}

// Close codes the server uses to say "do not come back with this". Reconnecting
// cannot fix any of them, so the streamer stops instead of hot looping.
let remoteControlCredentialRevokedCloseCode: UInt16 = 4001
let remoteControlNotAuthorizedCloseCode: UInt16 = 4004
private let pongDeadlineSeconds = 10.0
// How long a freshly built connection is left alone to finish its handshake.
private let handshakeGraceSeconds = 10

private let remoteControlTerminalCloseCodes: Set<UInt16> = [
    remoteControlCredentialRevokedCloseCode,
    remoteControlNotAuthorizedCloseCode,
]

class RemoteControlStreamer {
    private var clientUrl: URL
    private var password: String
    private weak var delegate: (any RemoteControlStreamerDelegate)?
    private var webSocket: WebSocketClient
    var connectionErrorMessage: String = ""
    private var connected = false
    private var encryption: RemoteControlEncryption
    private let keepAliveTimer = SimpleTimer(queue: .main)
    private let pongDeadlineTimer = SimpleTimer(queue: .main)
    private var gotPong = true
    // Only used to make the log say how long a connection lasted before it was
    // torn down. Bringing up an assistant is a lot easier when the log
    // distinguishes "died after 30 s" from "never got anywhere".
    private var connectedAt: ContinuousClock.Instant?
    private let createdAt = ContinuousClock.now
    private let additionalHeaders: [(String, String)]
    private let onTerminalClose: ((UInt16) -> Void)?
    private let reconnectDelaysMs: (shortest: Int, longest: Int)?
    @AppStorage("remoteControlStreamerId") var id = ""

    init(clientUrl: URL,
         password: String,
         delegate: any RemoteControlStreamerDelegate,
         additionalHeaders: [(String, String)] = [],
         reconnectDelaysMs: (shortest: Int, longest: Int)? = nil,
         onTerminalClose: ((UInt16) -> Void)? = nil)
    {
        self.clientUrl = clientUrl
        self.password = password
        self.delegate = delegate
        self.additionalHeaders = additionalHeaders
        self.reconnectDelaysMs = reconnectDelaysMs
        self.onTerminalClose = onTerminalClose
        encryption = RemoteControlEncryption(password: password)
        webSocket = .init(url: clientUrl, additionalHeaders: additionalHeaders)
        if id.isEmpty {
            id = UUID().uuidString
        }
    }

    private func makeWebSocket() -> WebSocketClient {
        guard let reconnectDelaysMs else {
            return .init(url: clientUrl, additionalHeaders: additionalHeaders)
        }
        return .init(url: clientUrl,
                     additionalHeaders: additionalHeaders,
                     shortestReconnectDelayMs: reconnectDelaysMs.shortest,
                     longestReconnectDelayMs: reconnectDelaysMs.longest)
    }

    func start() {
        logger.debug("remote-control-streamer: start")
        startInternal()
    }

    func stop() {
        logger.debug("remote-control-streamer: stop")
        stopInternal()
    }

    private func startInternal() {
        stopInternal()
        gotPong = true
        webSocket = makeWebSocket()
        webSocket.delegate = self
        webSocket.start()
    }

    func stopInternal() {
        connected = false
        webSocket.stop()
        stopKeepAlive()
    }

    func isConnected() -> Bool {
        connected
    }

    // Lets a caller keep a healthy connection instead of rebuilding an
    // identical one. Everything that reloads the app's outgoing connections
    // funnels through one place, so without this a stream switch or a pairing
    // check drops the director.
    func isConfigured(clientUrl: URL, password: String) -> Bool {
        self.clientUrl == clientUrl && self.password == password
    }

    // A connection that was built moments ago and is still shaking hands counts
    // as healthy for the purpose of not rebuilding it. Without this a second
    // caller arriving during the handshake tears down a connection that was
    // about to succeed, which the assistant sees as a stub that dies before it
    // identifies. The watchdog is unaffected: it only steps in after 30 s down,
    // by which time this window is long closed.
    func isSettlingIn() -> Bool {
        createdAt.duration(to: .now) < .seconds(handshakeGraceSeconds)
    }

    func stateChanged(state: RemoteControlAssistantStreamerState) {
        guard connected else {
            return
        }
        send(message: .event(data: .state(data: state)))
    }

    func log(entry: String) {
        guard connected else {
            return
        }
        send(message: .event(data: .log(entry: entry)))
    }

    func sendScoreboardUpdate(config: RemoteControlScoreboardMatchConfig) {
        send(message: .event(data: .scoreboard(config: config)))
    }

    func sendPreview(preview: Data) {
        send(message: .preview(preview: preview))
    }

    func sendStatus(
        general: RemoteControlStatusGeneral?,
        topLeft: RemoteControlStatusTopLeft?,
        topRight: RemoteControlStatusTopRight?
    ) {
        send(message: .event(data: .status(general: general, topLeft: topLeft, topRight: topRight)))
    }

    func twitchStart(channelName: String?, channelId: String, accessToken: String) {
        guard connected else {
            return
        }
        guard let accessToken = encryption.encrypt(data: accessToken.utf8Data)?.base64EncodedString() else {
            return
        }
        send(message: .twitchStart(channelName: channelName, channelId: channelId, accessToken: accessToken))
    }

    private func startKeepAlive() {
        // Ping early and often. A proxy or server idle timeout that only counts
        // data frames will drop a connection that is merely quiet, and the first
        // ping arriving at 30 s is too late to prove otherwise.
        keepAliveTimer.startPeriodic(interval: 15, initial: 5) { [weak self] in
            self?.sendPing()
        }
    }

    private func sendPing() {
        gotPong = false
        send(message: .ping)
        // On a mobile network a half open connection can sit there for minutes
        // without an error, and the director would be controlling nothing. Give
        // the pong a hard deadline instead of waiting for the next ping.
        pongDeadlineTimer.startSingleShot(timeout: pongDeadlineSeconds) { [weak self] in
            guard let self, !gotPong else {
                return
            }
            logger.info("""
            remote-control-streamer: Nothing received in \(Int(pongDeadlineSeconds)) s after a ping, \
            reconnecting \(elapsedSinceConnectText())
            """)
            startInternal()
        }
    }

    // Any frame from the assistant proves the connection is alive, so treat it
    // like a pong. The half open connection this deadline exists to catch
    // delivers nothing at all, and an assistant that does not implement the
    // application level ping/pong must not be mistaken for one.
    private func noteAssistantIsAlive() {
        gotPong = true
        pongDeadlineTimer.stop()
    }

    private func elapsedSinceConnectText() -> String {
        guard let connectedAt else {
            return "(never connected)"
        }
        return "after \(connectedAt.duration(to: .now).components.seconds) s connected"
    }

    private func stopKeepAlive() {
        keepAliveTimer.stop()
        pongDeadlineTimer.stop()
    }

    private func send(message: RemoteControlMessageToAssistant) {
        do {
            let message = try message.toJson()
            webSocket.send(string: message)
        } catch {
            logger.info("remote-control-streamer: Encode failed")
        }
    }

    private func handleMessage(message: String) throws {
        do {
            switch try RemoteControlMessageToStreamer.fromJson(data: message) {
            case let .hello(apiVersion: apiVersion, authentication: authentication):
                handleHello(apiVersion: apiVersion, authentication: authentication)
            case let .identified(result: result):
                if !handleIdentified(result: result) {
                    logger.debug("remote-control-streamer: Failed to identify")
                    return
                }
            case let .request(id: id, data: data):
                handleRequest(id: id, data: data)
            case .pong:
                noteAssistantIsAlive()
            }
        } catch {
            // Log the message itself. "Decode failed" on its own is useless when
            // bringing up a new assistant implementation. Redact first: an
            // undecodable message is exactly the case where we do not know what
            // is in it, and stream keys must never reach the log.
            let redacted = redactSensitiveJsonValues(message).prefix(300)
            logger.info("remote-control-streamer: Decode failed for \(redacted): \(error)")
            connectionErrorMessage = error.localizedDescription
        }
    }

    private func handleHello(apiVersion _: String, authentication: RemoteControlAuthentication) {
        let hash = remoteControlHashPassword(
            challenge: authentication.challenge,
            salt: authentication.salt,
            password: password
        )
        send(message: .identify(streamerId: id, authentication: hash))
    }

    private func handleIdentified(result: RemoteControlResult) -> Bool {
        switch result {
        case .ok:
            logger.info("remote-control-streamer: Identified")
            connected = true
            delegate?.remoteControlStreamerConnected()
            return true
        case .wrongPassword:
            connectionErrorMessage = "Wrong password"
        default:
            connectionErrorMessage = "Failed to identify"
        }
        // Without this the streamer stays silent forever: periodic status is
        // only sent once identified, so a rejected identify looks exactly like
        // a connected but mute app from the assistant's side.
        logger.info("remote-control-streamer: Not identified: \(connectionErrorMessage)")
        return false
    }

    private func handleRequest(id: Int, data: RemoteControlRequest) {
        guard let delegate else {
            return
        }
        switch data {
        case .getStatus:
            let (general, topLeft, topRight) = delegate.remoteControlStreamerGetStatus()
            send(message: .response(
                id: id,
                result: .ok,
                data: .getStatus(general: general, topLeft: topLeft, topRight: topRight)
            ))
        case .getSettings:
            let data = delegate.remoteControlStreamerGetSettings()
            send(message: .response(id: id, result: .ok, data: .getSettings(data: data)))
        case let .setScene(id: sceneId):
            delegate.remoteControlStreamerSetScene(id: sceneId)
            sendEmptyOkResponse(id: id)
        case let .setAutoSceneSwitcher(id: autoSceneSwitcherId):
            delegate.remoteControlStreamerSetAutoSceneSwitcher(id: autoSceneSwitcherId)
            sendEmptyOkResponse(id: id)
        case let .setMic(id: micId):
            delegate.remoteControlStreamerSetMic(id: micId)
            sendEmptyOkResponse(id: id)
        case let .setBitratePreset(id: bitratePresetId):
            delegate.remoteControlStreamerSetBitratePreset(id: bitratePresetId)
            sendEmptyOkResponse(id: id)
        case let .setRecord(on: on):
            delegate.remoteControlStreamerSetRecord(on: on)
            sendEmptyOkResponse(id: id)
        case let .setStream(on: on):
            delegate.remoteControlStreamerSetStream(on: on)
            sendEmptyOkResponse(id: id)
        case let .setZoom(x: x):
            delegate.remoteControlStreamerSetZoom(x: x)
            sendEmptyOkResponse(id: id)
        case let .setZoomPreset(id: presetId):
            delegate.remoteControlStreamerSetZoomPreset(id: presetId)
            sendEmptyOkResponse(id: id)
        case let .setMute(on: on):
            delegate.remoteControlStreamerSetMute(on: on)
            sendEmptyOkResponse(id: id)
        case let .setTorch(on: on):
            delegate.remoteControlStreamerSetTorch(on: on)
            sendEmptyOkResponse(id: id)
        case .reloadBrowserWidgets:
            delegate.remoteControlStreamerReloadBrowserWidgets()
            sendEmptyOkResponse(id: id)
        case let .setSrtConnectionPriority(id: priorityId, priority: priority, enabled: enabled):
            delegate.remoteControlStreamerSetSrtConnectionPriority(
                id: priorityId,
                priority: priority,
                enabled: enabled
            )
            sendEmptyOkResponse(id: id)
        case let .setSrtConnectionPrioritiesEnabled(enabled: enabled):
            delegate.remoteControlStreamerSetSrtConnectionPrioritiesEnabled(enabled: enabled)
            sendEmptyOkResponse(id: id)
        case let .twitchEventSubNotification(message: message):
            delegate.remoteControlStreamerTwitchEventSubNotification(message: message)
            sendEmptyOkResponse(id: id)
        case let .chatMessages(history: history, messages: messages):
            delegate.remoteControlStreamerChatMessages(history: history, messages: messages)
            sendEmptyOkResponse(id: id)
        case .startPreview:
            delegate.remoteControlStreamerStartPreview()
            sendEmptyOkResponse(id: id)
        case .stopPreview:
            delegate.remoteControlStreamerStopPreview()
            sendEmptyOkResponse(id: id)
        case let .setDebugLogging(on: on):
            delegate.remoteControlStreamerSetDebugLogging(on: on)
            sendEmptyOkResponse(id: id)
        case let .setRemoteSceneSettings(data: data):
            delegate.remoteControlStreamerSetRemoteSceneSettings(data: data)
            sendEmptyOkResponse(id: id)
        case let .setRemoteSceneData(data: data):
            delegate.remoteControlStreamerSetRemoteSceneData(data: data)
            sendEmptyOkResponse(id: id)
        case .instantReplay:
            delegate.remoteControlStreamerInstantReplay()
            sendEmptyOkResponse(id: id)
        case .saveReplay:
            delegate.remoteControlStreamerSaveReplay()
            sendEmptyOkResponse(id: id)
        case let .startStatus(interval: interval, filter: filter):
            delegate.remoteControlStreamerStartStatus(interval: interval, filter: filter)
            sendEmptyOkResponse(id: id)
        case .stopStatus:
            delegate.remoteControlStreamerStopStatus()
            sendEmptyOkResponse(id: id)
        case .getScoreboardSports:
            let sports = delegate.remoteControlStreamerGetScoreboardSports()
            send(message: .response(id: id,
                                    result: .ok,
                                    data: .getScoreboardSports(names: sports)))
        case let .setScoreboardSport(sportId):
            delegate.remoteControlStreamerSetScoreboardSport(sportId: sportId)
            sendEmptyOkResponse(id: id)
        case let .updateScoreboard(config):
            delegate.remoteControlStreamerUpdateScoreboard(config: config)
            sendEmptyOkResponse(id: id)
        case .toggleScoreboardClock:
            delegate.remoteControlStreamerToggleScoreboardClock()
            sendEmptyOkResponse(id: id)
        case let .setScoreboardDuration(minutes):
            delegate.remoteControlStreamerSetScoreboardDuration(minutes: minutes)
            sendEmptyOkResponse(id: id)
        case let .setScoreboardClock(time):
            delegate.remoteControlStreamerSetScoreboardClock(time: time)
            sendEmptyOkResponse(id: id)
        case let .whip(url: url, method: method, headers: headers, body: body):
            delegate
                .remoteControlStreamerWhip(url: url, method: method, headers: headers,
                                           body: body)
                { status, headers, body in
                    self.send(message: .response(id: id,
                                                 result: .ok,
                                                 data: .whip(status: status, headers: headers, body: body)))
                }
        case let .setFilter(filter: filter, on: on):
            delegate.remoteControlStreamerSetFilter(filter: filter, on: on)
            sendEmptyOkResponse(id: id)
        case let .triggerReaction(reaction: reaction):
            delegate.remoteControlStreamerTriggerReaction(reaction: reaction)
            sendEmptyOkResponse(id: id)
        case let .moveToGimbalPreset(id: presetId):
            delegate.remoteControlStreamerMoveToGimbalPreset(id: presetId)
            sendEmptyOkResponse(id: id)
        case .getGolfScoreboard:
            sendEmptyOkResponse(id: id)
        case .updateGolfScoreboard:
            sendEmptyOkResponse(id: id)
        case let .setStreamProfiles(profiles: profiles):
            let appliedId = delegate.remoteControlStreamerSetStreamProfiles(profiles: profiles)
            send(message: .response(id: id, result: .ok, data: .setStreamProfiles(appliedId: appliedId)))
        case let .setActiveStreamProfile(id: profileId):
            let appliedId = delegate.remoteControlStreamerSetActiveStreamProfile(id: profileId)
            send(message: .response(id: id, result: .ok, data: .setStreamProfiles(appliedId: appliedId)))
        case let .setManualSetupEnabled(enabled: enabled):
            delegate.remoteControlStreamerSetManualSetupEnabled(enabled: enabled)
            sendEmptyOkResponse(id: id)
        case let .showMessage(message: message, durationSeconds: durationSeconds):
            let displayed = delegate.remoteControlStreamerShowMessage(
                message: message,
                durationSeconds: durationSeconds
            )
            send(message: .response(id: id, result: .ok, data: .showMessage(displayed: displayed)))
        }
    }

    private func sendEmptyOkResponse(id: Int) {
        send(message: .response(id: id, result: .ok, data: nil))
    }
}

extension RemoteControlStreamer: WebSocketClientDelegate {
    func webSocketClientConnected(_: WebSocketClient) {
        logger.info("remote-control-streamer: Connected")
        connectedAt = .now
        startKeepAlive()
    }

    func webSocketClientDisconnected(_: WebSocketClient) {
        logger.info("remote-control-streamer: Disconnected \(elapsedSinceConnectText())")
        connectedAt = nil
        stopKeepAlive()
        if connected {
            delegate?.remoteControlStreamerDisconnected()
        }
        connected = false
        connectionErrorMessage = String(localized: "Disconnected")
    }

    func webSocketClientReceiveMessage(_: WebSocketClient, string: String) {
        noteAssistantIsAlive()
        try? handleMessage(message: string)
    }

    func webSocketClientShouldReconnect(_: WebSocketClient, closeCode: UInt16) -> Bool {
        guard remoteControlTerminalCloseCodes.contains(closeCode) else {
            return true
        }
        logger.info("remote-control-streamer: Server closed with \(closeCode), not reconnecting")
        connectionErrorMessage = closeCode == remoteControlCredentialRevokedCloseCode
            ? String(localized: "Control credential revoked")
            : String(localized: "Remote control not authorized")
        onTerminalClose?(closeCode)
        return false
    }
}
