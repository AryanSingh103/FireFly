import CoreHaptics

final class HapticPulser {
    private var engine: CHHapticEngine?

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        try? engine?.start()
    }

    func pulse(intensity: Float) {
        play(events: [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
                ],
                relativeTime: 0
            )
        ])
    }

    /// "All clear": a soft lub-dub, played steadily while nothing is in the path.
    func heartbeat() {
        play(events: [(0.0, Float(0.55)), (0.16, Float(0.35))].map { time, intensity in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)
                ],
                relativeTime: time
            )
        })
    }

    /// Quiet-mode danger: three sharp pulses, no voice.
    func urgentStop() {
        play(events: (0..<3).map { index in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 1)
                ],
                relativeTime: Double(index) * 0.12
            )
        })
    }

    private func play(events: [CHHapticEvent]) {
        guard let engine else { return }
        do {
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            try? engine.start()
        }
    }
}
