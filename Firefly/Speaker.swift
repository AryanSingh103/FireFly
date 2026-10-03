import AVFoundation

enum TTSClient {
    struct Failure: Error {}

    static func synthesize(_ text: String) async throws -> Data {
        var request: URLRequest
        if Secrets.backendURL.isEmpty {
            guard !Secrets.elevenLabsKey.isEmpty, !Secrets.elevenLabsVoiceID.isEmpty,
                  let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(Secrets.elevenLabsVoiceID)?output_format=mp3_44100_128")
            else { throw Failure() }
            request = URLRequest(url: url)
            request.setValue(Secrets.elevenLabsKey, forHTTPHeaderField: "xi-api-key")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": "eleven_flash_v2_5"])
        } else {
            guard let url = URL(string: Secrets.backendURL + "/tts") else { throw Failure() }
            request = URLRequest(url: url)
            request.setValue(Secrets.backendKey, forHTTPHeaderField: "x-functions-key")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 6

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure() }
        return data
    }
}

@MainActor
final class Speaker {
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var requestID = 0

    var isSpeaking: Bool {
        player?.isPlaying == true || synthesizer.isSpeaking
    }

    /// Plays a bundled clip if one matches the text, otherwise ElevenLabs live, otherwise the system voice.
    /// Returns false if it stayed quiet because something else was already being said.
    @discardableResult
    func say(_ text: String, pan: Float = 0, interrupt: Bool = false, allowNetwork: Bool = true) -> Bool {
        if isSpeaking {
            guard interrupt else { return false }
            stop()
        }
        requestID += 1
        let id = requestID

        if let url = Speaker.clipURL(for: text), start(try? AVAudioPlayer(contentsOf: url), pan: pan) {
            return true
        }
        guard allowNetwork else {
            synthesizer.speak(AVSpeechUtterance(string: text))
            return true
        }
        Task {
            let data = try? await TTSClient.synthesize(text)
            guard id == self.requestID, !self.isSpeaking else { return }
            if let data, self.start(try? AVAudioPlayer(data: data), pan: pan) { return }
            self.synthesizer.speak(AVSpeechUtterance(string: text))
        }
        return true
    }

    func stop() {
        requestID += 1
        player?.stop()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func start(_ newPlayer: AVAudioPlayer?, pan: Float) -> Bool {
        guard let newPlayer else { return false }
        newPlayer.pan = pan
        player = newPlayer
        return newPlayer.play()
    }

    /// Must match slug() in scripts/generate_phrases.py.
    static func slug(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    private static func clipURL(for text: String) -> URL? {
        let name = slug(text)
        return Bundle.main.url(forResource: name, withExtension: "mp3")
            ?? Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Phrases")
    }
}
