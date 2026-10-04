import Foundation

enum Verbosity: String, Codable {
    case brief, normal
}

enum UnitPreference: String, Codable {
    case stepsFirst
    /// Feet first. Imperial is the default.
    case distanceFirst
    case metersFirst
}

enum WalkingPace: String, Codable {
    case careful, normal
}

struct UserProfile: Codable, Equatable {
    var name: String
    var verbosity: Verbosity
    var units: UnitPreference
    var pace: WalkingPace
    var quietByDefault: Bool

    static let storageKey = "firefly.userProfile"

    /// What Firefly uses until changed by voice: normal detail, steps and feet, normal pace, speaking.
    static let standard = UserProfile(name: "", verbosity: .normal, units: .stepsFirst, pace: .normal, quietByDefault: false)

    static func load() -> UserProfile? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(UserProfile.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Rough step estimate from metres (pace-aware).
    func steps(forMeters meters: Float) -> Int {
        let stride: Float = pace == .careful ? 0.55 : 0.7
        return max(1, Int((meters / stride).rounded()))
    }

    /// Comma-separated so each part can be a bundled clip (see Speaker and scripts/generate_phrases.py).
    func formatDistance(_ meters: Float) -> String {
        let steps = steps(forMeters: meters)
        let feet = Self.feet(meters)
        switch units {
        case .stepsFirst:
            return "about \(steps) \(steps == 1 ? "step" : "steps"), maybe \(feet) feet"
        case .distanceFirst:
            return "about \(feet) feet, roughly \(steps) \(steps == 1 ? "step" : "steps")"
        case .metersFirst:
            let meterText = meters < 10 ? String(format: "%.1f meters", meters) : "\(Int(meters.rounded())) meters"
            return "about \(meterText), roughly \(steps) \(steps == 1 ? "step" : "steps")"
        }
    }

    /// Used when no profile is available.
    static func defaultDistance(_ meters: Float) -> String {
        "about \(feet(meters)) feet"
    }

    private static func feet(_ meters: Float) -> Int {
        max(1, Int((meters * 3.281).rounded()))
    }
}

enum GuideMode: String {
    case passive
    case navigate
}

enum AgentPhase: String {
    case ready
    case awaitingNavConfirm
    case handling
}
