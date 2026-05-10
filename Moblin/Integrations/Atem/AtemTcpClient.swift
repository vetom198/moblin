import Foundation
import Network

// Blackmagic ATEM Ethernet Protocol 1.0 — TCP/9993, text-based.
// Much simpler than the proprietary UDP/9910 binary control protocol:
// the switcher accepts plain commands like
//     stream start: url: rtmp://host:1935/live key: ABC123\n\n
// and replies with "200 ok" / "500 ..." status lines.
//
// We use this instead of the older CRSS write because:
//   - ATEM Mini Pro silently drops third-party CRSS writes (UDP)
//   - This protocol is the documented "remote control" path
//   - Starts streaming immediately — no need for the user to tap ON AIR
//     on the switcher front panel afterwards.

let atemTcpPort: UInt16 = 9993

enum AtemTcpResult {
    case ok
    case error(String)
}

protocol AtemTcpClientDelegate: AnyObject {
    func atemTcpClientDidConnect()
    func atemTcpClientDidFail(reason: String)
    func atemTcpClientDidReply(result: AtemTcpResult)
}

final class AtemTcpClient {
    private let host: String
    private let queue = DispatchQueue(label: "com.eerimoq.atem-tcp")
    private var connection: NWConnection?
    private var rxBuffer = Data()
    private var bannerSeen = false
    weak var delegate: AtemTcpClientDelegate?

    init(host: String) {
        self.host = host
    }

    func start() {
        queue.async {
            self.openConnection()
        }
    }

    func stop() {
        queue.async {
            self.connection?.cancel()
            self.connection = nil
        }
    }

    func send(command: String) {
        queue.async {
            guard let connection = self.connection else { return }
            let payload = command + "\n\n"
            guard let data = payload.data(using: .utf8) else { return }
            logger.info("atem-tcp: \(self.host) tx: \(command)")
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    logger.info("atem-tcp: \(self.host) send error: \(error)")
                }
            })
        }
    }

    private func openConnection() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: atemTcpPort)
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handleStateUpdate(state) }
        }
        connection.start(queue: queue)
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("atem-tcp: \(host) connected")
            startReceiveLoop()
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.atemTcpClientDidConnect()
            }
        case let .failed(error):
            logger.info("atem-tcp: \(host) NWConnection failed: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.atemTcpClientDidFail(reason: error.localizedDescription)
            }
        case .cancelled:
            break
        default:
            break
        }
    }

    private func startReceiveLoop() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    let preview = data.prefix(64).map { String(format: "%02x", $0) }.joined()
                    logger.info("atem-tcp: \(self.host) rx \(data.count) bytes: \(preview)")
                    self.rxBuffer.append(data)
                    self.parseRx()
                }
                if let error {
                    logger.info("atem-tcp: \(self.host) receive error: \(error)")
                    return
                }
                if isComplete {
                    logger.info("atem-tcp: \(self.host) receive complete")
                    return
                }
                self.startReceiveLoop()
            }
        }
    }

    // ATEM Ethernet Protocol response framing:
    //   Each response starts with a 3-digit status code line.
    //   - If the status line ends with ":", a multi-line body follows and
    //     the response terminates at the next blank line.
    //   - Otherwise the status line itself is the complete response.
    // Lines are CRLF-terminated.
    private func parseRx() {
        let crlf = Data("\r\n".utf8)
        let blank = Data("\r\n\r\n".utf8)
        while !rxBuffer.isEmpty {
            // Need at least one full line.
            guard let firstLineEnd = rxBuffer.range(of: crlf) else { return }
            let firstLineData = rxBuffer.subdata(in: 0 ..< firstLineEnd.lowerBound)
            guard let firstLine = String(data: firstLineData, encoding: .utf8) else {
                // Bad data — drop everything up through this CRLF and continue.
                rxBuffer.removeSubrange(0 ..< firstLineEnd.upperBound)
                continue
            }
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") {
                // Multi-line — wait for blank line terminator.
                guard let blankRange = rxBuffer.range(of: blank, in: firstLineEnd.lowerBound ..< rxBuffer.endIndex) else {
                    return
                }
                let blockData = rxBuffer.subdata(in: 0 ..< blankRange.lowerBound)
                rxBuffer.removeSubrange(0 ..< blankRange.upperBound)
                let block = String(data: blockData, encoding: .utf8) ?? ""
                handleResponseBlock(block)
            } else {
                // Single-line response — complete at the CRLF.
                rxBuffer.removeSubrange(0 ..< firstLineEnd.upperBound)
                handleResponseBlock(firstLine)
            }
        }
    }

    private func handleResponseBlock(_ block: String) {
        let firstLine = block.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if !bannerSeen, firstLine.hasPrefix("500 connection info") {
            bannerSeen = true
            logger.info("atem-tcp: \(host) banner received")
            return
        }
        if firstLine.hasPrefix("200 ") {
            logger.info("atem-tcp: \(host) rx: \(firstLine)")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.atemTcpClientDidReply(result: .ok)
            }
        } else {
            // Anything else is treated as an error, including "500 ..." that
            // isn't the connection-info banner.
            logger.info("atem-tcp: \(host) rx error: \(firstLine)")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.atemTcpClientDidReply(result: .error(firstLine))
            }
        }
    }
}

// Build a `stream start: ...` command for the Ethernet protocol. The URL
// and key are inserted verbatim — they're already plain ASCII for our use
// case (rtmp://ip:port/live + alphanum key), no escaping needed.
func atemStreamStartCommand(url: String, key: String) -> String {
    if key.isEmpty {
        return "stream start: url: \(url)"
    }
    return "stream start: url: \(url) key: \(key)"
}

func atemStreamStopCommand() -> String {
    "stream stop"
}
