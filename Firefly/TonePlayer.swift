import AVFoundation

/// Beeps and guide chimes via AVAudioPlayer (no second AVAudioEngine — that fights AlwaysListener).
final class TonePlayer {
    private var player: AVAudioPlayer?
    private let beepData: Data
    private let chimeData: Data

    init() {
        beepData = TonePlayer.render(duration: 0.06) { time, progress in
            sin(2 * Float.pi * 880 * time) * sin(Float.pi * progress) * 0.55
        }
        chimeData = TonePlayer.render(duration: 0.35) { time, progress in
            let bell = sin(2 * Float.pi * 1320 * time) + 0.4 * sin(2 * Float.pi * 1980 * time)
            return bell * min(progress * 40, 1) * exp(-6 * progress) * 0.32
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try? session.setActive(true)
    }

    func beep(pan: Float = 0) {
        play(beepData, pan: pan)
    }

    func chime(pan: Float = 0) {
        play(chimeData, pan: pan)
    }

    private func play(_ data: Data, pan: Float) {
        guard let next = try? AVAudioPlayer(data: data) else { return }
        next.pan = pan
        next.prepareToPlay()
        player = next
        next.play()
    }

    private static func render(duration: Double, sample: (_ time: Float, _ progress: Float) -> Float) -> Data {
        let sampleRate = 44_100
        let frameCount = Int(duration * Double(sampleRate))
        var data = Data(count: 44 + frameCount * 2)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            func write32(_ value: UInt32, at offset: Int) {
                base.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee = value.littleEndian }
            }
            func write16(_ value: UInt16, at offset: Int) {
                base.advanced(by: offset).withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee = value.littleEndian }
            }
            // WAV header, 16-bit mono PCM.
            memcpy(base, "RIFF", 4)
            write32(UInt32(36 + frameCount * 2), at: 4)
            memcpy(base.advanced(by: 8), "WAVE", 4)
            memcpy(base.advanced(by: 12), "fmt ", 4)
            write32(16, at: 16)
            write16(1, at: 20)
            write16(1, at: 22)
            write32(UInt32(sampleRate), at: 24)
            write32(UInt32(sampleRate * 2), at: 28)
            write16(2, at: 32)
            write16(16, at: 34)
            memcpy(base.advanced(by: 36), "data", 4)
            write32(UInt32(frameCount * 2), at: 40)
            let samples = UnsafeMutableRawPointer(base.advanced(by: 44)).bindMemory(to: Int16.self, capacity: frameCount)
            for i in 0..<frameCount {
                let time = Float(i) / Float(sampleRate)
                let progress = Float(i) / Float(frameCount)
                let clipped = max(-1, min(1, sample(time, progress)))
                samples[i] = Int16(clipped * Float(Int16.max))
            }
        }
        return data
    }
}
