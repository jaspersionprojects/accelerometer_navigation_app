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

enum MovementMode: String, CaseIterable, Identifiable {
    case walking
    case driving

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walking:
            return "Walking"
        case .driving:
            return "Driving"
        }
    }

    var systemImage: String {
        switch self {
        case .walking:
            return "figure.walk"
        case .driving:
            return "car.fill"
        }
    }
}

private struct RoadMatchState {
    var routeCoordinates: [CLLocationCoordinate2D]
    var lastSnappedCoordinate: CLLocationCoordinate2D
    var lastProgressDistance: Double
    var lastRefreshCoordinate: CLLocationCoordinate2D
    var lastRefreshHeading: Double
    var lastRefreshDate: Date
    var consecutiveMisses: Int
    var isLocked: Bool
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
    @Published private(set) var movementMode: MovementMode = .walking
    @Published private(set) var gpsTrailCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var inertialTrailCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var areTrailsVisible = true
    @Published private(set) var isPlacingInertialPin = false
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
    private let roadMatchRefreshDistance = 12.0
    private let roadSnapMaximumDistance = 25.0
    private let roadSnapWarningDistanceDriving = 9.0
    private let roadMissDistanceDriving = 20.0
    private let roadMissDistanceWalking = 18.0
    private let roadMissToleranceDriving = 8
    private let roadMissToleranceWalking = 4
    private let drivingRoadMatchMinimumSpeed = 1.5
    private let walkingRoadMatchMinimumSpeed = 0.8
    private let drivingRoadMatchRefreshHeadingDelta = 25.0
    private let drivingRoadMatchTurnHeadingDelta = 18.0
    private let walkingRoadMatchRefreshHeadingDelta = 40.0
    private let drivingRoadMatchRefreshInterval: TimeInterval = 3.0
    private let walkingRoadMatchRefreshInterval: TimeInterval = 8.0
    private let drivingRoadMatchProjectionDistance = 70.0
    private let walkingRoadMatchProjectionDistance = 18.0
    private let walkingRoadSeedMaximumDistanceFromGPS = 15.0
    private let trailMinimumSegmentDistance = 1.5
    private let maximumTrailPointCount = 3_000

    private var hasStarted = false
    private var lastLocation: CLLocation?
    private var inertialOrigin: CLLocationCoordinate2D?
    private var rawInertialCoordinate: CLLocationCoordinate2D?
    private var inertialOffsetMeters = SIMD2<Double>(repeating: 0)
    private var inertialVelocityMetersPerSecond = SIMD2<Double>(repeating: 0)
    private var lastMotionTimestamp: TimeInterval?
    private var motionHeadingDegrees: Double?
    private var shouldAutoCenterMap = true
    private var roadMatchState: RoadMatchState?
    private var roadMatchTask: Task<Void, Never>?

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

    func recenterMap() {
        shouldAutoCenterMap = true
        updateRegion()
    }

    func handleMapInteraction() {
        shouldAutoCenterMap = false
    }

    func showTrails() {
        areTrailsVisible = true
    }

    func hideTrails() {
        areTrailsVisible = false
    }

    func clearTrails() {
        gpsTrailCoordinates.removeAll()
        inertialTrailCoordinates.removeAll()

        if let lastLocation {
            appendTrailCoordinate(lastLocation.coordinate, to: &gpsTrailCoordinates)
        }
        if let inertialCoordinate = annotations.first(where: { $0.id == "inertial" })?.coordinate {
            appendTrailCoordinate(inertialCoordinate, to: &inertialTrailCoordinates)
        }
    }

    func resetInertialSpeed() {
        inertialVelocityMetersPerSecond = .zero
        lastMotionTimestamp = nil
        updateDerivedReadouts()
        statusText = "Inertial speed reset to 0."
    }

    func startPlacingInertialPin() {
        isPlacingInertialPin = true
        statusText = "Tap the map to move the inertial marker."
    }

    func cancelPlacingInertialPin() {
        isPlacingInertialPin = false
        statusText = "Pin placement cancelled."
    }

    func placeInertialMarker(at coordinate: CLLocationCoordinate2D) {
        isPlacingInertialPin = false
        inertialOrigin = coordinate
        rawInertialCoordinate = coordinate
        inertialOffsetMeters = .zero
        inertialVelocityMetersPerSecond = .zero
        lastMotionTimestamp = nil
        roadMatchTask?.cancel()
        roadMatchTask = nil
        roadMatchState = nil
        inertialTrailCoordinates = [coordinate]
        replaceInertialAnnotation(with: coordinate)
        updateDerivedReadouts()
        updateRegion()
        statusText = "Inertial marker moved to the selected pin."
    }

    func setMovementMode(_ mode: MovementMode) {
        guard movementMode != mode else { return }

        movementMode = mode

        if mode == .driving {
            statusText = "Driving mode can lock to roads when the fit looks reliable."
        } else {
            roadMatchTask?.cancel()
            roadMatchTask = nil
            roadMatchState = nil
            statusText = "Walking mode leaves the inertial marker free-moving."
        }

        if let rawInertialCoordinate {
            updateRoadMatchedCoordinate(using: rawInertialCoordinate)
            updateRegion()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorization(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }

        lastLocation = location
        gpsSpeedMPH = max(location.speed, 0) * 2.2369362920544
        appendTrailCoordinate(location.coordinate, to: &gpsTrailCoordinates)

        if inertialOrigin == nil {
            seedInertialState(from: location, resetMotionClock: true)
            statusText = "GPS locked. Inertial navigation seeded from GPS."
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

        rawInertialCoordinate = coordinate
        updateRoadMatchedCoordinate(using: coordinate)
        updateDerivedReadouts()
        updateRegion()
    }

    private func seedInertialState(from location: CLLocation, resetMotionClock: Bool) {
        inertialOrigin = location.coordinate
        rawInertialCoordinate = location.coordinate
        inertialOffsetMeters = .zero
        roadMatchState = nil
        roadMatchTask?.cancel()
        roadMatchTask = nil

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

        if gpsTrailCoordinates.isEmpty {
            appendTrailCoordinate(location.coordinate, to: &gpsTrailCoordinates)
        }
        if inertialTrailCoordinates.isEmpty {
            appendTrailCoordinate(location.coordinate, to: &inertialTrailCoordinates)
        }
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
        appendTrailCoordinate(coordinate, to: &inertialTrailCoordinates)
    }

    private func updateRoadMatchedCoordinate(using rawCoordinate: CLLocationCoordinate2D) {
        guard movementMode == .driving else {
            replaceInertialAnnotation(with: rawCoordinate)
            return
        }

        let speedMetersPerSecond = simd_length(inertialVelocityMetersPerSecond)
        let heading = courseDegrees(from: inertialVelocityMetersPerSecond)
        let snap = snapToCurrentRoute(rawCoordinate: rawCoordinate)
        let shouldStayRoadLocked = roadMatchState?.isLocked == true

        guard speedMetersPerSecond >= activeRoadMatchMinimumSpeed || shouldStayRoadLocked else {
            replaceInertialAnnotation(with: rawCoordinate)
            return
        }

        applyDrivingRoadBehavior(
            rawCoordinate: rawCoordinate,
            heading: heading,
            speedMetersPerSecond: speedMetersPerSecond,
            snap: snap
        )
    }

    private func applyDrivingRoadBehavior(
        rawCoordinate: CLLocationCoordinate2D,
        heading: Double,
        speedMetersPerSecond: Double,
        snap: (coordinate: CLLocationCoordinate2D, progressDistance: Double, distanceFromRaw: Double)?
    ) {
        if let snap {
            roadMatchState?.lastSnappedCoordinate = snap.coordinate
            roadMatchState?.lastProgressDistance = snap.progressDistance
            roadMatchState?.consecutiveMisses = 0
            roadMatchState?.isLocked = true
            replaceInertialAnnotation(with: snap.coordinate)
        } else if let roadMatchState, roadMatchState.isLocked {
            self.roadMatchState?.consecutiveMisses = roadMatchState.consecutiveMisses + 1

            if shouldReleaseDrivingLock(rawCoordinate: rawCoordinate) {
                self.roadMatchState?.isLocked = false
                self.roadMatchState?.consecutiveMisses = 0
                replaceInertialAnnotation(with: rawCoordinate)
            } else {
                replaceInertialAnnotation(with: roadMatchState.lastSnappedCoordinate)
            }
        } else {
            replaceInertialAnnotation(with: rawCoordinate)
        }

        let shouldForceRawStart = shouldForceRouteRefresh(rawCoordinate: rawCoordinate, tolerance: roadMissDistanceDriving)
        let shouldPreferRawStart = shouldPreferRawStartForDrivingRefresh(
            rawCoordinate: rawCoordinate,
            heading: heading,
            snap: snap
        )
        if shouldForceRawStart || shouldRefreshRoadMatch(for: rawCoordinate, heading: heading) {
            refreshRoadMatch(
                from: rawCoordinate,
                heading: heading,
                speedMetersPerSecond: speedMetersPerSecond,
                preferRawStart: shouldForceRawStart || shouldPreferRawStart || roadMatchState == nil
            )
        }
    }

    private func shouldRefreshRoadMatch(for coordinate: CLLocationCoordinate2D, heading: Double) -> Bool {
        guard let matchState = roadMatchState else { return roadMatchTask == nil }
        guard roadMatchTask == nil else { return false }

        let movedDistance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: matchState.lastRefreshCoordinate.latitude, longitude: matchState.lastRefreshCoordinate.longitude))
        let headingDelta = abs(normalizedDeltaDegrees(heading, matchState.lastRefreshHeading))
        let age = Date().timeIntervalSince(matchState.lastRefreshDate)
        let routeHeadingDelta = currentRouteHeadingDelta(for: heading) ?? 0

        return movedDistance >= roadMatchRefreshDistance ||
            headingDelta >= activeRoadMatchRefreshHeadingDelta ||
            routeHeadingDelta >= drivingRoadMatchTurnHeadingDelta ||
            age >= activeRoadMatchRefreshInterval
    }

    private func shouldForceRouteRefresh(rawCoordinate: CLLocationCoordinate2D, tolerance: Double) -> Bool {
        guard let roadMatchState else { return false }

        let rawLocation = CLLocation(latitude: rawCoordinate.latitude, longitude: rawCoordinate.longitude)
        let snappedLocation = CLLocation(
            latitude: roadMatchState.lastSnappedCoordinate.latitude,
            longitude: roadMatchState.lastSnappedCoordinate.longitude
        )

        return rawLocation.distance(from: snappedLocation) > tolerance
    }

    private func shouldReleaseDrivingLock(rawCoordinate: CLLocationCoordinate2D) -> Bool {
        guard let roadMatchState else { return false }

        let rawLocation = CLLocation(latitude: rawCoordinate.latitude, longitude: rawCoordinate.longitude)
        let snappedLocation = CLLocation(
            latitude: roadMatchState.lastSnappedCoordinate.latitude,
            longitude: roadMatchState.lastSnappedCoordinate.longitude
        )

        return roadMatchState.consecutiveMisses >= roadMissToleranceDriving &&
            rawLocation.distance(from: snappedLocation) > roadMissDistanceDriving
    }

    private func refreshRoadMatch(
        from coordinate: CLLocationCoordinate2D,
        heading: Double,
        speedMetersPerSecond: Double,
        preferRawStart: Bool
    ) {
        let startCoordinate = preferRawStart
            ? coordinate
            : ((roadMatchState?.isLocked == true ? roadMatchState?.lastSnappedCoordinate : nil) ?? lastLocation?.coordinate ?? coordinate)
        let projectionDistance = max(activeRoadMatchProjectionDistance, speedMetersPerSecond * 6.0)
        let destinationCoordinate = startCoordinate.offsetBy(
            eastMeters: sin(heading * .pi / 180) * projectionDistance,
            northMeters: cos(heading * .pi / 180) * projectionDistance,
            earthRadiusMeters: earthRadiusMeters
        )

        roadMatchTask?.cancel()
        roadMatchTask = Task { [weak self] in
            guard let self else { return }
            let routeCandidates = await self.fetchRoadRoutes(from: startCoordinate, to: destinationCoordinate)

            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.roadMatchTask = nil

                guard let routeCandidates else { return }
                let validRouteCandidates = routeCandidates.filter { $0.count >= 2 }
                guard !validRouteCandidates.isEmpty else { return }

                let previousState = self.roadMatchState
                let baseProgress = previousState?.lastProgressDistance ?? 0
                let wasLocked = previousState?.isLocked == true
                let progressSeed = preferRawStart || !wasLocked ? 0 : baseProgress
                let selectedRouteCoordinates = self.bestRouteCoordinates(
                    from: validRouteCandidates,
                    rawCoordinate: self.rawInertialCoordinate ?? coordinate,
                    heading: heading,
                    lastProgressDistance: progressSeed
                ) ?? validRouteCandidates[0]
                var nextRoadMatchState = RoadMatchState(
                    routeCoordinates: selectedRouteCoordinates,
                    lastSnappedCoordinate: startCoordinate,
                    lastProgressDistance: progressSeed,
                    lastRefreshCoordinate: coordinate,
                    lastRefreshHeading: heading,
                    lastRefreshDate: Date(),
                    consecutiveMisses: 0,
                    isLocked: wasLocked
                )

                if let rawInertialCoordinate = self.rawInertialCoordinate,
                   let match = self.snapToRoute(
                    rawCoordinate: rawInertialCoordinate,
                    routeCoordinates: selectedRouteCoordinates,
                    lastProgressDistance: progressSeed
                   ) {
                    nextRoadMatchState.lastSnappedCoordinate = match.coordinate
                    nextRoadMatchState.lastProgressDistance = match.progressDistance
                    nextRoadMatchState.consecutiveMisses = 0
                    nextRoadMatchState.isLocked = true
                    self.roadMatchState = nextRoadMatchState
                    self.replaceInertialAnnotation(with: match.coordinate)
                    self.updateRegion()
                } else {
                    self.roadMatchState = nextRoadMatchState
                }
            }
        }
    }

    private func fetchRoadRoutes(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) async -> [[CLLocationCoordinate2D]]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = movementMode == .driving ? .automobile : .walking
        request.requestsAlternateRoutes = movementMode == .driving

        let directions = MKDirections(request: request)

        do {
            let response = try await directions.calculate()
            let routes = response.routes.map(\.polyline.coordinates).filter { $0.count >= 2 }
            return routes.isEmpty ? nil : routes
        } catch {
            return nil
        }
    }

    private func shouldPreferRawStartForDrivingRefresh(
        rawCoordinate: CLLocationCoordinate2D,
        heading: Double,
        snap: (coordinate: CLLocationCoordinate2D, progressDistance: Double, distanceFromRaw: Double)?
    ) -> Bool {
        guard let roadMatchState else { return true }
        guard roadMatchState.isLocked else { return true }

        if let snap, snap.distanceFromRaw >= roadSnapWarningDistanceDriving {
            return true
        }

        if shouldForceRouteRefresh(rawCoordinate: rawCoordinate, tolerance: roadSnapWarningDistanceDriving) {
            return true
        }

        if let routeHeadingDelta = currentRouteHeadingDelta(for: heading),
           routeHeadingDelta >= drivingRoadMatchTurnHeadingDelta {
            return true
        }

        return false
    }

    private func currentRouteHeadingDelta(for heading: Double) -> Double? {
        guard
            let roadMatchState,
            let routeHeading = routeHeading(
                on: roadMatchState.routeCoordinates,
                near: roadMatchState.lastProgressDistance
            )
        else {
            return nil
        }

        return abs(normalizedDeltaDegrees(heading, routeHeading))
    }

    private func bestRouteCoordinates(
        from routeCandidates: [[CLLocationCoordinate2D]],
        rawCoordinate: CLLocationCoordinate2D,
        heading: Double,
        lastProgressDistance: Double
    ) -> [CLLocationCoordinate2D]? {
        var bestRoute: [CLLocationCoordinate2D]?
        var bestScore = Double.greatestFiniteMagnitude

        for routeCoordinates in routeCandidates {
            guard let match = snapToRoute(
                rawCoordinate: rawCoordinate,
                routeCoordinates: routeCoordinates,
                lastProgressDistance: lastProgressDistance
            ) else {
                continue
            }

            let routeHeading = routeHeading(on: routeCoordinates, near: match.progressDistance) ?? heading
            let headingDelta = abs(normalizedDeltaDegrees(heading, routeHeading))
            let score = match.distanceFromRaw + headingDelta * 0.35

            if score < bestScore {
                bestScore = score
                bestRoute = routeCoordinates
            }
        }

        return bestRoute
    }

    private func snapToCurrentRoute(rawCoordinate: CLLocationCoordinate2D) -> (coordinate: CLLocationCoordinate2D, progressDistance: Double, distanceFromRaw: Double)? {
        guard let roadMatchState else { return nil }
        return snapToRoute(
            rawCoordinate: rawCoordinate,
            routeCoordinates: roadMatchState.routeCoordinates,
            lastProgressDistance: roadMatchState.lastProgressDistance
        )
    }

    private func snapToRoute(
        rawCoordinate: CLLocationCoordinate2D,
        routeCoordinates: [CLLocationCoordinate2D],
        lastProgressDistance: Double
    ) -> (coordinate: CLLocationCoordinate2D, progressDistance: Double, distanceFromRaw: Double)? {
        guard routeCoordinates.count >= 2 else { return nil }

        let rawLocation = CLLocation(latitude: rawCoordinate.latitude, longitude: rawCoordinate.longitude)
        var bestSnap: (coordinate: CLLocationCoordinate2D, progressDistance: Double, distance: Double)?
        var runningDistance = 0.0

        for index in 0..<(routeCoordinates.count - 1) {
            let start = routeCoordinates[index]
            let end = routeCoordinates[index + 1]
            let segmentLength = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))

            guard segmentLength > 0.1 else { continue }

            let snap = nearestPointOnSegment(to: rawCoordinate, start: start, end: end)
            let snappedLocation = CLLocation(latitude: snap.coordinate.latitude, longitude: snap.coordinate.longitude)
            let snapDistance = rawLocation.distance(from: snappedLocation)
            let progressDistance = runningDistance + segmentLength * snap.progress
            let progressPenalty = progressDistance + 8.0 < lastProgressDistance ? 80.0 : 0.0
            let score = snapDistance + progressPenalty

            if bestSnap == nil || score < bestSnap!.distance {
                bestSnap = (snap.coordinate, progressDistance, score)
            }

            runningDistance += segmentLength
        }

        guard let bestSnap, bestSnap.distance <= roadSnapMaximumDistance else {
            return nil
        }

        return (bestSnap.coordinate, bestSnap.progressDistance, bestSnap.distance)
    }

    private func routeHeading(
        on routeCoordinates: [CLLocationCoordinate2D],
        near progressDistance: Double
    ) -> Double? {
        guard routeCoordinates.count >= 2 else { return nil }

        var runningDistance = 0.0

        for index in 0..<(routeCoordinates.count - 1) {
            let start = routeCoordinates[index]
            let end = routeCoordinates[index + 1]
            let segmentLength = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))

            guard segmentLength > 0.1 else { continue }

            let lowerBound = runningDistance - 6.0
            let upperBound = runningDistance + segmentLength + 6.0
            if progressDistance >= lowerBound, progressDistance <= upperBound {
                let segmentVector = end.localMeters(from: start, earthRadiusMeters: earthRadiusMeters)
                let velocity = SIMD2<Double>(segmentVector.eastMeters, segmentVector.northMeters)
                guard simd_length(velocity) > 0.1 else { return nil }
                return courseDegrees(from: velocity)
            }

            runningDistance += segmentLength
        }

        guard let penultimate = routeCoordinates.dropLast().last,
              let last = routeCoordinates.last
        else {
            return nil
        }

        let segmentVector = last.localMeters(from: penultimate, earthRadiusMeters: earthRadiusMeters)
        let velocity = SIMD2<Double>(segmentVector.eastMeters, segmentVector.northMeters)
        guard simd_length(velocity) > 0.1 else { return nil }
        return courseDegrees(from: velocity)
    }

    private func nearestPointOnSegment(
        to coordinate: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D
    ) -> (coordinate: CLLocationCoordinate2D, progress: Double) {
        let origin = start
        let target = coordinate.localMeters(from: origin, earthRadiusMeters: earthRadiusMeters)
        let segmentEnd = end.localMeters(from: origin, earthRadiusMeters: earthRadiusMeters)
        let segmentVector = SIMD2<Double>(segmentEnd.eastMeters, segmentEnd.northMeters)
        let targetVector = SIMD2<Double>(target.eastMeters, target.northMeters)
        let denominator = simd_dot(segmentVector, segmentVector)

        guard denominator > 0 else {
            return (start, 0)
        }

        let clampedProgress = min(max(simd_dot(targetVector, segmentVector) / denominator, 0), 1)
        let snappedMeters = segmentVector * clampedProgress
        let snappedCoordinate = origin.offsetBy(
            eastMeters: snappedMeters.x,
            northMeters: snappedMeters.y,
            earthRadiusMeters: earthRadiusMeters
        )

        return (snappedCoordinate, clampedProgress)
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

        if shouldAutoCenterMap {
            cameraPosition = .region(nextRegion)
        }
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

    private var activeRoadMatchMinimumSpeed: Double {
        drivingRoadMatchMinimumSpeed
    }

    private var activeRoadMatchRefreshHeadingDelta: Double {
        drivingRoadMatchRefreshHeadingDelta
    }

    private var activeRoadMatchRefreshInterval: TimeInterval {
        drivingRoadMatchRefreshInterval
    }

    private var activeRoadMatchProjectionDistance: Double {
        drivingRoadMatchProjectionDistance
    }

    private func normalizedDeltaDegrees(_ lhs: Double, _ rhs: Double) -> Double {
        let delta = normalize(angle: lhs - rhs)
        return delta > 180 ? delta - 360 : delta
    }

    private func span(for radiusMeters: Double, at center: CLLocationCoordinate2D) -> MKCoordinateSpan {
        let latitudeDelta = max((radiusMeters / earthRadiusMeters) * 180 / .pi, 0.002)
        let longitudeScale = max(cos(center.latitude * .pi / 180), 0.01)
        let longitudeDelta = max(latitudeDelta / longitudeScale, 0.002)
        return MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    }

    private func appendTrailCoordinate(_ coordinate: CLLocationCoordinate2D, to trail: inout [CLLocationCoordinate2D]) {
        if let lastCoordinate = trail.last {
            let lastLocation = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            let newLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard newLocation.distance(from: lastLocation) >= trailMinimumSegmentDistance else {
                return
            }
        }

        trail.append(coordinate)
        if trail.count > maximumTrailPointCount {
            trail.removeFirst(trail.count - maximumTrailPointCount)
        }
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

    func localMeters(from origin: CLLocationCoordinate2D, earthRadiusMeters: Double) -> (eastMeters: Double, northMeters: Double) {
        let latitudeDeltaRadians = (latitude - origin.latitude) * .pi / 180
        let longitudeDeltaRadians = (longitude - origin.longitude) * .pi / 180
        let latitudeRadians = origin.latitude * .pi / 180

        return (
            eastMeters: longitudeDeltaRadians * earthRadiusMeters * max(cos(latitudeRadians), 0.01),
            northMeters: latitudeDeltaRadians * earthRadiusMeters
        )
    }
}

private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coordinates = Array(repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
