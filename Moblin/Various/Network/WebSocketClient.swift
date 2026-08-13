import Network
import NWWebSocket
import SwiftUI

private let shortestDelayMs = 500
private let longestDelayMs = 10000

protocol WebSocketClientDelegate: AnyObject {
    func webSocketClientConnected(_ webSocket: WebSocketClient)
    func webSocketClientDisconnected(_ webSocket: WebSocketClient)
    func webSocketClientReceiveMessage(_ webSocket: WebSocketClient, string: String)
    // Lets a delegate stop the automatic reconnect when the server closed the
    // connection for a reason that reconnecting cannot fix, for example a
    // revoked credential.
    func webSocketClientShouldReconnect(_ webSocket: WebSocketClient, closeCode: UInt16) -> Bool
}

extension WebSocketClientDelegate {
    func webSocketClientShouldReconnect(_: WebSocketClient, closeCode _: UInt16) -> Bool {
        true
    }
}

final class WebSocketClient {
    private var webSocket: NWWebSocket
    private var connectTimer = SimpleTimer(queue: .main)
    private var networkInterfaceTypeSelector: NetworkInterfaceTypeSelector
    private var pingTimer = SimpleTimer(queue: .main)
    private var pongReceived = true
    var delegate: (any WebSocketClientDelegate)?
    private let url: URL
    private let loopback: Bool
    private var connected = false
    private var connectDelayMs = shortestDelayMs
    private let protocols: [String]?
    private let additionalHeaders: [(String, String)]

    init(url: URL,
         loopback: Bool = false,
         cellular: Bool = true,
         protocols: [String]? = nil,
         additionalHeaders: [(String, String)] = [])
    {
        self.url = url
        self.loopback = loopback
        self.protocols = protocols
        self.additionalHeaders = additionalHeaders
        networkInterfaceTypeSelector = NetworkInterfaceTypeSelector(queue: .main, cellular: cellular)
        webSocket = NWWebSocket(url: url, requiredInterfaceType: .cellular)
    }

    func start() {
        startInternal()
    }

    func stop() {
        stopInternal()
    }

    func isConnected() -> Bool {
        connected
    }

    func send(string: String) {
        webSocket.send(string: string)
    }

    private func startInternal() {
        stopInternal()
        if var interfaceType = networkInterfaceTypeSelector.getNextType() {
            if loopback {
                interfaceType = .loopback
            }
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            if let protocols {
                options.setSubprotocols(protocols)
            }
            // Network.framework sends no Origin header of its own. Servers that
            // validate the origin reject the handshake without one.
            if !additionalHeaders.isEmpty {
                options.setAdditionalHeaders(additionalHeaders)
            }
            webSocket = NWWebSocket(url: url,
                                    requiredInterfaceType: interfaceType,
                                    options: options)
            logger.debug("websocket: Connecting to \(url) over \(interfaceType)")
            webSocket.delegate = self
            webSocket.connect()
            startPingTimer()
        } else {
            connectDelayMs = shortestDelayMs
            startConnectTimer()
        }
    }

    private func stopInternal() {
        connected = false
        webSocket.disconnect()
        webSocket = .init(url: url, requiredInterfaceType: .cellular)
        stopConnectTimer()
        stopPingTimer()
    }

    private func startConnectTimer() {
        connected = false
        // Jitter keeps several devices coming back from the same dead spot from
        // retrying in lockstep and hammering the link the moment it returns.
        let jitter = Double.random(in: 0.8 ... 1.2)
        connectTimer.startSingleShot(timeout: jitter * Double(connectDelayMs) / 1000) { [weak self] in
            self?.startInternal()
        }
        connectDelayMs *= 2
        if connectDelayMs > longestDelayMs {
            connectDelayMs = longestDelayMs
        }
    }

    private func stopConnectTimer() {
        connectTimer.stop()
    }

    private func startPingTimer() {
        pongReceived = true
        pingTimer.startPeriodic(interval: 10, initial: 0) { [weak self] in
            guard let self else {
                return
            }
            if pongReceived {
                pongReceived = false
                webSocket.ping()
            } else {
                startInternal()
                delegate?.webSocketClientDisconnected(self)
            }
        }
    }

    private func stopPingTimer() {
        pingTimer.stop()
    }
}

extension WebSocketClient: WebSocketConnectionDelegate {
    func webSocketDidConnect(connection _: any WebSocketConnection) {
        logger.debug("websocket: Connected")
        connectDelayMs = shortestDelayMs
        stopConnectTimer()
        connected = true
        delegate?.webSocketClientConnected(self)
    }

    func webSocketDidDisconnect(connection _: any WebSocketConnection,
                                closeCode: NWProtocolWebSocket.CloseCode, reason _: Data?)
    {
        let code = Self.closeCodeValue(closeCode)
        logger.debug("websocket: Disconnected with close code \(code.map(String.init) ?? "-")")
        stopInternal()
        if let code, delegate?.webSocketClientShouldReconnect(self, closeCode: code) == false {
            logger.info("websocket: Not reconnecting after close code \(code)")
            delegate?.webSocketClientDisconnected(self)
            return
        }
        startConnectTimer()
        delegate?.webSocketClientDisconnected(self)
    }

    private static func closeCodeValue(_ closeCode: NWProtocolWebSocket.CloseCode) -> UInt16? {
        switch closeCode {
        case let .applicationCode(code):
            code
        case let .privateCode(code):
            code
        default:
            nil
        }
    }

    func webSocketViabilityDidChange(connection _: any WebSocketConnection, isViable: Bool) {
        logger.debug("websocket: Viability changed to \(isViable)")
        guard !isViable else {
            return
        }
        stopInternal()
        startConnectTimer()
        delegate?.webSocketClientDisconnected(self)
    }

    func webSocketDidAttemptBetterPathMigration(result _: Result<any WebSocketConnection, NWError>) {
        logger.debug("websocket: Better path migration")
    }

    func webSocketDidReceiveError(connection _: any WebSocketConnection, error: NWError) {
        logger.debug("websocket: Error \(error.localizedDescription)")
        let connected = connected
        stopInternal()
        startConnectTimer()
        if connected {
            delegate?.webSocketClientDisconnected(self)
        }
    }

    func webSocketDidReceivePong(connection _: any WebSocketConnection) {
        pongReceived = true
    }

    func webSocketDidReceiveMessage(connection _: any WebSocketConnection, string: String) {
        delegate?.webSocketClientReceiveMessage(self, string: string)
    }

    func webSocketDidReceiveMessage(connection _: any WebSocketConnection, data _: Data) {}
}
