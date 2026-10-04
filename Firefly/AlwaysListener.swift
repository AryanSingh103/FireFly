import AVFoundation
import Foundation
import Speech

/// Foreground always-on listener. Emits finished utterances; the engine filters for the Firefly prefix.
///
/// The Speech framework does not end an utterance when the speaker pauses: with partial results off,
/// nothing arrives until the request is ended, so the app never heard anything. Instead this listens
/// to partial results and treats a short silence as the end of the utterance.
@MainActor
final class AlwaysListener: NSObject {
    var onUtterance: ((String) -> Void)?
    /// "Firefly" was heard while Firefly was talking; the engine stops talking so the wearer can speak.
    var onWake: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var enabled = false
    private var paused = false
    private var restarting = false
    /// Bumped on every new session so callbacks from an old recognition task are ignored.
    private var generation = 0
    private var latestText = ""
    private var silenceTask: Task<Void, Never>?
    private let endOfSpeechDelay: UInt64 = 1_000_000_000
    /// While Firefly talks the mic stays open but only listens for "Firefly": everything else it hears
    /// is mostly Firefly's own voice.
    private var speaking = false
    /// When "Firefly" interrupted Firefly; the request is whatever is said after it.
    private var wokeAt: Date?
    /// After an interruption, how long to wait for the request when only "Firefly" has been said.
    private let requestWait: TimeInterval = 6

    func start() {
        enabled = true
        paused = false
        beginSession()
    }

    func stop() {
        enabled = false
        wokeAt = nil
        endSession()
    }

    /// Reopens the mic if it should be listening but isn't, whatever the reason it stopped.
    func ensureRunning() {
        guard enabled, !paused, !restarting else { return }
        // iOS stops the audio engine on its own when the audio setup changes (a route change, another
        // app); the session then looks open but hears nothing.
        if request != nil, audioEngine.isRunning { return }
        beginSession()
    }

    /// While true, only "Firefly" is acted on (it calls onWake); turning it off starts a fresh session so
    /// Firefly's own words aren't taken as a request.
    func setSpeaking(_ speaking: Bool) {
        guard speaking != self.speaking else { return }
        self.speaking = speaking
        if speaking { wokeAt = nil }
        if !speaking, wokeAt == nil, request != nil {
            endSession()
            scheduleRestart(after: 150_000_000)
        }
    }

    /// Pause completely (Firefly is thinking, or saying a line with "Firefly" in it).
    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        if paused {
            wokeAt = nil
            endSession()
        } else if enabled {
            beginSession()
        }
    }

    private func beginSession() {
        endSession()
        guard enabled, !paused, let recognizer, recognizer.isAvailable,
              SFSpeechRecognizer.authorizationStatus() == .authorized
        else {
            // Permission prompts may still be on screen at launch; try again shortly.
            scheduleRestart(after: 1_000_000_000)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            scheduleRestart(after: 500_000_000)
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            endSession()
            scheduleRestart(after: 500_000_000)
            return
        }
        // Set only once the mic is running. Set earlier, a failed start (the mic briefly reports no format
        // right after Firefly finishes speaking) left a request behind, and scheduleRestart, which only
        // restarts when there is no request, never reopened the mic: the next question was never heard.
        self.request = request

        generation += 1
        let session = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                self?.handle(text: text, isFinal: isFinal, failed: failed, session: session)
            }
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool, session: Int) {
        guard session == generation, request != nil else { return }
        if let text, !text.isEmpty {
            latestText = text
            if !speaking {
                waitForSilence()
            } else if Self.textAfterWake(text) != nil {
                speaking = false
                wokeAt = Date()
                onWake?()
                waitForSilence()
            }
        }
        if isFinal || failed {
            if speaking {
                // Only Firefly's own voice so far; keep listening for "Firefly".
                endSession()
                scheduleRestart(after: 150_000_000)
            } else {
                finishUtterance()
            }
        }
    }

    private func waitForSilence() {
        silenceTask?.cancel()
        silenceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: endOfSpeechDelay)
            guard !Task.isCancelled else { return }
            finishUtterance()
        }
    }

    private func finishUtterance() {
        var text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wokeAt {
            // Drop Firefly's own words from before the interruption.
            let request = Self.textAfterWake(text) ?? ""
            if request.isEmpty, Date().timeIntervalSince(wokeAt) < requestWait, self.request != nil {
                // Only "Firefly" so far: keep listening for the request.
                waitForSilence()
                return
            }
            self.wokeAt = nil
            text = "Firefly, " + request
        }
        endSession()
        if !text.isEmpty { onUtterance?(text) }
        // The handler may have paused us to speak a reply; beginSession checks that.
        scheduleRestart(after: 150_000_000)
    }

    private func scheduleRestart(after delay: UInt64) {
        guard enabled, !paused, !restarting else { return }
        restarting = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            self.restarting = false
            if self.enabled, !self.paused, self.request == nil { self.beginSession() }
        }
    }

    /// The words after the last "Firefly" in the text, or nil if it has no "Firefly".
    private static func textAfterWake(_ text: String) -> String? {
        let lowered = text.lowercased()
        let ranges = ["firefly", "fire fly"].compactMap { lowered.range(of: $0, options: .backwards) }
        guard let last = ranges.max(by: { $0.upperBound < $1.upperBound }) else { return nil }
        return String(lowered[last.upperBound...]).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private func endSession() {
        silenceTask?.cancel()
        silenceTask = nil
        latestText = ""
        generation += 1
        // Stop the mic before ending the request, so the tap can't append audio to a finished request.
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
    }
}
