import AVFoundation

final class TonePlayer {
    private let engine = AVAudioEngine()
    private let beepNode = AVAudioPlayerNode()
    private let chimeNode = AVAudioPlayerNode()
    private let beepBuffer: AVAudioPCMBuffer
    private let chimeBuffer: AVAudioPCMBuffer

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        beepBuffer = TonePlayer.makeBeep(format: format)
        chimeBuffer = TonePlayer.makeChime(format: format)

        // Record-capable so voice questions work. A2DP only (no hands-free profile) keeps
        // Bluetooth earbuds in stereo, which the left/right panning depends on.
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try? audioSession.setActive(true)

        engine.attach(beepNode)
        engine.attach(chimeNode)
        engine.connect(beepNode, to: engine.mainMixerNode, format: format)
        engine.connect(chimeNode, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    /// Obstacle warning. pan: -1 is the left ear, 0 is both, 1 is the right ear.
    func beep(pan: Float) {
        play(beepBuffer, on: beepNode, pan: pan)
    }

    /// Destination beacon.
    func chime(pan: Float) {
        play(chimeBuffer, on: chimeNode, pan: pan)
    }

    private func play(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode, pan: Float) {
        // The engine stops itself when earbuds are plugged in or removed.
        if !engine.isRunning {
            try? engine.start()
        }
        guard engine.isRunning else { return }
        node.pan = pan
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        node.play()
    }

    private static func makeBeep(format: AVAudioFormat) -> AVAudioPCMBuffer {
        makeBuffer(format: format, duration: 0.06) { time, progress in
            sin(2 * Float.pi * 880 * time) * sin(Float.pi * progress) * 0.6
        }
    }

    private static func makeChime(format: AVAudioFormat) -> AVAudioPCMBuffer {
        makeBuffer(format: format, duration: 0.35) { time, progress in
            let bell = sin(2 * Float.pi * 1320 * time) + 0.4 * sin(2 * Float.pi * 1980 * time)
            let attack = min(progress * 40, 1)
            return bell * attack * exp(-6 * progress) * 0.35
        }
    }

    private static func makeBuffer(format: AVAudioFormat, duration: Double, sample: (_ time: Float, _ progress: Float) -> Float) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            samples[i] = sample(Float(i) / Float(format.sampleRate), Float(i) / Float(frameCount))
        }
        return buffer
    }
}
