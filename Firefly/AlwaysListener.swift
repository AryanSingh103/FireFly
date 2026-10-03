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

    func start() {
        enabled = true
        paused = false
        beginSession()
    }

    func stop() {
        enabled = false
        endSession()
    }

    /// Pause while Firefly speaks so it doesn't hear itself.
    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        if paused {
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
        self.request = request

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
            waitForSilence()
        }
        if isFinal || failed {
            finishUtterance()
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
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func endSession() {
        silenceTask?.cancel()
        silenceTask = nil
        latestText = ""
        generation += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }
}
