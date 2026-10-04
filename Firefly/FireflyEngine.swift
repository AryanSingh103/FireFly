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
    /// Slow enough to clearly differ from the slowest obstacle rate (about 0.7 s at 2 m).
    private let heartbeatInterval: TimeInterval = 1.2
    private let pulseStrength: Float = 1.0
    /// Within this distance (about 3 ft) the continuous surface buzz runs.
    private let surfaceRange: Float = 0.9
    /// Side rhythms last up to 0.3 s; repeating faster than this blurs them together.
    private let minimumRhythmInterval: TimeInterval = 0.35
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
    private var lastAnnouncedDistance: Float = .infinity
    private var wasClose = false
    private var lastSceneRequest = Date.distantPast
    private var sceneRequestActive = false
    private var lastHazard = ""
    private var lastHazardTime = Date.distantPast
    private var flipWarned = false
    private var handlingUtterance = false
    private var speechWatchTask: Task<Void, Never>?
    /// When the speaker last started being busy. If it never finishes (a stuck player or fetch), every
    /// callout is refused and the mic stays paused, so it gets reset.
    private var speakingSince: Date?
    private let maxSpeakingTime: TimeInterval = 12

    override init() {
        super.init()
        // No setup questions: start with standard settings, changed later by voice ("Firefly, use metric").
        // Always start speaking. Quiet mode is only for the session it's turned on in; an old setup could
        // have saved it as the default and silenced every beep and callout.
        profile = UserProfile.load() ?? .standard
        listener.onUtterance = { [weak self] text in
            Task { @MainActor in self?.handleUtterance(text) }
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

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth
        session.delegate = self
        session.delegateQueue = frameQueue
        session.run(configuration)
        status = "Scanning"
        startFlipMonitor()
        listener.start()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.greetOnLaunch()
        }
    }

    /// Called when the app moves between foreground and background. In the background iOS refuses
    /// the audio session, and the listener kept retrying it.
    func setForeground(_ foreground: Bool) {
        if foreground {
            listener.start()
        } else {
            listener.stop()
            speaker.stop()
            haptics.stopSurface()
        }
    }

    /// 0 at the edge of the surface range, 1 at 0.3 m; nil when farther than the range.
    private func surfaceCloseness(_ distance: Float) -> Float? {
        guard distance < surfaceRange else { return nil }
        return 1 - min(max((distance - 0.3) / (surfaceRange - 0.3), 0), 1)
    }

    /// Repeat rate for the side rhythm. Inside the surface range the buzz shows closeness, so the rhythm
    /// keeps a steady, readable pace there.
    private func rhythmInterval(for alert: ObstacleAlert) -> TimeInterval {
        alert.zone == .center && alert.distance < surfaceRange ? 0.55 : max(alert.interval, minimumRhythmInterval)
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
        history.append(reading)
        if history.count > smoothingFrames { history.removeFirst() }
        distances = history.reduce(SIMD3<Float>(repeating: 0), +) / Float(history.count)
        alert = AlertPolicy.alert(for: distances)
        if (alert != nil) != obstacleNear { obstacleNear = alert != nil }

        let now = Date()

        // Haptics alone say where and how close, so quiet mode works by touch:
        // - clear path: one slow, steady tap so the wearer feels Firefly is working;
        // - obstacle in the path: a rhythm for its side (see HapticPulser.directional) that repeats faster
        //   as it gets closer, with a beep;
        // - the last stretch before something ahead: a continuous buzz that strengthens as you approach.
        let inPath = (alert?.distance ?? .infinity) < announceDistance
        // Only for something straight ahead: a wall beside you in a hallway shouldn't buzz the whole way.
        haptics.setSurface(closeness: alert.flatMap { $0.zone == .center ? surfaceCloseness($0.distance) : nil })
        if !inPath {
            if now.timeIntervalSince(lastPulse) >= heartbeatInterval {
                lastPulse = now
                haptics.pulse(intensity: pulseStrength)
            }
        } else if let alert, now.timeIntervalSince(lastPulse) >= rhythmInterval(for: alert) {
            lastPulse = now
            if quietMode, alert.distance < stopDistance {
                haptics.urgentStop()
            } else {
                haptics.directional(alert.zone, intensity: pulseStrength)
            }
            if !quietMode, !handlingUtterance {
                tones.beep(pan: 0)
            }
            pulseCount += 1
            if alert.distance < stopDistance { mood = .danger }
        }

        if speaker.isSpeaking {
            speakingSince = speakingSince ?? now
            if now.timeIntervalSince(speakingSince ?? now) > maxSpeakingTime {
                speaker.stop()
                speakingSince = nil
            }
        } else {
            speakingSince = nil
        }

        let speaking = speaker.isSpeaking
        if speaking != isSpeaking {
            isSpeaking = speaking
            if speaking {
                listener.setPaused(true)
            } else if !handlingUtterance {
                listener.setPaused(false)
                if mood != .danger { mood = .idle }
            }
        }

        speakWarnings(now: now)
        runSceneLoop(now: now)
    }

    private func speakWarnings(now: Date) {
        guard !handlingUtterance else { return }

        guard let alert else {
            lastAnnouncedZone = nil
            lastAnnouncedDistance = .infinity
            lastAnnouncedName = ""
            inPathSince = nil
            if wasClose, !quietMode, now.timeIntervalSince(lastVoice) > 2 {
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
                say("Stop", interrupt: true, allowNetwork: false)
            }
            return
        }

        guard !quietMode else { return }
        let geminiSpokeRecently = now.timeIntervalSince(lastHazardTime) < 6
        let isNewZone = alert.zone != lastAnnouncedZone
        let muchCloser = alert.distance < lastAnnouncedDistance - 0.6
        let isStale = now.timeIntervalSince(lastAnnouncement) > 10
        let inPath = alert.distance < announceDistance
        if inPath { inPathSince = inPathSince ?? now } else { inPathSince = nil }
        let name = deviceName(for: alert.zone, now: now)
        let nameChanged = name != nil && name != lastAnnouncedName
        // Give the on-device namer a moment, so the first callout is "Chair ahead", not "Obstacle ahead".
        let waitingForName = name == nil && now.timeIntervalSince(inPathSince ?? now) < 0.8
        if inPath, isNewZone || muchCloser || isStale || nameChanged, !waitingForName,
           !geminiSpokeRecently, now.timeIntervalSince(lastVoice) > 3 {
            let spokenName = name ?? "Obstacle"
            if say(callout(spokenName, alert), allowNetwork: false) {
                lastAnnouncedZone = alert.zone
                lastAnnouncedDistance = alert.distance
                lastAnnouncedName = spokenName
                lastAnnouncement = now
            }
        }
    }

    /// "Chair on your left, about 3 steps, maybe 7 feet". Each comma-separated part is a bundled clip.
    private func callout(_ name: String, _ alert: ObstacleAlert) -> String {
        let direction = directionWord(alert.zone)
        if profile?.verbosity == .brief { return "\(name) \(direction)" }
        let detail = profile?.formatDistance(alert.distance) ?? UserProfile.defaultDistance(alert.distance)
        return "\(name) \(direction), \(detail)"
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
        Task { await handleCommand(command) }
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
        isHandling = true
        mood = .thinking
        listener.setPaused(true)
        defer {
            handlingUtterance = false
            isHandling = false
            listener.setPaused(speaker.isSpeaking)
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

        if let reply = applySetting(lowered) {
            say(reply, interrupt: true)
            return
        }

        if lowered.contains("help") || lowered.contains("emergency") {
            mood = .danger
            say("I'm with you. Stay still if it feels unsafe. Call out for people nearby. I can describe what's around — ask me.", interrupt: true)
            return
        }

        if lowered.contains("stop") || lowered.contains("cancel") || lowered.contains("never mind") {
            speaker.stop()
            say("Okay", interrupt: true)
            return
        }

        if lowered.contains("close") || lowered.contains("quit") || lowered.contains("exit the app") {
            say("Closing Firefly.", interrupt: true)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            UIApplication.shared.perform(Selector(("suspend")))
            return
        }

        // Anything else is a question about what the camera sees: "what's in front of me?",
        // "what does that sign say?", "is that door open?".
        await describeScene(prompt: command)
    }

    /// Settings by voice: "Firefly, use metric", "use imperial", "shorter", "more detail", "careful pace",
    /// "normal pace". Returns the confirmation to speak, or nil if the command isn't a setting.
    private func applySetting(_ lowered: String) -> String? {
        var updated = profile ?? .standard
        let reply: String
        if lowered.contains("metric") || lowered.contains("meters") || lowered.contains("metres") {
            updated.units = .metersFirst
            reply = "Okay, I'll use meters."
        } else if lowered.contains("imperial") || lowered.contains("feet") {
            updated.units = .stepsFirst
            reply = "Okay, I'll use steps and feet."
        } else if lowered.contains("brief") || lowered.contains("shorter") || lowered.contains("less detail") {
            updated.verbosity = .brief
            reply = "Okay, I'll keep it short."
        } else if lowered.contains("more detail") || lowered.contains("normal detail") || lowered.contains("full detail") {
            updated.verbosity = .normal
            reply = "Okay, I'll give more detail."
        } else if lowered.contains("careful pace") || lowered.contains("slow pace") || lowered.contains("walk careful")
                    || lowered.contains("walking slowly") {
            updated.pace = .careful
            reply = "Okay, I'll count shorter steps."
        } else if lowered.contains("normal pace") || lowered.contains("regular pace") {
            updated.pace = .normal
            reply = "Okay, normal steps."
        } else {
            return nil
        }
        updated.save()
        profile = updated
        return reply
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
        guard !quietMode, !handlingUtterance, !sceneRequestActive,
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
            lastAnnouncedDistance = alert.distance
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
        listener.setPaused(true)
        if mood != .danger { mood = .listening }
        watchSpeechEnd()
        return true
    }

    /// ElevenLabs TTS is async, so speaker.isSpeaking is false for a bit after say() — keep mic paused until audio finishes.
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
            if !self.handlingUtterance {
                self.listener.setPaused(false)
            }
            if self.mood == .listening { self.mood = .idle }
        }
    }
}
