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

    static func == (lhs: PlaceHit, rhs: PlaceHit) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class MapNavigator: NSObject, ObservableObject {
    @Published private(set) var userCoordinate: CLLocationCoordinate2D?
    @Published private(set) var route: MKRoute?
    @Published private(set) var destinationName: String?
    @Published private(set) var nextInstruction: String?
    @Published private(set) var isNavigating = false

    private let locationManager = CLLocationManager()
    private var pendingConfirm: PlaceHit?
    private var destinationCoordinate: CLLocationCoordinate2D?
    private var lastReroute = Date.distantPast
    private var lastStepIndex = -1

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 3
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
            return response.mapItems.prefix(5).enumerated().map { index, item in
                let coord = item.placemark.coordinate
                let distance = origin?.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)) ?? 0
                let name = item.name ?? query
                let locality = [item.placemark.locality, item.placemark.title].compactMap { $0 }.first ?? ""
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

    func holdForConfirm(_ place: PlaceHit) {
        pendingConfirm = place
    }

    var pendingPlace: PlaceHit? { pendingConfirm }

    func startPendingRoute() async -> String? {
        guard let place = pendingConfirm else { return nil }
        return await startRoute(to: place)
    }

    func startRoute(to place: PlaceHit) async -> String? {
        guard let userCoordinate else {
            return "I don't have your location yet. Try again in a moment."
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: userCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        request.destination?.name = place.name
        request.transportType = .walking

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
            self.lastStepIndex = -1
            publishStep()
            let miles = route.distance / 1609.34
            return String(format: "Starting navigation to %@. About %.1f miles on foot. %@", place.name, miles, nextInstruction ?? "Follow the path.")
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
        lastStepIndex = -1
    }

    /// Call when LiDAR reports close danger — freeze spoken map steps until clear.
    private(set) var pausedForObstacle = false

    func setPausedForObstacle(_ paused: Bool) {
        pausedForObstacle = paused
    }

    func tick() {
        guard isNavigating, !pausedForObstacle else { return }
        publishStep()
        maybeReroute()
    }

    private func publishStep() {
        guard let route, let userCoordinate else { return }
        let user = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, step) in route.steps.enumerated() {
            let points = step.polyline
            var coords = Array(repeating: kCLLocationCoordinate2DInvalid, count: points.pointCount)
            points.getCoordinates(&coords, range: NSRange(location: 0, length: points.pointCount))
            for coord in coords where CLLocationCoordinate2DIsValid(coord) {
                let distance = user.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
        }
        if bestIndex != lastStepIndex, bestIndex < route.steps.count {
            lastStepIndex = bestIndex
            let raw = route.steps[bestIndex].instructions
            nextInstruction = Self.rewrite(raw)
        }
        if bestDistance < 18, bestIndex >= route.steps.count - 1 {
            nextInstruction = "You're at \(destinationName ?? "your destination")."
        }
    }

    private func maybeReroute() {
        guard isNavigating, let destinationName, let destinationCoordinate, let userCoordinate else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReroute) > 20 else { return }
        guard let route else { return }
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

    /// Turn MapKit prose into short Firefly guidance.
    static func rewrite(_ instruction: String) -> String {
        var text = instruction
        let replacements = [
            "Proceed to the route": "Keep going",
            "Continue straight": "Keep straight",
            "Turn left": "Turn left",
            "Turn right": "Turn right",
        ]
        for (from, to) in replacements {
            text = text.replacingOccurrences(of: from, with: to)
        }
        if text.count > 90 {
            text = String(text.prefix(87)) + "…"
        }
        return text
    }
}

extension MapNavigator: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.userCoordinate = coordinate
            self.tick()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                self.locationManager.startUpdatingLocation()
            }
        }
    }
}
