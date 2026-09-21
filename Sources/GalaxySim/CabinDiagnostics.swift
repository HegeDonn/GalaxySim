import Foundation
import Metal
import simd

/// Reproducible cabin images and camera invariants, without an AppKit window.
func runCabinDiagnostics(host: SimHost, output: String, width: Int, height: Int) throws {
    precondition(width > 0 && height > 0, "Cabin capture dimensions must be positive")
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    func failure(_ message: String) -> NSError {
        NSError(domain: "GalaxySim.CabinDiagnostics", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
    func check(_ condition: Bool, _ message: String) {
        precondition(condition, "Cabin check failed: " + message)
        print("PASS: " + message)
    }
    func elements(_ m: float4x4) -> [Float] {
        (0..<4).flatMap { c in (0..<4).map { r in m[c][r] } }
    }
    func differs(_ a: float4x4, _ b: float4x4) -> Bool {
        zip(elements(a), elements(b)).contains { abs($0 - $1) > 0.00001 }
    }

    if let assetURL = Bundle.module.url(forResource: "cabin", withExtension: "mesh", subdirectory: "Cabin") {
        let data = try Data(contentsOf: assetURL)
        check(!(try CabinAsset.decode(data)).isEmpty, "Bundled Blender mesh validates")
        func rejects(_ bytes: Data) -> Bool {
            do { _ = try CabinAsset.decode(bytes); return false } catch { return true }
        }
        check(rejects(Data(data.dropLast())), "Truncated cabin asset rejected")
        var badMagic = data; badMagic[0] = 0
        check(rejects(badMagic), "Invalid cabin header rejected")
        var badFloat = data
        // First position x becomes a quiet NaN (IEEE754 little endian).
        badFloat.replaceSubrange(12..<16, with: [0x00, 0x00, 0xC0, 0x7F])
        check(rejects(badFloat), "Nonfinite cabin vertices rejected")
    }

    let steps = Int(max(0, (300 - host.sim.currentTime) / host.sim.params.dt))
    host.advance(steps: steps)
    let extent = host.sim.sampleExtent()
    let flight = FlightCamera()
    flight.position = extent.center + SIMD3<Float>(0, extent.radius * 0.35, extent.radius * 2.2)
    flight.pitch = -atan2(0.35, 2.2)
    flight.travelDirection = flight.viewDirection
    flight.beta = 0.5
    let aspect = Float(width) / Float(height)
    let originalYaw = flight.yaw, originalPitch = flight.pitch
    let heading = flight.travelDirection
    let centered = flight.cabinState(aspect: aspect).viewProjection
    check(elements(centered).allSatisfy(\.isFinite), "Centered cabin matrix is finite")
    flight.look(dx: 120, dy: 20)
    check(differs(centered, flight.cabinState(aspect: aspect).viewProjection), "Head look changes cabin view")
    check(simd_length(flight.travelDirection - heading) < 0.000001, "Head look preserves ship heading")
    flight.setViewToTravelDirection()
    check(!differs(centered, flight.cabinState(aspect: aspect).viewProjection), "Recenter restores forward cabin view")
    flight.cabinLean = 0.22
    check(differs(centered, flight.cabinState(aspect: aspect).viewProjection), "Head lean creates cabin parallax")
    flight.cabinLean = 0
    flight.beta = 0.9999
    check(!differs(centered, flight.cabinState(aspect: aspect).viewProjection), "Relativistic speed does not distort cabin geometry")

    guard let texture = host.makeCaptureTexture(width, height) else {
        throw failure("Unable to allocate cabin capture texture")
    }
    func render(to target: MTLTexture, cabin: Bool) throws {
        let state = flight.cabinState(aspect: aspect)
        checkFinite(state.viewProjection)
        guard let cb = host.ctx.queue.makeCommandBuffer() else {
            throw failure("Unable to allocate cabin render command buffer")
        }
        host.renderer.render(into: target, commandBuffer: cb, simulation: host.sim,
            camera: host.camera,
            viewOverride: (flight.viewProjection(aspect: aspect), flight.position),
            relativity: flight.uniforms(), cabin: cabin ? state : nil)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        guard cb.status == .completed else { throw failure("Cabin GPU render did not complete") }
    }
    func checkFinite(_ matrix: float4x4) {
        precondition(elements(matrix).allSatisfy(\.isFinite), "Cabin camera matrix contains NaN or infinity")
    }
    let cases: [(String, Float, Float, Float, Float, Bool)] = [
        ("forward", 0, 0, 0, 0.5, true),
        ("left", -35, 0, 0, 0.5, true),
        ("right", 35, 0, 0, 0.5, true),
        ("down", 0, -20, 0, 0.5, true),
        ("aft", 180, 0, 0, 0.5, true),
        ("roof", 0, 65, 0, 0.5, true),
        ("floor", 0, -65, 0, 0.5, true),
        ("lean-left", 0, 0, -0.22, 0.5, true),
        ("lean-right", 0, 0, 0.22, 0.5, true),
        ("beta-099", 0, 0, 0, 0.99, true),
        ("cabin-off", 0, 0, 0, 0.5, false)
    ]
    for (name, yawDegrees, pitchDegrees, lean, beta, cabin) in cases {
        flight.yaw = originalYaw + yawDegrees * .pi / 180
        flight.pitch = originalPitch + pitchDegrees * .pi / 180
        flight.cabinLean = lean
        flight.beta = beta
        try render(to: texture, cabin: cabin)
        let path = URL(fileURLWithPath: output).appendingPathComponent("cabin-\(name)-\(width).png").path
        guard try host.saveTexture(texture, to: path) else { throw failure("Unable to save " + path) }
        print("Saved " + path)
    }

    // Private storage matches the live drawable more closely than capture storage.
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    guard let benchmarkTexture = host.ctx.device.makeTexture(descriptor: descriptor) else {
        throw failure("Unable to allocate cabin benchmark texture")
    }
    flight.yaw = originalYaw
    flight.pitch = originalPitch
    flight.cabinLean = 0
    flight.beta = 0.5
    var results: [Double] = []
    for cabin in [false, true] {
        for _ in 0..<5 { try render(to: benchmarkTexture, cabin: cabin) }
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<30 { try render(to: benchmarkTexture, cabin: cabin) }
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 30
        results.append(milliseconds)
        print(String(format: "Render %@ at %dx%d: %.2f ms/frame (30 synchronous frames, physics excluded)",
                     cabin ? "with cabin" : "without cabin", width, height, milliseconds))
    }
    print(String(format: "Measured cabin increment: %.2f ms/frame; sequential wall timing, not an isolated GPU benchmark",
                 results[1] - results[0]))
}
