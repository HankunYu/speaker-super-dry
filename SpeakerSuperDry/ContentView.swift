import SwiftUI

struct ContentView: View {
    @Environment(EjectController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase

    /// Frequency at the moment a horizontal drag took over; nil while the touch is still a tap.
    @State private var dragStartFrequency: Double?
    @State private var showsDone = false

    /// Horizontal drag distance in points that moves the frequency by one octave.
    private let pointsPerOctave: Double = 100

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RingOrbView(
                    frequency: controller.currentFrequency,
                    amplitude: controller.currentAmplitude,
                    isPlaying: controller.isPlaying,
                    isComplete: controller.didComplete
                )

                readout
                    .position(x: geo.size.width / 2, y: geo.size.height * RingOrbView.centerY)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .contentShape(Rectangle())
        .gesture(orbGesture)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap() }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setManualFrequency(controller.manualFrequency + 10)
            case .decrement: setManualFrequency(controller.manualFrequency - 10)
            @unknown default: break
            }
        }
        .animation(.smooth(duration: 0.35), value: readoutText)
        .sensoryFeedback(.selection, trigger: manualStep)
        .task(id: controller.didComplete) {
            guard controller.didComplete else {
                showsDone = false
                return
            }
            // Let the rings converge before the label appears.
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { showsDone = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.stop() }
        }
    }

    // MARK: - Readout

    private var readoutText: String? {
        if controller.isPlaying {
            switch controller.mode {
            case .auto:
                let remaining = EjectController.autoDuration * (1 - controller.progress)
                return "\(max(Int(remaining.rounded(.up)), 1))"
            case .manual:
                return "\(Int(controller.manualFrequency.rounded())) Hz"
            }
        }
        return showsDone ? "Done" : nil
    }

    private var readout: some View {
        Text(readoutText ?? " ")
            .font(.system(size: 24, weight: .light, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.9))
            .contentTransition(.numericText(countsDown: true))
            .opacity(readoutText == nil ? 0 : 1)
            .allowsHitTesting(false)
    }

    // MARK: - Interaction

    /// Tap toggles the automatic program; a horizontal drag switches to a held manual tone.
    private var orbGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.translation.width
                if dragStartFrequency == nil {
                    guard abs(dx) > 8 else { return }
                    let isManualPlaying = controller.isPlaying && controller.mode == .manual
                    dragStartFrequency = isManualPlaying ? controller.manualFrequency : 165
                    if !isManualPlaying {
                        controller.stop()
                        controller.mode = .manual
                        controller.manualFrequency = 165
                        controller.start()
                    }
                }
                guard let start = dragStartFrequency else { return }
                setManualFrequency(start * pow(2, dx / pointsPerOctave))
            }
            .onEnded { _ in
                if dragStartFrequency == nil { tap() }
                dragStartFrequency = nil
            }
    }

    private func tap() {
        if controller.isPlaying {
            controller.stop()
        } else {
            controller.mode = .auto
            controller.start()
        }
    }

    private func setManualFrequency(_ frequency: Double) {
        controller.manualFrequency = min(max(frequency, 60), 500)
    }

    /// Changes every 10 Hz while dragging, for selection haptics.
    private var manualStep: Int {
        dragStartFrequency == nil ? 0 : Int(controller.manualFrequency / 10)
    }

    private var accessibilityLabel: String {
        if controller.isPlaying {
            return controller.mode == .auto ? "Ejecting water, tap to stop" : "\(Int(controller.manualFrequency)) Hz, tap to stop"
        }
        return "Start water eject"
    }
}

#Preview {
    ContentView()
        .environment(EjectController())
        .preferredColorScheme(.dark)
}
