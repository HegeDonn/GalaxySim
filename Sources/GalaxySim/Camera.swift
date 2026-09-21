import simd
import Foundation

// MARK: - Matrix helpers

func perspectiveMatrix(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
    let y = 1 / tan(fovY * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return float4x4(columns: (
        SIMD4(x, 0, 0,  0),
        SIMD4(0, y, 0,  0),
        SIMD4(0, 0, z, -1),
        SIMD4(0, 0, z * near, 0)
    ))
}

func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return float4x4(columns: (
        SIMD4(s.x, u.x, -f.x, 0),
        SIMD4(s.y, u.y, -f.y, 0),
        SIMD4(s.z, u.z, -f.z, 0),
        SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

/// Orthonormal basis with `axis` as the third vector. Stable for any input.
func basis(forAxis axis: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
    let z = simd_normalize(axis)
    // pick the world axis least aligned with z to avoid a degenerate cross
    let helper: SIMD3<Float> = abs(z.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
    let x = simd_normalize(simd_cross(helper, z))
    let y = simd_cross(z, x)
    return (x, y, z)
}

// MARK: - Orbit camera

/// Turntable camera: azimuth/elevation around a target, with smoothed
/// motion so dragging and auto-orbit both feel weighted rather than snappy.
final class Camera {
    var target: SIMD3<Float> = .zero
    var distance: Float = 120
    var azimuth: Float = 0.6
    var elevation: Float = 0.45
    var fovY: Float = 50 * .pi / 180

    // smoothed values actually used for rendering
    private var sTarget: SIMD3<Float> = .zero
    private var sDistance: Float = 120
    private var sAzimuth: Float = 0.6
    private var sElevation: Float = 0.45
    private var initialised = false

    var autoOrbit: Bool = true
    var autoOrbitSpeed: Float = 0.035   // radians / second

    /// When set, the camera keeps the whole particle cloud framed. Zooming
    /// by hand switches it off so the user stays in control.
    var autoFrame: Bool = true
    var framePadding: Float = 1.45

    /// Feed the current cloud extent; the camera eases toward a distance
    /// that keeps it filling the view.
    func frame(center: SIMD3<Float>, radius: Float) {
        guard autoFrame else { return }
        target = center
        let needed = min(max(radius * framePadding / tan(fovY * 0.5), 12), 6000)
        // Deadband: ignore sub-2% changes entirely. Without it the camera is
        // always creeping toward a slightly different distance and never
        // settles, which reads as a permanent low-level drift.
        if abs(needed - distance) / max(distance, 1e-3) > 0.02 {
            distance = needed
        }
    }

    /// The distance actually used for rendering (post-smoothing), as opposed
    /// to `distance`, which is the target being eased toward.
    var renderedDistance: Float { sDistance }
    var renderedTarget: SIMD3<Float> { sTarget }

    var position: SIMD3<Float> {
        let ce = cos(sElevation), se = sin(sElevation)
        let ca = cos(sAzimuth),   sa = sin(sAzimuth)
        return sTarget + SIMD3(sDistance * ce * sa,
                               sDistance * se,
                               sDistance * ce * ca)
    }

    func update(dt: Float) {
        if !initialised {
            sTarget = target; sDistance = distance
            sAzimuth = azimuth; sElevation = elevation
            initialised = true
            return
        }
        if autoOrbit { azimuth += autoOrbitSpeed * dt }

        // Exponential smoothing, frame-rate independent. Rotation follows the
        // hand quickly, but dolly and target ease far more slowly: those are
        // driven by a measured particle extent that is inherently noisy, and a
        // fast response there turns measurement noise into visible jitter.
        let kRot  = 1 - exp(-dt * 9.0)
        let kDolly = 1 - exp(-dt * 1.1)
        sTarget    += (target - sTarget) * kDolly
        sDistance  += (distance - sDistance) * kDolly
        sAzimuth   += (azimuth - sAzimuth) * kRot
        sElevation += (elevation - sElevation) * kRot
    }

    func viewProjection(aspect: Float) -> float4x4 {
        // Near/far track the orbit distance so precision stays usable
        // whether you're inside a disk or 2000 kpc out.
        let near = max(0.05, sDistance * 0.002)
        let far  = max(2000, sDistance * 12)
        let proj = perspectiveMatrix(fovY: fovY, aspect: aspect, near: near, far: far)
        let view = lookAtMatrix(eye: position, center: sTarget, up: SIMD3(0, 1, 0))
        return proj * view
    }

    /// World-space ray through a normalised-device-coordinate point.
    /// Used to turn a click into a position on the orbital plane.
    func ray(ndc: SIMD2<Float>, aspect: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let inv = viewProjection(aspect: aspect).inverse
        var near = inv * SIMD4<Float>(ndc.x, ndc.y, 0, 1)
        var far  = inv * SIMD4<Float>(ndc.x, ndc.y, 1, 1)
        near /= near.w
        far  /= far.w
        let o = SIMD3(near.x, near.y, near.z)
        let d = simd_normalize(SIMD3(far.x, far.y, far.z) - o)
        return (o, d)
    }

    /// Where that ray meets the y = 0 plane, if it does at all.
    func groundHit(ndc: SIMD2<Float>, aspect: Float) -> SIMD3<Float>? {
        let r = ray(ndc: ndc, aspect: aspect)
        guard abs(r.direction.y) > 1e-4 else { return nil }
        let t = -r.origin.y / r.direction.y
        guard t > 0 else { return nil }
        return r.origin + r.direction * t
    }

    func drag(dx: Float, dy: Float) {
        azimuth   -= dx * 0.006
        elevation += dy * 0.006
        let lim: Float = .pi / 2 - 0.02
        elevation = min(max(elevation, -lim), lim)
    }

    func zoom(_ amount: Float) {
        autoFrame = false
        distance *= exp(-amount * 0.05)
        distance = min(max(distance, 1.5), 6000)
    }
}
