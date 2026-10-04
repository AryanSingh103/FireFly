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

    private(set) var distances = SIMD3<Float>(repeating: 5)
    private(set) var alert: ObstacleAlert?
    /// Published only when it flips, unlike `alert`, which changes every frame.
    @Published private(set) var obstacleNear = false
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

    /// Shared with the live camera view in ContentView.
    let session = ARSession()
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
    /// Automatic obstacle naming. Each call costs one Gemini request, and free-tier keys get very few per day.
    private let sceneInterval: TimeInterval = 10
    /// Slow enough to clearly differ from the slowest obstacle rate (about 0.7 s at 2 m).
    private let heartbeatInterval: TimeInterval = 1.2
    private let pulseStrength: Float = 1.0
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
    private var lastMapPrompt = ""
    private var lastBeaconSide = ""
    private var lastBeaconLine = Date.distantPast
    private var lastAnnouncedDistance: Float = .infinity
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
    /// Firefly just asked a question; its answer doesn't need the "Firefly" prefix until this time.
    private var replyDeadline = Date.distantPast
    private var lastSpokeQuestion = false
    private let replyWindow: TimeInterval = 8

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
        session.delegateQueue = frameQueue
        session.run(configuration)
        status = "Scanning"
        startFlipMonitor()
        listener.start()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self.greetOnLaunch()
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
        let camera = frame.camera.transform
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
            self.ingest(reading.distances, camera: camera)
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

    private func ingest(_ reading: SIMD3<Float>, camera: simd_float4x4) {
        lastCamera = camera
        history.append(reading)
        if history.count > smoothingFrames { history.removeFirst() }
        distances = history.reduce(SIMD3<Float>(repeating: 0), +) / Float(history.count)
        alert = AlertPolicy.alert(for: distances)
        if (alert != nil) != obstacleNear { obstacleNear = alert != nil }

        let now = Date()
        let inDanger = (alert?.distance ?? .infinity) < dangerDistance
        maps.setPausedForObstacle((inDanger && maps.isNavigating) || maps.isInInitialNavPhase)

        // One strong pulse everywhere; only its rate changes. A clear path pulses slowly and steadily so the
        // wearer can feel Firefly is working, and an obstacle in the path (within speaking range) speeds it up
        // as it gets closer, with a beep.
        let inPath = (alert?.distance ?? .infinity) < announceDistance
        if !inPath {
            if now.timeIntervalSince(lastPulse) >= heartbeatInterval {
                lastPulse = now
                haptics.pulse(intensity: pulseStrength)
            }
        } else if let alert, now.timeIntervalSince(lastPulse) >= alert.interval {
            lastPulse = now
            if quietMode, alert.distance < stopDistance {
                haptics.urgentStop()
            } else {
                haptics.pulse(intensity: pulseStrength)
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
        // BlindSpot: don't let obstacle callouts talk over the opening nav summary.
        if maps.isInInitialNavPhase { return }

        guard let alert else {
            lastAnnouncedZone = nil
            lastAnnouncedDistance = .infinity
            lastAnnouncedName = ""
            inPathSince = nil
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
            let direction = directionWord(alert.zone)
            let spokenName = name ?? "Obstacle"
            let line: String
            if profile?.verbosity == .brief {
                line = BlindSpotNav.obstaclePhrase(description: "\(spokenName) \(direction)")
            } else {
                let detail = profile?.formatDistance(alert.distance) ?? UserProfile.defaultDistance(alert.distance)
                line = BlindSpotNav.obstaclePhrase(description: "\(spokenName) \(direction), \(detail)")
            }
            if say(line, allowNetwork: false) {
                lastAnnouncedZone = alert.zone
                lastAnnouncedDistance = alert.distance
                lastAnnouncedName = spokenName
                lastAnnouncement = now
            }
        }
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
            let side: String
            if guidance.pan < -0.35 { side = "a bit left" }
            else if guidance.pan > 0.35 { side = "a bit right" }
            else { side = "straight ahead" }
            let sideChanged = side != lastBeaconSide
            if now.timeIntervalSince(lastVoice) > 3, sideChanged || now.timeIntervalSince(lastBeaconLine) > 10 {
                let name = beacon.name.prefix(1).uppercased() + beacon.name.dropFirst()
                let detail = profile?.formatDistance(guidance.distance) ?? UserProfile.defaultDistance(guidance.distance)
                if say("\(name) \(side), \(detail)", allowNetwork: false) {
                    lastBeaconSide = side
                    lastBeaconLine = now
                }
            }
        }
    }

    private func startBeacon(to target: String) async {
        guideMode = .navigate
        mood = .thinking
        for attempt in 0..<3 {
            guard let snapshot = await captureSnapshot() else { break }
            do {
                if let point = try await GeminiClient.locate(target, in: snapshot.jpeg) {
                    let located = snapshot.worldPoint(atPhotoPoint: point)
                    setBeacon(Beacon(name: target, position: located.position, isApproximate: located.isApproximate))
                    return
                }
            } catch {
                say(geminiProblem(error), interrupt: true)
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
        lastBeaconSide = ""
        beaconName = newBeacon.name
        guideMode = .navigate
        mood = .guiding
        say("Found the \(newBeacon.name). I'll guide you there.", interrupt: true)
    }

    // MARK: - Launch / onboarding

    /// Both greetings are fixed sentences with bundled clips, so the first thing anyone hears is
    /// Firefly's voice instantly, with or without Wi-Fi.
    private func greetOnLaunch() async {
        if profile != nil {
            phase = .ready
            say("Hi, I'm Firefly. I'll help you get around. Where would you like to go?", interrupt: true)
            status = "Say Firefly, then your request"
        } else {
            phase = .onboarding
            onboardingStep = 0
            say("Hi, I'm Firefly. I'll help you get around. First, what's your name?", interrupt: true)
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

        if let command = Self.stripFireflyPrefix(trimmed) {
            replyDeadline = .distantPast
            Task { await handleCommand(command) }
        } else if Date() < replyDeadline {
            // Answering Firefly's own question ("Where do you want to go?" / "Anything else?").
            replyDeadline = .distantPast
            Task { await handleCommand(trimmed) }
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
            guard let name = Self.name(from: text) else {
                say("Sorry, I didn't catch your name. What should I call you?", interrupt: true)
                return
            }
            draft.name = name
            onboardingStep = 1
            say("Nice to meet you, \(draft.name). Do you want brief updates, or normal detail?", interrupt: true)
        case 1:
            draft.verbosity = lowered.contains("brief") || lowered.contains("short") ? .brief : .normal
            onboardingStep = 2
            say("Got it. Should I lead with steps, or with distance in feet?", interrupt: true)
        case 2:
            if lowered.contains("meter") || lowered.contains("metric") {
                draft.units = .metersFirst
            } else if lowered.contains("distance") || lowered.contains("feet") || lowered.contains("foot") {
                draft.units = .distanceFirst
            } else {
                draft.units = .stepsFirst
            }
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

    /// Words that are never a name; usually the mic caught Firefly's own question or a filler word.
    private static let notNames: Set<String> = [
        "what", "what's", "whats", "your", "name", "my", "is", "the", "a", "firefly", "hi", "hey", "hello",
        "um", "uh", "okay", "ok", "yes", "no", "first", "sorry", "i", "it", "it's", "you", "help", "get", "around",
    ]

    /// "My name is Aryan." -> "Aryan". nil if what was heard doesn't look like a name.
    private static func name(from text: String) -> String? {
        var rest = text.lowercased()
        for lead in ["my name is ", "my name's ", "i'm ", "i am ", "it's ", "it is ", "call me ", "this is ", "hi ", "hey "]
        where rest.hasPrefix(lead) {
            rest = String(rest.dropFirst(lead.count))
        }
        let word = rest.split(separator: " ").first.map(String.init) ?? rest
        let letters = word.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard !letters.isEmpty, !notNames.contains(letters.lowercased()) else { return nil }
        return letters.prefix(1).uppercased() + letters.dropFirst()
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

        if lowered.contains("where am i") || lowered.contains("what's my location") || lowered.contains("what is my location") {
            say(maps.whereAmI(), interrupt: true)
            return
        }
        if lowered.contains("which way") || lowered.contains("am i facing") || lowered.contains("facing") {
            say(maps.facing(), interrupt: true)
            return
        }

        if lowered.contains("what's in front") || lowered.contains("what is in front")
            || lowered.contains("describe") || lowered.contains("around me") {
            await describeScene(prompt: command)
            return
        }

        // BlindSpot: "nearest coffee" picks one; vague "a coffee shop" lists options.
        if looksLikePlaceRequest(lowered) {
            let query = Self.placeQuery(from: lowered) ?? command
            let nearestOnly = lowered.contains("nearest") || lowered.contains("closest")
            await searchAndOffer(query, autoPickNearest: nearestOnly)
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

    private func searchAndOffer(_ query: String, autoPickNearest: Bool = false) async {
        mood = .thinking
        let hits = await maps.search(query)
        guard !hits.isEmpty else {
            say("I couldn't find that nearby. Try saying it another way.", interrupt: true)
            guideMode = .passive
            return
        }
        if autoPickNearest, let first = hits.first {
            maps.holdForConfirm(first)
            if let spoken = await maps.startPendingRoute() {
                guideMode = .navigate
                mood = .guiding
                phase = .ready
                say(spoken, interrupt: true)
            }
            return
        }
        // BlindSpot: list up to 3, ask which one.
        maps.holdChoices(hits)
        phase = .awaitingNavConfirm
        var lines: [String] = []
        for (index, hit) in hits.prefix(3).enumerated() {
            lines.append("\(index + 1). \(hit.addressLine)")
        }
        say("I found \(hits.count) places: \(lines.joined(separator: ". ")). Which one? Say the number or name.", interrupt: true)
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

        if answer.hasPrefix("y") || answer.contains("start") || answer.contains("yes") || answer.contains("go")
            || maps.pickChoice(matching: answer) != nil {
            if let picked = maps.pickChoice(matching: answer) {
                maps.holdForConfirm(picked)
            }
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

        say("Say one, two, or three — or yes to start, no to cancel.", interrupt: true)
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
        guard now >= geminiPausedUntil else { return }
        let refiningName = beacon?.isApproximate == true ? beacon?.name : nil
        // Only name obstacles that are actually in the path, not everything within 3 m.
        let obstacleInPath = (alert?.distance ?? .infinity) < announceDistance
        // Gemini only names what the phone couldn't.
        let unnamed = alert.map { deviceName(for: $0.zone) == nil } ?? false
        guard refiningName != nil || (obstacleInPath && unnamed && !maps.isNavigating) else { return }
        lastSceneRequest = now
        sceneRequestActive = true
        Task {
            defer { sceneRequestActive = false }
            guard let snapshot = await captureSnapshot() else { return }
            do {
                if let refiningName {
                    guard let point = try await GeminiClient.locate(refiningName, in: snapshot.jpeg) else { return }
                    let located = snapshot.worldPoint(atPhotoPoint: point)
                    if !located.isApproximate, beacon?.name == refiningName {
                        beacon = Beacon(name: refiningName, position: located.position, isApproximate: false)
                    }
                } else {
                    announceHazard(try await GeminiClient.nearestHazard(in: snapshot.jpeg))
                }
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
        let direction = directionWord(alert.zone)
        let name = "\(object.prefix(1).uppercased())\(object.dropFirst().lowercased())"
        let hazard: String
        if profile?.verbosity == .brief {
            hazard = BlindSpotNav.obstaclePhrase(description: "\(name) \(direction)")
        } else {
            let detail = profile?.formatDistance(alert.distance) ?? UserProfile.defaultDistance(alert.distance)
            hazard = BlindSpotNav.obstaclePhrase(description: "\(name) \(direction), \(detail)")
        }
        let now = Date()
        if hazard == lastHazard, now.timeIntervalSince(lastHazardTime) < 10 { return }
        if say(hazard) {
            lastHazard = hazard
            lastHazardTime = now
            lastAnnouncedZone = alert.zone
            lastAnnouncedDistance = alert.distance
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

    /// JPEG encoding and copying the depth map take tens of milliseconds, so they run off the main thread.
    private func captureSnapshot() async -> FrameSnapshot? {
        guard let frame = session.currentFrame else { return nil }
        return await Task.detached(priority: .userInitiated) { FrameSnapshot(frame: frame) }.value
    }

    @discardableResult
    private func say(_ text: String, interrupt: Bool = false, allowNetwork: Bool = true) -> Bool {
        // Quiet mode mutes safety callouts (handled in speakWarnings). Replies to "Firefly, …" still speak.
        guard speaker.say(text, pan: 0, interrupt: interrupt, allowNetwork: allowNetwork) else { return false }
        caption = text
        lastSpokeQuestion = text.hasSuffix("?")
        replyDeadline = .distantPast
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
            if self.lastSpokeQuestion, self.phase == .ready {
                self.replyDeadline = Date().addingTimeInterval(self.replyWindow)
            }
            if !self.handlingUtterance {
                self.listener.setPaused(false)
            }
            if self.mood == .listening { self.mood = self.guideMode == .navigate ? .guiding : .idle }
        }
    }
}
