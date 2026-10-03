import Foundation
import Speech

protocol SpeechTranscriber {
    func transcribe(fileURL: URL) async throws -> String
}

struct TranscriptionFailure: Error {}

final class AppleSpeechTranscriber: SpeechTranscriber {
    func transcribe(fileURL: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw TranscriptionFailure()
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    if gate.claim() { continuation.resume(returning: text) }
                } else if error != nil {
                    if gate.claim() { continuation.resume(throwing: TranscriptionFailure()) }
                }
            }
        }
    }
}

final class AzureSpeechTranscriber: SpeechTranscriber {
    func transcribe(fileURL: URL) async throws -> String {
        guard let url = URL(string: "https://\(Secrets.azureSpeechRegion).stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1?language=en-US&format=simple") else {
            throw TranscriptionFailure()
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Secrets.azureSpeechKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("audio/wav; codecs=audio/pcm; samplerate=16000", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.upload(for: request, from: Data(contentsOf: fileURL))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["RecognitionStatus"] as? String == "Success",
              let text = json["DisplayText"] as? String
        else { throw TranscriptionFailure() }
        return text
    }
}

/// The recognizer can call back more than once; a continuation must be resumed exactly once.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    nonisolated func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
