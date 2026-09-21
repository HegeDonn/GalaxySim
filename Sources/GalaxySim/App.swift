import AppKit
import MetalKit
import simd

// MARK: - Metal view with input handling

final class GalaxyView: MTKView {
    var onDrag: ((Float, Float) -> Void)?
    var onRotationDrag: ((Float, Float) -> Bool)?
    private var rotatedGesture = false
    var onScroll: ((Float) -> Void)?
    var onKey: ((String) -> Void)?
    var onKeyUp: ((String) -> Void)?
    var onFocusLost: (() -> Void)?
    /// Fires on a click that wasn't a camera drag, in view coordinates.
    var onClick: ((NSPoint) -> Void)?
    /// Cursor position in view coordinates, or nil when it leaves.
    var onHover: ((NSPoint?) -> Void)?

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited,
                                         .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    private var dragDistance: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragDistance = 0
        rotatedGesture = false
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func resignFirstResponder() -> Bool {
        onFocusLost?()
        return super.resignFirstResponder()
    }

    override func mouseUp(with event: NSEvent) {
        // Distinguish a click from an orbit drag so placing a galaxy and
        // turning the camera can share the left button.
        guard dragDistance < 4, !rotatedGesture else { return }
        onClick?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        dragDistance += abs(event.deltaX) + abs(event.deltaY)
        if event.modifierFlags.contains(.shift),
           onRotationDrag?(Float(event.deltaX), Float(event.deltaY)) == true {
            rotatedGesture = true
            return
        }
        onDrag?(Float(event.deltaX), Float(event.deltaY))
    }
    override func scrollWheel(with event: NSEvent) {
        onScroll?(Float(event.scrollingDeltaY))
    }
    override func magnify(with event: NSEvent) {
        onScroll?(Float(event.magnification) * 40)
    }
    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        onKey?(event.charactersIgnoringModifiers?.lowercased() ?? "")
    }
    override func keyUp(with event: NSEvent) {
        onKeyUp?(event.charactersIgnoringModifiers?.lowercased() ?? "")
    }
}

// MARK: - Main view controller

final class MainViewController: NSViewController, MTKViewDelegate {
    /// Which control surface is showing. Kids mode is the default: big
    /// targets, few choices, focused on playing. The engineer panel is one
    /// hamburger tap away.
    private enum UIMode { case kids, engineer }
    /// GALAXYSIM_ENGINEER=1 opens straight into the engineer panel. Only for
    /// screenshots and debugging; the app normally starts in kids mode.
    private var uiMode: UIMode =
        ProcessInfo.processInfo.environment["GALAXYSIM_ENGINEER"] != nil ? .engineer : .kids

    /// Galactic travel and the local ship inspection camera are independent.
    private var flight = FlightCamera()
    private var chase = ChaseCamera()
    private var flightPaused = false
    private var isFlying = false
    private var hud: FlightHUD!
    private var starPicker: StarPicker!
    private var starInspector: StarInspectorView!
    private var selectedStar: Int?
    private var selectedGeneration: UInt64 = 0
    private var stellarProfile: StellarProfile?
    private var planetObservatory: PlanetObservatoryView?
    private var pausedBeforePlanet = false
    private var settings = Settings.load()
    /// Keys currently held, for continuous flight controls.
    private var heldKeys = Set<String>()
    /// Tilt for the next placed galaxy, from the hotbar's arrows.
    private var placementTilt: Float { kidsPanel?.selectedTilt ?? 25 }
    /// Last cursor position on the orbital plane, for the guide ring.
    private var cursorGround: SIMD3<Float>?
    /// Eased 0...1 so the guide fades rather than snaps.
    private var gridFade: Float = 0

    private var host: SimHost!
    private var panel: ControlPanel!
    private var kidsPanel: KidsPanel!
    private var panelWidth: NSLayoutConstraint!
    private var kidsWidth: NSLayoutConstraint!
    private var metalView: GalaxyView!
    private var audio: AmbientAudio?

    private var lastFrame = CFAbsoluteTimeGetCurrent()
    private var stepAccumulator: Float = 0
    private var physicsStepMilliseconds: Double = 0
    private var measuredPhysicsCount = 0
    private var speed: Float = 1
    private var reframeCounter = 0

    private var frameTimes: [Double] = []
    private let inFlight = DispatchSemaphore(value: 1)

    private let startBudget: Int

    init(budget: Int) {
        self.startBudget = budget
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 980))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            host = try SimHost(budget: startBudget)
            starPicker = try StarPicker(ctx: host.ctx)
        } catch {
            presentFatal(error)
            return
        }

        metalView = GalaxyView(frame: view.bounds, device: host.ctx.device)
        metalView.colorPixelFormat = .bgra8Unorm
        // We render into the drawable with our own pass and never read it
        // back, so it can stay framebuffer-only.
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.delegate = self
        metalView.autoresizingMask = [.width, .height]
        metalView.onDrag = { [weak self] dx, dy in
            guard let self else { return }
            if self.isFlying {
                self.chase.orbit(dx: dx, dy: dy)
            } else {
                self.host.camera.autoOrbit = false
                self.host.camera.drag(dx: dx, dy: dy)
            }
        }
        metalView.onRotationDrag = { [weak self] dx, dy in
            guard let self, !self.isFlying, self.uiMode == .kids, self.kidsPanel.placeMode else { return false }
            self.kidsPanel.rotatePlacement(dx: dx, dy: dy)
            return true
        }
        metalView.onScroll = { [weak self] d in
            guard let self else { return }
            if self.isFlying {
                self.chase.zoom(d)
            } else {
                self.host.camera.zoom(d)
            }
        }
        metalView.onHover = { [weak self] p in
            guard let self else { return }
            guard self.uiMode == .kids, self.kidsPanel.placeMode, !self.isFlying,
                  let p, let hit = self.groundPoint(p) else {
                self.host.clearPreview()
                self.cursorGround = nil
                return
            }
            self.cursorGround = hit
            self.host.updatePreview(type: self.kidsPanel.selectedType,
                                    tiltDegrees: self.placementTilt,
                                    rollDegrees: self.kidsPanel.selectedRoll, at: hit)
        }
        metalView.onClick = { [weak self] p in
            guard let self else { return }
            if self.isFlying || !self.activePlaceMode {
                self.pickStar(at: p)
                return
            }
            self.clearStarSelection()
            guard let hit = self.groundPoint(p) else { return }
            let mass = self.uiMode == .kids ? 1.0 : self.panel.selectedMass
            let tilt: Float = self.uiMode == .kids ? self.placementTilt
                                                    : Float(self.panel.selectedTilt)
            self.host.addGalaxy(type: self.activeType,
                                massScale: Float(mass),
                                tiltDegrees: tilt,
                                rollDegrees: self.uiMode == .kids ? self.kidsPanel.selectedRoll : nil, at: hit)
            self.panel.updateBuilt(self.host.customDescription)
            self.kidsPanel.updateStatus("\(self.host.customSpecs.count) created — press Play")
            self.activeSetPlaying(false)
        }
        metalView.onKey = { [weak self] k in
            self?.heldKeys.insert(k)
            self?.handleKey(k)
        }
        metalView.onKeyUp = { [weak self] k in self?.heldKeys.remove(k) }
        metalView.onFocusLost = { [weak self] in self?.clearHeldKeys() }
        view.addSubview(metalView)

        panel = ControlPanel(sceneNames: host.scenes.map(\.name), initialBudget: startBudget)
        view.addSubview(panel)
        panelWidth = panel.widthAnchor.constraint(equalToConstant: 242)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panelWidth,
        ])
        wirePanel()

        kidsPanel = KidsPanel(sceneNames: host.scenes.map(\.name))
        kidsPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(kidsPanel)
        // Full-bleed transparent overlay, not a sidebar: its controls sit at
        // the edges and the middle of the screen stays clear.
        kidsWidth = kidsPanel.widthAnchor.constraint(equalToConstant: 0)
        kidsWidth.isActive = false
        NSLayoutConstraint.activate([
            kidsPanel.topAnchor.constraint(equalTo: metalView.topAnchor),
            kidsPanel.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            kidsPanel.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            kidsPanel.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
        ])
        hud = FlightHUD()
        hud.onExit = { [weak self] in self?.setFlight(false) }
        hud.onPause = { [weak self] in
            guard let self else { return }
            self.flightPaused.toggle()
            self.hud.update(flight: self.flight, paused: self.flightPaused)
            self.focusFlight()
        }
        hud.onRecenter = { [weak self] in self?.chase.recenter(); self?.focusFlight() }
        // Roll is a 1:1 drag on the stick's ring, so it lands here directly
        // rather than being integrated per frame like the held steering.
        hud.onRoll = { [weak self] radians in
            guard let self else { return }
            self.flight.roll(radians)
            self.focusFlight()
        }
        hud.onSpeed = { [weak self] beta in
            guard let self else { return }
            self.flight.beta = beta
            self.hud.update(flight: self.flight, paused: self.flightPaused)
            self.focusFlight()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(clearHeldKeys),
            name: NSWindow.didResignKeyNotification, object: nil)
        hud.isHidden = true
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: metalView.topAnchor),
            hud.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            hud.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
        ])

        // The hotbar floats over the render view pinned to the bottom of the
        // window, not inside the sidebar, so it reads as a game hotbar rather
        // than another panel row.
        let bar = kidsPanel.bottomBar
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: metalView.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),
        ])

        starInspector = StarInspectorView(frame: .zero)
        starInspector.isHidden = true
        starInspector.setAnimating(false)
        starInspector.onClose = { [weak self] in self?.clearStarSelection() }
        starInspector.onVisitPlanet = { [weak self] in self?.visitSelectedPlanet() }
        view.addSubview(starInspector)
        layoutStarInspector()

        kidsPanel.alignStatusWithHotbar()
        wireKidsPanel()
        applyUIMode()

        // Kids mode opens paused on the starting configuration, so the first
        // thing you see is two intact galaxies and a play button — not a
        // merger that already happened while you were reading the screen.
        kidsPanel.setPlaying(false)
        kidsPanel.updateStatus("Pick a crash and press play — or click a star to explore.")

        applyLoadedSettings()

        audio = AmbientAudio()
        audio?.volume = settings.masterVolume
        audio?.isEnabled = settings.audioEnabled
        for t in AmbientAudio.Track.allCases {
            audio?.setVolume(settings.trackVolumes[t.rawValue] ?? 1, for: t)
        }
        audio?.start()
        panel.apply(settings)

        view.window?.makeFirstResponder(metalView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.autoOpenObservatoryIfRequested()
        }
        if CommandLine.arguments.contains("--flight") { setFlight(true) }
    }

    private func presentFatal(_ error: Error) {
        let label = NSTextField(labelWithString:
            "Failed to start:\n\(error.localizedDescription)")
        label.alignment = .center
        label.frame = view.bounds
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)
    }

    private func wirePanel() {
        panel.onScene = { [weak self] i in
            guard let self else { return }
            self.host.customSpecs.removeAll()
            self.panel.updateBuilt(self.host.customDescription)
            self.host.loadScene(i)
            self.host.camera.autoOrbit = true
        }
        panel.onPlayPause  = { [weak self] p in self?.host.sim.isPaused = !p }
        panel.onRestart    = { [weak self] in self?.host.sim.restart() }
        panel.onSpeed      = { [weak self] s in self?.speed = s }
        panel.onSolver     = { [weak self] m in self?.applySolver(m) }
        panel.onBudget     = { [weak self] b in
            guard let self else { return }
            let budget = min(b, self.host.sim.mode.recommendedMax)
            self.host.rebuildScenes(budget: budget)
            self.panel.syncBudget(budget)
        }
        panel.onVisuals    = { [weak self] v in self?.host.renderer.settings = v }
        panel.onCamera     = { [weak self] on in self?.host.camera.autoOrbit = on }
        panel.onAudio      = { [weak self] on, vol in
            self?.audio?.isEnabled = on
            self?.audio?.volume = vol
        }
        panel.onAutoOrbit  = { [weak self] in
            guard let self else { return }
            self.host.autoOrbitCustom()
            self.panel.updateBuilt(self.host.customDescription)
        }
        panel.onClearBuild = { [weak self] in
            guard let self else { return }
            self.host.clearCustom()
            self.panel.updateBuilt(self.host.customDescription)
        }

    }

    /// Push saved configuration into the renderer and simulation. Called
    /// before the panel is synced, so the controls and the engine agree.
    private func applyLoadedSettings() {
        var r = host.renderer.settings
        r.exposure = settings.exposure
        r.psfStrength = settings.psfStrength
        r.starSize = settings.starSize
        r.filmK = settings.filmK
        r.filmN = settings.filmN
        r.halation = settings.halation
        r.saturation = settings.saturation
        r.webStrength = settings.webStrength
        r.brightness = settings.brightness
        r.showBackgroundStars = settings.showBackgroundStars
        host.renderer.settings = r

        host.sim.theta = settings.theta
        host.sim.params.dt = settings.timeStep
        host.camera.autoOrbit = settings.autoOrbit
        if settings.particleBudget != host.particleBudget {
            host.rebuildScenes(budget: settings.particleBudget)
        }
        applySolver(settings.solver)
    }

    /// Read the current live configuration back out of the engine.
    private func captureSettings() -> Settings {
        var s = settings
        let r = host.renderer.settings
        s.exposure = r.exposure
        s.psfStrength = r.psfStrength
        s.starSize = r.starSize
        s.filmK = r.filmK
        s.filmN = r.filmN
        s.halation = r.halation
        s.saturation = r.saturation
        s.webStrength = r.webStrength
        s.brightness = r.brightness
        s.showBackgroundStars = r.showBackgroundStars

        s.solver = host.sim.mode
        s.particleBudget = host.particleBudget
        s.theta = host.sim.theta
        s.timeStep = host.sim.params.dt
        s.autoOrbit = host.camera.autoOrbit

        s.masterVolume = audio?.volume ?? s.masterVolume
        s.audioEnabled = audio?.isEnabled ?? s.audioEnabled
        s.trackVolumes = panel.trackVolumeValues
        return s
    }

    private func wireKidsPanel() {
        kidsPanel.onScene = { [weak self] i in
            guard let self else { return }
            self.host.customSpecs.removeAll()
            self.host.loadScene(i)
            self.host.camera.autoOrbit = true
            self.host.camera.autoFrame = true
            self.kidsPanel.updateStatus("Watching: \(self.host.scenes[i].name)")
        }
        kidsPanel.onPlayPause = { [weak self] p in self?.host.sim.isPaused = !p }
        kidsPanel.onRestart   = { [weak self] in self?.host.sim.restart() }
        kidsPanel.onSpeed     = { [weak self] s in self?.speed = s }
        kidsPanel.onAutoOrbit = { [weak self] in
            guard let self else { return }
            self.host.autoOrbitCustom()
            self.host.sim.isPaused = false
            self.kidsPanel.setPlaying(true)
            self.kidsPanel.updateStatus("Off they go!")
        }
        kidsPanel.onClear = { [weak self] in
            guard let self else { return }
            self.host.clearCustom()
            self.kidsPanel.updateStatus("Cleared.")
        }
        kidsPanel.onPlaceType = { [weak self] t in
            self?.kidsPanel.updateStatus("Tap the sky to drop a \(t.rawValue)")
        }
        kidsPanel.onHamburger = { [weak self] in self?.setUIMode(.engineer) }
        kidsPanel.onFlyMode   = { [weak self] in
            guard let self else { return }
            self.setFlight(!self.isFlying)
        }
        kidsPanel.onTiltChanged = { [weak self] _ in
            guard let self, let position = self.cursorGround else { return }
            self.host.updatePreview(type: self.kidsPanel.selectedType,
                tiltDegrees: self.placementTilt, rollDegrees: self.kidsPanel.selectedRoll, at: position)
        }
        kidsPanel.onPlaceModeChanged = { [weak self] on in
            guard let self else { return }
            if !on {
                self.host.clearPreview()
                self.cursorGround = nil
                self.host.camera.autoFrame = true
            } else {
                // hold the view still so the ground plane doesn't slide
                self.host.camera.autoOrbit = false
            }
        }
        panel.onExitEngineer = { [weak self] in self?.setUIMode(.kids) }
        panel.onTrackVolume = { [weak self] track, v in
            self?.audio?.setVolume(v, for: track)
        }
        panel.onSaveSettings = { [weak self] in
            guard let self else { return false }
            self.settings = self.captureSettings()
            return self.settings.save()
        }
        panel.onResetSettings = { [weak self] in
            guard let self else { return }
            Settings.clear()
            self.settings = Settings()
            self.applyLoadedSettings()
            self.panel.apply(self.settings)
            self.audio?.volume = self.settings.masterVolume
            for t in AmbientAudio.Track.allCases {
                self.audio?.setVolume(1, for: t)
            }
        }
    }

    /// Where a point in the view meets the orbital plane, in world space.
    private func groundPoint(_ p: NSPoint) -> SIMD3<Float>? {
        let b = metalView.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        let ndc = SIMD2<Float>(Float(p.x / b.width) * 2 - 1,
                               Float(p.y / b.height) * 2 - 1)
        let d = metalView.drawableSize
        let aspect = Float(d.width / max(d.height, 1))
        return host.camera.groundHit(ndc: ndc, aspect: aspect)
    }

    /// Speed and ship steering are independent of the inspection orbit.
    private func applyFlightControls(dt: Float) {
        guard isFlying else { return }

        // The stick is held exactly like a key is, so it joins the same sum
        // rather than getting a control path of its own. A tablet with no
        // keyboard and a desk with one fly the ship identically. The throttle
        // strip is not in this sum: it is a position, not a rate, and it sets
        // beta directly through `onSpeed`.
        var throttle: Float = 0
        if heldKeys.contains("w") || heldKeys.contains("\u{f700}") { throttle += 1 }
        if heldKeys.contains("s") || heldKeys.contains("\u{f701}") { throttle -= 1 }
        throttle = min(max(throttle, -1), 1)
        if throttle != 0 {
            // Move in a warped coordinate so the control stays usable right up
            // against c, where almost all the visual change happens.
            let gap = max(1 - flight.beta, 1e-5)
            flight.beta = min(0.99995, max(0, flight.beta + throttle * dt * 0.55 * gap))
        }

        var yaw: Float = hud?.padYaw ?? 0
        if heldKeys.contains("a") || heldKeys.contains("\u{f702}") { yaw -= 1 }
        if heldKeys.contains("d") || heldKeys.contains("\u{f703}") { yaw += 1 }
        yaw = min(max(yaw, -1), 1)
        if yaw != 0 {
            flight.turn(yaw * dt * 0.8)
        }

        // Pitch has no key of its own: the arrows are already spoken for by
        // throttle and yaw, and the stick is the control this was added for.
        let pitch = min(max(hud?.padPitch ?? 0, -1), 1)
        if pitch != 0 {
            flight.pitchTurn(pitch * dt * 0.8)
        }
    }

    @objc private func clearHeldKeys() {
        heldKeys.removeAll()
        hud?.releaseSteering()
    }

    private func focusFlight() { view.window?.makeFirstResponder(metalView) }

    private func setFlight(_ on: Bool) {
        isFlying = on
        stepAccumulator = 0
        host.clearPreview()
        cursorGround = nil
        applyUIMode()
        audio?.setFlightMode(on)
        hud?.isHidden = !on
        // Hide the whole kids overlay while flying, not just the hotbar: the
        // encounter picker and the settings button were still drawing over the
        // flight view, and the top-left cluster collided with the HUD's own
        // velocity readout.
        kidsPanel?.isHidden = on || uiMode != .kids
        heldKeys.removeAll()
        hud?.releaseSteering()
        kidsPanel?.bottomBar.isHidden = on || uiMode != .kids
        if on {
            // Take off from wherever you were looking. Flight used to begin at
            // a fixed offset from the encounter's centre, which threw away the
            // view you had just set up and was disorienting: you pressed Fly
            // and the galaxy jumped somewhere else. The ship now appears at the
            // orbit camera's own position, already facing what it was facing.
            flight = FlightCamera()
            chase = ChaseCamera()
            flightPaused = false
            hud.controlsVisible = true

            let eye = host.camera.position
            let target = host.camera.renderedTarget
            var forward = target - eye
            if simd_length(forward) < 1e-3 { forward = SIMD3<Float>(0, 0, -1) }
            forward = simd_normalize(forward)

            flight.position = eye
            // Match the orbit camera's heading exactly: yaw 0 looks down -Z.
            flight.yaw = atan2(forward.x, -forward.z)
            flight.pitch = asin(simd_clamp(forward.y, -1, 1))
            flight.travelDirection = forward
            flight.beta = 0.5
            kidsPanel.updateStatus("Flying — press esc to come back")
        } else {
            host.camera.autoFrame = true
            kidsPanel.updateStatus("Back in orbit.")
        }
        view.window?.makeFirstResponder(metalView)
    }

    private func setUIMode(_ mode: UIMode) {
        uiMode = mode
        applyUIMode()
    }

    private func applyUIMode() {
        let kids = (uiMode == .kids)
        kidsPanel.isHidden = !kids || isFlying
        kidsPanel.bottomBar.isHidden = !kids || isFlying
        panel.isHidden = kids || isFlying
        panelWidth.constant = kids || isFlying ? 0 : 242
        kidsPanel.setPlaying(!host.sim.isPaused)
        panel.setPlaying(!host.sim.isPaused)
        view.window?.makeFirstResponder(metalView)
    }

    /// Whichever panel is on screen owns place mode.
    private var activePlaceMode: Bool {
        uiMode == .kids ? kidsPanel.placeMode : panel.placeMode
    }
    private var activeType: GalaxyType {
        uiMode == .kids ? kidsPanel.selectedType : panel.selectedType
    }
    private func activeSetPlaying(_ playing: Bool) {
        if uiMode == .kids { kidsPanel.setPlaying(playing) }
        else { panel.setPlaying(playing) }
    }

    /// Direct N² can't hold 600k particles; drop the budget when switching.
    private func applySolver(_ m: SolverMode) {
        host.sim.mode = m
        if host.particleBudget > m.recommendedMax {
            let b = m.recommendedMax
            host.rebuildScenes(budget: b)
            panel.syncBudget(b)
        }
    }

    private func handleKey(_ k: String) {
        if planetObservatory != nil {
            if k == "\u{1b}" { leavePlanet() }
            return
        }
        if k == "\u{1b}", selectedStar != nil {
            clearStarSelection()
            return
        }
        if isFlying {
            switch k {
            case " ": flightPaused.toggle()
            case "c": chase.recenter()
            case "\t": hud.controlsVisible.toggle()
            case "f", "\u{1b}": setFlight(false)
            default: break
            }
            return
        }
        switch k {
        case " ": activeSetPlaying(host.sim.isPaused)
        case "r": host.sim.restart()
        case "s": saveScreenshot()
        case "o": host.camera.autoOrbit.toggle()
        case "f": setFlight(true)
        default: break
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutStarInspector()
        planetObservatory?.frame = view.bounds
    }

    private func layoutStarInspector() {
        guard let starInspector else { return }
        let h = max(320, min(850, view.bounds.height - 150))
        starInspector.frame = NSRect(x: view.bounds.width - 338,
                                     y: view.bounds.height - h - 24,
                                     width: 320, height: h)
    }

    private func clearStarSelection() {
        selectedStar = nil
        stellarProfile = nil
        host?.renderer.selectedParticleIndex = nil
        starInspector?.isHidden = true
        starInspector?.setAnimating(false)
    }

    private func pickStar(at point: NSPoint) {
        guard planetObservatory == nil else { return }
        inFlight.wait()
        defer { inFlight.signal() }
        let size = metalView.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        let aspect = Float(size.width / size.height)
        let flightView = isFlying ? chase.galaxyView(aspect: aspect, flight: flight) : nil
        var cam = CameraUniforms()
        cam.viewProj = flightView?.0 ?? host.camera.viewProjection(aspect: aspect)
        cam.cameraPos = SIMD4(flightView?.1 ?? host.camera.position, 0)
        cam.viewport = SIMD4(Float(size.width), Float(size.height), 1 / Float(size.width), 1 / Float(size.height))
        cam.extra.w = host.renderer.settings.adaptiveStars
            ? min(1, Float(max(1, host.renderer.settings.distantStarBudget)) / Float(max(1, host.sim.particleCount))) : 1
        let scale = Float(size.width / metalView.bounds.width)
        let pixel = SIMD2(Float(point.x / metalView.bounds.width * size.width),
                          Float(point.y / metalView.bounds.height * size.height))
        let index = starPicker.pick(sim: host.sim, camera: cam,
                                    relativity: isFlying ? flight.uniforms() : RelativityUniforms(),
                                    pixel: pixel, radius: 9 * scale)
        guard let index else { clearStarSelection(); return }
        showStar(index: index)
    }

    /// Must be called after the previous GPU frame has completed.
    private func showStar(index: Int) {
        guard index >= 0, index < host.sim.particleCount else { return }
        selectedStar = index
        selectedGeneration = host.sim.sceneGeneration
        host.renderer.selectedParticleIndex = index
        let population = host.sim.auxBuffer.contents().bindMemory(to: UInt32.self,
                                                                  capacity: host.sim.particleCount)[index]
        let profile = StellarProfile.make(index: index, population: population,
                                          galaxy: host.sim.galaxyName(at: Int(population >> 8)))
        stellarProfile = profile
        starInspector.update(profile: profile)
        starInspector.isHidden = false
        starInspector.setAnimating(true)
        layoutStarInspector()
        host.camera.autoOrbit = false
    }

    private func visitSelectedPlanet() {
        guard let index = selectedStar, let profile = stellarProfile,
              selectedGeneration == host.sim.sceneGeneration, index < host.sim.particleCount,
              planetObservatory == nil else { return }
        inFlight.wait()
        let p = host.sim.particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: host.sim.particleCount)
        let aux = host.sim.auxBuffer.contents().bindMemory(to: UInt32.self, capacity: host.sim.particleCount)
        let origin = SIMD3(p[index].position.x, p[index].position.y, p[index].position.z)
        var stars: [ObservatoryStar] = []
        // Take as much of the galaxy as the view can hold. The sky's glow is
        // not a painted texture — it is the summed light of stars too faint
        // and too numerous to pick out individually, and it only appears if
        // those stars are actually there. At 20k the sky was a scatter of
        // dots; the simulation has millions. This view is static, so it can
        // afford them.
        let observatoryCap = 900_000
        let stride = max(1, (host.sim.particleCount + observatoryCap - 1) / observatoryCap)
        for i in Swift.stride(from: 0, to: host.sim.particleCount, by: stride) where i != index && aux[i] & 255 != 3 {
            let delta = SIMD3(p[i].position.x, p[i].position.y, p[i].position.z) - origin
            let distance = simd_length(delta)
            if distance > 0.00001 {
                let color = SIMD3(p[i].color.x, p[i].color.y, p[i].color.z)

                // Intrinsic luminosity, not just distance.
                //
                // Every tracer previously produced the same brightness at the
                // same range, so the sky came out as a field of identical
                // dots. Real stars differ in luminosity by many orders of
                // magnitude — a handful dominate the sky while the vast
                // majority are invisible. Draw a heavy-tailed luminosity from
                // a stable per-star hash so the same star is the same
                // brightness every time this sky is opened.
                var h = UInt64(bitPattern: Int64(i)) &* 0x9E37_79B9_7F4A_7C15
                h ^= h >> 30; h = h &* 0xBF58476D1CE4E5B9
                h ^= h >> 27; h = h &* 0x94D049BB133111EB
                h ^= h >> 31
                let u = Float(h >> 11) / Float(1 << 53)
                // A steep negative exponent is what gives the real spread:
                // at -1.1 the range from a typical star to the rarest spans
                // three orders of magnitude, so a few points genuinely
                // dominate the sky while most sit near the noise floor.
                let luminosity = pow(max(u, 1e-5), -1.1) * Self.observatoryLuminosityScale

                // inverse square, softened so a very close tracer cannot
                // produce a singular value
                let flux = luminosity / max(distance * distance, 0.05)
                // Clipped only at the extreme tail. A low ceiling here is
                // what flattened the sky: the top three orders of magnitude
                // all arrived at the same value, so no star could over-expose.
                let brightness = min(PlanetObservatoryView.brightnessCeiling, max(0.004, flux))
                stars.append(ObservatoryStar(direction: delta / distance, color: color, brightness: brightness))
            }
        }
        pausedBeforePlanet = host.sim.isPaused
        host.sim.isPaused = true
        metalView.isPaused = true
        inFlight.signal()
        clearHeldKeys()
        starInspector.setAnimating(false)
        let observatory = PlanetObservatoryView(profile: profile, stars: stars)
        observatory.frame = view.bounds
        observatory.autoresizingMask = [.width, .height]
        observatory.onBack = { [weak self] in self?.leavePlanet() }
        planetObservatory = observatory
        view.addSubview(observatory)
        view.window?.makeFirstResponder(observatory)
    }

    /// GALAXYSIM_OBSERVATORY=1 opens the night sky straight away on a star
    /// well inside the disc. For reviewing the sky without hunting for a
    /// clickable star first.
    private func autoOpenObservatoryIfRequested() {
        guard ProcessInfo.processInfo.environment["GALAXYSIM_OBSERVATORY"] != nil,
              planetObservatory == nil, host.sim.particleCount > 0 else { return }
        // Pick a particle a little out from the centre, where a planet would
        // actually see a rich sky rather than a blaze or an empty field.
        let p = host.sim.particleBuffer.contents()
            .bindMemory(to: GPUParticle.self, capacity: host.sim.particleCount)
        var best = 0
        var bestScore = Float.greatestFiniteMagnitude
        let centre = host.sim.cores.first?.position ?? .zero
        var i = 0
        while i < host.sim.particleCount {
            let d = simd_length(SIMD3(p[i].position.x, p[i].position.y, p[i].position.z) - centre)
            let score = abs(d - 7)
            if score < bestScore { bestScore = score; best = i }
            i += max(1, host.sim.particleCount / 4000)
        }
        let population = host.sim.auxBuffer.contents()
            .bindMemory(to: UInt32.self, capacity: host.sim.particleCount)[best]
        selectedStar = best
        selectedGeneration = host.sim.sceneGeneration
        stellarProfile = StellarProfile.make(index: best, population: population,
                                             galaxy: host.sim.galaxyName(at: Int(population >> 8)))
        visitSelectedPlanet()
    }

    /// Overall stellar luminosity for the observatory sky. Swept from the
    /// environment while tuning.
    static let observatoryLuminosityScale: Float =
        Float(ProcessInfo.processInfo.environment["GALAXYSIM_STARLUM"] ?? "") ?? 6.0

    private func leavePlanet() {
        guard let observatory = planetObservatory else { return }
        observatory.stop()
        observatory.removeFromSuperview()
        planetObservatory = nil
        host.sim.isPaused = pausedBeforePlanet
        lastFrame = CFAbsoluteTimeGetCurrent()
        stepAccumulator = 0
        metalView.isPaused = false
        starInspector.setAnimating(selectedStar != nil)
        view.window?.makeFirstResponder(metalView)
    }

    private func saveScreenshot() {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let path = dir.appendingPathComponent("GalaxySim-\(stamp).png").path
        _ = try? host.capture(width: 2560, height: 1440, to: path)
        NSLog("screenshot -> %@", path)
    }

    /// Integration checks use the same input callbacks as NSEvent handling.
    /// Invoked only by --uitest, in a real AppKit window with a Metal device.
    private func runExplorerUIReview(output: String) throws {
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            print("PASS: " + message)
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        metalView.isPaused = true
        inFlight.wait(); inFlight.signal()
        host.sim.isPaused = true
        audio?.isEnabled = false
        setFlight(false)
        setUIMode(.kids)
        kidsPanel.setPlaceMode(false)
        host.camera.autoOrbit = false
        view.window?.setContentSize(NSSize(width: 1440, height: 900))
        view.layoutSubtreeIfNeeded()
        host.reframe(immediate: true)
        metalView.draw()
        inFlight.wait(); inFlight.signal()
        let p = host.sim.particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: host.sim.particleCount)
        let aux = host.sim.auxBuffer.contents().bindMemory(to: UInt32.self, capacity: host.sim.particleCount)
        let vp = host.camera.viewProjection(aspect: Float(metalView.drawableSize.width / metalView.drawableSize.height))
        var click: NSPoint?
        for i in Swift.stride(from: 0, to: host.sim.particleCount, by: max(1, host.sim.particleCount / 20000)) where aux[i] & 255 != 3 {
            let v = p[i].position
            let c = vp * SIMD4(v.x, v.y, v.z, 1)
            if c.w > 0 && c.z > 0 && c.z < c.w {
                let x = c.x / c.w * 0.5 + 0.5, y = c.y / c.w * 0.5 + 0.5
                if x > 0.2 && x < 0.60 && y > 0.2 && y < 0.8 {
                    click = NSPoint(x: CGFloat(x) * metalView.bounds.width,
                                    y: CGFloat(y) * metalView.bounds.height)
                    break
                }
            }
        }
        check(click != nil, "Found a visible star for native click review")
        metalView.onClick?(click!)
        check(selectedStar != nil && !starInspector.isHidden, "Click opens selected-star inspector")
        let selection = selectedStar
        metalView.onDrag?(20, 10)
        check(selectedStar == selection, "Dragging the camera preserves selected identity")
        func screenshot(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            if let planet = planetObservatory { check(planet.reviewDraw(), planet.renderError ?? "Planet GPU frame completed") }
            else { metalView.draw() }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(view.window!.windowNumber), output + "/" + name + ".png"]
            try task.run(); task.waitUntilExit()
            if task.terminationStatus == 0 { check(true, "Captured " + name); return }
            // screencapture needs a display that is awake and Screen Recording
            // access; a command-line launch on a sleeping Mac has neither, and
            // the review used to abort there. Fall back to the AppKit views
            // drawn into a bitmap. The Metal sky is not in this image -- it is
            // a control shot, not a window screenshot -- but every card, label
            // and dial is, which is what the layout checks are looking at.
            guard let content = view.window?.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                check(false, "Captured " + name); return
            }
            content.cacheDisplay(in: content.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                check(false, "Captured " + name); return
            }
            try png.write(to: URL(fileURLWithPath: output + "/" + name + "-controls.png"))
            print("Window capture unavailable (exit \(task.terminationStatus)); saved AppKit controls for " + name)
            check(true, "Captured " + name + " (AppKit controls only; no window capture available)")
        }
        try screenshot("star-inspector")
        if let scroll = starInspector.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        try screenshot("star-story")
        // Scroll to the very end: the story block used to be clipped by a
        // hardcoded content height, so the tail of the card is now an artefact
        // the review looks at every run.
        if let scroll = starInspector.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView,
           let document = scroll.documentView {
            let bottom = max(0, document.frame.height - scroll.contentSize.height)
            check(document.frame.height > scroll.contentSize.height, "Star card content is taller than its window")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        try screenshot("star-fate")
        view.window?.setContentSize(NSSize(width: 1000, height: 650))
        try screenshot("star-small-window")
        view.window?.setContentSize(NSSize(width: 1440, height: 900))
        let previousPause = host.sim.isPaused
        visitSelectedPlanet()
        check(planetObservatory != nil && host.sim.isPaused && metalView.isPaused, "Planet entry freezes parent simulation")
        let planet = planetObservatory!
        check(abs(planet.reviewExposure(seconds: 30, openFor: 15) - 0.5) < 0.0001,
              "30-second exposure reaches halfway after 15 seconds")
        check(abs(planet.reviewKeepsLightWhileMoving(for: 3) - 0.6) < 0.0001,
              "Moving during an exposure keeps the light already gathered")
        planet.reviewExposure(seconds: 30, openFor: 8)
        try screenshot("planet-gathering")
        check(planet.reviewExposure(seconds: 0.2, openFor: 0.2) == 1,
              "Short exposure completes at requested time")
        planet.reviewExposure(seconds: 30, openFor: 30)
        try screenshot("planet-exposed")
        // The dial has to be visible in the picture, not only in the code:
        // one frame from each end of it and one from the middle, so a change
        // that flattens the exposure again shows up as three identical greys.
        for (seconds, name) in [(0.25, "exposure-quarter-second"),
                                (4.0, "exposure-4s"), (60.0, "exposure-60s")] {
            planet.reviewExposure(seconds: Float(seconds), openFor: Float(seconds))
            check(planet.reviewDraw(), planet.renderError ?? "exposure frame \(seconds)")
            try screenshot(name)
        }
        // The same three settings before the shutter is pressed. A viewfinder
        // that does not follow the dial is the failure this catches: it read
        // identically everywhere below three seconds, which made the bottom
        // half of the dial look broken.
        for (seconds, name) in [(0.25, "viewfinder-quarter-second"),
                                (4.0, "viewfinder-4s"), (60.0, "viewfinder-60s")] {
            planet.reviewViewfinder(seconds: Float(seconds))
            check(planet.reviewDraw(), planet.renderError ?? "viewfinder frame \(seconds)")
            try screenshot(name)
        }
        // Reaching for the dial mid-exposure must end the exposure, not leave
        // the screen frozen until the original seconds run out.
        planet.reviewExposure(seconds: 60, openFor: 12)
        planet.reviewTurnDial(to: 4)
        check(planet.exposureProgress == 0 || !planet.reviewIsExposing,
              "Turning the dial during an exposure closes the shutter")

        // ---- where the probe stands, and what its star does ----------
        // The galaxy used to lie along the skyline and, as often as not,
        // under it: the sky assumed the planet's pole was the simulation's
        // +Y axis, and the disc lies near its XZ plane. A landing now picks
        // a pole of its own. Six of them, because one lucky roll proves
        // nothing.
        planet.reviewViewfinder(seconds: 4)
        for attempt in 1...6 {
            planet.reviewReland()
            check(planet.reviewGalaxyAltitude > 0.40,
                  "Landing \(attempt) puts the galaxy well above the skyline")
            check(planet.reviewStarAltitude < 0,
                  "Landing \(attempt) arrives at night")
        }
        check(planet.reviewDraw(), planet.renderError ?? "relanded frame")
        print(planet.reviewSkyCensus)
        // A 25-degree cone is about a fifth of the sky that is up, so an
        // evenly sprinkled sky would put ~19% of the standing stars in front
        // of the camera and a galaxy ought to beat that comfortably. The
        // landing that this catches managed 0.14%: it aimed the probe's pole
        // straight out of the disc, at the one direction with nothing in it.
        check(Float(planet.reviewStarsAhead) > 0.10 * Float(planet.reviewStarsUp),
              "The camera opens on the crowded part of the sky")
        try screenshot("planet-relanded")
        // Sleeping turns the ground until the star is up, and again until it
        // has set. Both frames are captured: whether a star blots out its own
        // sky is the entire question, and it is a picture, not a number.
        planet.reviewSleep()
        check(planet.reviewStarAltitude > 0, "Sleeping brings the host star up")
        check(planet.reviewGalaxyAltitude > 0.40,
              "The galaxy is still overhead in daylight")
        check(planet.reviewDraw(), planet.renderError ?? "daylight frame")
        try screenshot("planet-daylight")
        planet.reviewSleep()
        check(planet.reviewStarAltitude < 0, "Sleeping again returns to night")
        check(planet.reviewDraw(), planet.renderError ?? "second night frame")
        try screenshot("planet-night-again")

        // ---- daylight on a world that actually gets some -------------
        // The landing above was around whatever star the explorer clicked,
        // and it kept picking dim ones, whose daylight the dial handles
        // without complaint. A G star at one AU is the case that does not
        // fit on the dial at all: the quarter-second stop is some three
        // hundred times too long, and every frame came back white. So the
        // ordinary star is now in the review, and the check is on what came
        // out rather than on whether anything did.
        planet.reviewSunlikeHost()
        planet.reviewSleep()          // and round to the daylight side again
        planet.reviewViewfinder(seconds: 4)
        check(planet.reviewDraw(), planet.renderError ?? "Sun-like daylight frame")
        check(planet.reviewStarAltitude > 0, "The Sun-like star is up")
        let auto = planet.reviewAutoShutter
        check(auto != nil, "Daylight past the dial makes the camera meter for itself")
        check(auto! < 0.25 && auto! > 1.0 / 4000,
              String(format: "The camera picks a daylight shutter: 1/%.0f s", 1 / auto!))
        let clipped = planet.reviewClippedFraction
        check(clipped < 0.35,
              String(format: "Daylight develops as a picture, not a white rectangle (%.0f%% clipped)",
                     clipped * 100))
        try screenshot("planet-daylight-sunlike")
        // And the photograph agrees with the viewfinder it was aimed with.
        _ = planet.reviewExposure(seconds: 4, openFor: 4)
        check(planet.reviewDraw(), planet.renderError ?? "Sun-like daylight photograph")
        let shot = planet.reviewClippedFraction
        check(shot < 0.35,
              String(format: "The daylight photograph is not a white rectangle either (%.0f%% clipped)",
                     shot * 100))
        try screenshot("planet-daylight-photo")

        // ---- and with the sun behind you ----------------------------
        // The same daylight, framed away from the star. The reading falls,
        // because a frame with a sun in it is far brighter than one without
        // -- and the first version of this handed the shutter back to a dial
        // still sitting on four seconds and blew the landscape out again.
        // Daylight is daylight whichever way the camera points.
        planet.reviewViewfinder(seconds: 4)
        planet.reviewLookAway()
        let away = planet.reviewAutoShutter
        check(away != nil, "Turning away from the sun keeps the camera metering")
        check(away! < 1, String(format: "The shutter follows the light round: %@ s",
                                PlanetObservatoryView.reviewSpeedText(away!)))
        let awayClipped = planet.reviewClippedFraction
        check(awayClipped < 0.35,
              String(format: "The sky away from the sun is still a picture (%.0f%% clipped)",
                     awayClipped * 100))
        try screenshot("planet-daylight-away")
        leavePlanet()
        check(planetObservatory == nil && host.sim.isPaused == previousPause && selectedStar == selection,
              "Returning restores prior pause state and selected star")
        metalView.isPaused = true
        host.sim.restart()
        metalView.draw()
        check(selectedStar == nil && starInspector.isHidden, "Restart clears stale selection")
        print("PASS: star explorer native review complete")
    }

    func runUIReview(output: String) throws {
        if CommandLine.arguments.contains("--explorerreview") {
            try runExplorerUIReview(output: output)
            return
        }
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fatalError("FAIL: " + name) }
            print("PASS: " + name)
        }
        if CommandLine.arguments.contains("--hotbarreview") {
            metalView.isPaused = true
            audio?.isEnabled = false
            setFlight(false); setUIMode(.kids)
            kidsPanel.setPlaceMode(false)
            check(metalView.onRotationDrag?(20, 10) == false, "Rotation shortcut inactive outside Creation")
            kidsPanel.setPlaceMode(true)
            let tiltBefore = kidsPanel.selectedTilt, rollBefore = kidsPanel.selectedRoll
            let cameraBefore = host.camera.viewProjection(aspect: 1.6)
            cursorGround = .zero
            check(metalView.onRotationDrag?(40, 30) == true, "Creation consumes Shift-drag")
            check(kidsPanel.selectedTilt == tiltBefore + 15 && kidsPanel.selectedRoll == rollBefore + 20,
                  "Shift-drag changes both galaxy orientation axes")
            check(host.camera.viewProjection(aspect: 1.6) == cameraBefore, "Rotating preview preserves camera")
            host.addGalaxy(type: kidsPanel.selectedType, massScale: 1, tiltDegrees: kidsPanel.selectedTilt,
                rollDegrees: kidsPanel.selectedRoll, at: .zero)
            check(simd_length(host.customSpecs.last!.spinAxis - Presets.tilt(kidsPanel.selectedTilt, roll: kidsPanel.selectedRoll)) < 0.00001,
                  "Created galaxy retains preview orientation")
            host.loadScene(0)
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            for width in [1800, 1440, 1000] {
                view.window?.setContentSize(NSSize(width: width, height: 900))
                for placing in [false, true] {
                    kidsPanel.setPlaceMode(placing)
                    view.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
                    view.layoutSubtreeIfNeeded()
                    metalView.draw(); view.window?.displayIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(view.window!.windowNumber),
                        output + "/hotbar-\(width)-\(placing ? "placing" : "orbit").png"]
                    try capture.run(); capture.waitUntilExit()
                    check(capture.terminationStatus == 0, "Hotbar screenshot at \(width), placing=\(placing)")
                }
            }
            return
        }
        metalView.isPaused = true
        audio?.isEnabled = false
        setUIMode(.kids)
        setFlight(true)
        let heading = flight.travelDirection
        metalView.onDrag?(100, 30)
        chase.update(dt: 1)
        check(simd_length(flight.travelDirection - heading) < 0.000001, "Orbit preserves travel heading")
        let paused = host.sim.isPaused
        metalView.onKey?(" ")
        check(flightPaused && host.sim.isPaused == paused, "Space pauses travel independently")
        metalView.onKey?(" ")
        check(!flightPaused, "Space resumes travel")
        let beta = flight.beta
        metalView.onKey?("s"); applyFlightControls(dt: 0.1); metalView.onKeyUp?("s")
        check(flight.beta < beta, "S reduces speed")
        metalView.onKey?("d"); applyFlightControls(dt: 0.1); metalView.onKeyUp?("d")
        check(flight.travelDirection.x > heading.x, "D turns ship right independently of view")
        metalView.onKey?("a"); applyFlightControls(dt: 0.1); metalView.onKeyUp?("a")
        check(simd_length(flight.travelDirection - heading) < 0.00001, "A turns ship left")
        let zoomBefore = chase.distance
        metalView.onScroll?(12); chase.update(dt: 1)
        check(chase.distance < zoomBefore, "Scroll zooms toward ship")
        metalView.onKey?("w"); clearHeldKeys()
        check(heldKeys.isEmpty, "Focus loss clears held controls")
        metalView.onKey?("c"); chase.update(dt: 2)
        check(abs(chase.yaw - 0.30) < 0.001, "C smoothly restores follow view")
        // Exercise the visible arcade HUD's actual native pause button.
        let pauseButton = hud.reviewControl("flight.pause") as! PillButton
        pauseButton.simulateTap()
        hud.update(flight: flight, paused: flightPaused)
        check(flightPaused && hud.reviewPauseTitle.contains("Resume"), "Visible Pause freezes flight and offers Resume")
        let frozenPosition = flight.position
        let frozenTime = flight.coordinateTimeMyr
        let frozenBeta = flight.beta
        metalView.draw()
        metalView.draw()
        check(flight.position == frozenPosition && flight.coordinateTimeMyr == frozenTime && flight.beta == frozenBeta,
              "Paused frames preserve position, time and relativistic speed")
        check(view.window?.firstResponder === metalView, "Pause returns keyboard focus to scene")
        pauseButton.simulateTap()
        hud.update(flight: flight, paused: flightPaused)
        check(!flightPaused && hud.reviewPauseTitle.contains("Pause"), "Visible Resume restores travel")

        // ---- flying with no keyboard at all ---------------------------
        // The whole point of the two pads: a tablet has no W, no A and no
        // escape key, so every one of them is driven here through the control
        // the finger actually lands on.
        view.layoutSubtreeIfNeeded()
        hud.layoutSubtreeIfNeeded()
        let throttleStrip = hud.reviewControl("flight.speed")!
        let stickPad = hud.reviewControl("flight.stick")!
        check(throttleStrip.frame.width >= 44 && stickPad.frame.width >= 44,
              "Both pads are wide enough for a thumb, not just tall enough")

        flight.beta = 0.5
        hud.update(flight: flight)
        let slideStart = flight.beta
        hud.reviewThrottleSlide(30)
        check(flight.beta > slideStart, "Sliding a thumb up the speed pad speeds the ship up")
        let firstStep = flight.beta - slideStart
        let afterFirstSlide = flight.beta
        hud.reviewThrottleSlide(30)
        // Relative, not absolute. An absolute pad would jump to wherever the
        // thumb landed, so the second slide would go nowhere — and the first
        // touch would always yank the ship.
        check(abs((flight.beta - afterFirstSlide) - firstStep) < 0.001,
              "The speed pad is relative: the same slide again adds the same again")
        hud.reviewThrottleSlide(-60)
        check(abs(flight.beta - slideStart) < 0.001, "Sliding back down brakes to where it started")

        let padHeading = flight.travelDirection
        hud.reviewSteer(x: 1, y: 0)
        applyFlightControls(dt: 0.1)
        hud.reviewSteer(x: 0, y: 0)
        check(flight.travelDirection.x > padHeading.x, "Pushing the stick right steers the ship right")
        hud.reviewSteer(x: -1, y: 0)
        applyFlightControls(dt: 0.1)
        hud.reviewSteer(x: 0, y: 0)
        check(simd_length(flight.travelDirection - padHeading) < 0.00001, "Pushing it left steers back")
        hud.reviewSteer(x: 0, y: 1)
        applyFlightControls(dt: 0.1)
        hud.reviewSteer(x: 0, y: 0)
        check(flight.travelDirection.y > padHeading.y, "Pushing the stick up lifts the nose")
        hud.reviewSteer(x: 0, y: -1)
        applyFlightControls(dt: 0.1)
        hud.reviewSteer(x: 0, y: 0)
        check(simd_length(flight.travelDirection - padHeading) < 0.00001, "Pushing it down puts the nose back down")

        // ---- the roll ring --------------------------------------------
        let rollUp = flight.shipUp
        let rollAspect = Float(1440) / 900
        let beforeRoll = chase.galaxyView(aspect: rollAspect, flight: flight).0
        hud.reviewRollDrag(0.6)
        check(chase.galaxyView(aspect: rollAspect, flight: flight).0 != beforeRoll,
              "Turning the ring actually tilts the view of the galaxy")
        check(simd_length(flight.shipUp - rollUp) > 0.01, "Rolling tilts the ship's own up")
        check(abs(simd_dot(flight.shipUp, flight.travelDirection)) < 0.0001,
              "The ship's frame stays square while it rolls")
        // Roll is a pure re-orientation: the boost is along the direction of
        // travel, so aberration, Doppler and beaming cannot notice it. The
        // sky turns and the aberration bullseye stays nailed where it was.
        check(simd_length(flight.travelDirection - padHeading) < 0.00001,
              "Rolling leaves the direction of travel, and so the optics, untouched")
        hud.reviewRollDrag(-0.6)
        check(simd_length(flight.shipUp - rollUp) < 0.00001, "Rolling back levels the ship again")

        // A stick that is still down when the window goes away never gets its
        // mouse-up, so the ship would turn for ever with nothing on screen.
        hud.reviewSteer(x: 1, y: 1)
        clearHeldKeys()
        applyFlightControls(dt: 0.1)
        check(hud.padYaw == 0 && hud.padPitch == 0
              && simd_length(flight.travelDirection - padHeading) < 0.00001,
              "Losing the window lets go of the stick")
                (hud.reviewControl("flight.follow") as! PillButton).simulateTap()
        chase.update(dt: 2)
        check(abs(chase.yaw - 0.30) < 0.001, "Visible Follow restores the view from behind")
        (hud.reviewControl("flight.exit") as! PillButton).simulateTap()
        check(!isFlying, "Visible Back leaves the ship without the escape key")
        setFlight(true)
        for b: Float in [0, 0.5, 0.9, 0.99, 0.9999] {
            check(abs(FlightHUD.beta(at: FlightHUD.throttlePosition(beta: b)) - b) < 0.00001,
                  "Throttle round trip at \(b)c")
        }
        setFlight(false)
        setUIMode(.engineer)
        setFlight(true)
        check(panel.isHidden && kidsPanel.isHidden && kidsPanel.bottomBar.isHidden,
              "All encounter controls hidden during engineer flight")
        metalView.onKey?("\u{1b}")
        check(!isFlying && !panel.isHidden, "Escape restores engineer interface")
        setFlight(true)
        check(flight.distanceTravelledKpc == 0, "New flight resets odometer")
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for (width, height) in [(1440, 900), (1000, 650)] {
            view.window?.setContentSize(NSSize(width: width, height: height))
            view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            view.layoutSubtreeIfNeeded()
            flight.beta = 0.5
            hud.update(flight: flight)
            hud.layoutSubtreeIfNeeded()
            // Everything with a target on it, rather than a hand-listed set
            // of classes: a filter naming classes silently stops testing
            // anything the day the classes change, and it did.
            let controls = hud.subviews.compactMap { $0 as? TouchTarget }
            for c in controls where !(hud.bounds.contains(c.frame) && c.frame.height >= 44) {
                fputs("off the pad: \(c.identifier?.rawValue ?? "?") \(c.frame) in \(hud.bounds)\n", stderr)
            }
            let named = Set(controls.compactMap { $0.identifier?.rawValue })
            check(named.isSuperset(of: ["flight.speed", "flight.stick", "flight.pause",
                                        "flight.follow", "flight.exit"]),
                  "The ship is fully drivable with no keyboard")
            check(controls.allSatisfy { hud.bounds.contains($0.frame) && $0.frame.height >= 44 },
                  "Ship controls fit and stay finger-sized at \(width) pixels")
            for i in controls.indices {
                for j in controls.indices where j > i {
                    check(!controls[i].frame.intersects(controls[j].frame), "Native controls do not overlap")
                }
            }
            let texture = host.makeCaptureTexture(width, height)!
            let cb = host.ctx.queue.makeCommandBuffer()!
            host.renderer.render(into: texture, commandBuffer: cb, simulation: host.sim,
                camera: host.camera,
                viewOverride: chase.galaxyView(aspect: Float(width) / Float(height), flight: flight),
                relativity: flight.uniforms(),
                ship: chase.state(aspect: Float(width) / Float(height), flight: flight))
            cb.commit(); cb.waitUntilCompleted()
            let scenePath = output + "/flight-\(width).png"
            check(try host.saveTexture(texture, to: scenePath), "Flight render saved")
            metalView.draw()
            view.window?.displayIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(view.window!.windowNumber),
                                 output + "/ship-window-\(width).png"]
            try capture.run()
            capture.waitUntilExit()
            if capture.terminationStatus == 0 {
                check(true, "Native window capture saved")
            } else {
                // Screen Recording access may be unavailable to a command-line launch.
                // Cache the actual AppKit HUD, then composite it over the separately
                // verified Metal image. This is explicitly NOT a window screenshot.
                print("Window capture unavailable (exit \(capture.terminationStatus), visible=\(view.window?.isVisible ?? false)); saving native-control composite")
                guard let overlay = hud.bitmapImageRepForCachingDisplay(in: hud.bounds),
                      let scene = NSImage(contentsOfFile: scenePath) else {
                    throw NSError(domain: "GalaxySim.UIReview", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unable to capture native controls"])
                }
                hud.cacheDisplay(in: hud.bounds, to: overlay)
                let canvas = NSImage(size: NSSize(width: width, height: height))
                canvas.lockFocus()
                scene.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
                NSImage(size: hud.bounds.size, flipped: false) { rect in
                    overlay.draw(in: rect)
                }.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
                canvas.unlockFocus()
                guard let tiff = canvas.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "GalaxySim.UIReview", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Unable to encode native-control composite"])
                }
                try png.write(to: URL(fileURLWithPath: output + "/ship-native-controls-composite-\(width).png"))
                check(true, "Native AppKit control composite saved; system window capture unavailable")
            }
        }
        print("UI review complete: " + output)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard host != nil, planetObservatory == nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(min(now - lastFrame, 0.1))
        lastFrame = now

        frameTimes.append(now)
        while frameTimes.count > 60 { frameTimes.removeFirst() }

        // CPU extent reads must wait for the previous GPU writes.
        inFlight.wait()
        if selectedStar != nil && selectedGeneration != host.sim.sceneGeneration {
            clearStarSelection()
        }

        // Re-frame periodically rather than every frame: sampleExtent walks
        // the particle buffer, and the camera smoothing makes the result
        // continuous anyway.
        reframeCounter += 1
        // Auto-framing is measured from the particle cloud, so it creeps
        // even when nothing is moving. That is fine while watching, but while
        // you are trying to place a galaxy the ground plane must hold still or
        // your aim slides out from under the cursor.
        let painting = (uiMode == .kids) && kidsPanel.placeMode
        if !isFlying && !painting && reframeCounter % 4 == 0 { host.reframe() }

        host.camera.update(dt: dt)

        // How many physics steps this frame. Fractional speeds accumulate so
        // slow motion is genuinely slow rather than stuttering.
        var steps = 0
        if isFlying && !flightPaused && !host.sim.isPaused {
            // While flying, the simulation must advance by the flight's own
            // COORDINATE time, not at the normal viewing rate. Crossing 30 kpc
            // at beta=0.99 takes 0.098 Myr; the galaxies should barely twitch.
            // Running the sim at its usual ~60 Myr per second would evolve a
            // whole merger during a few seconds of travel, which is what made
            // flight feel disconnected from the scene.
            let coordinateMyr = flight.flightTimeScale * dt
            stepAccumulator += coordinateMyr / max(host.sim.params.dt, 1e-4)
            steps = Int(stepAccumulator)
            stepAccumulator -= Float(steps)
            steps = min(steps, 4)
        } else if !isFlying && !host.sim.isPaused {
            stepAccumulator += speed * 120 * dt
            steps = Int(stepAccumulator)
            stepAccumulator -= Float(steps)
            // Bound catch-up work. A slow frame must not demand still more
            // physics in the next frame (the classic catch-up spiral). Keep
            // dt unchanged; under load, galaxy time advances more slowly.
            let estimate = measuredPhysicsCount == host.sim.particleCount
                ? physicsStepMilliseconds : Double(host.sim.particleCount) * 0.000002
            let allowance = max(1, min(12, Int(8.0 / max(estimate, 0.01))))
            steps = min(steps, allowance)
        }

        guard let cb = host.ctx.queue.makeCommandBuffer() else {
            inFlight.signal(); return
        }
        if steps > 0, let physicsCB = host.ctx.queue.makeCommandBuffer() {
            let wasPaused = host.sim.isPaused
            host.sim.isPaused = false
            for _ in 0..<steps { host.sim.step(commandBuffer: physicsCB) }
            host.sim.isPaused = wasPaused
            let measuredSteps = steps
            let count = host.sim.particleCount
            physicsCB.addCompletedHandler { [weak self] finished in
                let elapsed = (finished.gpuEndTime - finished.gpuStartTime) * 1000
                    / Double(measuredSteps)
                guard finished.status == .completed, elapsed > 0 else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.physicsStepMilliseconds = self.measuredPhysicsCount == count
                        ? self.physicsStepMilliseconds * 0.8 + elapsed * 0.2 : elapsed
                    self.measuredPhysicsCount = count
                }
            }
            physicsCB.commit() // same queue: render sees completed physics
        }

        if isFlying {
            applyFlightControls(dt: dt)
            if !flightPaused { flight.update(dt: dt) }
            chase.update(dt: dt)
            hud.update(flight: flight, paused: flightPaused)
            let d = view.drawableSize
            let aspect = Float(d.width / max(d.height, 1))
            let vo = chase.galaxyView(aspect: aspect, flight: flight)

            host.renderer.draw(in: view, commandBuffer: cb,
                               simulation: host.sim, camera: host.camera,
                               viewOverride: vo, relativity: flight.uniforms(),
                               ship: chase.state(aspect: aspect, flight: flight))
        } else {
            var ghost: (buffer: MTLBuffer, count: Int)? = nil
            if host.previewActive, let pb = host.previewBuffer, host.previewCount > 0 {
                ghost = (pb, host.previewCount)
            }

            // Ground guide, eased in and out so entering place mode is not a
            // hard cut.
            let wantGrid: Float = painting ? 1 : 0
            gridFade += (wantGrid - gridFade) * (1 - exp(-dt * 6))
            var grid: GridParams? = nil
            if gridFade > 0.004 {
                var g = GridParams()
                g.camPos = SIMD4(host.camera.position, gridFade * 0.17)
                if let c = cursorGround {
                    g.cursor = SIMD4(c, 1)
                } else {
                    g.cursor = SIMD4(0, 0, 0, 0)
                }
                // spacing follows the view so the grid never becomes a moire
                // field when zoomed out, nor three lines when zoomed in
                let span = host.camera.renderedDistance
                let raw = span / 12
                let mag = pow(10, (log10(max(raw, 1))).rounded(.down))
                let spacing = mag * [1, 2, 5, 10].first { mag * $0 >= raw }!
                g.tuning = SIMD4(spacing, span * 0.85, max(span * 0.075, 9), 0)
                grid = g
            }

            host.renderer.draw(in: view, commandBuffer: cb,
                               simulation: host.sim, camera: host.camera,
                               preview: ghost, grid: grid)
        }

        cb.addCompletedHandler { [weak self] _ in
            self?.inFlight.signal()
        }
        cb.commit()

        audio?.setIntensity(host.sim.intensityValue)
        audio?.setDispersal(host.sim.dispersalValue)
        updateReadouts(steps: steps)
    }

    private func updateReadouts(steps: Int) {
        guard uiMode == .engineer else { return }
        panel.updateTime(current: host.sim.currentTime)
        var fps = 0.0
        if frameTimes.count > 2, let f = frameTimes.first, let l = frameTimes.last, l > f {
            fps = Double(frameTimes.count - 1) / (l - f)
        }
        panel.updateReadouts(
            fps: String(format: "%.0f fps   %d steps/frame", fps, steps),
            stats: String(format: "%d particles\n%@",
                          host.sim.particleCount,
                          host.sim.cores.count > 1
                            ? String(format: "separation %.0f kpc",
                                     simd_length(host.sim.cores[0].position
                                                 - host.sim.cores[1].position))
                            : "single galaxy"))
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let budget: Int

    init(budget: Int) { self.budget = budget }

    func applicationDidFinishLaunching(_ note: Notification) {
        let vc = MainViewController(budget: budget)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 980)
        let w = min(1700, screen.width - 40)
        let h = min(1050, screen.height - 40)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.minSize = NSSize(width: 1000, height: 650)
        window.title = "Galaxy Collision Simulator"
        window.contentViewController = vc
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(vc.view.subviews.first)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--uitest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                do { try vc.runUIReview(output: parseArgs().out); exit(0) }
                catch { print("UI review failed: \(error)"); exit(1) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
