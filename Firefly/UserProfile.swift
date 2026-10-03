import Foundation

enum Verbosity: String, Codable {
    case brief, normal
}

enum UnitPreference: String, Codable {
    case stepsFirst
    case distanceFirst
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

    func formatDistance(_ meters: Float) -> String {
        let steps = steps(forMeters: meters)
        let feet = Int((meters * 3.281).rounded())
        let meterText = meters < 10 ? String(format: "%.1f meters", meters) : "\(Int(meters.rounded())) meters"
        switch units {
        case .stepsFirst:
            return "about \(steps) steps, maybe \(feet) feet"
        case .distanceFirst:
            return "about \(meterText), roughly \(steps) steps"
        }
    }
}

enum GuideMode: String {
    case passive
    case navigate
}

enum AgentPhase: String {
    case onboarding
    case ready
    case awaitingNavConfirm
    case handling
}
