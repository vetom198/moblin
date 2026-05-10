import Foundation

enum AtemControllerStatus: Equatable {
    case idle
    case connecting
    case connected
    case pushing
    case stopping
    case succeeded
    case stopped
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .connecting, .pushing, .stopping: true
        default: false
        }
    }

    var description: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .connecting: String(localized: "Connecting...")
        case .connected: String(localized: "Connected")
        case .pushing: String(localized: "Starting stream...")
        case .stopping: String(localized: "Stopping stream...")
        case .succeeded: String(localized: "Streaming")
        case .stopped: String(localized: "Stopped")
        case let .failed(reason): String(localized: "Failed: \(reason)")
        }
    }
}

protocol AtemControllerDelegate: AnyObject {
    func atemControllerStatusChanged(status: AtemControllerStatus)
    // Optional — invoked whenever the controller learns the active
    // streaming destination on the switcher (e.g. after a successful
    // start command that echoes back the parameters).
    func atemControllerDidReadStreamingService(serviceName: String, url: String)
}

extension AtemControllerDelegate {
    func atemControllerDidReadStreamingService(serviceName _: String, url _: String) {}
}

// One controller per ATEM device. Talks to the switcher over the
// documented Blackmagic Ethernet Protocol on TCP/9993 (text-based) —
// strictly more reliable than the proprietary UDP/9910 control protocol
// for third-party clients.
//
// The "push" operation issues `stream start: url: ... key: ...`, which
// causes the switcher to begin live-streaming to the supplied RTMP
// destination immediately. There is no separate "save destination" step;
// to retarget the stream the user just pushes again with new values.
enum AtemControllerAction {
    case startStream(serviceName: String, url: String, key: String)
    case stopStream
}

final class AtemController {
    private let host: String
    private var client: AtemTcpClient?
    private(set) var status: AtemControllerStatus = .idle
    private var pendingAction: AtemControllerAction?
    private var hasRetriedStart = false
    weak var delegate: AtemControllerDelegate?

    init(host: String) {
        self.host = host
    }

    deinit {
        client?.stop()
    }

    func pushStream(serviceName: String, url: String, key: String) {
        logger.info("atem: pushStream host=\(host) name=\(serviceName) url=\(url) key=\(key.isEmpty ? "(empty)" : "***")")
        pendingAction = .startStream(serviceName: serviceName, url: url, key: key)
        hasRetriedStart = false
        connect()
    }

    func stopStream() {
        logger.info("atem: stopStream host=\(host)")
        pendingAction = .stopStream
        connect()
    }

    func disconnect() {
        client?.stop()
        client = nil
        update(status: .idle)
    }

    private func connect() {
        update(status: .connecting)
        let client = AtemTcpClient(host: host)
        client.delegate = self
        self.client = client
        client.start()
    }

    private func sendPending() {
        guard let pendingAction else { return }
        switch pendingAction {
        case let .startStream(_, url, key):
            update(status: .pushing)
            client?.send(command: atemStreamStartCommand(url: url, key: key))
        case .stopStream:
            update(status: .stopping)
            client?.send(command: atemStreamStopCommand())
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

extension AtemController: AtemTcpClientDelegate {
    func atemTcpClientDidConnect() {
        update(status: .connected)
        sendPending()
    }

    func atemTcpClientDidFail(reason: String) {
        update(status: .failed(reason))
        client = nil
        pendingAction = nil
        hasRetriedStart = false
    }

    func atemTcpClientDidReply(result: AtemTcpResult) {
        let action = pendingAction
        switch result {
        case .ok:
            switch action {
            case let .startStream(name, url, _):
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.atemControllerDidReadStreamingService(serviceName: name, url: url)
                }
                update(status: .succeeded)
            case .stopStream:
                update(status: .stopped)
            case .none:
                break
            }
            pendingAction = nil
            hasRetriedStart = false
        case let .error(reason):
            // ATEM returns "150 invalid state" if a stream is already
            // running and we try to start a new one. Auto-recover: send
            // stop, wait briefly, retry start once. Surface other errors
            // straight to the user.
            if case let .startStream(name, url, key) = action,
               !hasRetriedStart,
               reason.contains("invalid state")
            {
                logger.info("atem: \(host) start rejected (invalid state) — issuing stop+restart")
                hasRetriedStart = true
                pendingAction = nil
                update(status: .stopping)
                client?.send(command: atemStreamStopCommand())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    self.pendingAction = .startStream(serviceName: name, url: url, key: key)
                    self.update(status: .pushing)
                    self.client?.send(command: atemStreamStartCommand(url: url, key: key))
                }
                return
            }
            update(status: .failed(reason))
            pendingAction = nil
            hasRetriedStart = false
        }
        // Brief delay so the success state shows in the UI before we drop
        // the connection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.client?.stop()
            self?.client = nil
        }
    }
}
