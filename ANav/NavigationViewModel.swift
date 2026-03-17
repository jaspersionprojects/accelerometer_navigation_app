//
//  NavigationViewModel.swift
//  ANav
//
//  Created by Codex on 17/03/2026.
//

import Combine
import CoreLocation
import CoreMotion
import MapKit
import SwiftUI
import simd

struct NavigationAnnotation: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let color: Color
    let coordinate: CLLocationCoordinate2D
}

@MainActor
final class NavigationViewModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
    @Published var region = NavigationViewModel.defaultRegion
    @Published var cameraPosition: MapCameraPosition = .region(NavigationViewModel.defaultRegion)
    @Published private(set) var annotations: [NavigationAnnotation] = []
    @Published private(set) var statusText = "Requesting location permission..."
    @Published private(set) var referenceFrameText = "Sensors idle"
    @Published private(set) var gpsSpeedMPH = 0.0
    @Published private(set) var inertialSpeedMPH = 0.0
    @Published private(set) var headingDegrees = 0.0

    var gpsSpeedText: String {
        String(format: "%.1f mph", gpsSpeedMPH)
    }

    var inertialSpeedText: String {
        String(format: "%.1f mph", inertialSpeedMPH)
    }

    var headingText: String {
        String(format: "%.0f°", headingDegrees)
    }

    var canSnapToGPS: Bool {
        lastLocation != nil
    }

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ANav.motion.queue"
        queue.qualityOfService = .userInteractive
        return queue
    }()

    private let earthRadiusMeters = 6_378_137.0
    private let gravityMetersPerSecondSquared = 9.80665
    private let accelerationDeadband = 0.05
    private let stoppedSpeedThreshold = 0.35

    private var hasStarted = false
    private var lastLocation: CLLocation?
    private var inertialOrigin: CLLocationCoordinate2D?
    private var inertialOffsetMeters = SIMD2<Double>(repeating: 0)
    private var inertialVelocityMetersPerSecond = SIMD2<Double>(repeating: 0)
    private var lastMotionTimestamp: TimeInterval?
    private var motionHeadingDegrees: Double?

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .otherNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.headingFilter = kCLHeadingFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false

        motionManager.deviceMotionUpdateInterval = 0.1

        startMotionUpdates()
        handleAuthorization(locationManager.authorizationStatus)

        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func snapToGPS() {
        guard let location = lastLocation else { return }
        seedInertialState(from: location, resetMotionClock: true)
        statusText = "Accelerometer marker snapped back to live GPS."
        updateDerivedReadouts()
        updateAnnotations()
        updateRegion()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorization(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }

        lastLocation = location
        gpsSpeedMPH = max(location.speed, 0) * 2.2369362920544

        if inertialOrigin == nil {
            seedInertialState(from: location, resetMotionClock: true)
            statusText = "GPS locked. Inertial navigation seeded from GPS."
        } else if location.speed >= 0, location.course >= 0 {
            inertialVelocityMetersPerSecond = velocityVector(from: location)
        } else if location.speed >= 0, location.speed < stoppedSpeedThreshold {
            inertialVelocityMetersPerSecond = .zero
        }

        updateDerivedReadouts()
        updateAnnotations()
        updateRegion()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        statusText = "Location error: \(error.localizedDescription)"
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let trueHeading = newHeading.trueHeading
        let magneticHeading = newHeading.magneticHeading

        if trueHeading >= 0 {
            motionHeadingDegrees = normalize(angle: trueHeading)
        } else if magneticHeading >= 0 {
            motionHeadingDegrees = normalize(angle: magneticHeading)
        }

        updateDerivedReadouts()
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                locationManager.startUpdatingHeading()
            }
            if inertialOrigin == nil {
                statusText = "Waiting for a GPS fix to seed inertial navigation..."
            }

        case .notDetermined:
            statusText = "Requesting location permission..."

        case .denied, .restricted:
            statusText = "Location access is required for the GPS marker and inertial starting point."

        @unknown default:
            statusText = "Unknown location authorization state."
        }
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            referenceFrameText = "No motion sensors"
            return
        }

        let referenceFrame = bestReferenceFrame()
        referenceFrameText = referenceFrameName(for: referenceFrame)

        motionManager.startDeviceMotionUpdates(using: referenceFrame, to: motionQueue) { [weak self] motion, error in
            if let error {
                Task { [weak self] in
                    await MainActor.run {
                        self?.statusText = "Motion error: \(error.localizedDescription)"
                    }
                }
                return
            }

            guard let motion else { return }

            Task { [weak self] in
                await MainActor.run {
                    self?.handleDeviceMotion(motion)
                }
            }
        }
    }

    private func handleDeviceMotion(_ motion: CMDeviceMotion) {
        if motion.heading >= 0 {
            motionHeadingDegrees = normalize(angle: motion.heading)
        }

        guard let inertialOrigin else {
            lastMotionTimestamp = motion.timestamp
            updateDerivedReadouts()
            return
        }

        guard let lastMotionTimestamp else {
            self.lastMotionTimestamp = motion.timestamp
            updateDerivedReadouts()
            return
        }

        let rawDeltaTime = motion.timestamp - lastMotionTimestamp
        let deltaTime = min(max(rawDeltaTime, 0.05), 0.2)
        self.lastMotionTimestamp = motion.timestamp

        let horizontalAcceleration = horizontalAccelerationMetersPerSecondSquared(from: motion)
        inertialOffsetMeters += inertialVelocityMetersPerSecond * deltaTime + 0.5 * horizontalAcceleration * deltaTime * deltaTime
        inertialVelocityMetersPerSecond += horizontalAcceleration * deltaTime

        if simd_length(horizontalAcceleration) < accelerationDeadband,
           simd_length(inertialVelocityMetersPerSecond) < stoppedSpeedThreshold {
            inertialVelocityMetersPerSecond = .zero
        }

        let coordinate = inertialOrigin.offsetBy(
            eastMeters: inertialOffsetMeters.x,
            northMeters: inertialOffsetMeters.y,
            earthRadiusMeters: earthRadiusMeters
        )

        replaceInertialAnnotation(with: coordinate)
        updateDerivedReadouts()
        updateRegion()
    }

    private func seedInertialState(from location: CLLocation, resetMotionClock: Bool) {
        inertialOrigin = location.coordinate
        inertialOffsetMeters = .zero

        if location.speed >= 0, location.course >= 0 {
            inertialVelocityMetersPerSecond = velocityVector(from: location)
        } else {
            inertialVelocityMetersPerSecond = .zero
        }

        if resetMotionClock {
            lastMotionTimestamp = nil
        }

        annotations = [
            NavigationAnnotation(
                id: "gps",
                title: "GPS",
                systemImage: "location.fill",
                color: Color(red: 0.13, green: 0.56, blue: 0.95),
                coordinate: location.coordinate
            ),
            NavigationAnnotation(
                id: "inertial",
                title: "Inertial",
                systemImage: "scope",
                color: Color(red: 0.97, green: 0.45, blue: 0.15),
                coordinate: location.coordinate
            )
        ]
    }

    private func updateAnnotations() {
        guard let lastLocation else { return }

        let gpsAnnotation = NavigationAnnotation(
            id: "gps",
            title: "GPS",
            systemImage: "location.fill",
            color: Color(red: 0.13, green: 0.56, blue: 0.95),
            coordinate: lastLocation.coordinate
        )

        let inertialCoordinate = annotations.first(where: { $0.id == "inertial" })?.coordinate ?? lastLocation.coordinate
        let inertialAnnotation = NavigationAnnotation(
            id: "inertial",
            title: "Inertial",
            systemImage: "scope",
            color: Color(red: 0.97, green: 0.45, blue: 0.15),
            coordinate: inertialCoordinate
        )

        annotations = [gpsAnnotation, inertialAnnotation]
    }

    private func replaceInertialAnnotation(with coordinate: CLLocationCoordinate2D) {
        if annotations.isEmpty, let lastLocation {
            seedInertialState(from: lastLocation, resetMotionClock: false)
            return
        }

        var nextAnnotations = annotations.filter { $0.id != "inertial" }
        nextAnnotations.append(
            NavigationAnnotation(
                id: "inertial",
                title: "Inertial",
                systemImage: "scope",
                color: Color(red: 0.97, green: 0.45, blue: 0.15),
                coordinate: coordinate
            )
        )
        annotations = nextAnnotations.sorted { $0.id < $1.id }
    }

    private func updateDerivedReadouts() {
        let speedMetersPerSecond = simd_length(inertialVelocityMetersPerSecond)
        inertialSpeedMPH = speedMetersPerSecond * 2.2369362920544

        if speedMetersPerSecond > stoppedSpeedThreshold {
            headingDegrees = courseDegrees(from: inertialVelocityMetersPerSecond)
        } else if let motionHeadingDegrees {
            headingDegrees = motionHeadingDegrees
        } else if let lastLocation, lastLocation.course >= 0 {
            headingDegrees = normalize(angle: lastLocation.course)
        }
    }

    private func updateRegion() {
        let coordinates = annotations.map(\.coordinate)
        guard let first = coordinates.first else { return }

        let center: CLLocationCoordinate2D
        let radiusMeters: Double

        if coordinates.count == 1 {
            center = first
            radiusMeters = 180
        } else {
            let averageLatitude = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
            let averageLongitude = coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
            center = CLLocationCoordinate2D(latitude: averageLatitude, longitude: averageLongitude)

            let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
            radiusMeters = max(
                180,
                coordinates.map { coordinate in
                    CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        .distance(from: centerLocation)
                }.max() ?? 180
            ) * 2.4
        }

        let nextRegion = MKCoordinateRegion(center: center, span: span(for: radiusMeters, at: center))
        region = nextRegion
        cameraPosition = .region(nextRegion)
    }

    private func bestReferenceFrame() -> CMAttitudeReferenceFrame {
        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()

        if availableFrames.contains(.xTrueNorthZVertical) {
            return .xTrueNorthZVertical
        }
        if availableFrames.contains(.xMagneticNorthZVertical) {
            return .xMagneticNorthZVertical
        }
        if availableFrames.contains(.xArbitraryCorrectedZVertical) {
            return .xArbitraryCorrectedZVertical
        }
        return .xArbitraryZVertical
    }

    private func referenceFrameName(for referenceFrame: CMAttitudeReferenceFrame) -> String {
        switch referenceFrame {
        case .xTrueNorthZVertical:
            return "True north"
        case .xMagneticNorthZVertical:
            return "Magnetic north"
        case .xArbitraryCorrectedZVertical:
            return "Corrected frame"
        case .xArbitraryZVertical:
            return "Arbitrary frame"
        default:
            return "Sensors active"
        }
    }

    private func velocityVector(from location: CLLocation) -> SIMD2<Double> {
        let courseRadians = location.course * .pi / 180
        let eastVelocity = location.speed * sin(courseRadians)
        let northVelocity = location.speed * cos(courseRadians)
        return SIMD2<Double>(eastVelocity, northVelocity)
    }

    private func horizontalAccelerationMetersPerSecondSquared(from motion: CMDeviceMotion) -> SIMD2<Double> {
        let acceleration = motion.userAcceleration
        let rotation = motion.attitude.rotationMatrix

        // Core Motion reports the rotation matrix as the device attitude, so transpose it
        // to rotate the device-frame acceleration vector into the chosen reference frame.
        let referenceX = rotation.m11 * acceleration.x + rotation.m21 * acceleration.y + rotation.m31 * acceleration.z
        let referenceY = rotation.m12 * acceleration.x + rotation.m22 * acceleration.y + rotation.m32 * acceleration.z

        var eastNorthAcceleration = SIMD2<Double>(
            -referenceY * gravityMetersPerSecondSquared,
            referenceX * gravityMetersPerSecondSquared
        )

        if simd_length(eastNorthAcceleration) < accelerationDeadband {
            eastNorthAcceleration = .zero
        }

        return eastNorthAcceleration
    }

    private func courseDegrees(from velocity: SIMD2<Double>) -> Double {
        let angleRadians = atan2(velocity.x, velocity.y)
        return normalize(angle: angleRadians * 180 / .pi)
    }

    private func normalize(angle: Double) -> Double {
        let normalized = angle.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }

    private func span(for radiusMeters: Double, at center: CLLocationCoordinate2D) -> MKCoordinateSpan {
        let latitudeDelta = max((radiusMeters / earthRadiusMeters) * 180 / .pi, 0.002)
        let longitudeScale = max(cos(center.latitude * .pi / 180), 0.01)
        let longitudeDelta = max(latitudeDelta / longitudeScale, 0.002)
        return MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    }
}

private extension CLLocationCoordinate2D {
    func offsetBy(eastMeters: Double, northMeters: Double, earthRadiusMeters: Double) -> CLLocationCoordinate2D {
        let latitudeRadians = latitude * .pi / 180
        let latitudeDelta = northMeters / earthRadiusMeters
        let longitudeDelta = eastMeters / (earthRadiusMeters * max(cos(latitudeRadians), 0.01))

        return CLLocationCoordinate2D(
            latitude: latitude + latitudeDelta * 180 / .pi,
            longitude: longitude + longitudeDelta * 180 / .pi
        )
    }
}
