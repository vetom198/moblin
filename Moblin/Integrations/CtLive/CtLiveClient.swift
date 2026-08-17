import Foundation

// Client for the CTLive live tracking backend (https://live.ctyeh.com).
//
// Two endpoint families are used:
//
//  - Device pairing, which binds this device to a CTLive account once, using a
//    six digit code the user generates in the CTLive web backend. No API key.
//  - Device data, a "latest snapshot" upload (last write wins) that the race
//    broadcast dashboard reads.
//
// The unit contract is easy to get wrong and silently produces wrong numbers on
// the broadcast overlay, so it is spelled out on CtLiveDataPayload below.

let ctLiveDefaultBaseUrl = "https://live.ctyeh.com"

enum CtLiveRideStatus: String {
    case recording = "Recording"
    case paused = "Paused"
    case stopped = "Stopped"
}

struct CtLiveDataPayload: Encodable {
    // Milliseconds since epoch. Seconds makes the backend show a time 1000x off.
    let timestamp: Int64
    let deviceId: String
    let deviceUid: String
    let profileName: String
    let rideStatus: String
    let latitude: Double
    let longitude: Double
    // Meters.
    let locationAccuracy: Double
    // Degrees, 0 is north. CLLocation.course is -1 when unknown, send 0 instead.
    let orientation: Double
    // Meters per second. The backend multiplies by 3.6 itself, never send km/h.
    let speed: Double
    // Meters, accumulated by us.
    let distance: Double
    // Milliseconds since the race start. Negative or > 48 h gets rejected.
    let elapsedTime: Int64
    // Meters of accumulated climb, not the absolute altitude.
    let elevationGain: Double
    // Percent.
    let elevationGrade: Double
}

struct CtLivePairing {
    var bound: Bool
    var ownerUsername: String
    var deviceInternalId: String
    // Remote control credentials, issued by the backend only for a bound
    // device. Absent means this device may not be controlled remotely.
    var controlToken: String?
    var controlUrl: String?
    // Whether the operator may configure by hand what CTLive normally owns.
    // Off unless the backend says otherwise, and only an administrator can turn
    // it on there. Absent means unchanged rather than off, so a backend that
    // does not know about this cannot silently lock a device out.
    var manualSetupEnabled: Bool?
}

// The backend error bodies are already human readable strings meant to be shown
// as is, so failures are just carried as a message.
struct CtLiveError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct CtLiveCheckResponse: Decodable {
    let bound: Bool
    let ownerUsername: String?
    let controlToken: String?
    let controlUrl: String?
    let manualSetupEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case bound
        case ownerUsername = "owner_username"
        case controlToken = "control_token"
        case controlUrl = "control_url"
        case manualSetupEnabled = "manual_setup_enabled"
    }
}

private struct CtLiveRedeemResponse: Decodable {
    let ownerUsername: String?
    let deviceInternalId: String?
    let controlToken: String?
    let controlUrl: String?
    let manualSetupEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case ownerUsername = "owner_username"
        case deviceInternalId = "device_internal_id"
        case controlToken = "control_token"
        case controlUrl = "control_url"
        case manualSetupEnabled = "manual_setup_enabled"
    }
}

// The backend uses "detail" for pairing errors and "error" for data upload
// errors. Both are plain strings meant to be shown as is.
private struct CtLiveErrorResponse: Decodable {
    let detail: String?
    let error: String?
}

class CtLiveClient {
    private let baseUrl: String
    private let apiKey: String

    init(baseUrl: String, apiKey: String) {
        var baseUrl = baseUrl.trim()
        while baseUrl.hasSuffix("/") {
            baseUrl.removeLast()
        }
        self.baseUrl = baseUrl.isEmpty ? ctLiveDefaultBaseUrl : baseUrl
        self.apiKey = apiKey.trim()
    }

    func checkPairing(deviceId: String, onComplete: @escaping (Result<CtLivePairing, CtLiveError>) -> Void) {
        guard var components = URLComponents(string: "\(baseUrl)/api/live/device-pairing/check/") else {
            onComplete(.failure(CtLiveError(message: String(localized: "Malformed base URL"))))
            return
        }
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceId)]
        guard let url = components.url else {
            onComplete(.failure(CtLiveError(message: String(localized: "Malformed base URL"))))
            return
        }
        perform(request: URLRequest(url: url)) { result in
            switch result {
            case let .success(data):
                guard let response = try? JSONDecoder().decode(CtLiveCheckResponse.self, from: data) else {
                    onComplete(.failure(CtLiveError(message: String(localized: "Malformed response"))))
                    return
                }
                onComplete(.success(CtLivePairing(bound: response.bound,
                                                  ownerUsername: response.ownerUsername ?? "",
                                                  deviceInternalId: "",
                                                  controlToken: response.controlToken,
                                                  controlUrl: response.controlUrl,
                                                  manualSetupEnabled: response.manualSetupEnabled)))
            case let .failure(error):
                onComplete(.failure(error))
            }
        }
    }

    func redeemPairing(code: String,
                       deviceId: String,
                       deviceName: String,
                       onComplete: @escaping (Result<CtLivePairing, CtLiveError>) -> Void)
    {
        guard var request = makeRequest(path: "/api/live/device-pairing/redeem/", withApiKey: false) else {
            onComplete(.failure(CtLiveError(message: String(localized: "Malformed base URL"))))
            return
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": code,
            "device_id": deviceId,
            "device_name": deviceName,
        ])
        perform(request: request) { result in
            switch result {
            case let .success(data):
                guard let response = try? JSONDecoder().decode(CtLiveRedeemResponse.self, from: data) else {
                    onComplete(.failure(CtLiveError(message: String(localized: "Malformed response"))))
                    return
                }
                onComplete(.success(CtLivePairing(bound: true,
                                                  ownerUsername: response.ownerUsername ?? "",
                                                  deviceInternalId: response.deviceInternalId ?? "",
                                                  controlToken: response.controlToken,
                                                  controlUrl: response.controlUrl,
                                                  manualSetupEnabled: response.manualSetupEnabled)))
            case let .failure(error):
                onComplete(.failure(error))
            }
        }
    }

    func upload(payload: CtLiveDataPayload, onComplete: @escaping (String?) -> Void) {
        guard var request = makeRequest(path: "/api/live/device-data/", withApiKey: true) else {
            onComplete(String(localized: "Malformed base URL"))
            return
        }
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            onComplete(error.localizedDescription)
            return
        }
        perform(request: request) { result in
            switch result {
            case .success:
                onComplete(nil)
            case let .failure(error):
                onComplete(error.message)
            }
        }
    }

    private func makeRequest(path: String, withApiKey: Bool) -> URLRequest? {
        guard let url = URL(string: "\(baseUrl)\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setContentType("application/json")
        // The backend is in a transition period where a missing key only logs a
        // warning, but it will be enforced later. Always send it when set.
        if withApiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Device-API-Key")
        }
        // A stalled request must not outlive the upload interval by much or the
        // in flight guard blocks the next snapshot.
        request.timeoutInterval = 10
        return request
    }

    private func perform(request: URLRequest, onComplete: @escaping (Result<Data, CtLiveError>) -> Void) {
        httpRequest(request: request) { data, response, error in
            if let error {
                onComplete(.failure(CtLiveError(message: error.localizedDescription)))
                return
            }
            guard let response = response?.http else {
                onComplete(.failure(CtLiveError(message: String(localized: "No response"))))
                return
            }
            guard response.isSuccessful else {
                let message = Self.errorMessage(data: data, statusCode: response.statusCode)
                onComplete(.failure(CtLiveError(message: message)))
                return
            }
            onComplete(.success(data ?? Data()))
        }
    }

    private static func errorMessage(data: Data?, statusCode: Int) -> String {
        if let data, let response = try? JSONDecoder().decode(CtLiveErrorResponse.self, from: data) {
            if let detail = response.detail, !detail.isEmpty {
                return detail
            }
            if let error = response.error, !error.isEmpty {
                return error
            }
        }
        return "HTTP \(statusCode)"
    }
}
