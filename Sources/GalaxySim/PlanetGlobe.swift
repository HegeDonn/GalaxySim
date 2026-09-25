import AppKit
import MetalKit
import simd

/// Direct GPU material evaluation: no CPU texture baking or image readback.
final class PlanetGlobeView: MTKView, MTKViewDelegate {
    private struct Uniforms {
        var gasMotion = SIMD4<Float>.zero
        var gasShape = SIMD4<Float>.zero
        var cloudControls = SIMD4<Float>(1,1,1,0.018)
        var materialControls = SIMD4<Float>(0.24,1,1,0.45)
        var optics = SIMD4<Float>(0.22,0,0,0)
        var normal = SIMD4<Float>(0,0,1,0)
        var up = SIMD4<Float>(0,1,0,0)
        var right = SIMD4<Float>(1,0,0,0)
        var axis = SIMD4<Float>(0,1,0,0)
        var air = SIMD4<Float>(0.18,0.48,0.95,1)
        var parameters = SIMD4<Float>.zero // time, material, seed, descent
        var ship = SIMD4<Float>.zero // speed, view width in points, upper seed bits
    }
    private static let gpu = MTLCreateSystemDefaultDevice()
    private static let compiler = DispatchQueue(label: "planet.metal.pipeline", qos: .userInitiated)
    private static var cachedPipeline: MTLRenderPipelineState?
    private var pipeline: MTLRenderPipelineState?
    private var commands: MTLCommandQueue?
    private var uniforms = Uniforms()
    private let inFlight = DispatchSemaphore(value: 2)
    private let started = CACurrentMediaTime()
    private(set) var hasFrame = false
    private(set) var errorMessage: String?
    private(set) var gpuMilliseconds: Double = 0
    private(set) var completedFrames = 0
    private(set) var firstFrameMilliseconds: Double = 0
    var reviewTime: Float?
    var tuning = PlanetTuning.load()
    private var gasDrift: Float = 0
    private var gasEvolution: Float = 0
    private var cloudDrift: Float = 0
    private var cloudEvolution: Float = 0
    private var previousTime: Float = 0

    init(seed: UInt32, atmosphere: String, axis: SIMD3<Float>) {
        super.init(frame: .zero, device: Self.gpu)
        uniforms.axis = SIMD4(axis,0)
        uniforms.parameters.z = Float(seed & 65535)
        uniforms.ship.z = Float(seed >> 16)
        setAtmosphere(atmosphere)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0,0,0,0)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        commands = device?.makeCommandQueue()
        delegate = self
        guard let gpu = device else { errorMessage = "Metal is unavailable"; return }
        Self.compiler.async { [weak self] in
            do {
                let state: MTLRenderPipelineState
                if let cached = Self.cachedPipeline { state = cached }
                else {
                    let url = Bundle.module.url(forResource: "PlanetGlobe", withExtension: "metal", subdirectory: "Shaders")!
                    let source = try String(contentsOf: url, encoding: .utf8)
                    let library = try gpu.makeLibrary(source: source, options: nil)
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = library.makeFunction(name: "planetVertex")
                    descriptor.fragmentFunction = library.makeFunction(name: "planetFragment")
                    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                    state = try gpu.makeRenderPipelineState(descriptor: descriptor)
                    Self.cachedPipeline = state
                }
                RunLoop.main.perform(inModes: [.default,.eventTracking]) { [weak self] in self?.pipeline = state }
            } catch {
                let message = error.localizedDescription
                RunLoop.main.perform(inModes: [.default,.eventTracking]) { [weak self] in
                    self?.errorMessage = message
                    print("Planet Metal shader failed: \(message)")
                }
            }
        }
    }
    required init(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func setAtmosphere(_ name: String) {
        let n = name.lowercased()
        let kind: Float
        let air: SIMD3<Float>
        if n.contains("nitrogen") || n.contains("aurora") { kind=0; air=SIMD3(0.18,0.48,0.95) }
        else if n.contains("ice giant") { kind=1; air=SIMD3(0.13,0.65,0.85) }
        else if n.contains("hydrogen") { kind=2; air=SIMD3(0.58,0.66,0.82) }
        else if n.contains("vacuum") { kind=3; air = .zero }
        else if n.contains("ammonia") { kind=4; air=SIMD3(0.59,0.49,0.7) }
        else if n.contains("chlorine") { kind=5; air=SIMD3(0.53,0.65,0.2) }
        else if n.contains("thin") { kind=6; air=SIMD3(0.67,0.34,0.2) }
        else { kind=7; air=SIMD3(0.88,0.51,0.2) }
        uniforms.parameters.y = kind
        uniforms.air = SIMD4(air,kind == 3 ? 0 : kind == 6 ? 0.16 : 1)
    }
    func update(normal: SIMD3<Float>, up: SIMD3<Float>, right: SIMD3<Float>, speed: Float, descent: Float) {
        uniforms.normal = SIMD4(normal,0); uniforms.up = SIMD4(up,0); uniforms.right = SIMD4(right,0)
        let time = reviewTime ?? Float(CACurrentMediaTime()-started)
        let dt = max(0,min(0.1,time-previousTime)); previousTime=time
        gasDrift += dt*tuning.gasSpeed
        gasEvolution += dt*tuning.gasEvolution
        uniforms.gasMotion = SIMD4(reviewTime.map { $0*tuning.gasSpeed } ?? gasDrift,
            reviewTime.map { $0*tuning.gasEvolution } ?? gasEvolution,tuning.gasDistortion,tuning.gasScale)
        uniforms.gasShape = SIMD4(tuning.gasBands,tuning.gasShear,0,0)
        cloudDrift += dt*tuning.cloudSpeed
        cloudEvolution += dt*tuning.cloudEvolution
        uniforms.cloudControls = SIMD4(reviewTime.map { $0*tuning.cloudSpeed } ?? cloudDrift,
            reviewTime.map { $0*tuning.cloudEvolution } ?? cloudEvolution,tuning.cloudCover,tuning.cloudHeight)
        uniforms.materialControls = SIMD4(tuning.cloudShadow,tuning.airDensity,tuning.waterWaves,tuning.waterGloss)
        uniforms.optics.x = tuning.waterRoughness
        uniforms.parameters.x = time
        uniforms.parameters.w = descent
        uniforms.ship = SIMD4(speed,Float(bounds.width),uniforms.ship.z,0)
        draw()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let pipeline, let commands, window != nil, drawableSize.width > 0,
              inFlight.wait(timeout: .now()) == .success else { return }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = commands.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal(); return
        }
        encoder.setRenderPipelineState(pipeline)
        var u = uniforms
        encoder.setFragmentBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        encoder.endEncoding()
        command.present(drawable)
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] buffer in
            semaphore.signal()
            let elapsed = (buffer.gpuEndTime-buffer.gpuStartTime)*1000
            let success = buffer.status == .completed
            let error = buffer.error?.localizedDescription
            RunLoop.main.perform(inModes:[.default,.eventTracking]) { [weak self] in
                guard let self else { return }
                if success {
                    if !self.hasFrame { self.firstFrameMilliseconds = (CACurrentMediaTime()-self.started)*1000 }
                    self.hasFrame = true; self.completedFrames += 1; self.gpuMilliseconds = elapsed }
                else { self.errorMessage = error ?? "GPU rendering failed" }
            }
        }
        command.commit()
    }
}
