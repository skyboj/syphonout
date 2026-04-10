import MetalKit
import AppKit

/// MTKView-based renderer for one output display.
/// Handles passthrough, crossfade, blank, and freeze modes entirely on the GPU.
final class MetalRenderer: NSObject, MTKViewDelegate {
    let mtkView: MTKView

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    // Pipeline states
    private var passthroughPipeline: MTLRenderPipelineState?
    private var crossfadePipeline: MTLRenderPipelineState?
    private var solidColorPipeline: MTLRenderPipelineState?
    private var smpteBarsPipeline: MTLRenderPipelineState?

    // Textures
    private var currentTexture: MTLTexture?
    private var previousTexture: MTLTexture?
    private var frozenTexture: MTLTexture?

    // Crossfade state (duration driven by PreferencesStore)
    private var crossfadeAlpha: Float = 1.0
    private var isCrossfading: Bool = false
    private var crossfadeStepPerFrame: Float {
        // Crossfade duration in seconds → fraction per frame at display refresh rate
        let fps = Float(mtkView.preferredFramesPerSecond > 0 ? mtkView.preferredFramesPerSecond : 60)
        let duration = Float(PreferencesStore.shared.crossfadeDuration)
        return 1.0 / (fps * duration)
    }

    // Blank mode state
    private var blankColor: SIMD4<Float>?
    private var showingTestPattern: Bool = false

    // Sampler
    private var sampler: MTLSamplerState?

    init(frame: CGRect, device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        let view = MTKView(frame: frame, device: device)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Match output display refresh rate (ProMotion, 60Hz, etc.)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(frame.origin) }) {
            view.preferredFramesPerSecond = screen.maximumFramesPerSecond
        }

        self.mtkView = view
        super.init()

        view.delegate = self
        buildPipelines()
        buildSampler()
    }

    // MARK: - Public API

    func updateTexture(_ texture: MTLTexture) {
        // Start crossfade: previous = last current, current = new
        previousTexture = currentTexture
        currentTexture = texture
        blankColor = nil

        if previousTexture != nil {
            crossfadeAlpha = 0.0
            isCrossfading = true
        } else {
            crossfadeAlpha = 1.0
            isCrossfading = false
        }
    }

    func beginFreeze() {
        frozenTexture = currentTexture
    }

    func endFreeze() {
        // On exit freeze → signal: crossfade from frozenTexture → live
        if let frozen = frozenTexture {
            previousTexture = frozen
            crossfadeAlpha = 0.0
            isCrossfading = true
        }
        frozenTexture = nil
    }

    func showBlank(option: OutputMode.BlankOption) {
        showingTestPattern = false
        switch option {
        case .black:
            blankColor = SIMD4<Float>(0, 0, 0, 1)
        case .white:
            blankColor = SIMD4<Float>(1, 1, 1, 1)
        case .testPattern:
            // GPU-generated SMPTE EBU color bars via smpteBarsFragment shader
            blankColor = nil
            showingTestPattern = true
        }
        isCrossfading = false
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        // Crossfade alpha ramp: duration from PreferencesStore (default 100ms)
        if isCrossfading {
            crossfadeAlpha += crossfadeStepPerFrame
            if crossfadeAlpha >= 1.0 {
                crossfadeAlpha = 1.0
                isCrossfading = false
                previousTexture = nil
            }
        }

        // Frozen frame overrides live texture
        let displayTexture = frozenTexture ?? currentTexture

        if showingTestPattern {
            drawTestPattern(encoder: encoder)
        } else if let color = blankColor {
            drawSolidColor(color, encoder: encoder)
        } else if isCrossfading, let prev = previousTexture, let curr = displayTexture {
            drawCrossfade(from: prev, to: curr, alpha: crossfadeAlpha, encoder: encoder)
        } else if let tex = displayTexture {
            drawPassthrough(tex, encoder: encoder)
        } else {
            drawSolidColor(SIMD4<Float>(0, 0, 0, 1), encoder: encoder)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Draw calls

    private func drawPassthrough(_ texture: MTLTexture, encoder: MTLRenderCommandEncoder) {
        guard let pipeline = passthroughPipeline, let sampler = sampler else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawCrossfade(from texA: MTLTexture, to texB: MTLTexture, alpha: Float, encoder: MTLRenderCommandEncoder) {
        guard let pipeline = crossfadePipeline, let sampler = sampler else { return }
        var uniforms = alpha
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texA, index: 0)
        encoder.setFragmentTexture(texB, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawSolidColor(_ color: SIMD4<Float>, encoder: MTLRenderCommandEncoder) {
        guard let pipeline = solidColorPipeline else { return }
        var c = color
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawTestPattern(encoder: MTLRenderCommandEncoder) {
        guard let pipeline = smpteBarsPipeline else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    // MARK: - Pipeline setup

    private func buildPipelines() {
        guard let library = device.makeDefaultLibrary() else { return }

        let vertex = library.makeFunction(name: "vertexShader")!

        passthroughPipeline = makePipeline(vertex: vertex, fragment: library.makeFunction(name: "passthroughFragment")!)
        crossfadePipeline = makePipeline(vertex: vertex, fragment: library.makeFunction(name: "crossfadeFragment")!)
        solidColorPipeline = makePipeline(vertex: vertex, fragment: library.makeFunction(name: "solidColorFragment")!)
        smpteBarsPipeline = makePipeline(vertex: vertex, fragment: library.makeFunction(name: "smpteBarsFragment")!)
    }

    private func makePipeline(vertex: MTLFunction, fragment: MTLFunction) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    private func buildSampler() {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.mipFilter = .notMipmapped
        sampler = device.makeSamplerState(descriptor: desc)
    }
}
