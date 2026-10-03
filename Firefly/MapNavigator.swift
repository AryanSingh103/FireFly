import CoreLocation
import Foundation
import MapKit

struct PlaceHit: Identifiable, Equatable {
    let id: String
    let name: String
    let locality: String
    let coordinate: CLLocationCoordinate2D
    let distanceMeters: CLLocationDistance

    var spokenSummary: String {
        let miles = distanceMeters / 1609.34
        if miles < 0.1 {
            let feet = Int(distanceMeters * 3.281)
            return "\(name), about \(feet) feet away"
        }
        return String(format: "%@, about %.1f miles away", name, miles)
    }

    var addressLine: String {
        locality.isEmpty ? name : "\(name) at \(locality)"
    }

    static func == (lhs: PlaceHit, rhs: PlaceHit) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class MapNavigator: NSObject, ObservableObject {
    @Published private(set) var userCoordinate: CLLocationCoordinate2D?
    @Published private(set) var userHeading: CLLocationDirection?
    @Published private(set) var route: MKRoute?
    @Published private(set) var destinationName: String?
    @Published private(set) var nextInstruction: String?
    @Published private(set) var isNavigating = false

    private let locationManager = CLLocationManager()
    private var pendingConfirm: PlaceHit?
    private var pendingChoices: [PlaceHit] = []
    private var destinationCoordinate: CLLocationCoordinate2D?
    private var lastReroute = Date.distantPast
    private var lastSpokenStep = -1
    private var routeStartedAt: Date?
    private var currentStepIndex = 0

    /// BlindSpot: freeze obstacle voice during the opening nav summary.
    var isInInitialNavPhase: Bool {
        guard let routeStartedAt else { return false }
        return Date().timeIntervalSince(routeStartedAt) < BlindSpotNav.routeStartGraceSeconds
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 3
        locationManager.headingFilter = 8
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }

    func search(_ query: String) async -> [PlaceHit] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let userCoordinate {
            request.region = MKCoordinateRegion(center: userCoordinate, latitudinalMeters: 4_000, longitudinalMeters: 4_000)
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            let origin = userCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            return response.mapItems.prefix(3).enumerated().map { index, item in
                let coord = item.placemark.coordinate
                let distance = origin?.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)) ?? 0
                let name = item.name ?? query
                let locality = item.placemark.title ?? item.placemark.locality ?? ""
                return PlaceHit(
                    id: "\(index)-\(name)-\(coord.latitude)",
                    name: name,
                    locality: locality,
                    coordinate: coord,
                    distanceMeters: distance
                )
            }
        } catch {
            return []
        }
    }

    /// BlindSpot flow: hold up to 3 choices so the user can pick by number/name.
    func holdChoices(_ places: [PlaceHit]) {
        pendingChoices = Array(places.prefix(3))
        pendingConfirm = pendingChoices.first
    }

    var choices: [PlaceHit] { pendingChoices }

    func pickChoice(matching answer: String) -> PlaceHit? {
        let lowered = answer.lowercased()
        if lowered.contains("1") || lowered.contains("first") || lowered.contains("one") {
            return pendingChoices.first
        }
        if pendingChoices.count > 1, lowered.contains("2") || lowered.contains("second") {
            return pendingChoices[1]
        }
        if pendingChoices.count > 2, lowered.contains("3") || lowered.contains("third") {
            return pendingChoices[2]
        }
        return pendingChoices.first { place in
            lowered.contains(place.name.lowercased()) || place.name.lowercased().contains(lowered)
        }
    }

    func holdForConfirm(_ place: PlaceHit) {
        pendingConfirm = place
        pendingChoices = [place]
    }

    var pendingPlace: PlaceHit? { pendingConfirm }

    func startPendingRoute() async -> String? {
        guard let place = pendingConfirm else { return nil }
        return await startRoute(to: place)
    }

    func startRoute(to place: PlaceHit) async -> String? {
        guard let userCoordinate else {
            return "I don't have your location yet. Make sure the app is open and GPS is on, then ask again."
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: userCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        request.destination?.name = place.name
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                return "I couldn't find a walking path there."
            }
            self.route = route
            self.destinationName = place.name
            self.destinationCoordinate = place.coordinate
            self.isNavigating = true
            self.pendingConfirm = nil
            self.pendingChoices = []
            self.currentStepIndex = 0
            self.lastSpokenStep = -1
            self.routeStartedAt = Date()
            self.nextInstruction = nil

            let miles = route.distance / 1609.34
            let minutes = max(1, Int(route.expectedTravelTime / 60))
            let arrival = Date().addingTimeInterval(route.expectedTravelTime)
            let arrivalText = Self.timeFormatter.string(from: arrival)
            let firstRaw = route.steps.first(where: { !$0.instructions.isEmpty })?.instructions ?? "Follow the path"
            let toward = stepEndCoordinate(route.steps.first) ?? place.coordinate
            let first = BlindSpotNav.rewriteInstruction(
                firstRaw,
                userHeading: userHeading,
                from: userCoordinate,
                toward: toward
            )
            // BlindSpot announcement order: destination → distance → time → arrival → first direction.
            return String(
                format: "Destination: %@. Total distance: about %.1f miles. Estimated time: %d minutes. Arrival around %@. First direction: %@.",
                place.name, miles, minutes, arrivalText, first
            )
        } catch {
            return "Sorry, there's no connection for maps right now. I can stay in Passive and watch for obstacles."
        }
    }

    func stop() {
        isNavigating = false
        route = nil
        destinationName = nil
        destinationCoordinate = nil
        nextInstruction = nil
        pendingConfirm = nil
        pendingChoices = []
        routeStartedAt = nil
        currentStepIndex = 0
        lastSpokenStep = -1
    }

    private(set) var pausedForObstacle = false

    func setPausedForObstacle(_ paused: Bool) {
        pausedForObstacle = paused
    }

    func whereAmI() -> String {
        guard let userCoordinate else {
            return "Location not available yet. Make sure the app is open and GPS is on."
        }
        var facing = ""
        if let userHeading {
            facing = " \(BlindSpotNav.facingPhrase(heading: userHeading))"
        }
        return String(format: "You are near %.5f, %.5f.%@", userCoordinate.latitude, userCoordinate.longitude, facing)
    }

    func facing() -> String {
        guard let userHeading else {
            return "Compass heading is not available yet."
        }
        return "You are \(BlindSpotNav.facingPhrase(heading: userHeading).lowercased())"
    }

    func tick() {
        guard isNavigating, !pausedForObstacle else { return }
        if isInInitialNavPhase { return }
        publishStep()
        maybeReroute()
    }

    /// BlindSpot-style: warn at ~45 m, say "Now" at ~12 m, then advance.
    private func publishStep() {
        guard let route, let userCoordinate else { return }
        let steps = route.steps.filter { !$0.instructions.isEmpty || $0.distance > 0 }
        guard !steps.isEmpty else { return }
        if currentStepIndex >= steps.count {
            nextInstruction = "You have arrived at your destination: \(destinationName ?? "your destination")"
            return
        }

        let step = steps[currentStepIndex]
        guard let end = stepEndCoordinate(step) else { return }
        let dist = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))

        let nextIndex = currentStepIndex + 1
        if nextIndex >= steps.count {
            if lastSpokenStep < currentStepIndex, dist < BlindSpotNav.turnNowMeters {
                lastSpokenStep = currentStepIndex
                nextInstruction = "You have arrived at your destination: \(destinationName ?? "your destination")"
            }
            return
        }

        let next = steps[nextIndex]
        let toward = stepEndCoordinate(next) ?? end
        let rewritten = BlindSpotNav.rewriteInstruction(
            next.instructions.isEmpty ? "Continue" : next.instructions,
            userHeading: userHeading,
            from: userCoordinate,
            toward: toward
        )

        if dist < BlindSpotNav.turnNowMeters {
            if lastSpokenStep <= nextIndex {
                lastSpokenStep = nextIndex
                currentStepIndex = nextIndex
                nextInstruction = "\(rewritten) Now."
            }
        } else if dist < BlindSpotNav.turnAnnounceMeters {
            if lastSpokenStep < nextIndex {
                lastSpokenStep = nextIndex
                nextInstruction = "In \(Int(dist)) meters, \(rewritten)"
            }
        }
    }

    private func stepEndCoordinate(_ step: MKRoute.Step?) -> CLLocationCoordinate2D? {
        guard let step, step.polyline.pointCount > 0 else { return nil }
        var coords = Array(repeating: kCLLocationCoordinate2DInvalid, count: step.polyline.pointCount)
        step.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: step.polyline.pointCount))
        return coords.last(where: CLLocationCoordinate2DIsValid)
    }

    private func maybeReroute() {
        guard isNavigating, let destinationName, let destinationCoordinate, let userCoordinate, let route else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReroute) > 20 else { return }
        let user = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        var nearest = Double.greatestFiniteMagnitude
        for step in route.steps {
            var coords = Array(repeating: kCLLocationCoordinate2DInvalid, count: step.polyline.pointCount)
            step.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: step.polyline.pointCount))
            for coord in coords where CLLocationCoordinate2DIsValid(coord) {
                nearest = min(nearest, user.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)))
            }
        }
        guard nearest > 40 else { return }
        lastReroute = now
        let place = PlaceHit(
            id: "reroute",
            name: destinationName,
            locality: "",
            coordinate: destinationCoordinate,
            distanceMeters: nearest
        )
        Task { _ = await startRoute(to: place) }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}

extension MapNavigator: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.userCoordinate = coordinate
            self.tick()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard heading >= 0 else { return }
        Task { @MainActor in
            self.userHeading = heading
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                self.locationManager.startUpdatingLocation()
                self.locationManager.startUpdatingHeading()
            }
        }
    }
}
