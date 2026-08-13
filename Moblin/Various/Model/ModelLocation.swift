import CoreLocation

extension Model {
    func updateLocation() {
        var location = locationManager.status()
        if let realtimeIrl {
            location += realtimeIrl.status()
        }
        if location != statusTopRight.location {
            statusTopRight.location = location
        }
    }

    func reloadLocation() {
        locationManager.stop()
        if isLocationEnabled() {
            locationManager.start(accuracy: database.location.desiredAccuracy,
                                  distanceFilter: database.location.distanceFilter,
                                  onUpdate: handleLocationUpdate)
        }
        reloadRealtimeIrl()
    }

    private func resetDistance() {
        database.location.distance = 0.0
        latestKnownLocation = nil
    }

    func resetLocationData() {
        resetDistance()
        resetAverageSpeed()
        resetSlope()
    }

    func isLocationEnabled() -> Bool {
        // CTLive needs location updates whether or not the user turned on
        // Moblin's own location features. Remote control needs them too, not for
        // the position but because they are what keeps the app running once the
        // screen goes off. Without that the director cannot reach an idle phone.
        database.location.enabled || ctLive.isActive || ctLiveIsRemoteControlActive()
    }

    private func handleLocationUpdate(location: CLLocation) {
        guard !isLocationInPrivacyRegion(location: location) else {
            return
        }
        ctLive.handleLocation(location: location)
        guard isLive else {
            return
        }
        realtimeIrl?.update(location: location)
    }

    func isLocationInPrivacyRegion(location: CLLocation) -> Bool {
        for region in database.location.privacyRegions
            where region.contains(coordinate: location.coordinate)
        {
            return true
        }
        return false
    }

    func getLatestKnownLocation() -> (Double, Double)? {
        if let location = locationManager.getLatestKnownLocation() {
            (location.coordinate.latitude, location.coordinate.longitude)
        } else {
            nil
        }
    }

    func isRealtimeIrlConfigured() -> Bool {
        stream.realtimeIrlEnabled && !stream.realtimeIrlBaseUrl.isEmpty && !stream.realtimeIrlPushKey
            .isEmpty
    }

    func reloadRealtimeIrl() {
        realtimeIrl?.stop()
        realtimeIrl = nil
        if isRealtimeIrlConfigured() {
            realtimeIrl = RealtimeIrl(baseUrl: stream.realtimeIrlBaseUrl, pushKey: stream.realtimeIrlPushKey)
        }
    }

    func updateDistance() {
        let location = locationManager.getLatestKnownLocation()
        if let latestKnownLocation {
            let distance = location?.distance(from: latestKnownLocation) ?? 0
            if distance > latestKnownLocation.horizontalAccuracy {
                database.location.distance += distance
                self.latestKnownLocation = location
            }
        } else {
            latestKnownLocation = location
        }
    }

    func resetSlope() {
        slopePercent = 0.0
        previousSlopeAltitude = nil
        previousSlopeDistance = database.location.distance
    }

    func updateSlope() {
        guard let location = locationManager.getLatestKnownLocation() else {
            return
        }
        let deltaDistance = database.location.distance - previousSlopeDistance
        guard deltaDistance != 0 else {
            return
        }
        previousSlopeDistance = database.location.distance
        let deltaAltitude = location.altitude - (previousSlopeAltitude ?? location.altitude)
        previousSlopeAltitude = location.altitude
        slopePercent = 0.7 * slopePercent + 0.3 * (100 * deltaAltitude / deltaDistance)
    }

    func resetAverageSpeed() {
        averageSpeed = 0.0
        averageSpeedStartTime = .now
        averageSpeedStartDistance = database.location.distance
    }

    func updateAverageSpeed(now: ContinuousClock.Instant) {
        let distance = database.location.distance - averageSpeedStartDistance
        let elapsed = averageSpeedStartTime.duration(to: now)
        averageSpeed = distance / elapsed.seconds
    }

    func getDistance() -> String {
        format(distance: database.location.distance)
    }

    func isShowingStatusLocation() -> Bool {
        database.show.location && isLocationEnabled()
    }
}
