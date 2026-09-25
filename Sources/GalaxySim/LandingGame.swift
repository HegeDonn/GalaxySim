import AppKit
import simd
import AVFoundation

/// All geometry is in the same galaxy frame as the final sky renderer.
struct LandingNavigation {
    let planet: LandingSite
    let heart: SIMD3<Float>
    let right: SIMD3<Float>
    let facing: SIMD3<Float>
    private(set) var normal = SIMD3<Float>(0, 0, 1)
    private(set) var heading = SIMD3<Float>(0, 1, 0)
    private(set) var speed: Float = 0
    var screenRight: SIMD3<Float> { simd_normalize(simd_cross(heading, normal)) }

    init(planet: LandingSite, heart: SIMD3<Float>) {
        self.planet = planet
        self.heart = simd_normalize(heart)
        let night = -planet.sun + self.heart * simd_dot(planet.sun, self.heart)
        facing = simd_length_squared(night) > 0.00001 ? simd_normalize(night) : planet.east
        right = simd_normalize(simd_cross(self.heart, facing))
        move(to: SIMD2(0, 0.24))
    }
    /// Retained for choosing the initial photographic skyline and diagnostics.
    mutating func move(to p: SIMD2<Float>) {
        let length = simd_length(p)
        let point = length > 0.96 ? p * (0.96 / length) : p
        let z = sqrt(max(0, 1 - simd_length_squared(point)))
        normal = simd_normalize(right * point.x + heart * point.y + facing * z)
        heading = simd_normalize(heart - normal * simd_dot(heart, normal))
        halt()
    }
    mutating func resume(at site: LandingSite) { normal = site.zenith; heading = site.north; halt() }
    private var drift = SIMD2<Float>.zero
    mutating func halt() { speed = 0; drift = .zero }
    mutating func rotate(_ radians: Float) {
        heading = simd_normalize(heading * cos(radians) + screenRight * sin(radians))
    }
    mutating func drive(dt: Float, input: SIMD2<Float>, brake: Bool) {
        let target = input * 0.32
        drift += (target - drift) * (1 - exp(-dt * (brake ? 24 : 12)))
        if simd_length(drift) < 0.001 { drift = .zero }
        speed = simd_length(drift)
        guard speed > 0 else { return }
        let tangent = (screenRight * drift.x + heading * drift.y) / speed
        let axis = simd_normalize(simd_cross(normal, tangent))
        let angle = speed * dt
        func transport(_ v: SIMD3<Float>) -> SIMD3<Float> {
            v * cos(angle) + simd_cross(axis, v) * sin(angle) + axis * simd_dot(axis, v) * (1 - cos(angle))
        }
        normal = simd_normalize(transport(normal))
        heading = simd_normalize(transport(heading))
    }
    var site: LandingSite { planet.relocated(to: normal) }
    var aim: (yaw: Float, pitch: Float) {
        (site.aim(at: heart).yaw, 0.18)
    }
}

/// A deliberately toy-sized planet and ship. The sky inset shares the chosen
/// location and camera direction with the real observatory, not a random vista.
final class LandingGameView: NSView {
    func restNavigation() { globeView.isHidden = true; stick.alphaValue = 0.35 }
    var isResting: Bool { globeView.isHidden }
    private func usedNavigation() {
        lastInteraction = CACurrentMediaTime()
        globeView.isHidden = false; stick.alphaValue = 1
    }
    var embedded = false
    var reviewKeepsAwake = false
    var onNavigate: ((LandingSite, SIMD3<Float>) -> Void)?
    var onIdle: (() -> Void)?
    private var lastInteraction = CACurrentMediaTime()
    private var reportedNormal = SIMD3<Float>.zero
    private var reportedHeading = SIMD3<Float>.zero
    func resume(at site: LandingSite) {
        navigation.resume(at: site)
        reportedNormal = navigation.normal; reportedHeading = navigation.heading
    }
    var onLand: ((LandingSite) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var navigation: LandingNavigation
    private let stars: [ObservatoryStar]
    private let fieldOfView: Float
    private var atmosphereName: String
    private var tuningPanel: PlanetTuningPanel?
    private let originalAtmosphere: String
    private let globeView: PlanetGlobeView
    private let stick = ShipStick()
    private let sounds = LandingSounds()
    private var keys = Set<UInt16>()
    private var lastTick = CACurrentMediaTime()
    private var focusObserver: NSObjectProtocol?
    private let land = PillButton(title: "Land", symbol: "arrow.down.to.line")
    private let back = PillButton(title: "Back", symbol: "chevron.left")
    private var timer: Timer?
    private var descent: Double?
    private var phase: CGFloat = 0
    private var clock: CGFloat = 0
    override var acceptsFirstResponder: Bool { true }

    init(site: LandingSite, heart: SIMD3<Float>, stars: [ObservatoryStar], fieldOfView: Float, atmosphere: Atmosphere, seed: UInt32) {
        originalAtmosphere = atmosphere.name
        globeView = PlanetGlobeView(seed: seed, atmosphere: atmosphere.name, axis: site.axis)
        navigation = LandingNavigation(planet: site, heart: heart)
        self.fieldOfView = fieldOfView
        atmosphereName = atmosphere.name
        let stride = max(1, stars.count / 4500)
        self.stars = Swift.stride(from: 0, to: stars.count, by: stride).map { stars[$0] }
        super.init(frame: .zero)
        reportedNormal = navigation.normal; reportedHeading = navigation.heading
        wantsLayer = true
        addSubview(globeView)
        land.isProminent = true
        land.onTap = { [weak self] in self?.beginLanding() }
        back.iconOnlyOverLength = 0
        back.onTap = { [weak self] in self?.onCancel?() }
        back.toolTip = "Go back without moving"
        addSubview(land); addSubview(back)
        stick.setAccessibilityLabel("Fly over the planet; turn the ring to rotate")
        stick.toolTip = "Push to move. Release to stop. Turn the ring to rotate."
        stick.onRoll = { [weak self] angle in
            guard let self, self.descent == nil else { return }
            self.usedNavigation()
            self.navigation.rotate(-angle)
        }
        addSubview(stick)
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.releaseControls()
        }
        setAccessibilityLabel("Push the pad to move. Release to stop. Turn its ring to rotate. Arrow keys or W A S D move; Q and R rotate; E opens the planet workshop. Enter lands.")
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
    private func releaseControls() {
        keys.removeAll()
        stick.release()
        navigation.halt()
        sounds.movement(0)
    }
    func stop() { tuningPanel?.orderOut(nil); timer?.invalidate(); timer = nil; releaseControls() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, max(0, now - lastTick)))
        lastTick = now
        clock += CGFloat(dt)
        if !keys.isEmpty || simd_length(stick.vector) > 0 || tuningPanel?.isVisible == true { usedNavigation() }
        if isHidden { releaseControls(); return }
        if descent == nil {
            var input = stick.vector
            input.x += (keys.contains(124) || keys.contains(2) ? 1 : 0) - (keys.contains(123) || keys.contains(0) ? 1 : 0)
            input.y += (keys.contains(126) || keys.contains(13) ? 1 : 0) - (keys.contains(125) || keys.contains(1) ? 1 : 0)
            if simd_length(input) > 1 { input = simd_normalize(input) }
            navigation.rotate(((keys.contains(15) ? Float(1) : 0) - (keys.contains(12) ? Float(1) : 0)) * dt * 1.5)
            navigation.drive(dt: dt, input: keys.contains(49) ? .zero : input, brake: keys.contains(49))
            sounds.movement(navigation.speed / 0.32)
        }
        if let descent {
            phase = min(1, (CACurrentMediaTime() - descent) / 1.25)
            if phase >= 1 {
                stop()
                onLand?(navigation.site)
                return
            }
        }
        if embedded {
            if simd_distance(reportedNormal, navigation.normal) > 0.00001 || simd_distance(reportedHeading, navigation.heading) > 0.00001 {
                reportedNormal = navigation.normal; reportedHeading = navigation.heading
                usedNavigation()
                onNavigate?(navigation.site, navigation.heading)
            } else if now - lastInteraction > 6 && tuningPanel?.isVisible != true && !reviewKeepsAwake {
                onIdle?()
            }
        }
        updateGlobe()
        needsDisplay = true
    }
    private func updateGlobe() {
        let swell = phase * phase * 0.12
        let disk = globe.insetBy(dx: -globe.width*swell, dy: -globe.height*swell)
        globeView.frame = disk.insetBy(dx: -disk.width*0.035, dy: -disk.height*0.035)
        globeView.update(normal: navigation.normal, up: navigation.heading, right: navigation.screenRight,
                         speed: navigation.speed, descent: Float(phase))
    }
    func beginLanding() {
        if embedded { onCancel?(); return }
        guard descent == nil else { return }
        releaseControls()
        tuningPanel?.orderOut(nil)
        atmosphereName=originalAtmosphere;globeView.setAtmosphere(originalAtmosphere)
        stick.isHidden = true
        sounds.land()
        descent = CACurrentMediaTime()
        land.isEnabled = false
        back.isEnabled = false
        land.title = "Landing…"
    }
    private var globe: NSRect {
        if embedded { return NSRect(x: (bounds.width-150)/2, y: 130, width: 150, height: 150) }
        let d = min(bounds.width * 0.43, bounds.height * 0.62)
        return NSRect(x: bounds.width * 0.255 - d / 2, y: bounds.height * 0.49 - d / 2, width: d, height: d)
    }
    private var preview: NSRect {
        let w = bounds.width * 0.43
        return NSRect(x: bounds.width * 0.535, y: bounds.height * 0.49 - w * bounds.height / bounds.width / 2,
                      width: w, height: w * bounds.height / bounds.width)
    }
    override func layout() {
        super.layout()
        updateGlobe()
        if embedded {
            land.isHidden = true; back.isHidden = true
            stick.frame = NSRect(x: (bounds.width-120)/2, y: 4, width: 120, height: 120)
            return
        }
        land.frame = NSRect(x: preview.minX + 12, y: max(28, preview.minY - 100), width: 148, height: 52)
        back.frame = NSRect(x: 24, y: bounds.height - 76, width: 48, height: 48)
        stick.frame = NSRect(x: preview.maxX - 158, y: max(12, preview.minY - 190), width: 152, height: 152)
    }
    // The globe is display-only. All pointer navigation belongs to the pad.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    func reviewFlightControls() -> Bool {
        let original = navigation
        stick.holdForReview(SIMD2(0.5, 0.7))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        let moved = navigation.speed > 0 && simd_distance(original.normal, navigation.normal) > 0.001
        stick.release()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        let stopped = navigation.speed < 0.001
        let heading = navigation.heading
        stick.rollForReview(0.5)
        let turned = simd_distance(heading, navigation.heading) > 0.1
        keys.insert(124)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        let keyed = navigation.speed > 0.01
        releaseControls()
        let released = stick.vector == .zero && keys.isEmpty && navigation.speed == 0
        navigation = original
        return moved && stopped && turned && keyed && released
    }
    func reviewWaitForSurface() -> Bool {
        let deadline = Date(timeIntervalSinceNow: 15)
        while !globeView.hasFrame && globeView.errorMessage == nil && Date() < deadline {
            updateGlobe()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        print("Planet first GPU frame: \(globeView.firstFrameMilliseconds) ms")
        print("Planet GPU: \(globeView.gpuMilliseconds) ms, \(globeView.completedFrames) completed frames")
        return globeView.hasFrame && globeView.errorMessage == nil
    }
    func reviewAtmosphere(_ atmosphere: Atmosphere) {
        atmosphereName = atmosphere.name
        globeView.setAtmosphere(atmosphere.name)
        updateGlobe()
        needsDisplay = true
    }
    func reviewCloudTime(_ time: Float?) { globeView.reviewTime = time; updateGlobe() }
    func reviewTurn(_ angle: Float) { navigation.rotate(angle); onNavigate?(navigation.site, navigation.heading) }
    func reviewMove(to p: SIMD2<Float>) { navigation.move(to: p); onNavigate?(navigation.site, navigation.heading); needsDisplay = true }
    var reviewControlsFit: Bool {
        if embedded { return bounds.contains(stick.frame) && bounds.contains(globe) && !stick.frame.intersects(globe) }
        return [land, back, stick].allSatisfy { bounds.contains($0.frame) }
            && !globe.intersects(preview)
    }
    func reviewTuning() -> Bool { toggleTuning(); return tuningPanel?.reviewControlsFit == true }
    func reviewCloseTuning() { usedNavigation(); tuningPanel?.orderOut(nil); window?.makeKey(); window?.makeFirstResponder(self) }
    private func toggleTuning() {
        if tuningPanel?.isVisible == true { tuningPanel?.orderOut(nil); window?.makeFirstResponder(self); return }
        releaseControls()
        if tuningPanel == nil {
            let type=Atmosphere.all.firstIndex { $0.name == atmosphereName } ?? 0
            let panel=PlanetTuningPanel(tuning:globeView.tuning,type:type)
            panel.onChange = { [weak self] value in self?.globeView.tuning=value }
            panel.onType = { [weak self] index in self?.reviewAtmosphere(Atmosphere.all[index]) }
            tuningPanel=panel
        }
        if let window, let panel=tuningPanel { window.addChildWindow(panel,ordered:.above);panel.setFrameOrigin(NSPoint(x:window.frame.maxX-panel.frame.width-18,y:window.frame.midY-panel.frame.height/2)) }
        tuningPanel?.makeKeyAndOrderFront(nil)
    }
    override func keyDown(with event: NSEvent) {
        usedNavigation()
        guard descent == nil else { return }
        if event.keyCode == 14 { toggleTuning() }
        else if event.keyCode == 36 { beginLanding() }
        else if event.keyCode == 53 { onCancel?() }
        else { keys.insert(event.keyCode) }
    }
    override func keyUp(with event: NSEvent) { keys.remove(event.keyCode) }
    private func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat = 16, color: NSColor = .white) {
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: KidsStyle.font(size), .foregroundColor: color])
    }
    override func draw(_ dirtyRect: NSRect) {
        if embedded { return }
        NSColor(srgbRed: 0.018, green: 0.032, blue: 0.065, alpha: 1).setFill(); bounds.fill()
        for i in 0..<110 {
            let x = CGFloat((i * 197 + 31) % 997) / 997 * bounds.width
            let y = CGFloat((i * 389 + 71) % 991) / 991 * bounds.height
            NSColor.white.withAlphaComponent(0.15 + Double(i % 4) * 0.08).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
        }
        text("Find your favourite skyline", x: 94, y: bounds.height - 64, size: 25)
        text("Push the pad · let go to stop", x: globe.minX, y: globe.maxY + 24, size: 16)
        text(atmosphereName, x: globe.minX, y: globe.minY - 32, size: 13, color: .lightGray)
        drawPreview()
        text(descent == nil ? "Your view from here" : "Coming in to land…", x: preview.minX, y: preview.maxY + 18, size: 20)
        let altitude = navigation.site.altitude(of: navigation.heart)
        let caption = navigation.site.altitude(of: navigation.site.sun) > 0 ? "Daylight here — the stars may be faint" :
            altitude < 0 ? "Galaxy below the horizon — keep exploring" : altitude > 0.7 ? "High overhead — fly a little further" : "A galaxy above your horizon"
        text(caption, x: preview.minX, y: preview.minY - 30, size: 13, color: KidsStyle.accentOnNight)
    }
    private func drawPreview() {
        let rect = preview
        let site = navigation.site, aim = navigation.aim
        let forward = site.east * (sin(aim.yaw) * cos(aim.pitch)) + site.zenith * sin(aim.pitch) + site.north * (cos(aim.yaw) * cos(aim.pitch))
        let right = simd_normalize(simd_cross(forward, site.zenith))
        let up = simd_normalize(simd_cross(right, forward))
        NSGraphicsContext.saveGraphicsState()
        let frame = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        frame.addClip()
        NSColor(srgbRed: 0.025, green: 0.05, blue: 0.10, alpha: 1).setFill(); rect.fill()
        for star in stars {
            let d = simd_normalize(star.direction)
            let z = simd_dot(d, forward)
            if z <= 0 || site.altitude(of: d) < 0 { continue }
            let x = CGFloat(simd_dot(d, right) / (z * fieldOfView)) * rect.height / 2 + rect.midX
            let y = CGFloat(simd_dot(d, up) / (z * fieldOfView)) * rect.height / 2 + rect.midY
            guard rect.contains(NSPoint(x: x, y: y)) else { continue }
            let r = CGFloat(min(2.4, max(0.65, log2(1 + star.brightness) * 0.18)))
            NSColor(srgbRed: CGFloat(star.color.x), green: CGFloat(star.color.y), blue: CGFloat(star.color.z), alpha: 0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
        }
        let horizon = rect.midY - CGFloat(tan(aim.pitch) / fieldOfView) * rect.height / 2
        NSColor(srgbRed: 0.055, green: 0.12, blue: 0.13, alpha: 1).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, horizon - rect.minY)).fill()
        NSColor.cyan.withAlphaComponent(0.5).setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: rect.minX, y: horizon)); line.line(to: NSPoint(x: rect.maxX, y: horizon)); line.stroke()
        NSGraphicsContext.restoreGraphicsState()
        KidsStyle.accentOnNight.withAlphaComponent(0.4).setStroke(); frame.lineWidth = 1; frame.stroke()
    }
}

/// Quiet, locally synthesized cues; no downloaded audio or continuous loud bed.
private final class LandingSounds {
    private var motor: AVAudioPlayer?
    private var touchdown: AVAudioPlayer?
    private var lastLevel: Float = 0
    private func player(landing: Bool) -> AVAudioPlayer? {
        let rate = 22050, count = landing ? 22050 : 11025
        var data = Data()
        func word(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of:&n) { data.append(contentsOf:$0) } }
        func long(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of:&n) { data.append(contentsOf:$0) } }
        data.append(contentsOf:"RIFF".utf8);long(UInt32(36+count*2));data.append(contentsOf:"WAVEfmt ".utf8)
        long(16);word(1);word(1);long(UInt32(rate));long(UInt32(rate*2));word(2);word(16)
        data.append(contentsOf:"data".utf8);long(UInt32(count*2))
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i)/Double(rate)
            let frequency = landing ? (t < 0.55 ? 420-260*t : 523.25) : 88.0
            phase += 2 * Double.pi * frequency / Double(rate)
            let envelope = landing ? min(1,t*25)*pow(max(0,1-t),1.5) : 1
            let sample = (sin(phase)*0.7+sin(phase*2)*0.2+sin(phase*4)*0.1)*envelope*0.25
            word(UInt16(bitPattern:Int16(sample*32767)))
        }
        return try? AVAudioPlayer(data:data)
    }
    func movement(_ level: Float) {
        guard level > 0.02 else { motor?.pause();lastLevel=0;return }
        if motor == nil { motor=player(landing:false);motor?.numberOfLoops = -1 }
        motor?.volume=min(0.12,level*0.10)
        if lastLevel == 0 { motor?.play() }
        lastLevel=level
    }
    func land() { motor?.stop();touchdown=player(landing:true);touchdown?.volume=0.18;touchdown?.play() }
}
