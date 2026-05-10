import Foundation

enum AtemControllerStatus: Equatable {
    case idle
    case connecting
    case connected
    case pushing
    case succeeded
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .connecting, .pushing: true
        default: false
        }
    }

    var description: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .connecting: String(localized: "Connecting...")
        case .connected: String(localized: "Connected")
        case .pushing: String(localized: "Pushing settings...")
        case .succeeded: String(localized: "Succeeded")
        case let .failed(reason): String(localized: "Failed: \(reason)")
        }
    }
}

protocol AtemControllerDelegate: AnyObject {
    func atemControllerStatusChanged(status: AtemControllerStatus)
}

// One controller per ATEM device. Stays alive as long as the user is doing
// something with that device — connecting, pushing, etc. After a successful
// push it stays connected briefly so we can show "Succeeded" then disconnects.
final class AtemController {
    private let host: String
    private var connection: AtemConnection?
    private(set) var status: AtemControllerStatus = .idle
    private var pendingPushCommands: [AtemCommand]?
    weak var delegate: AtemControllerDelegate?

    init(host: String) {
        self.host = host
    }

    deinit {
        connection?.stop()
    }

    func pushStream(serviceName: String, url: String, key: String) {
        let command = atemCStpCommand(serviceName: serviceName, url: url, streamKey: key)
        pendingPushCommands = [command]
        if let connection, connection.isConnected {
            sendPending()
        } else {
            connect()
        }
    }

    func disconnect() {
        connection?.stop()
        connection = nil
        update(status: .idle)
    }

    private func connect() {
        update(status: .connecting)
        let connection = AtemConnection(host: host)
        connection.delegate = self
        self.connection = connection
        connection.start()
    }

    private func sendPending() {
        guard let pendingPushCommands else { return }
        update(status: .pushing)
        connection?.send(commands: pendingPushCommands)
        // ATEM doesn't reply to CStP synchronously — it just applies the
        // settings. Give it 600ms then declare success and disconnect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if case .pushing = self.status {
                self.update(status: .succeeded)
                self.pendingPushCommands = nil
                self.connection?.stop()
                self.connection = nil
            }
        }
    }

    private func update(status: AtemControllerStatus) {
        self.status = status
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.atemControllerStatusChanged(status: status)
        }
    }
}

extension AtemController: AtemConnectionDelegate {
    func atemConnectionDidConnect() {
        update(status: .connected)
        if pendingPushCommands != nil {
            sendPending()
        }
    }

    func atemConnectionDidFail(reason: String) {
        update(status: .failed(reason))
        connection = nil
        pendingPushCommands = nil
    }

    func atemConnectionDidDisconnect() {
        if case .succeeded = status { return }
        update(status: .idle)
    }

    func atemConnectionDidReceive(commands _: [AtemCommand]) {
        // We don't currently react to incoming state — handshake/ack is enough
        // for "fire-and-forget" RTMP push. Logged at the connection layer.
    }
}
