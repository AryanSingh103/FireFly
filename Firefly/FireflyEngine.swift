import ARKit
import AVFoundation
import Combine
import Speech

@MainActor
final class FireflyEngine: NSObject, ObservableObject, ARSessionDelegate {
    enum Mode {
        case idle, listening, thinking
    }

    @Published private(set) var distances = SIMD3<Float>(repeating: 5)
    @Published private(set) var alert: ObstacleAlert?
    @Published private(set) var pulseCount = 0
    @Published private(set) var status = "Starting"
    @Published private(set) var caption = ""
    @Published private(set) var mode = Mode.idle
    @Published private(set) var beaconName: String?
    @Published var demoMode = false

    private let session = ARSession()
    private let haptics = HapticPulser()
    private let tones = TonePlayer()
    private let speaker = Speaker()
    private let recorder = VoiceRecorder()
    private let transcribers: [SpeechTranscriber]

    private let smoothingFrames = 5
    private let dangerDistance: Float = 1.0
    private let stopDistance: Float = 0.5
    private let announceDistance: Float = 1.5
    private let arrivalDistance: Float = 1.2
    private let sceneInterval: TimeInterval = 4

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

    override init() {
        var transcribers: [SpeechTranscriber] = []
        if !Secrets.azureSpeechKey.isEmpty { transcribers.append(AzureSpeechTranscriber()) }
        transcribers.append(AppleSpeechTranscriber())
        self.transcribers = transcribers
        super.init()
    }

    func start() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            status = "This iPhone has no LiDAR"
            return
        }
        AVAudioSession.sharedInstance().requestRecordPermission { @Sendable _ in }
        SFSpeechRecognizer.requestAuthorization { @Sendable _ in }

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .sceneDepth
        session.delegate = self
        session.run(configuration)
        status = "Scanning"
    }

    // MARK: - ARKit

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depth = frame.sceneDepth else { return }
        let reading = DepthZoneAnalyzer.nearestPerZone(in: depth)
        let camera = frame.camera.transform
        Task { @MainActor in self.ingest(reading, camera: camera) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.status = message }
    }

    // MARK: - Safety loop (no network)

    private func ingest(_ reading: SIMD3<Float>, camera: simd_float4x4) {
        lastCamera = camera
        history.append(reading)
        if history.count > smoothingFrames { history.removeFirst() }
        distances = history.reduce(SIMD3<Float>(repeating: 0), +) / Float(history.count)
        alert = AlertPolicy.alert(for: distances)

        let now = Date()
        let inDanger = (alert?.distance ?? .infinity) < dangerDistance

        if let alert, now.timeIntervalSince(lastPulse) >= alert.interval {
            lastPulse = now
            haptics.pulse(intensity: alert.intensity)
            // While a beacon is guiding, distant obstacles stay haptic-only so the chime remains readable.
            if mode != .listening, beacon == nil || inDanger {
                tones.beep(pan: alert.zone.pan)
            }
            pulseCount += 1
        }

        speakWarnings(now: now)
        updateBeacon(camera: camera, inDanger: inDanger, now: now)
        runSceneLoop(now: now)
    }

    private func speakWarnings(now: Date) {
        guard mode != .listening else { return }
        guard let alert else {
            lastAnnouncedZone = nil
            if wasClose, now.timeIntervalSince(lastVoice) > 2 {
                say("Clear path", allowNetwork: false)
            }
            wasClose = false
            return
        }

        if alert.distance < announceDistance { wasClose = true }

        if alert.distance < stopDistance, now.timeIntervalSince(lastStop) > 3 {
            lastStop = now
            say("Stop", interrupt: true, allowNetwork: false)
            return
        }

        let geminiSpokeRecently = now.timeIntervalSince(lastHazardTime) < 6
        let isNewZone = alert.zone != lastAnnouncedZone || now.timeIntervalSince(lastAnnouncement) > 6
        if alert.distance < announceDistance, isNewZone, !geminiSpokeRecently, now.timeIntervalSince(lastVoice) > 2.5 {
            let direction = alert.zone == .center ? "ahead" : alert.zone.label.lowercased()
            if say("Obstacle, \(direction)", pan: alert.zone.pan, allowNetwork: false) {
                lastAnnouncedZone = alert.zone
                lastAnnouncement = now
            }
        }
    }

    // MARK: - Door beacon (local once the target is anchored)

    private func updateBeacon(camera: simd_float4x4, inDanger: Bool, now: Date) {
        guard let beacon else { return }
        let guidance = beacon.guidance(from: camera)
        if !beacon.isApproximate, guidance.distance < arrivalDistance {
            self.beacon = nil
            beaconName = nil
            say("You're at the \(beacon.name)", interrupt: true)
        } else if !inDanger, mode != .listening, now.timeIntervalSince(lastChime) >= guidance.interval {
            lastChime = now
            tones.chime(pan: guidance.pan)
        }
    }

    private func startBeacon(to target: String) async {
        if demoMode {
            let ahead = lastCamera * SIMD4<Float>(0, 0, -3, 1)
            setBeacon(Beacon(name: target, position: SIMD3(ahead.x, ahead.y, ahead.z), isApproximate: false))
            return
        }
        for attempt in 0..<3 {
            guard let snapshot = captureSnapshot() else { break }
            do {
                if let point = try await GeminiClient.locate(target, in: snapshot.jpeg) {
                    let located = snapshot.worldPoint(atPhotoPoint: point)
                    setBeacon(Beacon(name: target, position: located.position, isApproximate: located.isApproximate))
                    return
                }
            } catch {
                say("I can't reach the network", interrupt: true)
                return
            }
            if attempt < 2 {
                say("Turn slowly", interrupt: true)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
        say("I can't see a \(target)", interrupt: true)
    }

    private func setBeacon(_ newBeacon: Beacon) {
        beacon = newBeacon
        beaconName = newBeacon.name
        say("Found the \(newBeacon.name). Follow the chime.", interrupt: true)
    }

    // MARK: - Voice questions

    /// Tap once to ask, tap again to stop listening early.
    func handleTap() {
        switch mode {
        case .idle:
            Task { await listenAndRespond() }
        case .listening:
            recorder.stop()
        case .thinking:
            break
        }
    }

    func demoDoor() {
        runDemo { await self.startBeacon(to: "door") }
    }

    func demoQuestion() {
        runDemo { await self.answer("What's in front of me?") }
    }

    func cancelBeacon() {
        beacon = nil
        beaconName = nil
    }

    private func runDemo(_ action: @escaping @MainActor () async -> Void) {
        guard mode == .idle else { return }
        mode = .thinking
        Task {
            await action()
            mode = .idle
        }
    }

    private func listenAndRespond() async {
        speaker.stop()
        mode = .listening
        haptics.pulse(intensity: 1)
        let recording = await recorder.record()
        mode = .thinking
        if let recording, let text = await transcribe(recording) {
            caption = "\u{201C}\(text)\u{201D}"
            await respond(to: text)
        } else {
            say("I didn't catch that", interrupt: true)
        }
        mode = .idle
    }

    private func transcribe(_ recording: URL) async -> String? {
        for transcriber in transcribers {
            if let text = try? await transcriber.transcribe(fileURL: recording), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func respond(to text: String) async {
        let lowered = text.lowercased()
        if beacon != nil, lowered.contains("stop") || lowered.contains("cancel") {
            cancelBeacon()
            say("Okay", interrupt: true)
        } else if let target = FireflyEngine.destination(in: lowered) {
            await startBeacon(to: target)
        } else {
            await answer(text)
        }
    }

    private func answer(_ question: String) async {
        if demoMode {
            say("Doorway, slightly right", interrupt: true)
            return
        }
        guard let snapshot = captureSnapshot(),
              let reply = try? await GeminiClient.answer(question, in: snapshot.jpeg),
              !reply.isEmpty
        else {
            say("I can't reach the network", interrupt: true)
            return
        }
        say(reply, interrupt: true)
    }

    /// "take me to the door" -> "door". Returns nil for anything that is not a request to be guided somewhere.
    private static func destination(in lowered: String) -> String? {
        for phrase in ["take me to", "guide me to", "lead me to", "bring me to", "go to", "find"] {
            guard let range = lowered.range(of: phrase) else { continue }
            var target = lowered[range.upperBound...].trimmingCharacters(in: CharacterSet.letters.inverted)
            for article in ["the ", "a ", "an ", "my "] where target.hasPrefix(article) {
                target.removeFirst(article.count)
            }
            if !target.isEmpty { return target }
        }
        return nil
    }

    // MARK: - Gemini scene loop (never safety-critical)

    private func runSceneLoop(now: Date) {
        guard mode == .idle, !demoMode, !sceneRequestActive,
              now.timeIntervalSince(lastSceneRequest) >= sceneInterval
        else { return }
        // An approximate beacon was placed beyond LiDAR range; keep re-locating it until depth is available.
        let refiningName = beacon?.isApproximate == true ? beacon?.name : nil
        guard refiningName != nil || (alert != nil && beacon == nil) else { return }
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
        let hazard = phrase.trimmingCharacters(in: CharacterSet.letters.inverted)
        let lowered = hazard.lowercased()
        guard mode == .idle, beacon == nil, !hazard.isEmpty, hazard.count < 40, !lowered.hasPrefix("none") else { return }
        let now = Date()
        if hazard == lastHazard, now.timeIntervalSince(lastHazardTime) < 10 { return }
        let pan: Float = lowered.hasSuffix("left") ? -1 : lowered.hasSuffix("right") ? 1 : 0
        if say(hazard, pan: pan) {
            lastHazard = hazard
            lastHazardTime = now
        }
    }

    // MARK: - Helpers

    private func captureSnapshot() -> FrameSnapshot? {
        session.currentFrame.flatMap { FrameSnapshot(frame: $0) }
    }

    @discardableResult
    private func say(_ text: String, pan: Float = 0, interrupt: Bool = false, allowNetwork: Bool = true) -> Bool {
        guard speaker.say(text, pan: pan, interrupt: interrupt, allowNetwork: allowNetwork) else { return false }
        caption = text
        lastVoice = Date()
        return true
    }
}
