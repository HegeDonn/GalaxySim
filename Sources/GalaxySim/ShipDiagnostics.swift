import Foundation
import Metal
import simd

/// Third-person invariants and reproducible inspection images. Physics excluded from timing.
func runShipDiagnostics(host: SimHost, output: String, width: Int, height: Int) throws {
    precondition(width > 0 && height > 0)
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    func check(_ value: Bool, _ name: String) { precondition(value, name); print("PASS: " + name) }
    func elements(_ m: float4x4) -> [Float] { (0..<4).flatMap { c in (0..<4).map { r in m[c][r] } } }
    let flight = FlightCamera(), chase = ChaseCamera()
    let e = host.sim.sampleExtent()
    flight.position = e.center + SIMD3(0, e.radius * 0.35, e.radius * 2.2)
    flight.pitch = -atan2(0.35, 2.2)
    flight.travelDirection = flight.viewDirection
    let initialPosition = flight.position, heading = flight.travelDirection
    let aspect = Float(width) / Float(height)
    chase.orbit(dx: 120, dy: 50); chase.update(dt: 1)
    check(simd_length(flight.travelDirection - heading) < 1e-6 && flight.position == initialPosition,
          "Orbit changes neither heading nor physical position")
    let before = chase.eye
    chase.zoom(20); chase.update(dt: 1)
    check(simd_length(chase.eye - before) > 1, "Zoom changes inspection distance")
    chase.recenter(); chase.update(dt: 2)
    check(abs(chase.yaw - 0.30) < 0.001 && abs(chase.distance - 370) < 0.001,
          "Follow returns smoothly to rear quarter")
    let localBefore = chase.state(aspect: aspect, flight: flight).viewProjection
    flight.turn(0.3)
    check(flight.travelDirection.x > heading.x, "Right steering turns ship toward world right")
    check(elements(localBefore) == elements(chase.state(aspect: aspect, flight: flight).viewProjection),
          "Chase remains attached while ship turns")
    flight.travelDirection = heading
    flight.update(dt: 0.5)
    check(simd_length(flight.position - initialPosition) > 0, "Ship advances through galaxy")
    flight.position = initialPosition
    flight.beta = 0.995
    check(elements(localBefore) == elements(chase.state(aspect: aspect, flight: flight).viewProjection),
          "Relativistic speed does not deform ship")
    guard let texture = host.makeCaptureTexture(width, height) else { throw NSError(domain: "ShipCapture", code: 1) }
    func render(ship: Bool) throws {
        let state = chase.state(aspect: aspect, flight: flight)
        check(elements(state.viewProjection).allSatisfy(\.isFinite), "Finite ship matrix")
        let cb = host.ctx.queue.makeCommandBuffer()!
        host.renderer.render(into: texture, commandBuffer: cb, simulation: host.sim, camera: host.camera,
            viewOverride: chase.galaxyView(aspect: aspect, flight: flight), relativity: flight.uniforms(), ship: ship ? state : nil)
        cb.commit(); cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        check(cb.status == .completed, "GPU render completed")
    }
    let cases: [(String, Float, Float, Float)] = [
        ("chase", 0.30, 0.36, 0.5), ("port", -1.3, 0.3, 0.5), ("starboard", 1.3, 0.3, 0.5),
        ("front", 2.8, 0.3, 0.5), ("above", 0.3, 1.2, 0.5), ("below", 0.3, -0.7, 0.5),
        ("warp", 0.30, 0.36, 0.95), ("extreme", 0.30, 0.36, 0.995)]
    for (name, yaw, elevation, beta) in cases {
        chase.pose(yaw: yaw, elevation: elevation); flight.beta = beta
        try render(ship: true)
        let path = output + "/ship-\(name)-\(width).png"
        check(try host.saveTexture(texture, to: path), "Saved " + path)
    }
    chase.pose(yaw: 0.30, elevation: 0.36); flight.beta = 0.5
    var times: [Double] = []
    for ship in [false, true] {
        // Avoid diagnostics print overhead within the measured loop.
        func frame() throws {
            let cb = host.ctx.queue.makeCommandBuffer()!
            host.renderer.render(into: texture, commandBuffer: cb, simulation: host.sim, camera: host.camera,
                viewOverride: chase.galaxyView(aspect: aspect, flight: flight), relativity: flight.uniforms(),
                ship: ship ? chase.state(aspect: aspect, flight: flight) : nil)
            cb.commit(); cb.waitUntilCompleted()
            if let error = cb.error { throw error }
        }
        for _ in 0..<5 { try frame() }
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<30 { try frame() }
        times.append((CFAbsoluteTimeGetCurrent() - start) * 1000 / 30)
    }
    print(String(format: "Scene %.2f ms/frame; with ship %.2f; increment %.2f (30 sequential wall timings, physics excluded)", times[0], times[1], times[1] - times[0]))
}
