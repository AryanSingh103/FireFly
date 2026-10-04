import ARKit
import AVFoundation
import Combine
import CoreMotion
import Speech
import UIKit

/// Firefly is a passive companion: it watches the next few steps and calls out what's there. Getting
/// somewhere is left to a maps app running alongside it.
@MainActor
final class FireflyEngine: NSObject, ObservableObject, ARSessionDelegate {
    enum Mood: String {
        case idle, listening, thinking, danger, happy
    }

    private(set) var distances = SIMD3<Float>(repeating: 5)
    private(set) var alert: ObstacleAlert?
    /// Published only when it flips, unlike `alert`, which changes every frame.
    @Published private(set) var obstacleNear = false
    @Published private(set) var pulseCount = 0
    @Published private(set) var caption = ""
    @Published private(set) var status = "Starting"
    @Published private(set) var isHandling = false
    @Published private(set) var mood = Mood.idle
    @Published private(set) var isSpeaking = false
    @Published private(set) var quietMode = false
    @Published private(set) var profile: UserProfile?
    @Published private(set) var preview: DebugPreview?
    @Published private(set) var lastHeard = ""

    /// Shared with the live camera view in ContentView.
    let session = ARSession()
    private let haptics = HapticPulser()
    private let tones = TonePlayer()
    private let speaker = Speaker()
    private let listener = AlwaysListener()
    private let motion = CMMotionManager()

    private let smoothingFrames = 5
    private let stopDistance: Float = 0.5
    private let announceDistance: Float = 2.0
    /// Automatic obstacle naming. Each call costs one Gemini request, and free-tier keys get very few per day.
    private let sceneInterval: TimeInterval = 10
    private let heartbeatInterval: TimeInterval = 1.1
    /// Set when Gemini answers 429; automatic calls stop until then.
    private var geminiPausedUntil = Date.distantPast
    private nonisolated static let previewInterval: TimeInterval = 0.12
    private let frameQueue = DispatchQueue(label: "firefly.frames", qos: .userInteractive)
    /// Only touched on frameQueue.
    private nonisolated(unsafe) var lastPreviewTime = Date.distantPast
    /// Only touched on frameQueue.
    private nonisolated(unsafe) var lastNamingTime = Date.distantPast
    private nonisolated static let namingInterval: TimeInterval = 0.7
    private nonisolated static let namingRange: Float = 2.0
    /// What the on-device namer last saw in each zone.
    private var deviceNames: [Zone: (name: String, time: Date)] = [:]
    private let deviceNameLifetime: TimeInterval = 1.5
    /// When the current in-path obstacle first appeared; a generic "Obstacle" callout waits briefly for a name.
    private var inPathSince: Date?
    private var lastAnnouncedName = ""

    private var history: [SIMD3<Float>] = []
    private var lastPulse = Date.distantPast
    private var lastStop = Date.distantPast
    private var lastVoice = Date.distantPast
    private var lastAnnouncement = Date.distantPast
    private var lastAnnouncedZone: Zone?
    private var wasClose = false
    private var lastSceneRequest = Date.distantPast
    private var sceneRequestActive = false
    private var lastHazard = ""
    private var lastHazardTime = Date.distantPast
    private var flipWarned = false
    private var handlingUtterance = false
    private var speechWatchTask: Task<Void, Never>?
    /// For the health check: when the last depth frame arrived, and since when a question has been worked on.
    private var lastFrameAt = Date()
    private var handlingSince: Date?
    private var isForeground = true
    private var healthTask: Task<Void, Never>?
    /// Set when the wearer says "Firefly" over Firefly; callouts hold off so they don't talk over the request.
    private var awaitingRequestUntil = Date.distantPast

    override init() {
        super.init()
        // No setup questions: always start with standard settings (feet first, speaking).
        profile = .standard
        listener.onUtterance = { [weak self] text in
            Task { @MainActor in self?.handleUtterance(text) }
        }
        listener.onWake = { [weak self] in
            Task { @MainActor in self?.interruptedByWearer() }
        }
    }

    func start() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            status = "This iPhone has no LiDAR"
            caption = status
            return
        }

        AVAudioSession.sharedInstance().requestRecordPermission { @Sendable _ in }
        SFSpeechRecognizer.requestAuthorization { @Sendable _ in }

        session.delegate = self
        session.delegateQueue = frameQueue
        runSession()
        status = "Scanning"
        startFlipMonitor()
        listener.start()
        startHealthCheck()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.greetOnLaunch()
        }
    }

    private func runSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth
        session.run(configuration)
        lastFrameAt = Date()
    }

    /// Runs once a second, outside the frame loop, so it still runs if frames stop. Brings back anything
    /// that would otherwise leave Firefly silent for good: depth frames that stopped arriving, a question
    /// that never finished (which kept beeps, callouts and the mic switched off), and the audio session.
    private func startHealthCheck() {
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.checkHealth()
            }
        }
    }

    private func checkHealth() {
        guard isForeground else { return }
        let now = Date()
        if now.timeIntervalSince(lastFrameAt) > 2 {
            status = "Restarting the camera"
            runSession()
        }
        if let handlingSince, now.timeIntervalSince(handlingSince) > 20 {
            self.handlingSince = nil
            handlingUtterance = false
            isHandling = false
            if mood == .thinking { mood = .idle }
            syncListener()
        }
        tones.keepSessionActive()
        if !handlingUtterance {
            syncListener()
            listener.ensureRunning()
        }
    }

    /// Called when the app moves between foreground and background. In the background iOS refuses
    /// the audio session, and the listener kept retrying it.
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        lastFrameAt = Date()
        if foreground {
            listener.start()
        } else {
            listener.stop()
            speaker.stop()
        }
    }

    // MARK: - ARKit

    /// Runs on frameQueue. Everything that needs the frame happens here, so ARKit gets each frame back
    /// immediately; only small values cross to the main actor. (Doing this on the main queue let frames
    /// pile up behind UI work and ARKit warned it would stop delivering camera images.)
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // If this queue fell behind, skip stale frames so ARKit gets them back at once instead of
        // queueing up (ARKit stops the camera if too many are held).
        guard ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.05 else { return }
        guard let depth = frame.sceneDepth else { return }
        let reading = DepthZoneAnalyzer.nearestPerZone(in: depth)
        var preview: DebugPreview?
        let now = Date()
        if now.timeIntervalSince(lastPreviewTime) >= Self.previewInterval {
            lastPreviewTime = now
            preview = DebugPreview(frame: frame, points: reading.points)
        }
        // Name the nearest obstacle in the path on the device (Apple Vision): offline and unlimited.
        var named: (zone: Zone, name: String?)?
        if now.timeIntervalSince(lastNamingTime) >= Self.namingInterval,
           let nearest = Zone.allCases.min(by: { reading.distances[$0.rawValue] < reading.distances[$1.rawValue] }),
           reading.distances[nearest.rawValue] < Self.namingRange,
           let point = reading.points[nearest.rawValue] {
            lastNamingTime = now
            named = (nearest, ObstacleNamer.name(in: frame, at: point))
        }
        Task { @MainActor in
            self.ingest(reading.distances)
            if let preview { self.preview = preview }
            if let named {
                if let name = named.name {
                    self.deviceNames[named.zone] = (name, Date())
                } else {
                    self.deviceNames[named.zone] = nil
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.status = message }
    }

    // MARK: - Safety loop

    private func ingest(_ reading: SIMD3<Float>) {
        lastFrameAt = Date()
        if status == "Restarting the camera" { status = "Scanning" }
        history.append(reading)
        if history.count > smoothingFrames { history.removeFirst() }
        distances = history.reduce(SIMD3<Float>(repeating: 0), +) / Float(history.count)
        alert = AlertPolicy.alert(for: distances)
        if (alert != nil) != obstacleNear { obstacleNear = alert != nil }

        let now = Date()

        // Something within speaking range is "in the path": fast pulses and beeps. Anything farther
        // (or nothing at all) gets a steady heartbeat, so the wearer can feel Firefly is still working.
        let inPath = (alert?.distance ?? .infinity) < announceDistance
        if !inPath {
            if now.timeIntervalSince(lastPulse) >= heartbeatInterval {
                lastPulse = now
                haptics.heartbeat()
            }
        } else if let alert, now.timeIntervalSince(lastPulse) >= alert.interval {
            lastPulse = now
            if quietMode, alert.distance < stopDistance {
                haptics.urgentStop()
            } else {
                haptics.pulse(intensity: alert.intensity)
            }
            if !quietMode, !handlingUtterance {
                tones.beep(pan: 0)
            }
            pulseCount += 1
            if alert.distance < stopDistance { mood = .danger }
        }

        speaker.recoverIfStuck()
        let speaking = speaker.isSpeaking
        if speaking != isSpeaking {
            isSpeaking = speaking
            syncListener()
            if !speaking, !handlingUtterance, mood != .danger { mood = .idle }
        }

        speakWarnings(now: now)
        runSceneLoop(now: now)
    }

    private func speakWarnings(now: Date) {
        guard !handlingUtterance else { return }

        guard let alert else {
            lastAnnouncedZone = nil
            lastAnnouncedName = ""
            inPathSince = nil
            if wasClose, !quietMode, now >= awaitingRequestUntil, now.timeIntervalSince(lastVoice) > 2 {
                say("Clear path", allowNetwork: false)
            }
            wasClose = false
            if mood == .danger { mood = .idle }
            return
        }

        if alert.distance < announceDistance { wasClose = true }

        if alert.distance < stopDistance, now.timeIntervalSince(lastStop) > 3 {
            lastStop = now
            mood = .danger
            if quietMode {
                haptics.urgentStop()
            } else {
                say(dodge(for: alert).map { "Stop, \($0)" } ?? "Stop", interrupt: true, allowNetwork: false)
            }
            return
        }

        guard !quietMode, now >= awaitingRequestUntil else { return }
        let geminiSpokeRecently = now.timeIntervalSince(lastHazardTime) < 6
        let isNewZone = alert.zone != lastAnnouncedZone || now.timeIntervalSince(lastAnnouncement) > 5
        let inPath = alert.distance < announceDistance
        if inPath { inPathSince = inPathSince ?? now } else { inPathSince = nil }
        let name = deviceName(for: alert.zone, now: now)
        let nameChanged = name != nil && name != lastAnnouncedName
        // Give the on-device namer a moment, so the first callout is "Chair ahead", not "Obstacle ahead".
        let waitingForName = name == nil && now.timeIntervalSince(inPathSince ?? now) < 0.8
        if inPath, isNewZone || nameChanged, !waitingForName,
           !geminiSpokeRecently, now.timeIntervalSince(lastVoice) > 2.5 {
            let spokenName = name ?? "Obstacle"
            if say(callout(spokenName, alert), allowNetwork: false) {
                lastAnnouncedZone = alert.zone
                lastAnnouncedName = spokenName
                lastAnnouncement = now
            }
        }
    }

    /// "Chair on your left, about 7 feet, roughly 3 steps", plus "move left" and the like for something
    /// ahead. Each comma-separated part is a bundled clip.
    private func callout(_ name: String, _ alert: ObstacleAlert) -> String {
        let direction = directionWord(alert.zone)
        var parts = ["\(name) \(direction)"]
        if profile?.verbosity != .brief {
            parts.append(profile?.formatDistance(alert.distance) ?? UserProfile.defaultDistance(alert.distance))
        }
        if let dodge = dodge(for: alert) { parts.append(dodge) }
        return parts.joined(separator: ", ")
    }

    /// Which way to get around something. For anything in the path ahead (even when a side reads a few
    /// centimetres nearer, as a big object right in front often does): "move" toward a side open enough to
    /// step into, otherwise "turn" toward the more open side to look for a way through. For something
    /// very close on one side only: move away from it.
    private func dodge(for alert: ObstacleAlert) -> String? {
        let left = distances[Zone.left.rawValue]
        let center = distances[Zone.center.rawValue]
        let right = distances[Zone.right.rawValue]
        if center < announceDistance {
            let side = left >= right ? "left" : "right"
            return max(left, right) >= max(center + 0.7, 1.5) ? "move \(side)" : "turn \(side)"
        }
        if alert.distance < stopDistance {
            return alert.zone == .left ? "move right" : "move left"
        }
        return nil
    }

    private func deviceName(for zone: Zone, now: Date = Date()) -> String? {
        guard let entry = deviceNames[zone], now.timeIntervalSince(entry.time) < deviceNameLifetime else { return nil }
        return entry.name
    }

    private func directionWord(_ zone: Zone) -> String {
        switch zone {
        case .left: return "on your left"
        case .center: return "ahead"
        case .right: return "on your right"
        }
    }

    // MARK: - Voice

    /// A fixed sentence with a bundled clip, so the first thing anyone hears is Firefly's voice instantly,
    /// with or without Wi-Fi.
    private func greetOnLaunch() {
        say("Hi, I'm Firefly. I'll watch the path with you.", interrupt: true)
        status = "Say Firefly, then your question"
    }

    private func handleUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastHeard = trimmed
        guard let command = Self.stripFireflyPrefix(trimmed) else { return }
        // A short chime says "I heard you", so a slow answer isn't mistaken for not being heard.
        // After an interruption it already chimed.
        if Date() >= awaitingRequestUntil { tones.chime(pan: 0) }
        awaitingRequestUntil = .distantPast
        Task { await handleCommand(command) }
    }

    /// The wearer said "Firefly" while Firefly was talking: go quiet at once and listen for the request.
    private func interruptedByWearer() {
        speechWatchTask?.cancel()
        speaker.stop()
        isSpeaking = false
        caption = ""
        awaitingRequestUntil = Date().addingTimeInterval(7)
        mood = .listening
        tones.chime(pan: 0)
        syncListener()
    }

    /// What the mic listens for. Nothing while Firefly works on a question. While it talks, only "Firefly",
    /// so the wearer can interrupt; but not during a line that itself says "Firefly", which would
    /// interrupt itself. Otherwise, everything.
    private func syncListener() {
        let talking = speaker.isSpeaking
        if handlingUtterance || talking && caption.lowercased().contains("firefly") {
            listener.setPaused(true)
        } else {
            listener.setSpeaking(talking)
            listener.setPaused(false)
        }
    }

    private static func stripFireflyPrefix(_ text: String) -> String? {
        let lowered = text.lowercased()
        let prefixes = ["firefly,", "firefly ", "hey firefly,", "hey firefly ", "ok firefly,", "okay firefly "]
        for prefix in prefixes where lowered.hasPrefix(prefix) {
            return text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Exact wake only
        if lowered == "firefly" || lowered == "hey firefly" { return "" }
        return nil
    }

    private func handleCommand(_ command: String) async {
        handlingUtterance = true
        handlingSince = Date()
        isHandling = true
        mood = .thinking
        listener.setPaused(true)
        defer {
            handlingUtterance = false
            handlingSince = nil
            isHandling = false
            syncListener()
            if mood == .thinking { mood = .idle }
        }

        let lowered = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered.isEmpty {
            say("I'm here. Ask me what's in front of you.", interrupt: true)
            return
        }

        if lowered.contains("quiet") && (lowered.contains("on") || lowered.contains("enable") || lowered.contains("start")) {
            quietMode = true
            say("Quiet mode on. I'll tap only.", interrupt: true)
            return
        }
        if lowered.contains("quiet") && (lowered.contains("off") || lowered.contains("disable") || lowered.contains("stop"))
            || lowered.contains("speak again") || lowered.contains("talk again") {
            quietMode = false
            say("Quiet mode off. I'll speak again.", interrupt: true)
            return
        }

        if lowered == "help" || lowered == "help me" || lowered.contains("emergency") {
            mood = .danger
            say("I'm with you. Stay still if it feels unsafe. Call out for people nearby. I can describe what's around — ask me.", interrupt: true)
            return
        }

        if lowered.hasPrefix("stop") && !lowered.contains("sign") || lowered.contains("cancel") || lowered.contains("never mind") {
            speaker.stop()
            say("Okay", interrupt: true)
            return
        }

        if lowered == "close" || lowered.contains("close the app") || lowered.contains("close firefly")
            || lowered.contains("quit") || lowered.contains("exit the app") {
            say("Closing Firefly.", interrupt: true)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            UIApplication.shared.perform(Selector(("suspend")))
            return
        }

        // Anything else is a question about what the camera sees: "what's in front of me?",
        // "what does that sign say?", "is that door open?".
        await describeScene(prompt: command)
    }

    private func describeScene(prompt: String) async {
        mood = .thinking
        guard let snapshot = await captureSnapshot() else { return }
        do {
            let reply = try await GeminiClient.answer(prompt, in: snapshot.jpeg)
            say(reply.isEmpty ? "I'm not sure what's there." : reply, interrupt: true)
        } catch {
            say(geminiProblem(error), interrupt: true)
        }
    }

    /// What to say when a Gemini request fails. Only a real network failure is called "no connection".
    private func geminiProblem(_ error: Error) -> String {
        switch error as? GeminiClient.Failure {
        case .offline:
            return "I can't reach the internet right now, but I'm still watching for obstacles."
        case .quota(let retryAfter):
            geminiPausedUntil = Date().addingTimeInterval(retryAfter)
            return "I've used up my AI requests for now, but I'm still watching for obstacles."
        default:
            return "Something went wrong asking the AI, but I'm still watching for obstacles."
        }
    }

    // MARK: - Gemini naming (only for what the phone couldn't name)

    private func runSceneLoop(now: Date) {
        guard !quietMode, !handlingUtterance, !sceneRequestActive, now >= awaitingRequestUntil,
              now.timeIntervalSince(lastSceneRequest) >= sceneInterval,
              now >= geminiPausedUntil,
              let alert, alert.distance < announceDistance, deviceName(for: alert.zone) == nil
        else { return }
        lastSceneRequest = now
        sceneRequestActive = true
        Task {
            defer { sceneRequestActive = false }
            guard let snapshot = await captureSnapshot() else { return }
            do {
                announceHazard(try await GeminiClient.nearestHazard(in: snapshot.jpeg))
            } catch GeminiClient.Failure.quota(let retryAfter) {
                // Background naming is optional; just stop asking until the quota resets.
                geminiPausedUntil = Date().addingTimeInterval(retryAfter)
            } catch {}
        }
    }

    private func announceHazard(_ phrase: String) {
        guard !quietMode else { return }
        let object = (phrase.components(separatedBy: ",").first ?? "")
            .trimmingCharacters(in: CharacterSet.letters.inverted)
        guard let alert, alert.distance >= stopDistance,
              !object.isEmpty, object.count < 25, !object.lowercased().hasPrefix("none")
        else { return }
        let name = "\(object.prefix(1).uppercased())\(object.dropFirst().lowercased())"
        let hazard = callout(name, alert)
        let now = Date()
        if hazard == lastHazard, now.timeIntervalSince(lastHazardTime) < 10 { return }
        if say(hazard) {
            lastHazard = hazard
            lastHazardTime = now
            lastAnnouncedZone = alert.zone
            lastAnnouncedName = name
            lastAnnouncement = now
        }
    }

    // MARK: - Flip once

    private func startFlipMonitor() {
        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 0.5
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data, !self.flipWarned else { return }
            // Upside down / camera likely facing wrong way for chest mount.
            if data.acceleration.y > 0.65 {
                self.flipWarned = true
                if !self.quietMode {
                    self.say("I might be flipped — check the lanyard.", interrupt: true, allowNetwork: false)
                } else {
                    self.haptics.urgentStop()
                }
            }
        }
    }

    // MARK: - Helpers

    /// JPEG encoding takes tens of milliseconds, so it runs off the main thread.
    private func captureSnapshot() async -> FrameSnapshot? {
        guard let frame = session.currentFrame else { return nil }
        return await Task.detached(priority: .userInitiated) { FrameSnapshot(frame: frame) }.value
    }

    @discardableResult
    private func say(_ text: String, interrupt: Bool = false, allowNetwork: Bool = true) -> Bool {
        // Quiet mode mutes safety callouts (handled in speakWarnings). Replies to "Firefly, …" still speak.
        guard speaker.say(text, pan: 0, interrupt: interrupt, allowNetwork: allowNetwork) else { return false }
        caption = text
        lastVoice = Date()
        isSpeaking = true
        syncListener()
        if mood != .danger { mood = .listening }
        watchSpeechEnd()
        return true
    }

    /// ElevenLabs TTS is async, so speaker.isSpeaking is false for a bit after say(); the mic stays in
    /// "Firefly only" mode until the audio finishes.
    private func watchSpeechEnd() {
        speechWatchTask?.cancel()
        speechWatchTask = Task { @MainActor in
            for _ in 0..<40 {
                if Task.isCancelled { return }
                if speaker.isSpeaking { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            while speaker.isSpeaking {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.isSpeaking = false
            self.syncListener()
            if self.mood == .listening { self.mood = .idle }
        }
    }
}
