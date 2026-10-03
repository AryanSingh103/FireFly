import CoreLocation
import Foundation

/// Navigation helpers ported from BlindSpot (`navigation.py`) for native FireFly.
/// Source: https://github.com/benz16107/BlindSpot — partner project; adapted to MapKit / Swift.
enum BlindSpotNav {
    /// Don't announce GPS turn-by-turn for this long after route start (lets the summary finish).
    static let routeStartGraceSeconds: TimeInterval = 18
    /// Early warning distance (meters).
    static let turnAnnounceMeters: CLLocationDistance = 45
    /// "Do it now" distance (meters).
    static let turnNowMeters: CLLocationDistance = 12

    static func bearingDegrees(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let phi1 = a.latitude * .pi / 180
        let phi2 = b.latitude * .pi / 180
        let dLambda = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        var bearing = atan2(y, x) * 180 / .pi
        bearing = (bearing + 360).truncatingRemainder(dividingBy: 360)
        return bearing
    }

    static func cardinal(fromBearing bearing: Double) -> String {
        if bearing < 22.5 || bearing >= 337.5 { return "north" }
        if bearing < 67.5 { return "north-east" }
        if bearing < 112.5 { return "east" }
        if bearing < 157.5 { return "south-east" }
        if bearing < 202.5 { return "south" }
        if bearing < 247.5 { return "south-west" }
        if bearing < 292.5 { return "west" }
        return "north-west"
    }

    /// Relative direction from the wearer's heading to a target bearing.
    static func relativeDirection(userHeading: Double, targetBearing: Double) -> String {
        var diff = (targetBearing - userHeading + 540).truncatingRemainder(dividingBy: 360) - 180
        if diff <= -180 { diff += 360 }
        if diff > 180 { diff -= 360 }
        if (-45...45).contains(diff) { return "forward" }
        if (45...135).contains(diff) { return "right" }
        if (-135 ..< -45).contains(diff) { return "left" }
        return "behind"
    }

    /// BlindSpot-style rewrite: "Head left onto Main St, that's west".
    static func rewriteInstruction(_ raw: String, userHeading: Double?, from: CLLocationCoordinate2D, toward: CLLocationCoordinate2D) -> String {
        guard let userHeading else { return shorten(raw) }
        let target = bearingDegrees(from: from, to: toward)
        let relative = relativeDirection(userHeading: userHeading, targetBearing: target)
        let card = cardinal(fromBearing: target)
        let head: String
        switch relative {
        case "forward": head = "Head forward, that's \(card)"
        case "left": head = "Head left, that's \(card)"
        case "right": head = "Head right, that's \(card)"
        default: head = "Head behind you, that's \(card)"
        }
        for sep in [" onto ", " toward ", " on "] {
            if let range = raw.range(of: sep, options: .caseInsensitive) {
                let rest = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { return "\(head)\(sep)\(rest)" }
            }
        }
        return head
    }

    static func facingPhrase(heading: Double) -> String {
        "Facing \(cardinal(fromBearing: heading))."
    }

    static func obstaclePhrase(description: String) -> String {
        "Obstacle ahead: \(description)"
    }

    private static func shorten(_ text: String) -> String {
        var t = text
        for (from, to) in [("Proceed to the route", "Keep going"), ("Continue straight", "Keep straight")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return t.count > 90 ? String(t.prefix(87)) + "…" : t
    }
}
