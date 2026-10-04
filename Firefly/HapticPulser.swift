import CoreHaptics
import QuartzCore

/// The phone has one vibration motor, so direction is carried by rhythm and closeness by rate and, up
/// close, by a continuous "surface" buzz that strengthens as you approach.
final class HapticPulser {
    private var engine: CHHapticEngine?
    private var surfacePlayer: CHHapticAdvancedPatternPlayer?
    private var lastSurfaceUpdate: CFTimeInterval = 0

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        // After an interruption the engine resets and running players become invalid; the surface player
        // is rebuilt on its next update.
        engine?.resetHandler = { [weak self] in
            try? self?.engine?.start()
        }
        try? engine?.start()
    }

    /// Obstacle rhythm by side:
    ///   ahead: single tap      "tap"
    ///   left:  quick double    "ta-tap"
    ///   right: long then short "taaa-tap"
    func directional(_ zone: Zone, intensity: Float) {
        switch zone {
        case .center:
            play(events: [tap(at: 0, intensity: intensity)])
        case .left:
            play(events: [tap(at: 0, intensity: intensity), tap(at: 0.1, intensity: intensity)])
        case .right:
            play(events: [
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
                    ],
                    relativeTime: 0,
                    duration: 0.2
                ),
                tap(at: 0.3, intensity: intensity)
            ])
        }
    }

    /// Continuous buzz for the last stretch before an obstacle. `closeness` runs from 0 (edge of the
    /// range) to 1 (about to touch); nil stops it. Cheap to call every frame.
    func setSurface(closeness: Float?) {
        guard let engine else { return }
        guard let closeness else {
            stopSurface()
            return
        }
        let now = CACurrentMediaTime()
        if surfacePlayer != nil, now - lastSurfaceUpdate < 0.05 { return }
        lastSurfaceUpdate = now

        if surfacePlayer == nil {
            do {
                let hum = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                    ],
                    relativeTime: 0,
                    duration: 2
                )
                let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [hum], parameters: []))
                player.loopEnabled = true
                try player.start(atTime: CHHapticTimeImmediate)
                surfacePlayer = player
            } catch {
                try? engine.start()
                return
            }
        }
        let parameters = [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0.25 + 0.75 * closeness, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: -0.3 + 0.6 * closeness, relativeTime: 0)
        ]
        do {
            try surfacePlayer?.sendParameters(parameters, atTime: CHHapticTimeImmediate)
        } catch {
            surfacePlayer = nil
        }
    }

    func stopSurface() {
        try? surfacePlayer?.stop(atTime: CHHapticTimeImmediate)
        surfacePlayer = nil
    }

    private func tap(at time: TimeInterval, intensity: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
            ],
            relativeTime: time
        )
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
