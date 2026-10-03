import ARKit
import AVFoundation
import Combine
import CoreMotion
import Speech
import UIKit

@MainActor
final class FireflyEngine: NSObject, ObservableObject, ARSessionDelegate {
    enum Mood: String {
        case idle, listening, thinking, guiding, danger, happy
    }

    @Published private(set) var distances = SIMD3<Float>(repeating: 5)
    @Published private(set) var alert: ObstacleAlert?
    @Published private(set) var pulseCount = 0
    @Published private(set) var caption = ""
    @Published private(set) var status = "Starting"
    @Published private(set) var guideMode = GuideMode.passive
    @Published private(set) var phase = AgentPhase.onboarding
    @Published private(set) var mood = Mood.idle
    @Published private(set) var isSpeaking = false
    @Published private(set) var quietMode = false
    @Published private(set) var beaconName: String?
    @Published private(set) var profile: UserProfile?
    @Published private(set) var preview: DebugPreview?
    @Published private(set) var lastHeard = ""

    let maps = MapNavigator()

    private let session = ARSession()
    private let haptics = HapticPulser()
    private let tones = TonePlayer()
    private let speaker = Speaker()
    private let listener = AlwaysListener()
    private let motion = CMMotionManager()

    private let smoothingFrames = 5
    private let dangerDistance: Float = 1.0
    private let stopDistance: Float = 0.5
    private let announceDistance: Float = 2.0
    private let arrivalDistance: Float = 1.2
    private let sceneInterval: TimeInterval = 4
    private let previewInterval: TimeInterval = 0.12

    private var history: [SIMD3<Float>] = []
    private var beacon: Beacon?
    private var lastCamera = matrix_identity_float4x4
    private var lastPulse = Date.distantPast
    private var lastChime = Date.distantPast
    private var lastStop = Date.distantPast
    private var lastVoice = Date.distantPast
    private var lastAnnouncement = Date.distantPast
    private var lastAnnouncedZone: Zone?
    private var wasClose = false
    private var lastSceneRequest = Date.distantPast
    private var sceneRequestActive = false
    private var lastHazard = ""
    private var lastHazardTime = Date.distantPast
    private var lastPreview = Date.distantPast
    private var lastMapPrompt = ""
    private var flipWarned = false
    private var onboardingStep = 0
    private var draft = UserProfile(
        name: "",
        verbosity: .normal,
        units: .stepsFirst,
        pace: .normal,
        quietByDefault: false
    )
    private var handlingUtterance = false
    private var askedExitFirst = false
    private var speechWatchTask: Task<Void, Never>?

    override init() {
        super.init()
        profile = UserProfile.load()
        if let profile {
            quietMode = profile.quietByDefault
            phase = .ready
        } else {
            phase = .onboarding
        }
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
        maps.requestPermission()

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth
        session.delegate = self
        session.run(configuration)
        status = "Scanning"
        startFlipMonitor()
        listener.start()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self.greetOnLaunch()
        }
    }

    // MARK: - ARKit

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depth = frame.sceneDepth else { return }
        let reading = DepthZoneAnalyzer.nearestPerZone(in: depth)
        let camera = frame.camera.transform
        MainActor.assumeIsolated {
            ingest(reading.distances, camera: camera)
            updatePreview(from: frame, points: reading.points)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.status = message }
    }

    private func updatePreview(from frame: ARFrame, points: [SIMD2<Float>?]) {
        let now = Date()
        guard now.timeIntervalSince(lastPreview) >= previewInterval else { return }
        lastPreview = now
        preview = DebugPreview(frame: frame, points: points)
    }

    // MARK: - Safety loop

    private func ingest(_ reading: SIMD3<Float>, camera: simd_float4x4) {
        lastCamera = camera
        history.append(reading)
        if history.count > smoothingFrames { history.removeFirst() }
        distances = history.reduce(SIMD3<Float>(repeating: 0), +) / Float(history.count)
        alert = AlertPolicy.alert(for: distances)

        let now = Date()
        let inDanger = (alert?.distance ?? .infinity) < dangerDistance
        maps.setPausedForObstacle(inDanger && maps.isNavigating)

        if let alert, now.timeIntervalSince(lastPulse) >= alert.interval {
            lastPulse = now
            if quietMode, alert.distance < stopDistance {
                haptics.urgentStop()
            } else {
                haptics.pulse(intensity: alert.intensity)
            }
            if !quietMode, phase != .handling, beacon == nil || inDanger {
                tones.beep(pan: 0)
            }
            pulseCount += 1
            if alert.distance < stopDistance { mood = .danger }
        }

        let speaking = speaker.isSpeaking
        if speaking != isSpeaking {
            isSpeaking = speaking
            if speaking {
                listener.setPaused(true)
            } else if !handlingUtterance {
                listener.setPaused(false)
                if mood != .danger, mood != .guiding { mood = .idle }
            }
        }

        speakWarnings(now: now)
        updateBeacon(camera: camera, inDanger: inDanger, now: now)
        runSceneLoop(now: now)
        speakMapStepIfNeeded(now: now)
    }

    private func speakWarnings(now: Date) {
        guard phase != .onboarding else { return }
        guard !handlingUtterance else { return }

        guard let alert else {
            lastAnnouncedZone = nil
            if wasClose, !quietMode, now.timeIntervalSince(lastVoice) > 2 {
                say("Clear path", allowNetwork: false)
            }
            wasClose = false
            if mood == .danger { mood = guideMode == .navigate ? .guiding : .idle }
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
        let isNewZone = alert.zone != lastAnnouncedZone || now.timeIntervalSince(lastAnnouncement) > 5
        if alert.distance < announceDistance, isNewZone, !geminiSpokeRecently, now.timeIntervalSince(lastVoice) > 2.5 {
            let direction = directionWord(alert.zone)
            let line: String
            if profile?.verbosity == .brief {
                line = "Obstacle \(direction)"
            } else {
                let detail = profile?.formatDistance(alert.distance) ?? String(format: "%.1f meters", alert.distance)
                line = "Obstacle \(direction), \(detail)"
            }
            if say(line, allowNetwork: false) {
                lastAnnouncedZone = alert.zone
                lastAnnouncement = now
            }
        }
    }

    private func directionWord(_ zone: Zone) -> String {
        switch zone {
        case .left: return "on your left"
        case .center: return "ahead"
        case .right: return "on your right"
        }
    }

    // MARK: - Beacon (exit / door)

    private func updateBeacon(camera: simd_float4x4, inDanger: Bool, now: Date) {
        guard let beacon else { return }
        mood = .guiding
        let guidance = beacon.guidance(from: camera)
        if !beacon.isApproximate, guidance.distance < arrivalDistance {
            self.beacon = nil
            beaconName = nil
            guideMode = .passive
            mood = .happy
            say("You're at the \(beacon.name). Anything else?", interrupt: true)
        } else if !inDanger, !quietMode, now.timeIntervalSince(lastChime) >= guidance.interval {
            lastChime = now
            tones.chime(pan: 0)
            if now.timeIntervalSince(lastVoice) > 4 {
                let side: String
                if guidance.pan < -0.35 { side = "a bit left" }
                else if guidance.pan > 0.35 { side = "a bit right" }
                else { side = "straight ahead" }
                let detail = profile?.formatDistance(guidance.distance) ?? String(format: "%.1f meters", guidance.distance)
                _ = say("Exit \(side), \(detail)", allowNetwork: false)
            }
        }
    }

    private func startBeacon(to target: String) async {
        guideMode = .navigate
        mood = .thinking
        for attempt in 0..<3 {
            guard let snapshot = captureSnapshot() else { break }
            do {
                if let point = try await GeminiClient.locate(target, in: snapshot.jpeg) {
                    let located = snapshot.worldPoint(atPhotoPoint: point)
                    setBeacon(Beacon(name: target, position: located.position, isApproximate: located.isApproximate))
                    return
                }
            } catch {
                say("Sorry, there's no connection right now, but I can stay in Passive and watch for obstacles.", interrupt: true)
                guideMode = .passive
                return
            }
            if attempt < 2 {
                say("Turn slowly", interrupt: true)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
        say("I can't see a \(target) yet. Turn slowly and ask me again.", interrupt: true)
        guideMode = .passive
    }

    private func setBeacon(_ newBeacon: Beacon) {
        beacon = newBeacon
        beaconName = newBeacon.name
        guideMode = .navigate
        mood = .guiding
        say("Found the \(newBeacon.name). I'll guide you there.", interrupt: true)
    }

    // MARK: - Launch / onboarding

    private func greetOnLaunch() async {
        if let profile {
            phase = .ready
            say("Hi \(profile.name), how can I help? Where do you want to go?", interrupt: true)
            status = "Say Firefly, then your request"
        } else {
            phase = .onboarding
            onboardingStep = 0
            say("Hi — I'm Firefly. What's your name?", interrupt: true)
            status = "Onboarding"
        }
    }

    private func handleUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastHeard = trimmed

        if phase == .onboarding {
            Task { await advanceOnboarding(with: trimmed) }
            return
        }

        if phase == .awaitingNavConfirm {
            Task { await handleNavConfirm(trimmed) }
            return
        }

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
        if lowered == "firefly" { return "" }
        return nil
    }

    private func advanceOnboarding(with text: String) async {
        handlingUtterance = true
        listener.setPaused(true)
        defer {
            handlingUtterance = false
            listener.setPaused(speaker.isSpeaking)
        }
        let lowered = text.lowercased()
        switch onboardingStep {
        case 0:
            draft.name = text.split(separator: " ").first.map(String.init) ?? text
            onboardingStep = 1
            say("Nice to meet you, \(draft.name). Do you want brief updates, or normal detail?", interrupt: true)
        case 1:
            draft.verbosity = lowered.contains("brief") || lowered.contains("short") ? .brief : .normal
            onboardingStep = 2
            say("Got it. Should I lead with steps, or with distance in feet and meters?", interrupt: true)
        case 2:
            draft.units = (lowered.contains("distance") || lowered.contains("feet") || lowered.contains("meter"))
                ? .distanceFirst : .stepsFirst
            onboardingStep = 3
            say("Okay. Careful walking pace, or normal?", interrupt: true)
        case 3:
            draft.pace = lowered.contains("careful") || lowered.contains("slow") ? .careful : .normal
            onboardingStep = 4
            say("Last thing — start in quiet mode with haptics only? Yes or no.", interrupt: true)
        case 4:
            draft.quietByDefault = lowered.hasPrefix("y") || lowered.contains("yes") || lowered.contains("quiet")
            quietMode = draft.quietByDefault
            draft.save()
            profile = draft
            phase = .ready
            onboardingStep = 5
            mood = .happy
            say("Thanks, \(draft.name). I'm Firefly — I'll watch with you. Say Firefly, nowhere to stay passive, or tell me where to go with Firefly.", interrupt: true)
            status = "Say Firefly, then your request"
        default:
            phase = .ready
        }
    }

    private func handleCommand(_ command: String) async {
        handlingUtterance = true
        phase = .handling
        mood = .thinking
        listener.setPaused(true)
        defer {
            handlingUtterance = false
            if phase == .handling { phase = maps.pendingPlace != nil ? .awaitingNavConfirm : .ready }
            listener.setPaused(speaker.isSpeaking)
            if mood == .thinking { mood = guideMode == .navigate ? .guiding : .idle }
        }

        let lowered = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered.isEmpty {
            say("I'm here. Where do you want to go?", interrupt: true)
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

        if lowered.contains("help") || lowered.contains("emergency") {
            mood = .danger
            say("I'm with you. Stay still if it feels unsafe. Call out for people nearby. I can describe what's around — ask me.", interrupt: true)
            return
        }

        if lowered.contains("stop") || lowered.contains("cancel") {
            cancelGuidance()
            say("Okay. Staying in Passive.", interrupt: true)
            return
        }

        if lowered.contains("close") || lowered.contains("quit") || lowered.contains("exit the app") {
            say("Closing Firefly.", interrupt: true)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            UIApplication.shared.perform(Selector(("suspend")))
            return
        }

        if isPassiveIntent(lowered) {
            cancelGuidance()
            guideMode = .passive
            say("Okay. I'll watch for obstacles and call them out.", interrupt: true)
            return
        }

        if lowered.contains("exit") || lowered.contains("way out") {
            await startBeacon(to: "exit")
            return
        }
        if lowered.contains("door") && (lowered.contains("take") || lowered.contains("find") || lowered.contains("guide") || lowered.contains("to the")) {
            await startBeacon(to: "door")
            return
        }

        if let target = Self.indoorTarget(in: lowered) {
            await startBeacon(to: target)
            return
        }

        if lowered.contains("what's in front") || lowered.contains("what is in front")
            || lowered.contains("describe") || lowered.contains("around me") || lowered.contains("see") {
            await describeScene(prompt: command)
            return
        }

        // Outdoor / place search
        if looksLikePlaceRequest(lowered) {
            let query = Self.placeQuery(from: lowered) ?? command
            await searchAndOffer(query)
            return
        }

        // Fallback: treat as scene question
        await describeScene(prompt: command)
    }

    private func isPassiveIntent(_ lowered: String) -> Bool {
        let keys = ["nowhere", "no where", "nothing", "just watch", "just help", "passive", "stay with me", "no destination", "nah"]
        return keys.contains { lowered.contains($0) }
    }

    private func looksLikePlaceRequest(_ lowered: String) -> Bool {
        lowered.contains("take me") || lowered.contains("navigate") || lowered.contains("directions")
            || lowered.contains("how do i get") || lowered.contains("go to") || lowered.contains("find ")
            || lowered.contains("library") || lowered.contains("building") || lowered.contains("cafe")
    }

    private static func indoorTarget(in lowered: String) -> String? {
        for phrase in ["take me to the ", "guide me to the ", "lead me to the ", "find the ", "go to the "] {
            guard let range = lowered.range(of: phrase) else { continue }
            let rest = lowered[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let word = rest.split(separator: " ").first.map(String.init) ?? ""
            if ["exit", "door", "doorway", "stairs"].contains(word) { return word }
        }
        return nil
    }

    private static func placeQuery(from lowered: String) -> String? {
        for phrase in ["take me to ", "guide me to ", "navigate to ", "directions to ", "go to ", "find "] {
            guard let range = lowered.range(of: phrase) else { continue }
            var q = String(lowered[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if q.hasPrefix("the ") { q = String(q.dropFirst(4)) }
            return q.isEmpty ? nil : q
        }
        return nil
    }

    private func searchAndOffer(_ query: String) async {
        mood = .thinking
        let hits = await maps.search(query)
        guard let first = hits.first else {
            say("Sorry, there's no connection right now, but I can stay in Passive and watch for obstacles.", interrupt: true)
            guideMode = .passive
            return
        }
        maps.holdForConfirm(first)
        phase = .awaitingNavConfirm
        say("I found \(first.spokenSummary). Start nav?", interrupt: true)
    }

    private func handleNavConfirm(_ text: String) async {
        handlingUtterance = true
        listener.setPaused(true)
        defer {
            handlingUtterance = false
            listener.setPaused(speaker.isSpeaking)
        }
        // Allow with or without Firefly prefix during confirm.
        let body = Self.stripFireflyPrefix(text) ?? text
        let answer = body.lowercased()

        if answer.contains("exit first") || answer.contains("find exit") || (askedExitFirst && answer.contains("exit")) {
            askedExitFirst = false
            maps.stop()
            phase = .ready
            await startBeacon(to: "exit")
            return
        }

        if askedExitFirst && (answer.contains("outdoor") || answer.contains("outside") || answer.contains("navigation") || answer.contains("maps")) {
            askedExitFirst = false
            if let spoken = await maps.startPendingRoute() {
                guideMode = .navigate
                mood = .guiding
                phase = .ready
                say(spoken, interrupt: true)
            } else {
                phase = .ready
                say("I couldn't start navigation. Staying Passive.", interrupt: true)
            }
            return
        }

        if answer.hasPrefix("y") || answer.contains("start") || answer.contains("yes") || answer.contains("go") {
            // If clearly indoors and destination is far, ask about exit first once.
            if !askedExitFirst, let place = maps.pendingPlace, place.distanceMeters > 80, alert != nil {
                askedExitFirst = true
                say("We might be inside. Should I take you to an exit first, or start outdoor navigation?", interrupt: true)
                return
            }
            askedExitFirst = false
            if let spoken = await maps.startPendingRoute() {
                guideMode = .navigate
                mood = .guiding
                phase = .ready
                say(spoken, interrupt: true)
            } else {
                phase = .ready
                say("I couldn't start navigation. Staying Passive.", interrupt: true)
            }
            return
        }

        if answer.hasPrefix("n") || answer.contains("no") || answer.contains("cancel") {
            askedExitFirst = false
            maps.stop()
            phase = .ready
            guideMode = .passive
            say("Okay. Staying Passive.", interrupt: true)
            return
        }

        say("Say yes to start nav, or no to cancel.", interrupt: true)
    }

    private func cancelGuidance() {
        beacon = nil
        beaconName = nil
        maps.stop()
        askedExitFirst = false
        guideMode = .passive
        phase = .ready
        mood = .idle
    }

    private func describeScene(prompt: String) async {
        mood = .thinking
        guard let snapshot = captureSnapshot(),
              let reply = try? await GeminiClient.answer(prompt, in: snapshot.jpeg),
              !reply.isEmpty
        else {
            say("I can't reach the network right now.", interrupt: true)
            return
        }
        say(reply, interrupt: true)
    }

    private func speakMapStepIfNeeded(now: Date) {
        guard guideMode == .navigate, maps.isNavigating, !quietMode, !maps.pausedForObstacle else { return }
        guard let step = maps.nextInstruction, step != lastMapPrompt else { return }
        guard now.timeIntervalSince(lastVoice) > 5 else { return }
        if step.lowercased().contains("you're at") {
            lastMapPrompt = step
            mood = .happy
            say(step + " Anything else?", interrupt: true)
            cancelGuidance()
            return
        }
        lastMapPrompt = step
        _ = say(step, allowNetwork: true)
    }

    // MARK: - Gemini naming loop

    private func runSceneLoop(now: Date) {
        guard phase == .ready || phase == .awaitingNavConfirm, !quietMode, !handlingUtterance, !sceneRequestActive,
              now.timeIntervalSince(lastSceneRequest) >= sceneInterval
        else { return }
        let refiningName = beacon?.isApproximate == true ? beacon?.name : nil
        guard refiningName != nil || (alert != nil && !maps.isNavigating) else { return }
        guard let snapshot = captureSnapshot() else { return }

        lastSceneRequest = now
        sceneRequestActive = true
        Task {
            defer { sceneRequestActive = false }
            if let refiningName {
                guard let point = try? await GeminiClient.locate(refiningName, in: snapshot.jpeg) else { return }
                let located = snapshot.worldPoint(atPhotoPoint: point)
                if !located.isApproximate, beacon?.name == refiningName {
                    beacon = Beacon(name: refiningName, position: located.position, isApproximate: false)
                }
            } else if let phrase = try? await GeminiClient.nearestHazard(in: snapshot.jpeg) {
                announceHazard(phrase)
            }
        }
    }

    private func announceHazard(_ phrase: String) {
        guard !quietMode else { return }
        let object = (phrase.components(separatedBy: ",").first ?? "")
            .trimmingCharacters(in: CharacterSet.letters.inverted)
        guard let alert, alert.distance >= stopDistance,
              !object.isEmpty, object.count < 25, !object.lowercased().hasPrefix("none")
        else { return }
        let direction = directionWord(alert.zone)
        let name = "\(object.prefix(1).uppercased())\(object.dropFirst().lowercased())"
        let hazard: String
        if profile?.verbosity == .brief {
            hazard = "\(name) \(direction)"
        } else {
            let detail = profile?.formatDistance(alert.distance) ?? String(format: "%.1f meters", alert.distance)
            hazard = "\(name) \(direction), \(detail)"
        }
        let now = Date()
        if hazard == lastHazard, now.timeIntervalSince(lastHazardTime) < 10 { return }
        if say(hazard) {
            lastHazard = hazard
            lastHazardTime = now
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

    private func captureSnapshot() -> FrameSnapshot? {
        session.currentFrame.flatMap { FrameSnapshot(frame: $0) }
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
            if self.mood == .listening { self.mood = self.guideMode == .navigate ? .guiding : .idle }
        }
    }
}
