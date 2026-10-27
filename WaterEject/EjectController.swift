import AVFoundation
import Observation
import UIKit

enum EjectMode: String, CaseIterable, Identifiable {
    case auto
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "一键排水"
        case .manual: "手动频率"
        }
    }
}

struct AutoPhase: Identifiable {
    let title: String
    let start: Double
    let end: Double

    var id: String { title }
}

@MainActor
@Observable
final class EjectController {
    /// Stages of the automatic eject program, in seconds from start.
    static let autoPhases: [AutoPhase] = [
        AutoPhase(title: "持续震动", start: 0, end: 12),
        AutoPhase(title: "脉冲推水", start: 12, end: 22),
        AutoPhase(title: "扫频清残留", start: 22, end: 30),
    ]

    /// Duration of the automatic eject program in seconds.
    static let autoDuration: Double = autoPhases.last!.end

    var mode: EjectMode = .auto
    var manualFrequency: Double = 165

    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var currentFrequency: Double = 165
    private(set) var currentAmplitude: Double = 0
    private(set) var phaseIndex = 0
    /// True for a few seconds after the automatic program finishes on its own.
    private(set) var didComplete = false
    private(set) var phaseLabel = ""
    private(set) var outputVolume: Float = 1
    private(set) var isUsingSpeaker = true
    private(set) var errorMessage: String?

    var isVolumeLow: Bool { outputVolume < 0.9 }

    private let generator = ToneGenerator()
    private var playbackTask: Task<Void, Never>?
    private var completionResetTask: Task<Void, Never>?
    private var volumeObservation: NSKeyValueObservation?

    init() {
        let session = AVAudioSession.sharedInstance()
        outputVolume = session.outputVolume
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.outputVolume = value }
        }
        refreshRoute()

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRoute() }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    // MARK: - Public API

    func toggle() {
        isPlaying ? stop() : start()
    }

    func start() {
        guard !isPlaying else { return }
        do {
            // Activate the session first so outputVolume reflects the playback route.
            try generator.start()
        } catch {
            errorMessage = "无法启动音频：\(error.localizedDescription)"
            return
        }

        errorMessage = nil
        completionResetTask?.cancel()
        didComplete = false
        isPlaying = true
        progress = 0
        outputVolume = AVAudioSession.sharedInstance().outputVolume
        refreshRoute()
        UIApplication.shared.isIdleTimerDisabled = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        switch mode {
        case .auto: playbackTask = Task { await runAutoProgram() }
        case .manual: playbackTask = Task { await runManual() }
        }
    }

    func stop() {
        guard isPlaying else { return }
        playbackTask?.cancel()
        playbackTask = nil
        generator.set(frequency: currentFrequency, amplitude: 0)
        currentAmplitude = 0
        isPlaying = false
        phaseLabel = ""
        UIApplication.shared.isIdleTimerDisabled = false

        // Let the amplitude ramp down before tearing the engine down.
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            if !self.isPlaying { self.generator.stop() }
        }
    }

    // MARK: - Programs

    private func runAutoProgram() async {
        let start = Date.now
        while !Task.isCancelled {
            let t = Date.now.timeIntervalSince(start)
            if t >= Self.autoDuration { break }

            let step = Self.autoProgram(at: t)
            currentFrequency = step.frequency
            currentAmplitude = step.amplitude
            phaseIndex = step.phaseIndex
            phaseLabel = Self.autoPhases[step.phaseIndex].title
            progress = t / Self.autoDuration
            generator.set(frequency: step.frequency, amplitude: step.amplitude)

            try? await Task.sleep(for: .milliseconds(16))
        }

        guard !Task.isCancelled else { return }
        progress = 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        didComplete = true
        stop()
        completionResetTask = Task {
            try? await Task.sleep(for: .seconds(3.6))
            if !Task.isCancelled { self.didComplete = false }
        }
    }

    private func runManual() async {
        while !Task.isCancelled {
            currentFrequency = manualFrequency
            currentAmplitude = 1
            phaseLabel = "持续播放"
            generator.set(frequency: manualFrequency, amplitude: 1)
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Seconds over which the tone fades out at the end of the automatic program.
    private static let fadeOutDuration: Double = 2

    /// Three-stage program: steady 165 Hz, pulsed 165 Hz, then a low-frequency sweep that fades out.
    private static func autoProgram(at t: Double) -> (frequency: Double, amplitude: Double, phaseIndex: Int) {
        let index = autoPhases.firstIndex { t < $0.end } ?? autoPhases.count - 1
        let local = t - autoPhases[index].start
        switch index {
        case 0:
            return (165, 1, index)
        case 1:
            // 0.4 s on / 0.2 s off pulses to shake droplets loose.
            let cycle = local.truncatingRemainder(dividingBy: 0.6)
            return (165, cycle < 0.4 ? 1 : 0, index)
        default:
            // Triangle sweep 120 -> 260 -> 120 Hz every 4 s to hit varying resonances.
            let unit = local.truncatingRemainder(dividingBy: 4) / 4
            let tri = unit < 0.5 ? unit * 2 : (1 - unit) * 2
            let fade = min(max((autoDuration - t) / fadeOutDuration, 0), 1)
            return (120 + 140 * tri, fade * fade * (3 - 2 * fade), index)
        }
    }

    // MARK: - Route

    private func refreshRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        // Before the session is active the route may be empty; treat that as speaker.
        isUsingSpeaker = outputs.isEmpty || outputs.contains { $0.portType == .builtInSpeaker }
    }
}
