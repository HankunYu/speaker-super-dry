import AVFoundation

/// Real-time sine generator driven by AVAudioSourceNode.
/// Frequency and amplitude are smoothed on the render thread to avoid clicks.
final class ToneGenerator: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // Written from the main thread, read on the render thread.
    // Plain Double stores are atomic enough on arm64 for this use.
    private var targetFrequency: Double = 165
    private var targetAmplitude: Double = 0

    // Render-thread state.
    private var currentFrequency: Double = 165
    private var currentAmplitude: Double = 0
    private var phase: Double = 0

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        guard !engine.isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)

        if sourceNode == nil {
            let format = engine.outputNode.inputFormat(forBus: 0)
            let sampleRate = format.sampleRate > 0 ? format.sampleRate : 48_000
            let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            let node = makeSourceNode(sampleRate: sampleRate)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: stereoFormat)
            sourceNode = node
        }

        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        try engine.start()
    }

    func stop() {
        targetAmplitude = 0
        engine.stop()
        currentAmplitude = 0
        phase = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func set(frequency: Double, amplitude: Double) {
        targetFrequency = frequency
        targetAmplitude = min(max(amplitude, 0), 1)
    }

    private func makeSourceNode(sampleRate: Double) -> AVAudioSourceNode {
        let twoPi = 2 * Double.pi
        // ~8 ms one-pole smoothing for amplitude, ~30 ms for frequency.
        let ampCoeff = 1 - exp(-1 / (0.008 * sampleRate))
        let freqCoeff = 1 - exp(-1 / (0.030 * sampleRate))

        return AVAudioSourceNode { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let targetFreq = self.targetFrequency
            let targetAmp = self.targetAmplitude
            var freq = self.currentFrequency
            var amp = self.currentAmplitude
            var phase = self.phase

            for frame in 0..<Int(frameCount) {
                freq += (targetFreq - freq) * freqCoeff
                amp += (targetAmp - amp) * ampCoeff
                let sample = Float(sin(phase) * amp)
                phase += twoPi * freq / sampleRate
                if phase >= twoPi { phase -= twoPi }

                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }

            self.currentFrequency = freq
            self.currentAmplitude = amp
            self.phase = phase
            return noErr
        }
    }
}
