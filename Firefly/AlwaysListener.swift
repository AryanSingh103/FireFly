import AVFoundation
import Foundation
import Speech

/// Foreground always-on listener. Emits finalized utterances; the engine filters for the Firefly prefix.
@MainActor
final class AlwaysListener: NSObject {
    var onUtterance: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var enabled = false
    private var restarting = false

    func start() {
        enabled = true
        beginSession()
    }

    func stop() {
        enabled = false
        endSession()
    }

    /// Pause while Firefly speaks to avoid feedback loops.
    func setPaused(_ paused: Bool) {
        if paused {
            endSession()
        } else if enabled {
            beginSession()
        }
    }

    private func beginSession() {
        endSession()
        guard enabled, let recognizer, recognizer.isAvailable else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            endSession()
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.onUtterance?(text)
                    }
                    self.scheduleRestart()
                } else if error != nil {
                    self.scheduleRestart()
                }
            }
        }
    }

    private func scheduleRestart() {
        guard enabled, !restarting else { return }
        restarting = true
        endSession()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.restarting = false
            if self.enabled { self.beginSession() }
        }
    }

    private func endSession() {
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
