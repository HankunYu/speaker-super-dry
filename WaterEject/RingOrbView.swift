import MetalKit
import SwiftUI

/// Full-screen HDR rendering of colored wavy rings that follow the tone.
struct RingOrbView: View {
    /// Vertical position of the ring center as a fraction of the height, from the top.
    static let centerY: Double = 0.5

    var frequency: Double
    var amplitude: Double
    var isPlaying: Bool
    var isComplete: Bool

    var body: some View {
        RingOrbCanvas(
            inputs: OrbInputs(
                frequency: frequency,
                amplitude: isPlaying ? amplitude : 0,
                isComplete: isComplete
            )
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct OrbInputs {
    var frequency: Double = 165
    var amplitude: Double = 0
    var isComplete = false
}

/// Hosts an EDR-capable MTKView so line highlights can exceed SDR white.
private struct RingOrbCanvas: UIViewRepresentable {
    var inputs: OrbInputs

    func makeCoordinator() -> RingOrbRenderer {
        RingOrbRenderer()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.inputs = inputs
    }
}

/// Must match `OrbUniforms` in RingOrb.metal.
private struct OrbUniforms {
    var size: SIMD2<Float>
    var scale: Float
    var centerY: Float
    var time: Float
    var frequency: Float
    var amplitude: Float
    var flow: Float
    var causticPhase: Float
    var converge: Float
    var flash: Float
    var headroom: Float
}

private final class RingOrbRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    var inputs = OrbInputs()

    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let motion = OrbMotion()

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        pipeline = Self.makePipeline(device: device)
        super.init()
    }

    func configure(_ view: MTKView) {
        view.colorPixelFormat = .rgba16Float
        view.preferredFramesPerSecond = 120
        view.isOpaque = true
        view.backgroundColor = .black
        view.delegate = self
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let pipeline,
            let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let frame = motion.step(
            date: .now,
            targetAmplitude: inputs.amplitude,
            frequency: inputs.frequency,
            isComplete: inputs.isComplete
        )
        let scale = max(view.drawableSize.width / max(view.bounds.width, 1), 1)
        // Headroom changes with screen brightness and ambient light, so read it every frame.
        let headroom = view.window?.windowScene?.screen.currentEDRHeadroom ?? 1

        var uniforms = OrbUniforms(
            size: SIMD2(Float(view.drawableSize.width / scale), Float(view.drawableSize.height / scale)),
            scale: Float(scale),
            centerY: Float(RingOrbView.centerY),
            time: Float(frame.time),
            frequency: Float(inputs.frequency),
            amplitude: Float(frame.amplitude),
            flow: Float(frame.flow),
            causticPhase: Float(frame.causticPhase),
            converge: Float(frame.converge),
            flash: Float(frame.flash),
            headroom: Float(headroom)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
        guard let device, let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "ringOrbVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "ringOrbFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// Shader inputs for one rendered frame.
private struct OrbFrame {
    var time: Double
    var amplitude: Double
    var flow: Double
    var causticPhase: Double
    var converge: Double
    var flash: Double
}

/// Mutable per-frame state. Not observed: it is advanced while the timeline renders.
private final class OrbMotion {
    private static let springStep = 1.0 / 60

    private let start = Date.now
    private var lastTime: Double?
    private var springAccumulator: Double = 0
    private var amplitude: Double = 0
    private var velocity: Double = 0
    private var flow: Double = 0
    private var causticPhase: Double = 0
    private var wasComplete = false
    private var completeTime: Double = -.infinity

    func step(date: Date, targetAmplitude: Double, frequency: Double, isComplete: Bool) -> OrbFrame {
        let time = date.timeIntervalSince(start)
        let dt = min(max(time - (lastTime ?? time), 0), 1.0 / 20)
        lastTime = time

        if isComplete && !wasComplete {
            completeTime = time
        }
        wasComplete = isComplete

        // Underdamped spring so the rings bloom with a little overshoot; fixed step keeps it frame-rate independent.
        springAccumulator += dt
        while springAccumulator >= Self.springStep {
            velocity = velocity * 0.8 + (targetAmplitude - amplitude) * 0.07
            amplitude += velocity
            springAccumulator -= Self.springStep
        }

        // Integrate phases so changing frequency or amplitude never makes the motion jump.
        let pitch = min(max(log(frequency / 60) / log(500.0 / 60), 0), 1)
        flow += dt * (0.5 + pitch * 1.4)
        causticPhase += dt * 0.3 * (0.6 + 0.8 * max(amplitude, 0))

        let sinceComplete = time - completeTime
        let converge = smoothstep(0, 1.1, sinceComplete) * (1 - smoothstep(2.4, 4.2, sinceComplete))
        let flash = exp(-pow((sinceComplete - 0.75) / 0.55, 2))

        return OrbFrame(
            time: time,
            amplitude: amplitude,
            flow: flow,
            causticPhase: causticPhase,
            converge: converge,
            flash: flash.isFinite ? flash : 0
        )
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
