import AVFoundation

@MainActor
final class VoiceRecorder {
    private var stopRequested = false

    func stop() {
        stopRequested = true
    }

    /// Records until the speaker goes quiet, stop() is called, or maxSeconds passes.
    func record(maxSeconds: Double = 6) async -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("question.wav")
        // 16 kHz mono 16-bit PCM is what the Azure Speech REST endpoint expects.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return nil }
        recorder.isMeteringEnabled = true
        guard recorder.record() else { return nil }

        stopRequested = false
        var elapsed = 0.0
        var quiet = 0.0
        var heardSpeech = false
        while elapsed < maxSeconds, !stopRequested {
            try? await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 0.1
            recorder.updateMeters()
            if recorder.averagePower(forChannel: 0) > -30 {
                heardSpeech = true
                quiet = 0
            } else if heardSpeech {
                quiet += 0.1
                if quiet >= 1.0 { break }
            }
        }
        recorder.stop()
        return url
    }
}
