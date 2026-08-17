import CoreLocation
import Foundation

private class BackgroundActivity {
    private var backgroundSession: Any?

    func start() {
        if #available(iOS 17.0, *) {
            backgroundSession = CLBackgroundActivitySession()
        }
    }

    func stop() {
        if #available(iOS 17.0, *) {
            if let session = backgroundSession as? CLBackgroundActivitySession {
                session.invalidate()
            }
        }
    }
}

class Location: NSObject {
    private var manager = CLLocationManager()
    private var onUpdate: ((CLLocation) -> Void)?
    private var latestLocation: CLLocation?
    private var backgroundActivity = BackgroundActivity()

    func start(accuracy: SettingsLocationDesiredAccuracy,
               distanceFilter: SettingsLocationDistanceFilter,
               onUpdate: @escaping (CLLocation) -> Void)
    {
        logger.debug("location: Start with accuracy \(accuracy) and distance filter \(distanceFilter)")
        self.onUpdate = onUpdate
        manager.delegate = self
        switch accuracy {
        case .best:
            manager.desiredAccuracy = kCLLocationAccuracyBest
        case .nearestTenMeters:
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        case .hundredMeters:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        }
        switch distanceFilter {
        case .none:
            manager.distanceFilter = kCLDistanceFilterNone
        case .oneMeter:
            manager.distanceFilter = 1
        case .threeMeters:
            manager.distanceFilter = 3
        case .fiveMeters:
            manager.distanceFilter = 5
        case .tenMeters:
            manager.distanceFilter = 10
        case .twentyMeters:
            manager.distanceFilter = 20
        case .fiftyMeters:
            manager.distanceFilter = 50
        case .hundredMeters:
            manager.distanceFilter = 100
        case .twoHundredMeters:
            manager.distanceFilter = 200
        }
        manager.activityType = .fitness
        // iOS otherwise pauses updates when it decides we stopped moving, which
        // stalls distance and live tracking uploads at every red light.
        manager.pausesLocationUpdatesAutomatically = false
        #if !targetEnvironment(macCatalyst)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        #endif
        requestAuthorization()
        manager.startUpdatingLocation()
        backgroundActivity.start()
    }

    // "While Using the App" is not enough for a phone in a photographer's
    // pocket. Without Always, iOS stops the location updates the moment the app
    // goes to the background, which takes away the background execution the
    // director's connection depends on, and with it any reason for iOS to
    // relaunch the app after terminating it. That is the difference between a
    // camera that comes back on its own and one somebody has to walk over to.
    //
    // Always cannot be asked for from a standing start: iOS wants When In Use
    // first and only then offers the upgrade.
    private func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // Reported to the operator and to the dashboard. A device configured with
    // anything less than Always is one that will go quiet in a pocket, and
    // nobody can see that from the outside otherwise.
    func authorizationStatus() -> CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func stop() {
        logger.debug("location: Stop")
        onUpdate = nil
        manager.stopUpdatingLocation()
        backgroundActivity.stop()
    }

    func status() -> String {
        guard let latestLocation else {
            return ""
        }
        return format(speed: latestLocation.speed)
    }

    func getLatestKnownLocation() -> CLLocation? {
        latestLocation
    }
}

extension Location: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        logger.info("location: Authorization is now \(manager.authorizationStatus.rawValue)")
        // Granting When In Use is the step that makes the Always upgrade
        // askable, so take it as soon as it arrives rather than at the next
        // start, which on a race phone may be never.
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManager(_: CLLocationManager, didFailWithError error: any Error) {
        logger.info("location: Error \(error)")
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            latestLocation = location
            onUpdate?(location)
        }
    }
}
