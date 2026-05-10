import Foundation
import Network

protocol AtemConnectionDelegate: AnyObject {
    func atemConnectionDidConnect()
    func atemConnectionDidFail(reason: String)
    func atemConnectionDidDisconnect()
    func atemConnectionDidReceive(commands: [AtemCommand])
}

// The 20-byte hello packet exactly as Sofie's libatem-connection sends it.
// The header is fixed: flag=Hello (0x02 in upper 5 bits) + length 20 ->
// 0x1014, sessionId 0x53AB (any non-zero will do — server reassigns), and
// the 0x003A at offset 8..9 is interpreted as a client-capability /
// protocol-version marker; without it ATEM has been observed to accept
// the handshake but silently drop subsequent control writes (CRSS etc).
private let atemHelloFullPacket = Data([
    0x10, 0x14, 0x53, 0xab, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3a, 0x00, 0x00,
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
    private var initComplete = false

    init(host: String, port: UInt16 = atemUdpPort) {
        self.host = host
        self.port = port
        // Start packet id at a random non-trivial value. ATEM seems to
        // reuse session ids across short-lived UDP connections, and if we
        // start at 1 every time the switcher may treat our first packet
        // as a duplicate of an already-acknowledged one and drop it.
        localPacketIdCounter = UInt16.random(in: 1024 ... 32_000)
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
            guard self.isConnected else {
                logger.info("atem: send skipped — not connected (isConnected=false)")
                return
            }
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
            let opcodes = commands.map(\.opcode).joined(separator: ",")
            logger.info("atem: \(self.host) tx packetId=\(self.localPacketIdCounter) opcodes=\(opcodes) bytes=\(pkt.serialize().count)")
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
        // Send the exact 20-byte buffer Sofie's libatem-connection uses;
        // bypass our regular packet builder so the 0x003A at offset 8..9
        // (a client-capability marker on hello packets only) lands intact.
        sessionId = 0x53ab
        guard let connection else { return }
        connection.send(content: atemHelloFullPacket, completion: .contentProcessed { error in
            if let error {
                logger.info("atem: \(self.host) hello send error: \(error)")
            }
        })
        logger.info("atem: \(host) -> Hello (Sofie-format, 20 bytes)")
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
        // Hello reply: server has assigned the real session id.
        if packet.flags.contains(.helloPacket) {
            sessionId = packet.sessionId
            // ACK the hello-reply.
            let ack = AtemPacket(
                flags: [.ack],
                sessionId: sessionId,
                ackPacketId: packet.packetId
            )
            sendRaw(ack)
            // Note: we don't fire didConnect yet — we wait for InCm so the
            // delegate only sends control commands after ATEM finishes its
            // initial state dump. CRSS sent before InCm is silently dropped.
            handshakeTimer?.cancel()
            startPingTimer()
            logger.info("atem: \(host) handshake ack (session=\(sessionId)), waiting for InCm")
            return
        }
        // Server's ACK of one of our packets.
        if packet.flags.contains(.ack) {
            logger.info("atem: \(host) rx ACK of packetId=\(packet.ackPacketId)")
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
            // Watch for InCm — ATEM's "init complete" marker. Until we see it
            // ATEM ignores our control commands (CRSS etc).
            if !initComplete, commands.contains(where: { $0.opcode == "InCm" }) {
                initComplete = true
                isConnected = true
                logger.info("atem: \(host) InCm received — sending 0x61 ack + settling 100ms")
                // After init complete, send the "ready to write" marker:
                // an ACK whose retransmit-id field carries the constant
                // 0x0061. Some third-party reverse-engineering reports
                // claim this is what flips the switcher into a state that
                // accepts CRSS / other write commands; without it the
                // session stays in passive-monitoring mode.
                let readyAck = AtemPacket(
                    flags: [.ack],
                    sessionId: sessionId,
                    ackPacketId: lastReceivedPacketId,
                    retransmitPacketId: 0x0061
                )
                sendRaw(readyAck)
                // Settling delay: ATEM may keep streaming trailing state
                // (camera control, audio params) right after InCm. Issuing
                // a write right now risks colliding with that processing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.delegate?.atemConnectionDidConnect()
                }
            }
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
        initComplete = false
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
