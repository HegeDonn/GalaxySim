import AppKit
import simd
import Foundation

// ---------------------------------------------------------------
//  Entry point. Normally opens a window; --headless renders frames
//  offscreen so the simulator can be inspected and benchmarked
//  without a display.
// ---------------------------------------------------------------

struct Args {
    var headless = false
    var explorerTest = false
    var performanceTest = false
    var bench = false
    var scene = 0
    var budget = 300_000
    var shots: [Float] = [0, 150, 300, 450, 600]
    var out = "/tmp/galaxyshots"
    var width = 1920
    var height = 1080
    var solver: SolverMode = .restricted
    var info = false
    var buildTest = false
    var camTest = false
    var gallery = false
    var renderBench = false
    var sensorTest = false
    var flyTest = false
    var shipTest = false
    var skyTest = false
    var cabinTest = false
    var ghostTest = false
    var steerTest = false
    var settingsTest = false
    var starTest = false
    var localGroup = false
    var expComp = false
    var look: [String: Float] = [:]
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--headless": a.headless = true
        case "--explorertest": a.explorerTest = true; a.headless = true
        case "--perftest": a.performanceTest = true; a.headless = true
        case "--bench":    a.bench = true; a.headless = true
        case "--info":     a.info = true; a.headless = true
        case "--buildtest": a.buildTest = true; a.headless = true
        case "--camtest":  a.camTest = true; a.headless = true
        case "--gallery":  a.gallery = true; a.headless = true
        case "--renderbench": a.renderBench = true; a.headless = true
        case "--sensortest": a.sensorTest = true; a.headless = true
        case "--skytest": a.skyTest = true; a.headless = true
        case "--shiptest": a.shipTest = true; a.headless = true
        case "--cabintest": a.cabinTest = true; a.headless = true
        case "--flytest":  a.flyTest = true; a.headless = true
        case "--ghosttest": a.ghostTest = true; a.headless = true
        case "--steertest": a.steerTest = true; a.headless = true
        case "--settingstest": a.settingsTest = true; a.headless = true
        case "--startest": a.starTest = true; a.headless = true
        case "--localgroup": a.localGroup = true; a.headless = true
        case "--look":
            // e.g. --look white=220,beta=0.05,sat=1.4,bright=42,exp=1.0
            if let s = it.next() {
                for kv in s.split(separator: ",") {
                    let parts = kv.split(separator: "=")
                    if parts.count == 2, let v = Float(parts[1]) {
                        a.look[String(parts[0])] = v
                    }
                }
            }
        case "--scene":    a.scene = Int(it.next() ?? "") ?? 0
        case "--budget":   a.budget = Int(it.next() ?? "") ?? a.budget
        case "--out":      a.out = it.next() ?? a.out
        case "--shots":
            if let s = it.next() {
                a.shots = s.split(separator: ",").compactMap { Float($0) }
            }
        case "--size":
            if let s = it.next() {
                let p = s.split(separator: "x").compactMap { Int($0) }
                if p.count == 2 { a.width = p[0]; a.height = p[1] }
            }
        case "--solver":
            if let s = it.next() {
                switch s {
                case "direct":       a.solver = .direct
                case "bh", "tree":   a.solver = .barnesHut
                default:             a.solver = .restricted
                }
            }
        default: break
        }
    }
    return a
}

var args = parseArgs()
var args2ExpComp = false

if args.headless {
    do {
        let t0 = CFAbsoluteTimeGetCurrent()
        let host = try SimHost(budget: args.budget)
        host.sim.mode = args.solver
        for (k, v) in args.look {
            switch k {
            case "fullstars": host.renderer.settings.adaptiveStars = v < 0.5
            case "starbudget": host.renderer.settings.distantStarBudget = Int(v)
            case "splitphysics": host.sim.useFusedRestricted = v < 0.5
            case "filmk":  host.renderer.settings.filmK = v
            case "filmn":  host.renderer.settings.filmN = v
            case "psf":    host.renderer.settings.psfStrength = v
            case "halo":   host.renderer.settings.halation = v
            case "web":    host.renderer.settings.webStrength = v
            case "nofade": host.renderer.settings.disableWrapFade = v > 0.5
            case "expo":   host.renderer.settings.starExposure = v
            case "nostars": host.renderer.settings.showBackgroundStars = v < 0.5
            case "sat":    host.renderer.settings.saturation = v
            case "bright": host.renderer.settings.brightness = v
            case "exp":    host.renderer.settings.exposure = v
            case "star":   host.renderer.settings.starSize = v
            case "bloom":  host.renderer.settings.psfStrength = v
            case "sbthr":  host.sim.params.starburstThreshold = v
            case "sbgain": host.sim.params.starburstGain = v
            case "soft":   host.sim.params.softening = v
            case "expcomp": args2ExpComp = v > 0.5
            case "debug":  host.renderer.settings.debugParams = v > 0.5
            default: break
            }
        }
        if args.scene != 0 { host.loadScene(args.scene) }
        host.renderer.enableHDRReadback = true   // headless diagnostics only
        let setupMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        try FileManager.default.createDirectory(atPath: args.out,
                                            withIntermediateDirectories: true)

        print("scene      : \(host.scenes[args.scene].name)")
        print("solver     : \(args.solver.displayName)")
        print("particles  : \(host.sim.particleCount)")
        print("setup      : \(String(format: "%.0f ms", setupMs))")

        if args.explorerTest {
            try runStarExplorerDiagnostics(host: host, output: args.out)
            exit(0)
        }
        if args.performanceTest {
            try runPerformanceDiagnostics(host: host, output: args.out, width: args.width, height: args.height)
            exit(0)
        }

        if args.skyTest {
            try runSkyDiagnostics(host: host, output: args.out)
            exit(0)
        }

        if args.localGroup {
            try runLocalGroupDiagnostics(host: host, output: args.out)
            exit(0)
        }

        if args.shipTest {
            try runShipDiagnostics(host: host, output: args.out, width: args.width, height: args.height)
            exit(0)
        }

        if args.cabinTest {
            try runCabinDiagnostics(host: host, output: args.out, width: args.width, height: args.height)
            exit(0)
        }

        if args.starTest {
            // Fly straight forward and capture consecutive frames. A star that
            // pops at the wrap boundary shows up as an isolated pixel that
            // changes brightness abruptly between adjacent frames.
            try FileManager.default.createDirectory(atPath: args.out,
                                                    withIntermediateDirectories: true)
            host.sim.isPaused = true
            host.renderer.settings.webStrength = 0      // isolate the star field

            let flight = FlightCamera()
            flight.position = SIMD3(0, 0, 600)
            flight.yaw = 0
            flight.pitch = 0
            flight.travelDirection = flight.viewDirection
            flight.beta = 0.0                            // no aberration in the way

            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: args.width, height: args.height,
                mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let tex = host.ctx.device.makeTexture(descriptor: d)!
            let aspect = Float(args.width) / Float(args.height)

            // step by a fraction of the wrap cell so several stars must wrap
            let steps = 160
            let stride = Float(1400) / Float(steps)
            for i in 0..<steps {
                flight.position.z = 600 - Float(i) * stride
                guard let cb = host.ctx.queue.makeCommandBuffer() else { continue }
                host.renderer.render(into: tex, commandBuffer: cb,
                                     simulation: host.sim, camera: host.camera,
                                     viewOverride: (flight.viewProjection(aspect: aspect),
                                                    flight.position),
                                     relativity: flight.uniforms())
                cb.commit(); cb.waitUntilCompleted()
                try host.saveTexture(tex, to: "\(args.out)/f\(String(format: "%03d", i)).png")
            }
            print("wrote \(steps) frames to \(args.out)")
            exit(0)
        }

        if args.settingsTest {
            Settings.clear()
            let fresh = Settings.load()
            print("defaults      : exposure \(fresh.exposure)  budget \(fresh.particleBudget)  solver \(fresh.solver.displayName)")

            var s = Settings()
            s.exposure = 2.25
            s.psfStrength = 0.42
            s.starSize = 1.9
            s.webStrength = 0.0031
            s.particleBudget = 1_000_000
            s.solver = .barnesHut
            s.theta = 0.45
            s.autoOrbit = false
            s.masterVolume = 0.31
            s.audioEnabled = false
            s.trackVolumes = ["pads": 0.4, "glide": 0.8, "bells": 1.0, "drums": 0.65]
            let ok = s.save()
            print("save          : \(ok ? "ok" : "FAILED")")

            let back = Settings.load()
            var fails: [String] = []
            func chk(_ name: String, _ a: Bool) { if !a { fails.append(name) } }
            chk("exposure", back.exposure == s.exposure)
            chk("psfStrength", back.psfStrength == s.psfStrength)
            chk("starSize", back.starSize == s.starSize)
            chk("webStrength", back.webStrength == s.webStrength)
            chk("particleBudget", back.particleBudget == s.particleBudget)
            chk("solver", back.solver == s.solver)
            chk("theta", back.theta == s.theta)
            chk("autoOrbit", back.autoOrbit == s.autoOrbit)
            chk("masterVolume", back.masterVolume == s.masterVolume)
            chk("audioEnabled", back.audioEnabled == s.audioEnabled)
            chk("trackVolumes", back.trackVolumes == s.trackVolumes)
            print("round trip    : \(back == s ? "IDENTICAL" : "DIFFERS")")
            print(fails.isEmpty ? "PASS: every field survived"
                                : "FAIL: \(fails.joined(separator: ", "))")

            // a corrupt blob must not stop the app launching
            UserDefaults.standard.set(Data("not json".utf8), forKey: "GalaxySim.settings.v1")
            let rescued = Settings.load()
            print("corrupt blob  : recovered with defaults = \(rescued == Settings())")

            Settings.clear()
            print("cleared       : back to defaults = \(Settings.load() == Settings())")
            exit(fails.isEmpty ? 0 : 1)
        }

        if args.steerTest {
            for beta in [Float(0.1), 0.5, 0.9, 0.99] {
                let f = FlightCamera()
                f.beta = beta
                f.travelDirection = SIMD3(0, 0, -1)
                f.yaw = .pi          // look straight backwards
                f.pitch = 0
                var t: Float = 0
                let dt: Float = 1.0 / 60
                while f.headingOffsetDegrees > 2 && t < 60 {
                    f.steerTowardView(dt: dt)
                    t += dt
                }
                print(String(format:
                    "beta %.2f  gamma %.2f  ->  180 deg turn took %.1f s%@",
                    beta, f.gamma, t, t >= 60 ? "  (capped)" : ""))
            }
            exit(0)
        }

        if args.ghostTest {
            try FileManager.default.createDirectory(atPath: args.out,
                                                    withIntermediateDirectories: true)
            host.sim.isPaused = true
            host.customSpecs.removeAll()
            host.addGalaxy(type: .sb, massScale: 1.0, tiltDegrees: 20, at: SIMD3(-55, 0, 0))
            // frame both the placed galaxy and the ghost, then freeze the
            // camera exactly as painting mode does
            host.camera.autoFrame = false
            host.camera.autoOrbit = false
            host.camera.target = .zero
            host.camera.distance = 210
            host.camera.elevation = 0.55
            host.camera.azimuth = 0.2
            for _ in 0..<300 { host.camera.update(dt: 1.0 / 60.0) }
            for (i, t) in [Float(0), 45, 80].enumerated() {
                let cursor = SIMD3<Float>(55, 0, 15)
                host.updatePreview(type: .sc, tiltDegrees: t, at: cursor)
                var g = GridParams()
                g.camPos = SIMD4(host.camera.position, 0.17)
                g.cursor = SIMD4(cursor, 1)
                let span = host.camera.renderedDistance
                g.tuning = SIMD4(20, span * 0.85, max(span * 0.075, 9), 0)
                let path = "\(args.out)/ghost_tilt\(Int(t)).png"
                try host.capture(width: 1100, height: 700, to: path, grid: g)
                print("  tilt \(Int(t))° -> \(path)   preview particles: \(host.previewCount)")
                _ = i
            }
            exit(0)
        }

        if args.flyTest {
            let compensateBeaming = args2ExpComp
            try FileManager.default.createDirectory(atPath: args.out,
                                                    withIntermediateDirectories: true)
            // let the encounter develop so there is structure to fly through
            host.advance(steps: Int(420 / host.sim.params.dt))

            let flight = FlightCamera()
            let e = host.sim.sampleExtent()
            flight.position = e.center + SIMD3<Float>(0, e.radius * 0.20, e.radius * 1.9)
            flight.yaw = 0            // yaw 0 looks toward -Z, i.e. back at the galaxies
            flight.pitch = -0.10
            flight.travelDirection = flight.viewDirection

            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: args.width, height: args.height,
                mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            let tex = host.ctx.device.makeTexture(descriptor: desc)!
            let aspect = Float(args.width) / Float(args.height)

            let baseExposure = host.renderer.settings.exposure
            for beta in [Float(0.0), 0.5, 0.9, 0.99] {
                flight.beta = beta
                // Forward beaming brightens the view by D^2, which saturates
                // the plate and hides the colour. Compensate so the images are
                // comparable in brightness and the Doppler HUE is measurable.
                // (Set expcomp=0 in --look to see the real beaming instead.)
                if compensateBeaming {
                    let dFwd = ((1 + beta) / max(1 - beta, 1e-6)).squareRoot()
                    host.renderer.settings.exposure = baseExposure / (dFwd * dFwd)
                }
                guard let cb = host.ctx.queue.makeCommandBuffer() else { continue }
                host.renderer.render(into: tex, commandBuffer: cb,
                                     simulation: host.sim, camera: host.camera,
                                     viewOverride: (flight.viewProjection(aspect: aspect),
                                                    flight.position),
                                     relativity: flight.uniforms())
                cb.commit(); cb.waitUntilCompleted()

                let path = "\(args.out)/beta_\(Int(beta * 100)).png"
                try host.saveTexture(tex, to: path)
                print(String(format: "  beta=%.2f  %@", beta, flight.timeDilationDisplay))
            }
            exit(0)
        }

        if args.sensorTest {
            // Three isolated, heavily over-exposed stars of known colour.
            // The question this answers: does an over-exposed core render
            // white while its halo keeps the star's real colour?
            host.sim.isPaused = true
            let colours: [SIMD3<Float>] = [
                SIMD3(0.55, 0.72, 1.00),   // hot blue O star
                SIMD3(1.00, 0.92, 0.72),   // yellow G star
                SIMD3(1.00, 0.50, 0.28),   // red M star
            ]
            let xs: [Float] = [-34, 0, 34]
            let buf = host.sim.particleBuffer!
            let pp = buf.contents().bindMemory(to: GPUParticle.self,
                                               capacity: host.sim.particleCount)
            for i in 0..<host.sim.particleCount {
                if i < 3 {
                    pp[i].position = SIMD4(xs[i], 0, 0, 0)
                    pp[i].velocity = .zero
                    pp[i].color = SIMD4(colours[i], 55.0)
                } else {
                    // park the rest far behind the camera
                    pp[i].position = SIMD4(0, 0, 1e6, 0)
                    pp[i].color = .zero
                }
            }
            host.renderer.settings.showBackgroundStars = false
            // N is still the full particle count, so undo the 1/N normalisation
            // and aim the three stars at ~300x the mid-grey exposure
            host.renderer.settings.brightness =
                300.0 / (300_000.0 / Float(host.sim.particleCount))
            host.camera.autoFrame = false
            host.camera.autoOrbit = false
            host.camera.target = .zero
            host.camera.distance = 150
            host.camera.elevation = 0
            host.camera.azimuth = 0
            for _ in 0..<200 { host.camera.update(dt: 1.0 / 60.0) }
            try host.capture(width: 1200, height: 500, to: "/tmp/sensortest.png")
            print("wrote /tmp/sensortest.png")
            exit(0)
        }

        if args.renderBench {
            let w = args.width, h = args.height
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            let tex = host.ctx.device.makeTexture(descriptor: desc)!
            for t in args.shots {
                let need = Int(max(0, (t - host.sim.currentTime) / host.sim.params.dt))
                host.advance(steps: need)
                host.reframe(immediate: true)
                // warm up
                for _ in 0..<5 {
                    let cb = host.ctx.queue.makeCommandBuffer()!
                    host.renderer.render(into: tex, commandBuffer: cb,
                                         simulation: host.sim, camera: host.camera)
                    cb.commit(); cb.waitUntilCompleted()
                }
                let t0 = CFAbsoluteTimeGetCurrent()
                let frames = 30
                for _ in 0..<frames {
                    let cb = host.ctx.queue.makeCommandBuffer()!
                    host.renderer.render(into: tex, commandBuffer: cb,
                                         simulation: host.sim, camera: host.camera)
                    cb.commit(); cb.waitUntilCompleted()
                }
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(frames)
                print(String(format: "t=%5.0f Myr  render %6.2f ms  (%.0f fps render-only)  camDist=%.0f kpc",
                             t, ms, 1000/max(ms,1e-6), Double(host.camera.renderedDistance)))
            }
            exit(0)
        }

        if args.gallery {
            try FileManager.default.createDirectory(atPath: args.out,
                                                    withIntermediateDirectories: true)
            for (i, type) in GalaxyType.allCases.enumerated() {
                host.customSpecs.removeAll()
                host.addGalaxy(type: type, massScale: 1.0, tiltDegrees: 28,
                               at: .zero)
                host.sim.isPaused = false
                host.advance(steps: 120)          // let it settle 60 Myr
                let path = "\(args.out)/type_\(String(format: "%02d", i))_\(type.rawValue).png"
                try host.capture(width: 640, height: 520, to: path)
                print("  \(type.displayName) -> \(path)")
            }
            exit(0)
        }

        if args.camTest {
            // Replay the exact GUI loop headlessly and measure how smoothly
            // the auto-framed camera dollies.
            var dists: [Double] = []
            for frame in 0..<1200 {
                host.advance(steps: 2)
                if frame % 4 == 0 { host.reframe() }
                host.camera.update(dt: 1.0 / 60.0)
                dists.append(Double(host.camera.renderedDistance))
            }
            var maxStep = 0.0, sumSq = 0.0
            var jerkMax = 0.0
            for i in 1..<dists.count {
                let rel = abs(dists[i] - dists[i-1]) / max(dists[i], 1e-6)
                maxStep = max(maxStep, rel)
                sumSq += rel * rel
                if i >= 2 {
                    let d2 = abs(dists[i] - 2*dists[i-1] + dists[i-2]) / max(dists[i], 1e-6)
                    jerkMax = max(jerkMax, d2)
                }
            }
            let rms = (sumSq / Double(dists.count - 1)).squareRoot()
            var mtot: Float = 0
            var com = SIMD3<Float>.zero
            for c in host.sim.cores { com += c.position * c.mass; mtot += c.mass }
            if mtot > 0 { com /= mtot }
            print(String(format: "centre-of-mass drift after %.0f Myr: %.3f kpc",
                         host.sim.currentTime, simd_length(com)))
            print(String(format: "camera dolly over %d frames:", dists.count))
            print(String(format: "  distance %.1f -> %.1f kpc", dists.first ?? 0, dists.last ?? 0))
            print(String(format: "  per-frame change: rms %.4f%%  max %.4f%%", rms*100, maxStep*100))
            print(String(format: "  max 2nd difference (jitter): %.5f%%", jerkMax*100))
            exit(0)
        }

        if args.buildTest {
            // Place into a RUNNING preset, which is what used to wipe it.
            print("preset loaded : \(host.sim.cores.count) galaxies, "
                + "\(host.sim.particleCount) particles")
            host.sim.isPaused = false
            host.advance(steps: 400)
            let beforeN = host.sim.particleCount
            let beforeG = host.sim.cores.count
            print("after 200 Myr : \(beforeG) galaxies, \(beforeN) particles")

            host.addGalaxy(type: .sc,  massScale: 1.0, tiltDegrees: 20,
                           at: SIMD3(-70, 0, 0))
            host.addGalaxy(type: .sbb, massScale: 0.8, tiltDegrees: 55,
                           at: SIMD3(70, 0, 30))
            print("after placing : \(host.sim.cores.count) galaxies, "
                + "\(host.sim.particleCount) particles")
            print(host.sim.cores.count == beforeG + 2 && host.sim.particleCount > beforeN
                  ? "PASS: preset survived, both galaxies added"
                  : "FAIL: scene was wiped")
            host.advance(steps: 60)
            try host.capture(width: 1300, height: 820, to: "/tmp/placelive.png")
            print("render -> /tmp/placelive.png")
            exit(0)
            print("placed:\n\(host.customDescription)")
            let before = simd_length(host.sim.cores[0].position - host.sim.cores[1].position)
            host.autoOrbitCustom()
            print(String(format: "separation at placement: %.1f kpc", before))
            print(String(format: "assigned relative speed: %.0f km/s",
                         Units.kms(simd_length(host.sim.cores[0].velocity
                                               - host.sim.cores[1].velocity))))
            host.sim.isPaused = false
            var minSep = Float.greatestFiniteMagnitude
            var tMin: Float = 0
            for _ in 0..<160 {
                host.advance(steps: 10)
                let sep = simd_length(host.sim.cores[0].position - host.sim.cores[1].position)
                if sep < minSep { minSep = sep; tMin = host.sim.currentTime }
            }
            print(String(format: "pericentre reached: %.1f kpc at t=%.0f Myr", minSep, tMin))
            print(String(format: "final separation: %.1f kpc at t=%.0f Myr",
                         simd_length(host.sim.cores[0].position - host.sim.cores[1].position),
                         host.sim.currentTime))
            print(host.sim.starburstReport())

            try host.capture(width: 1400, height: 850, to: "/tmp/buildtest.png")
            print("render -> /tmp/buildtest.png")
            exit(0)
        }

        if args.info {
            host.diagnose(until: args.shots.last ?? 900)
            exit(0)
        }

        if args.bench {
            // warm up, then measure steady-state step cost
            host.advance(steps: 10)
            host.advance(steps: 120, measure: true)
            let ms = host.stepMillis
            print(String(format: "step time  : %.3f ms  (%.0f steps/s)", ms, 1000 / max(ms, 1e-6)))
            print(String(format: "at 2 steps/frame -> %.0f fps physics-limited", 1000 / max(ms * 2, 1e-6)))
        } else {
            let dt = host.sim.params.dt
            for (i, target) in args.shots.enumerated() {
                let need = Int(max(0, (target - host.sim.currentTime) / dt))
                host.advance(steps: need, measure: true)
                let path = "\(args.out)/shot_\(String(format: "%02d", i))_t\(Int(target)).png"
                try host.capture(width: args.width, height: args.height, to: path)
                print("  \(path)   \(host.statistics())")
                print("      \(host.renderer.hdrLuminanceReport())")
                print("      \(host.sim.starburstReport())")
            }
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate(budget: args.budget)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
