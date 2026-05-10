import Foundation
import Network

protocol AtemConnectionDelegate: AnyObject {
    func atemConnectionDidConnect()
    func atemConnectionDidFail(reason: String)
    func atemConnectionDidDisconnect()
    func atemConnectionDidReceive(commands: [AtemCommand])
}

private let atemHelloPayload = Data([
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
])
private let atemQueueLabel = "com.eerimoq.atem"
private let atemHandshakeTimeout: TimeInterval = 3.0
private let atemPingInterval: TimeInterval = 0.5

// Single-ATEM UDP transport. Owns handshake, ACKs incoming server packets,
// pings periodically, and surfaces decoded commands to the delegate.
final class AtemConnection {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: atemQueueLabel)
    private var connection: NWConnection?
    weak var delegate: AtemConnectionDelegate?
    private(set) var isConnected = false
    private var sessionId: UInt16 = 0
    private var localPacketIdCounter: UInt16 = 0
    private var receiveLoopRunning = false
    private var handshakeTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var lastReceivedPacketId: UInt16 = 0

    init(host: String, port: UInt16 = atemUdpPort) {
        self.host = host
        self.port = port
    }

    func start() {
        queue.async {
            self.connectInternal()
        }
    }

    func stop() {
        queue.async {
            self.stopInternal(notify: false)
        }
    }

    func send(commands: [AtemCommand]) {
        queue.async {
            guard self.isConnected else { return }
            var payload = Data()
            for command in commands {
                payload.append(command.serialize())
            }
            self.localPacketIdCounter &+= 1
            let pkt = AtemPacket(
                flags: [.ackRequest],
                sessionId: self.sessionId,
                packetId: self.localPacketIdCounter,
                payload: payload
            )
            self.sendRaw(pkt)
        }
    }

    private func connectInternal() {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(integerLiteral: port)
        let endpoint = NWEndpoint.hostPort(host: nwHost, port: nwPort)
        let parameters = NWParameters.udp
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                self?.handleStateUpdate(state)
            }
        }
        receiveLoopRunning = true
        connection.start(queue: queue)
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            startReceiveLoop()
            sendHello()
            scheduleHandshakeTimeout()
        case let .failed(error):
            failConnection(reason: "NWConnection failed: \(error.localizedDescription)")
        case .cancelled:
            if isConnected || receiveLoopRunning {
                disconnect(notify: true)
            }
        default:
            break
        }
    }

    private func sendHello() {
        // First Hello: session id is essentially arbitrary on client side; many
        // ATEM implementations use a small random value. Server will assign the
        // real session id in its reply.
        sessionId = UInt16.random(in: 0x0001 ... 0x7FFF)
        let pkt = AtemPacket(
            flags: [.helloPacket],
            sessionId: sessionId,
            payload: atemHelloPayload
        )
        sendRaw(pkt)
        logger.info("atem: \(host) -> Hello (session=\(sessionId))")
    }

    private func scheduleHandshakeTimeout() {
        handshakeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + atemHandshakeTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.isConnected {
                self.failConnection(reason: "Handshake timeout")
            }
        }
        timer.resume()
        handshakeTimer = timer
    }

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + atemPingInterval, repeating: atemPingInterval)
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        timer.resume()
        pingTimer = timer
    }

    private func sendPing() {
        guard isConnected else { return }
        // Empty AckRequest packet with incremented id.
        localPacketIdCounter &+= 1
        let pkt = AtemPacket(
            flags: [.ackRequest],
            sessionId: sessionId,
            packetId: localPacketIdCounter
        )
        sendRaw(pkt)
    }

    private func sendRaw(_ packet: AtemPacket) {
        guard let connection else { return }
        let data = packet.serialize()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                logger.info("atem: \(self.host) send error: \(error)")
            }
        })
    }

    private func startReceiveLoop() {
        guard let connection else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                self.handleReceived(data: data, error: error)
            }
        }
    }

    private func handleReceived(data: Data?, error: NWError?) {
        if let error {
            logger.info("atem: \(host) receive error: \(error)")
        }
        if let data, let pkt = AtemPacket.parse(data) {
            handleIncoming(packet: pkt)
        }
        if receiveLoopRunning {
            startReceiveLoop()
        }
    }

    private func handleIncoming(packet: AtemPacket) {
        // Hello reply finalises the session.
        if packet.flags.contains(.helloPacket) {
            sessionId = packet.sessionId
            // ACK the hello-reply.
            let ack = AtemPacket(
                flags: [.ack],
                sessionId: sessionId,
                ackPacketId: packet.packetId
            )
            sendRaw(ack)
            if !isConnected {
                isConnected = true
                handshakeTimer?.cancel()
                startPingTimer()
                logger.info("atem: \(host) connected (session=\(sessionId))")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.atemConnectionDidConnect()
                }
            }
            return
        }
        // Server sent commands and asked us to ACK.
        if packet.flags.contains(.ackRequest) {
            lastReceivedPacketId = packet.packetId
            let ack = AtemPacket(
                flags: [.ack],
                sessionId: sessionId,
                ackPacketId: packet.packetId
            )
            sendRaw(ack)
        }
        if !packet.payload.isEmpty {
            let commands = AtemCommand.parseAll(packet.payload)
            if !commands.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.atemConnectionDidReceive(commands: commands)
                }
            }
        }
    }

    private func failConnection(reason: String) {
        logger.info("atem: \(host) failed: \(reason)")
        let wasConnected = isConnected
        disconnect(notify: false)
        DispatchQueue.main.async { [weak self] in
            if wasConnected {
                self?.delegate?.atemConnectionDidDisconnect()
            } else {
                self?.delegate?.atemConnectionDidFail(reason: reason)
            }
        }
    }

    private func disconnect(notify: Bool) {
        receiveLoopRunning = false
        handshakeTimer?.cancel()
        handshakeTimer = nil
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        let wasConnected = isConnected
        isConnected = false
        if notify, wasConnected {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.atemConnectionDidDisconnect()
            }
        }
    }

    private func stopInternal(notify: Bool) {
        disconnect(notify: notify)
    }
}
