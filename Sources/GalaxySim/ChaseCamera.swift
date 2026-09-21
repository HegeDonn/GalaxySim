import Foundation
import simd

/// Ship geometry uses local display units; galactic travel remains in kpc.
/// Orbiting never changes the ship's heading or its physical position.
final class ChaseCamera {
    var yaw: Float = 0.30
    var elevation: Float = 0.36
    var distance: Float = 370
    private var desiredYaw: Float = 0.30
    private var desiredElevation: Float = 0.36
    private var desiredDistance: Float = 370
    let fovY: Float = 60 * .pi / 180
    // Aim above the hull to keep it below the centre, leaving room for the sky.
    var target: SIMD3<Float> { SIMD3(0, 20, 0) }
    var eye: SIMD3<Float> {
        target + distance * SIMD3(cos(elevation) * sin(yaw), sin(elevation), cos(elevation) * cos(yaw))
    }
    func orbit(dx: Float, dy: Float) {
        desiredYaw -= dx * 0.006
        desiredElevation = min(max(desiredElevation + dy * 0.006, -1.35), 1.35)
    }
    func zoom(_ delta: Float) { desiredDistance = min(max(desiredDistance * exp(-delta * 0.015), 250), 780) }
    func recenter() {
        desiredYaw = yaw + atan2(sin(0.30 - yaw), cos(0.30 - yaw))
        desiredElevation = 0.36; desiredDistance = 370
    }
    func update(dt: Float) {
        let blend = 1 - exp(-max(dt, 0) * 8)
        yaw += (desiredYaw - yaw) * blend
        elevation += (desiredElevation - elevation) * blend
        distance += (desiredDistance - distance) * blend
    }
    func pose(yaw: Float, elevation: Float, distance: Float = 370) {
        self.yaw = yaw; desiredYaw = yaw
        self.elevation = elevation; desiredElevation = elevation
        self.distance = distance; desiredDistance = distance
    }
    func state(aspect: Float, flight: FlightCamera) -> ShipRenderState {
        let projection = perspectiveMatrix(fovY: fovY, aspect: max(aspect, 0.001), near: 1, far: 2500)
        return ShipRenderState(viewProjection: projection * lookAtMatrix(eye: eye, center: target, up: SIMD3(0, 1, 0)),
            eye: eye, beta: flight.beta, time: Float(flight.coordinateTimeMyr / Double(max(flight.flightTimeScale, 1e-9))))
    }
    /// Map a direction expressed in the ship's own frame into world space.
    /// The frame is the ship's, roll included, which is the whole reason the
    /// galaxy tilts when the stick's ring is turned.
    func worldDirection(_ local: SIMD3<Float>, flight: FlightCamera) -> SIMD3<Float> {
        local.x * flight.shipRight + local.y * flight.shipUp - local.z * flight.travelDirection
    }
    func galaxyView(aspect: Float, flight: FlightCamera) -> (float4x4, SIMD3<Float>) {
        // Camera offset is negligible at galactic scale; orientations match exactly.
        let direction = worldDirection(simd_normalize(target - eye), flight: flight)
        let up = worldDirection(SIMD3(0, 1, 0), flight: flight)
        let projection = perspectiveMatrix(fovY: fovY, aspect: max(aspect, 0.001), near: 0.05, far: 50_000)
        return (projection * lookAtMatrix(eye: flight.position, center: flight.position + direction, up: up), flight.position)
    }
}
