import CoreLocation
import Foundation
import UIKit

// Ride session for CTLive uploads. Distance, elapsed time and elevation
// accumulate here from CoreLocation updates, and a timer pushes the latest
// snapshot to the backend.
//
// The upload endpoint has last write wins semantics, so nothing is ever queued.
// While the network is down samples are simply dropped. Distance and elapsed
// time are cumulative values, so a dropped sample loses nothing, and replaying
// old points after a tunnel would only make the broadcast overlay rewind.
//
// Everything here runs on the main queue.

// The backend wants a sample every 1 to 5 seconds. Slower is allowed here so a
// long ride can trade dashboard smoothness for battery and data.
let ctLiveMinimumUploadInterval = 1.0
let ctLiveMaximumUploadInterval = 10.0
private let maximumUploadBackoff = 30.0
// Accept a move only once it exceeds the accuracy of the point it is measured
// from. Standing still at a red light still jitters by several meters.
private let minimumDistanceStep = 2.0
private let maximumUsableHorizontalAccuracy = 50.0
private let maximumUsableVerticalAccuracy = 15.0
// GPS altitude wanders even when standing still, so only count climb once the
// smoothed altitude has risen this far above the last reference point.
private let elevationGainThreshold = 3.0
private let gradeWindowDistance = 30.0
private let minimumGradeWindowDistance = 10.0
private let maximumGradeMagnitude = 30.0
// The backend rejects anything longer than this.
private let maximumElapsedTime = 48 * 3600.0

private struct GradeSample {
    let distance: Double
    let altitude: Double
}

class CtLiveTracker: ObservableObject {
    @Published private(set) var rideStatus: CtLiveRideStatus = .stopped
    @Published private(set) var uploading = false
    @Published private(set) var distance = 0.0
    @Published private(set) var elapsedTime = 0.0
    @Published private(set) var elevationGain = 0.0
    @Published private(set) var elevationGrade = 0.0
    @Published private(set) var speed = 0.0
    @Published private(set) var horizontalAccuracy: Double?
    @Published private(set) var uploadedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var paired = false
    @Published private(set) var ownerUsername = ""
    @Published private(set) var pairingBusy = false
    @Published private(set) var pairingError: String?
    @Published private(set) var pairingLockedUntil: Date?
    // Seconds left on the self imposed lock, so the UI can count down instead of
    // just showing a dead button.
    @Published private(set) var pairingLockSecondsLeft = 0
    private(set) var deviceId = ""
    private var redeemFailureCount = 0

    private var settings: SettingsCtLive?
    // Called after the pairing state changed so the model can bring the remote
    // control connection up or down with the new credentials.
    var onPairingChanged: (() -> Void)?
    private var client: CtLiveClient?
    private let uploadTimer = SimpleTimer(queue: .main)
    private var uploadInFlight = false
    private var uploadBackoffUntil: ContinuousClock.Instant?
    private var uploadRetryDelay = 0.0
    private var accumulatedElapsedTime: Duration = .zero
    private var runningSince: ContinuousClock.Instant?
    // Wall clock twin of runningSince, only used for persistence.
    private var runningSinceDate: Date?
    private var latestLocation: CLLocation?
    private var previousLocation: CLLocation?
    private var smoothedAltitude: Double?
    private var elevationReference: Double?
    private var gradeSamples: [GradeSample] = []

    func setup(settings: SettingsCtLive) {
        self.settings = settings
        deviceId = CtLiveDeviceId.getOrCreate()
        paired = !settings.ownerUsername.isEmpty
        ownerUsername = settings.ownerUsername
        // The binding lives on the backend and can be revoked there, so the
        // cached owner is only a starting point. Confirm it at launch.
        if settings.enabled {
            checkPairing()
            restoreSession()
        }
    }

    // Called when the operator turns CTLive on, so the pairing state is fresh
    // without having to go looking for the check button.
    func handleEnabledChanged() {
        guard let settings, settings.enabled else {
            return
        }
        checkPairing()
    }

    // MARK: - Session persistence

    private func restoreSession() {
        guard let settings, settings.uploadingWasActive else {
            return
        }
        distance = settings.sessionDistance
        elevationGain = settings.sessionElevationGain
        // The race clock keeps running even while the app is not, so the time
        // the app spent dead counts. Fold it into the accumulated total.
        var elapsed = settings.sessionElapsedTime
        if !settings.sessionPaused, let runningSince = settings.sessionRunningSince {
            elapsed += max(Date().timeIntervalSince(runningSince), 0)
        }
        accumulatedElapsedTime = .seconds(elapsed.clamped(to: 0 ... maximumElapsedTime))
        elapsedTime = accumulatedElapsedTime.seconds
        rideStatus = settings.sessionPaused ? .paused : .recording
        if settings.sessionPaused {
            runningSince = nil
            runningSinceDate = nil
        } else {
            setRunningSinceNow()
        }
        logger.info("ct-live: Resuming ride at \(format(distance: distance)) after restart")
        startUploading()
    }

    private func persistSession() {
        guard let settings else {
            return
        }
        settings.uploadingWasActive = uploading
        settings.sessionPaused = rideStatus == .paused
        settings.sessionDistance = distance
        settings.sessionElevationGain = elevationGain
        settings.sessionElapsedTime = accumulatedElapsedTime.seconds
        settings.sessionRunningSince = runningSince != nil ? runningSinceDate : nil
    }

    // MARK: - Ride control

    // The start line. Distance and elapsed time restart from zero at the moment
    // the button is pressed, which is the whole point of the button.
    func startRace() {
        resetData()
        rideStatus = .recording
        setRunningSinceNow()
        startUploading()
    }

    private func setRunningSinceNow() {
        runningSince = .now
        runningSinceDate = Date()
    }

    func startUploading() {
        guard let settings else {
            return
        }
        client = CtLiveClient(baseUrl: settings.baseUrl, apiKey: settings.apiKey)
        if rideStatus == .stopped {
            rideStatus = .recording
            setRunningSinceNow()
        }
        uploading = true
        lastError = nil
        uploadInFlight = false
        uploadBackoffUntil = nil
        uploadRetryDelay = 0
        let interval = startUploadTimer(settings: settings)
        persistSession()
        logger.info("ct-live: Start uploading every \(interval) s as \(deviceId)")
    }

    // Picks up a new interval while a ride is running, so dragging the slider
    // mid race takes effect without stopping and restarting the upload.
    func updateUploadInterval() {
        guard uploading, let settings else {
            return
        }
        let interval = startUploadTimer(settings: settings)
        logger.info("ct-live: Now uploading every \(interval) s")
    }

    @discardableResult
    private func startUploadTimer(settings: SettingsCtLive) -> Double {
        let interval = settings.uploadInterval
            .clamped(to: ctLiveMinimumUploadInterval ... ctLiveMaximumUploadInterval)
        uploadTimer.startPeriodic(interval: interval, initial: 0.1) { [weak self] in
            self?.handleUploadTick()
        }
        return interval
    }

    func stopUploading() {
        guard uploading else {
            return
        }
        uploadTimer.stop()
        accumulateElapsedTime()
        rideStatus = .stopped
        uploading = false
        // Best effort final snapshot so the dashboard shows the ride as ended
        // instead of just going silent.
        persistSession()
        if let latestLocation {
            send(location: latestLocation, rideStatus: .stopped)
        }
        logger.info("ct-live: Stop uploading")
    }

    func pause() {
        guard rideStatus == .recording else {
            return
        }
        accumulateElapsedTime()
        rideStatus = .paused
        // Do not bridge distance or elevation across the pause. Being carried in
        // a car between two segments must not count as riding.
        clearLocationContinuity()
        persistSession()
    }

    func resume() {
        guard rideStatus == .paused else {
            return
        }
        setRunningSinceNow()
        rideStatus = .recording
        persistSession()
    }

    func resetData() {
        distance = 0
        elapsedTime = 0
        elevationGain = 0
        elevationGrade = 0
        accumulatedElapsedTime = .zero
        if rideStatus == .recording {
            setRunningSinceNow()
        } else {
            runningSince = nil
            runningSinceDate = nil
        }
        clearLocationContinuity()
        persistSession()
    }

    var isActive: Bool {
        uploading
    }

    // MARK: - Location

    func handleLocation(location: CLLocation) {
        latestLocation = location
        horizontalAccuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        speed = max(location.speed, 0)
        guard rideStatus == .recording else {
            return
        }
        updateDistance(location: location)
        updateElevation(location: location)
    }

    // Refreshes the elapsed time shown in the UI. Called once a second by the
    // model. The value sent to the backend is computed at upload time.
    func tick() {
        elapsedTime = currentElapsedTime()
        updatePairingLock()
    }

    private func updatePairingLock() {
        guard let pairingLockedUntil else {
            return
        }
        let secondsLeft = Int(pairingLockedUntil.timeIntervalSinceNow.rounded(.up))
        if secondsLeft <= 0 {
            self.pairingLockedUntil = nil
            pairingLockSecondsLeft = 0
        } else if secondsLeft != pairingLockSecondsLeft {
            pairingLockSecondsLeft = secondsLeft
        }
    }

    private func clearLocationContinuity() {
        previousLocation = nil
        smoothedAltitude = nil
        elevationReference = nil
        gradeSamples.removeAll()
    }

    private func updateDistance(location: CLLocation) {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy < maximumUsableHorizontalAccuracy
        else {
            return
        }
        guard let previousLocation else {
            previousLocation = location
            return
        }
        let step = location.distance(from: previousLocation)
        guard step > max(previousLocation.horizontalAccuracy, minimumDistanceStep) else {
            return
        }
        distance += step
        self.previousLocation = location
    }

    private func updateElevation(location: CLLocation) {
        guard location.verticalAccuracy > 0,
              location.verticalAccuracy < maximumUsableVerticalAccuracy
        else {
            return
        }
        let altitude: Double = if let smoothedAltitude {
            0.8 * smoothedAltitude + 0.2 * location.altitude
        } else {
            location.altitude
        }
        smoothedAltitude = altitude
        if let elevationReference {
            if altitude > elevationReference + elevationGainThreshold {
                elevationGain += altitude - elevationReference
                self.elevationReference = altitude
            } else if altitude < elevationReference {
                self.elevationReference = altitude
            }
        } else {
            elevationReference = altitude
        }
        updateGrade(altitude: altitude)
    }

    private func updateGrade(altitude: Double) {
        gradeSamples.append(GradeSample(distance: distance, altitude: altitude))
        // Keep the oldest sample that still covers the window, drop the rest.
        while gradeSamples.count > 1, distance - gradeSamples[1].distance >= gradeWindowDistance {
            gradeSamples.removeFirst()
        }
        guard let oldest = gradeSamples.first else {
            return
        }
        let windowDistance = distance - oldest.distance
        guard windowDistance >= minimumGradeWindowDistance else {
            return
        }
        let grade = 100 * (altitude - oldest.altitude) / windowDistance
        elevationGrade = (0.7 * elevationGrade + 0.3 * grade)
            .clamped(to: -maximumGradeMagnitude ... maximumGradeMagnitude)
    }

    private func accumulateElapsedTime() {
        accumulatedElapsedTime = currentElapsedDuration()
        runningSince = nil
        runningSinceDate = nil
        elapsedTime = accumulatedElapsedTime.seconds
    }

    private func currentElapsedDuration() -> Duration {
        accumulatedElapsedTime + (runningSince?.duration(to: .now) ?? .zero)
    }

    private func currentElapsedTime() -> Double {
        currentElapsedDuration().seconds
    }

    // MARK: - Upload

    private func handleUploadTick() {
        guard uploading, !uploadInFlight else {
            return
        }
        if let uploadBackoffUntil, ContinuousClock.now < uploadBackoffUntil {
            return
        }
        guard let latestLocation else {
            lastError = String(localized: "Waiting for GPS fix")
            return
        }
        persistSession()
        send(location: latestLocation, rideStatus: rideStatus)
    }

    private func send(location: CLLocation, rideStatus: CtLiveRideStatus) {
        guard let client, let settings else {
            return
        }
        let elapsedTime = currentElapsedTime().clamped(to: 0 ... maximumElapsedTime)
        let payload = CtLiveDataPayload(
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            deviceId: deviceId,
            deviceUid: deviceId,
            profileName: settings.resolvedProfileName(),
            rideStatus: rideStatus.rawValue,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            locationAccuracy: max(location.horizontalAccuracy, 0),
            orientation: location.course >= 0 ? location.course : 0,
            speed: max(location.speed, 0),
            distance: distance,
            elapsedTime: Int64(elapsedTime * 1000),
            elevationGain: elevationGain,
            elevationGrade: elevationGrade
        )
        uploadInFlight = true
        client.upload(payload: payload) { [weak self] error in
            self?.handleUploadCompleted(error: error)
        }
    }

    private func handleUploadCompleted(error: String?) {
        uploadInFlight = false
        guard let error else {
            uploadedCount += 1
            lastUploadAt = Date()
            lastError = nil
            uploadRetryDelay = 0
            uploadBackoffUntil = nil
            return
        }
        failedCount += 1
        lastError = error
        uploadRetryDelay = min(max(2 * uploadRetryDelay, 2), maximumUploadBackoff)
        uploadBackoffUntil = ContinuousClock.now.advanced(by: .seconds(uploadRetryDelay))
        logger.info("ct-live: Upload failed with \(error). Retrying in \(uploadRetryDelay) s")
    }

    // MARK: - Pairing

    func checkPairing() {
        guard let settings, !pairingBusy else {
            return
        }
        pairingBusy = true
        pairingError = nil
        CtLiveClient(baseUrl: settings.baseUrl, apiKey: settings.apiKey)
            .checkPairing(deviceId: deviceId) { [weak self] result in
                self?.handlePairingResult(result: result, isRedeem: false)
            }
    }

    func redeemPairingCode(code: String) {
        guard let settings, !pairingBusy, pairingLockedUntil == nil else {
            return
        }
        pairingBusy = true
        pairingError = nil
        CtLiveClient(baseUrl: settings.baseUrl, apiKey: settings.apiKey)
            .redeemPairing(code: code.trim(),
                           deviceId: deviceId,
                           deviceName: settings.resolvedProfileName())
            { [weak self] result in
                self?.handlePairingResult(result: result, isRedeem: true)
            }
    }

    private func updateControlCredentials(pairing: CtLivePairing) {
        guard let settings else {
            return
        }
        guard pairing.bound else {
            // Unbound devices get no control credentials. Drop whatever we had.
            settings.controlToken = ""
            settings.controlUrl = ""
            return
        }
        // The backend omits these when it has nothing new to say, so absent
        // means keep what we have, not clear it.
        if let controlToken = pairing.controlToken, !controlToken.isEmpty {
            settings.controlToken = controlToken
        }
        if let controlUrl = pairing.controlUrl, !controlUrl.isEmpty {
            settings.controlUrl = controlUrl
        }
    }

    // Clears the local pairing state so a new code can be entered. The backend
    // binding is untouched, a later check re-fetches it if it is still valid.
    func startRebinding() {
        paired = false
        ownerUsername = ""
        pairingError = nil
        settings?.ownerUsername = ""
        settings?.controlToken = ""
        settings?.controlUrl = ""
        onPairingChanged?()
    }

    private func handlePairingResult(result: Result<CtLivePairing, CtLiveError>, isRedeem: Bool) {
        pairingBusy = false
        switch result {
        case let .success(pairing):
            redeemFailureCount = 0
            // A check that comes back saying exactly what we already knew is
            // not a change. Reporting it as one rebuilds the control
            // connection and rewrites the settings for nothing, which is what
            // opening the CTLive settings screen used to do mid race.
            let wasPaired = paired
            let previousToken = settings?.controlToken
            let previousUrl = settings?.controlUrl
            let previousOwner = settings?.ownerUsername
            let previousInternalId = settings?.deviceInternalId
            paired = pairing.bound
            ownerUsername = pairing.ownerUsername
            settings?.ownerUsername = pairing.bound ? pairing.ownerUsername : ""
            if !pairing.deviceInternalId.isEmpty {
                settings?.deviceInternalId = pairing.deviceInternalId
            }
            updateControlCredentials(pairing: pairing)
            if wasPaired != paired
                || previousToken != settings?.controlToken
                || previousUrl != settings?.controlUrl
                || previousOwner != settings?.ownerUsername
                || previousInternalId != settings?.deviceInternalId
            {
                onPairingChanged?()
            }
        case let .failure(error):
            pairingError = error.message
            guard isRedeem else {
                return
            }
            // The redeem endpoint is rate limited per IP. Back off after a run
            // of wrong codes so fat fingering does not get the device blocked.
            redeemFailureCount += 1
            if redeemFailureCount >= 5 {
                redeemFailureCount = 0
                pairingLockedUntil = Date().addingTimeInterval(10)
                updatePairingLock()
            }
        }
    }
}

extension SettingsCtLive {
    func resolvedProfileName() -> String {
        let profileName = profileName.trim()
        return profileName.isEmpty ? UIDevice.current.name : profileName
    }
}
