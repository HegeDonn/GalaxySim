import AppKit
import MetalKit
import CoreImage
import QuartzCore
import simd

/// A frozen snapshot of real simulation particles as seen from the selected star.
/// Brightness is a display proxy supplied by the caller, not a catalogue magnitude.
struct ObservatoryStar {
    var direction: SIMD3<Float>
    var color: SIMD3<Float>
    var brightness: Float
}

/// A reversible reading highlight, independent of the sky's night palette.
private final class SkyReadingLabel: NSTextField {
    private var restingText: NSAttributedString?
    private var restingColor: NSColor?
    var isReading: Bool { restingText != nil }

    func endReading() {
        guard let original = restingText else { return }
        // Status text can change while highlighted; restore its color, never old words.
        let restored = NSMutableAttributedString(attributedString: attributedStringValue)
        let color = original.length > 0
            ? original.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            : restingColor
        restored.addAttribute(.foregroundColor, value: color ?? KidsStyle.chromeInk,
                              range: NSRange(location: 0, length: restored.length))
        attributedStringValue = restored
        textColor = restingColor
        restingText = nil
        restingColor = nil
    }

    func toggleReading() {
        if isReading { endReading(); return }
        guard KidsStyle.nightVision else { return }
        restingText = attributedStringValue.copy() as? NSAttributedString
        restingColor = textColor
        let readable = NSMutableAttributedString(attributedString: attributedStringValue)
        readable.addAttribute(.foregroundColor, value: NSColor.white,
                              range: NSRange(location: 0, length: readable.length))
        attributedStringValue = readable
        textColor = .white
    }

    override func mouseDown(with event: NSEvent) { toggleReading() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// An imagined planet's night sky. The landscape/atmosphere are illustrative;
/// every point of starlight comes from the caller's simulation snapshot.
final class PlanetObservatoryView: NSView {

    /// Highest flux a star may carry onto the plate. Deliberately far above
    /// anything a display can show: see the matching clamp in the star shader.
    static let brightnessCeiling: Float = 100_000

    var onBack: (() -> Void)?
    private var landingGame: LandingGameView?
    private var hasLanded = false
    private let planetSeed: UInt32
    private let landingStars: [ObservatoryStar]
    private let sky: ObservatoryMetalView
    private let progress = NSProgressIndicator()
    private let status = SkyReadingLabel(labelWithString: "")
    private let dial = ExposureDial()
    private let shutter = ShutterButton()
    private let focal = FocalLengthToggle()
    private let toast = PhotoToast()
    /// viewDidMoveToWindow can fire more than once; the diagnostic shutter
    /// must not fire with it.
    private var autoShotFired = false
    /// Built the first time E is pressed, so a visitor who never asks for it
    /// never pays for it.
    private var tuningPanel: ObservatoryTuningPanel?
    private let menuButton = SkyMenuButton()
    /// The two things a visitor cannot do for themselves: move, and wait.
    private let relandButton = PillButton(title: "Explore this planet", symbol: "location")
    private let sleepButton = PillButton(title: "Bring up the sun", symbol: "moon.zzz")
    private let placeCard = SkyReadingLabel(wrappingLabelWithString: "")
    private let dialGlass = DialGlassView()
    private let hint = SkyReadingLabel(labelWithString: "Drag to look around · press the shutter")

    // ---- chrome that gets out of the way -------------------------------
    // The whole screen is one picture of a sky. Controls that hold full
    // strength while you stare at it are the brightest objects in the frame
    // and the eye keeps going back to them, so they retire a few seconds
    // after your hand stops and return the instant it moves. The reading
    // matter goes further back than the buttons do: you need the shutter
    // findable, you do not need a paragraph about the planet.
    private var dimControls: [NSView] = []
    private var dimText: [NSView] = []
    /// Labels whose colour comes from the palette, with the weight each is
    /// drawn at. A text field's colour is a stored value rather than
    /// something re-read at draw time, so the sun coming up has to come
    /// round and repaint them by hand.
    private var chromeLabels: [(NSTextField, CGFloat)] = []
    /// What the place card last said, so it can be re-set in a new colour.
    private var placeText = ""
    private var chromeTimer: Timer?
    private var chromeAwake = true
    private var hasInteracted = false

    init(profile: StellarProfile, stars: [ObservatoryStar]) {
        // You arrive at night, so the app arrives in red-light chrome. From
        // here the light meter has the say: turn the planet into its day and
        // the red goes with the dark, because it was only ever there to
        // protect an eye that by then has nothing left to protect.
        planetSeed = profile.planetSeed
        landingStars = stars
        KidsStyle.nightVision = true
        sky = ObservatoryMetalView(stars: stars, profile: profile)
        let air = Atmosphere.forPlanet(name: profile.name)
        sky.atmosphere = air
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(sky)
        sky.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sky.leadingAnchor.constraint(equalTo: leadingAnchor),
            sky.trailingAnchor.constraint(equalTo: trailingAnchor),
            sky.topAnchor.constraint(equalTo: topAnchor),
            sky.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // The saved frame appears in the top-right corner for a couple of
        // seconds and then leaves, so it confirms the picture without ever
        // standing between you and the sky.
        // The menu sits in the corner a phone puts its settings in, and the
        // saved-photo card drops in underneath it rather than over it.
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.onPress = { [weak self] in self?.wakeChrome(); self?.showSkyMenu() }
        addSubview(menuButton)
        toast.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toast)
        NSLayoutConstraint.activate([
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            menuButton.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            menuButton.widthAnchor.constraint(equalToConstant: 40),
            menuButton.heightAnchor.constraint(equalToConstant: 40),
            toast.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            toast.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 14)
        ])
        sky.photoBaseName = "Night near \(profile.name)"
        sky.onPhotoSaved = { [weak self] image, url in
            self?.toast.show(image: image, caption: "Saved")
            self?.status.stringValue = "Saved to \(url.deletingLastPathComponent().lastPathComponent)"
        }
        sky.onPhotoFailed = { [weak self] message in
            self?.toast.show(image: nil, caption: "Not saved")
            self?.status.stringValue = message
        }

        // Same night-sky pill as the ship's controls and the first screen.
        // A bezelled system button here was the single loudest note of the
        // app changing character between the galaxy and the planet.
        let back = PillButton(title: "Back to the stars", symbol: "chevron.left")
        back.onTap = { [weak self] in self?.goBack() }
        back.setAccessibilityLabel("Leave the planet and return to the galaxy")
        let title = SkyReadingLabel(labelWithString: "A night near \(profile.name)")
        title.font = KidsStyle.font(20, .bold)
        let home = profile.galaxyName.isEmpty ? "this galaxy" : profile.galaxyName
        let subtitle = SkyReadingLabel(labelWithString:
            "Imagined planet · " + air.name + " air · sky from " + home)
        subtitle.font = KidsStyle.font(11.5, .medium)
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 5
        let top = NSStackView(views: [back, heading])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 24
        top.translatesAutoresizingMaskIntoConstraints = false
        addSubview(top)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            top.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28)
        ])

        // ---- camera controls ---------------------------------------
        // A phone camera, not an engineering panel: choose a shutter time by
        // swiping a dial, press the button, and watch the picture develop.
        // The dial and shutter float directly over the sky — no rectangular
        // container behind them.
        dial.onSelect = { [weak self] seconds in
            guard let self else { return }
            self.handUsed()
            // Reaching for the dial mid-exposure is a decision: you are done
            // waiting. It used to change the number the plate was counting up
            // to while the plate itself kept filling, so the screen stayed
            // frozen until the original seconds ran out and the dial appeared
            // dead. It now closes the shutter where it stands -- the light
            // already gathered is a real photograph of however long it ran --
            // and the new setting is ready for the next press.
            if self.sky.shutterState == .exposing {
                let gathered = self.sky.progressFraction * self.sky.exposureSeconds
                self.sky.endExposure()
                self.shutter.isExposing = false
                self.shutter.flash()
                self.status.stringValue = String(
                    format: "Stopped at %.1f s · that is your photograph", gathered)
            }
            self.sky.exposureSeconds = seconds
            self.shutter.needsDisplay = true
        }
        shutter.onPress = { [weak self] in self?.handUsed(); self?.toggleExposure() }
        focal.onChange = { [weak self] _, halfFovTan in
            self?.handUsed()
            self?.sky.halfFovTan = halfFovTan
        }
        sky.halfFovTan = focal.currentHalfFovTan

        status.font = KidsStyle.font(12.5, .semibold)
        status.alignment = .center
        // One line, and only until you have done it once. A permanent
        // instruction is a permanent distraction.
        hint.font = KidsStyle.font(11, .medium)
        hint.alignment = .center
        chromeLabels = [(title, 1), (subtitle, 0.55), (status, 0.80), (hint, 0.45)]

        // Focal-length toggle sits to the left of the shutter, so the two
        // primary buttons are a thumb-swipe apart.
        let buttons = NSStackView(views: [focal, shutter])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 22
        let content = NSStackView(views: [dial, buttons, status, hint])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
            dial.widthAnchor.constraint(equalToConstant: 320),
            dial.heightAnchor.constraint(equalToConstant: 82),
            shutter.widthAnchor.constraint(equalToConstant: 68),
            shutter.heightAnchor.constraint(equalToConstant: 68),
            focal.widthAnchor.constraint(equalToConstant: 52),
            focal.heightAnchor.constraint(equalToConstant: 52),
        ])

        // ---- standing somewhere, and waiting there --------------------
        // One spot on a planet sees one sky. The probe lands facing the
        // galaxy, but the view from a different latitude is a different
        // picture, and the star this planet orbits is under the skyline on
        // arrival -- which is the only reason there is anything to look at.
        // These two buttons are the whole of that: go somewhere else, or
        // stay and let the ground turn.
        let star = HostStar(profile: profile)
        // Three sentences, and all three matter: where the planet sits, how
        // wide its star looks, and how much daylight arrives. Clipping the
        // last one was throwing away the punchline, so the card is given the
        // room it needs and no line limit at all.
        setPlaceCard(star.description)
        placeCard.maximumNumberOfLines = 0
        placeCard.preferredMaxLayoutWidth = 360
        placeCard.setContentCompressionResistancePriority(.required, for: .vertical)
        relandButton.onTap = { [weak self] in self?.handUsed(); self?.relandPressed() }
        sleepButton.onTap = { [weak self] in self?.handUsed(); self?.sleepPressed() }
        relandButton.setAccessibilityLabel("Show or hide the planet navigation pad")
        sleepButton.setAccessibilityLabel("Bring the sun up or return to night without moving your view")
        // Always glyphs. Their titles change with the state ("Stop here" is
        // short, "Sleep until sunrise" is not), and a control that swaps
        // between a word and an icon is a control that moves under the thumb.
        relandButton.iconOnlyOverLength = 0
        sleepButton.iconOnlyOverLength = 0
        let cornerButtons = NSStackView(views: [relandButton, sleepButton])
        cornerButtons.orientation = .horizontal
        cornerButtons.alignment = .centerY
        cornerButtons.spacing = 10
        let corner = NSStackView(views: [placeCard, cornerButtons])
        corner.orientation = .vertical
        corner.alignment = .leading
        corner.spacing = 12
        corner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(corner)
        NSLayoutConstraint.activate([
            corner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            corner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
            corner.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            corner.trailingAnchor.constraint(lessThanOrEqualTo: content.leadingAnchor,
                                             constant: -24),
        ])
        // Behind the dial, not inside it: a layer's own drawing always sits
        // under its sublayers, so a blur added to the dial would have been
        // smeared over the scale instead of the sky.
        addSubview(dialGlass, positioned: .below, relativeTo: content)
        // Tied to the dial rather than measured against it once a layout.
        // The face is a circle of 3.4 dial-heights, centred on the dial's
        // own centre line and topped out at the dial's top edge -- state
        // that, and the glass cannot drift when the stack above it shifts
        // by a few points. It used to, and the two rims read as one arc
        // slightly off another.
        dialGlass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dialGlass.widthAnchor.constraint(equalTo: dial.heightAnchor, multiplier: 6.8),
            dialGlass.heightAnchor.constraint(equalTo: dialGlass.widthAnchor),
            dialGlass.centerXAnchor.constraint(equalTo: dial.centerXAnchor),
            dialGlass.topAnchor.constraint(equalTo: dial.topAnchor),
        ])

        dimControls = [top, menuButton, cornerButtons, content, dialGlass]
        dimText = [placeCard, hint]
        paintChrome()
        wakeChrome()

        sky.onTurnEnded = { [weak self] line in
            guard let self else { return }
            self.status.stringValue = line
            self.updateSleepTitle()
        }

        sky.onProgress = { [weak self] amount, moving, state in
            guard let self else { return }
            // A hand on the glass, or a plate still filling: either way the
            // person is using this screen and the chrome stays up.
            if moving || state == .exposing { self.wakeChrome() }
            self.applyNightVision()
            self.shutter.progress = CGFloat(amount)
            let open = state == .exposing
            if self.shutter.isExposing && !open {
                self.shutter.flash()
                self.status.stringValue = "Photograph taken"
            }
            self.shutter.isExposing = open
            self.shutter.needsDisplay = true
            let auto = self.sky.autoShutter
            self.dial.autoSeconds = auto
            switch state {
            case .idle:
                if let auto {
                    // Worth saying out loud rather than leaving as a number
                    // on a dial: this is the one thing about photographing a
                    // sky that surprises people. Daylight is not a brighter
                    // version of night, it is a different order of magnitude,
                    // and the shutter has to be a different order of
                    // magnitude back.
                    self.status.stringValue = String(
                        format: "Daylight · the camera is choosing the shutter for you · %@ s",
                        ObservatoryMetalView.speedText(auto))
                } else {
                    self.status.stringValue = moving
                        ? "Find a view you like"
                        : "Press the shutter to gather light"
                }
            case .exposing:
                // Seconds, not a percentage: the number on the dial is the
                // number the plate is counting up to, and the light on it is
                // the light those seconds actually collected.
                let full = self.sky.shutterSeconds
                let gathered = amount * full
                if full < ObservatoryMetalView.dialFloorSeconds {
                    self.status.stringValue = "Daylight · the shutter is already shut again"
                } else {
                    self.status.stringValue = moving
                        ? String(format: "Exposing %.1f s · drawing trails", gathered)
                        : String(format: "Exposing %.1f of %@ s · press again to stop",
                                 gathered, ObservatoryMetalView.speedText(full))
                }
            case .developed:
                // Left alone on purpose: the transition above wrote
                // "Photograph taken", and the save handler replaces it with
                // where the file went. Repainting it here every frame would
                // wipe that out before it could be read.
                break
            }
        }
        status.stringValue = "Press the shutter to gather light"
    }

    /// One press opens the shutter; it closes by itself when the dial's
    /// seconds have been gathered. Pressing again before then cuts the
    /// exposure short, the way a cable release ends a bulb frame. Holding the
    /// button down is not part of it — a 60 s exposure is not something a
    /// hand should have to sit through.
    private func toggleExposure() {
        if landingGame != nil { dismissLandingGame() }
        if sky.shutterState == .exposing {
            sky.endExposure()
            status.stringValue = "Photograph taken"
        } else {
            sky.beginExposure()
            status.stringValue = sky.shutterSeconds < ObservatoryMetalView.dialFloorSeconds
                ? "Daylight · the shutter is already shut again"
                : String(format: "Exposing… %.0f s", sky.shutterSeconds)
        }
        shutter.isExposing = sky.shutterState == .exposing
        shutter.needsDisplay = true
    }
    @objc private func relandPressed() {
        if landingGame == nil { showLandingGame() } else { dismissLandingGame() }
    }

    private func showLandingGame() {
        guard landingGame == nil else { return }
        sky.isPaused = false
        let game = LandingGameView(site: sky.site, heart: sky.galaxyHeart,
                                   stars: landingStars, fieldOfView: sky.halfFovTan, atmosphere: sky.atmosphere, seed: planetSeed)
        game.embedded = true
        if hasLanded { game.resume(at: sky.site) }
        else { sky.land(at: game.navigation.site); hasLanded = true }
        sky.prepareNavigation(heading: game.navigation.heading)
        game.onNavigate = { [weak self] site, heading in
            guard let self else { return }
            self.sky.navigate(at: site, heading: heading)
            self.shutter.isExposing = false
            self.shutter.needsDisplay = true
        }
        game.onCancel = { [weak self] in self?.dismissLandingGame() }
        game.onIdle = { [weak game] in game?.restNavigation() }
        game.onLand = { [weak self] site in self?.finishLanding(at: site) }
        landingGame = game
        addSubview(game)
        needsLayout = true
        window?.makeFirstResponder(game)
    }

    private func finishLanding(at site: LandingSite) {
        sky.land(at: site)
        hasLanded = true
        shutter.isExposing = false
        shutter.needsDisplay = true
        updateSleepTitle()
        status.stringValue = "Touchdown — your skyline is waiting"
        dismissLandingGame()
    }

    private func dismissLandingGame() {
        landingGame?.stop()
        landingGame?.removeFromSuperview()
        landingGame = nil
        sky.isPaused = false
        window?.makeFirstResponder(self)
        wakeChrome()
    }

    func focusControls() { window?.makeFirstResponder(landingGame ?? self) }
    var reviewLookDirection: SIMD3<Float> { sky.reviewDirection }
    func reviewTurnNavigator(_ angle: Float) { landingGame?.reviewTurn(angle) }
    func reviewPressShutter() { toggleExposure() }
    func reviewKeepNavigatorAwake() { landingGame?.reviewKeepsAwake = true }
    var reviewSkyPose: SIMD4<Float> { sky.reviewPose }
    var reviewNavigatorResting: Bool { landingGame?.isResting == true }
    var reviewLandingGameVisible: Bool { landingGame != nil }
    func reviewStartLanding() { landingGame?.beginLanding() }
    func reviewOpenLanding() { showLandingGame() }
    func reviewCancelLanding() { landingGame?.onCancel?() }
    var reviewLandingControlsFit: Bool { landingGame?.reviewControlsFit ?? false }
    func reviewPlanetTuning() -> Bool { landingGame?.reviewTuning() ?? false }
    func reviewClosePlanetTuning() { landingGame?.reviewCloseTuning() }
    func reviewCloudTime(_ time: Float?) { landingGame?.reviewCloudTime(time) }
    var reviewLandingSurfaceReady: Bool { landingGame?.reviewWaitForSurface() ?? false }
    var reviewLandingFlightControls: Bool { landingGame?.reviewFlightControls() ?? false }
    func reviewLandingAtmosphere(_ air: Atmosphere?) { landingGame?.reviewAtmosphere(air ?? sky.atmosphere) }
    func reviewMoveLanding(to p: SIMD2<Float>) { landingGame?.reviewMove(to: p) }
    var reviewChosenAltitude: Float { landingGame.map { $0.navigation.site.altitude(of: sky.galaxyHeart) } ?? -2 }
    var reviewLandingSite: LandingSite { sky.site }

    func reviewLandAtChosenSpot() {
        if let game = landingGame { finishLanding(at: game.navigation.site) }
    }

    /// A second press stops the gentle lighting transition in place.
    @objc private func sleepPressed() {
        if landingGame != nil { dismissLandingGame() }
        if sky.isTurning {
            sky.stopTurning()
            updateSleepTitle()
            status.stringValue = "Stopped there"
            return
        }
        status.stringValue = sky.sleep()
        shutter.isExposing = false
        shutter.needsDisplay = true
        sleepButton.title = "Stop here"
        sleepButton.symbolName = "stop.fill"
        sleepButton.setAccessibilityLabel("Stop the lighting transition")
    }

    /// The words live in the tooltip and the accessibility label now, so the
    /// glyph has to carry the state change on its own: a waiting moon while
    /// the ground is still, a stop square while it is turning.
    private func updateSleepTitle() {
        sleepButton.title = sky.starIsUp ? "Bring back night" : "Bring up the sun"
        sleepButton.symbolName = "moon.zzz"
        sleepButton.setAccessibilityLabel(
            "Move the sun until it " + (sky.starIsUp ? "sets" : "rises"))
    }

    /// Entry point for the auto-shoot diagnostic: a single press, exactly as
    /// a hand would give it. The exposure ends itself.
    private func takePhoto() { toggleExposure() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Put the current palette on everything that stores a colour instead of
    /// reading one. The controls draw themselves from the palette and only
    /// need telling that it moved, which `KidsStyle.nightVision` does.
    private func paintChrome() {
        for (label, weight) in chromeLabels {
            (label as? SkyReadingLabel)?.endReading()
            label.toolTip = "Click to read in white; click again to return to red"
            label.textColor = KidsStyle.chromeInk.withAlphaComponent(weight)
        }
        setPlaceCard(placeText)
    }

    /// Red light is worth its ugliness only while the sky is dark, and the
    /// meter already knows. Standing in daylight the app looks like the rest
    /// of the app; walk the planet round to night and it turns red.
    private func applyNightVision() {
        guard sky.isDark != KidsStyle.nightVision else { return }
        KidsStyle.nightVision = sky.isDark
        paintChrome()
    }

    override func layout() {
        super.layout()
        landingGame?.frame = NSRect(x: bounds.width - 205, y: 18, width: 190, height: 290)
    }

    // MARK: - chrome that gets out of the way

    /// Called by anything that counts as using the screen. Brings the chrome
    /// back and restarts the clock.
    func wakeChrome() {
        chromeTimer?.invalidate()
        if !chromeAwake {
            chromeAwake = true
            fadeChrome(controls: 1, text: 1, over: 0.18)
        }
        chromeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) {
            [weak self] _ in self?.retireChrome()
        }
    }

    private func retireChrome() {
        guard chromeAwake else { return }
        chromeAwake = false
        // Slow on the way out so it reads as the screen settling rather than
        // as something vanishing.
        fadeChrome(controls: 0.42, text: 0.10, over: 1.2)
    }

    private func fadeChrome(controls: CGFloat, text: CGFloat, over: TimeInterval) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = over
            ctx.allowsImplicitAnimation = true
            for v in dimControls { v.animator().alphaValue = controls }
            for v in dimText { v.animator().alphaValue = text }
        }
    }

    /// Anything the hand actually pressed. Also retires the one-line hint:
    /// you have now done the thing it was telling you to do.
    private func handUsed() {
        if !hasInteracted {
            hasInteracted = true
            dimText.removeAll { $0 === hint }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.9
                hint.animator().alphaValue = 0
            }
        }
        wakeChrome()
    }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sky.isPaused = window == nil
        if window != nil {
            if !hasLanded { showLandingGame() }
            else { window?.makeFirstResponder(self) }
        } else { landingGame?.stop() }
        // GALAXYSIM_AUTOSHOOT=<seconds> presses the shutter by itself, so the
        // developed frame can be reviewed without a hand on the mouse.
        if ProcessInfo.processInfo.environment["GALAXYSIM_TUNE"] != nil,
           window != nil, tuningPanel == nil {
            toggleTuningPanel()
        }
        if let d = ProcessInfo.processInfo.environment["GALAXYSIM_AUTOSHOOT"],
           let delay = Double(d), window != nil, !autoShotFired {
            autoShotFired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.takePhoto()
            }
        }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: goBack()                                   // esc
        case 14 where !event.modifierFlags.contains(.command): toggleTuningPanel()  // E
        default: super.keyDown(with: event)
        }
    }

    /// The menu behind the corner button: three skies to choose from, and a
    /// way down to the sliders for anyone who wants them. Presets come first
    /// because almost nobody wants seventeen numbers — they want the sky to
    /// look different, and to be told what the difference is.
    private func showSkyMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Choose a sky", action: nil, keyEquivalent: "")
            .isEnabled = false
        let current = ObservatoryTuning.current.matchingPreset?.name
        for preset in ObservatoryTuning.presets {
            let item = NSMenuItem(title: preset.name,
                                  action: #selector(choosePreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.name
            item.toolTip = preset.blurb
            item.state = preset.name == current ? .on : .off
            // The blurb is the point: a name alone tells nobody what
            // "Storybook sky" is going to do to their picture.
            item.attributedTitle = NSAttributedString(string: preset.name + "\n" + preset.blurb,
                attributes: [.font: KidsStyle.font(13, .regular)])
            menu.addItem(item)
        }
        if current == nil {
            let item = NSMenuItem(title: "Your own settings", action: nil, keyEquivalent: "")
            item.state = .on
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let engineering = NSMenuItem(title: tuningPanel?.isHidden == false
                                     ? "Hide the sliders" : "All the numbers…",
                                     action: #selector(toggleTuningFromMenu), keyEquivalent: "e")
        engineering.keyEquivalentModifierMask = []
        engineering.target = self
        menu.addItem(engineering)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: menuButton.bounds.minY - 6), in: menuButton)
    }

    @objc private func choosePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let preset = ObservatoryTuning.presets.first(where: { $0.name == name })
        else { return }
        ObservatoryTuning.current = preset.values
        tuningPanel?.refresh()
        sky.needsDisplay = true
        status.stringValue = preset.name + " · " + preset.blurb
    }

    @objc private func toggleTuningFromMenu() { toggleTuningPanel() }

    /// The engineering panel. Behind the menu and the E key, never in the way:
    /// the sky belongs to whoever is looking at it, and a wall of sliders is
    /// the fastest way to make that person feel it does not.
    func toggleTuningPanel() {
        if let panel = tuningPanel {
            panel.isHidden.toggle()
            if !panel.isHidden { panel.refresh() }
            sky.needsDisplay = true
            return
        }
        let panel = ObservatoryTuningPanel()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onChange = { [weak self] _ in self?.sky.needsDisplay = true }
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 110),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -160),
            panel.widthAnchor.constraint(equalToConstant: 300),
        ])
        tuningPanel = panel
        status.stringValue = "Engineering panel open · press E to hide it"
    }
    func stop() {
        landingGame?.stop()
        sky.isPaused = true
        sky.onProgress = nil
        chromeTimer?.invalidate()
        chromeTimer = nil
        KidsStyle.nightVision = false
    }
    var exposureProgress: Float { sky.progressFraction }
    var renderError: String? { sky.renderError }
    /// MTK display callbacks may not run inside the synchronous UI-review
    /// harness. Explicitly render and wait for a real GPU frame before capture.
    private func setPlaceCard(_ text: String) {
        placeCard.endReading()
        placeCard.toolTip = "Click to read in white; click again to return to red"
        placeText = text
        let cardStyle = NSMutableParagraphStyle()
        cardStyle.lineSpacing = 2.5
        placeCard.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: KidsStyle.font(11.5, .medium),
                         .foregroundColor: KidsStyle.chromeInk.withAlphaComponent(0.66),
                         .paragraphStyle: cardStyle])
    }

    /// Whether the frosted disc still sits exactly on the face the dial
    /// draws. Two circles of the same size a few points apart read as a
    /// double rim, which is what a drifting glass looked like.
    var reviewReadingToggle: Bool {
        guard let label = chromeLabels.first?.0 as? SkyReadingLabel else { return false }
        let original = label.attributedStringValue
        let color = label.textColor
        label.toggleReading()
        let becameWhite = label.isReading && label.textColor == NSColor.white
        label.toggleReading()
        let restored = !label.isReading && label.textColor == color
            && label.attributedStringValue.isEqual(to: original)
        let card = placeCard.attributedStringValue
        placeCard.toggleReading()
        let cardWhite = placeCard.isReading && placeCard.textColor == NSColor.white
        placeCard.toggleReading()
        return becameWhite && restored && cardWhite
            && placeCard.attributedStringValue.isEqual(to: card)
    }

    var reviewGlassOnFace: Bool {
        let want = convert(dial.faceRect, from: dial)
        let got = dialGlass.frame
        return abs(want.minX - got.minX) < 0.5 && abs(want.minY - got.minY) < 0.5
            && abs(want.width - got.width) < 0.5 && abs(want.height - got.height) < 0.5
    }

    /// Every pill the review is allowed to poke at, found by walking the
    /// tree rather than by listing them here -- a hand-written list stops
    /// testing the day somebody adds a button.
    var reviewTouchTargets: [PillButton] {
        var found: [PillButton] = []
        var queue = subviews
        while let v = queue.popLast() {
            if let pill = v as? PillButton, !pill.isHidden { found.append(pill) }
            queue.append(contentsOf: v.subviews)
        }
        return found
    }

    @discardableResult
    func reviewDraw() -> Bool {
        // Screenshots want the chrome at full strength; a review run takes
        // longer than the fade-out clock.
        wakeChrome()
        layoutSubtreeIfNeeded()
        let result = sky.drawForReview()
        applyNightVision()
        dial.autoSeconds = sky.autoShutter
        progress.doubleValue = Double(sky.progressFraction)
        status.stringValue = sky.progressFraction >= 1 ? "The sky is yours. Take your time."
            : "Gathering starlight…"
        return result
    }
    /// Deterministic diagnostics use the same accumulation update as draw().
    /// The shutter has to be open for the plate to fill, exactly as in use.
    @discardableResult
    func reviewExposure(seconds: Float, openFor elapsed: Float) -> Float {
        let bounded = max(0.2, min(60, seconds))
        dial.select(seconds: Double(bounded))
        sky.savesPhotos = false
        sky.exposureSeconds = Float(bounded)
        sky.beginExposure()
        // What the plate is told to gather is what the shutter gathered, not
        // how long the check held it open. Those were the same number while
        // the dial was the only thing setting the speed; under a metered
        // daylight shutter they are not, and handing the raw elapsed time to
        // the plate lays four seconds of sunlight onto a thirtieth-of-a-
        // second exposure -- the white rectangle again, this time only in
        // the photograph.
        sky.reviewFrameSeconds = sky.advanceExposure(elapsed: elapsed, moving: false)
        shutter.isExposing = sky.shutterState == .exposing
        return sky.progressFraction
    }
    /// Drive the dial the way a hand does, for the diagnostic that checks a
    /// turn mid-exposure closes the shutter rather than freezing the screen.
    func reviewTurnDial(to seconds: Float) {
        dial.select(seconds: Double(seconds))
        dial.onSelect?(seconds)
    }
    var reviewIsExposing: Bool { sky.shutterState == .exposing }
    /// The speed the camera took for itself, or nil while the dial is in
    /// charge.
    var reviewAutoShutter: Float? { sky.autoShutter }
    /// Stand under a Sun-like star and let the frame be read back.
    func reviewSunlikeHost() {
        sky.keepsReadableFrame = true
        sky.useSunlikeHost()
        // The card has to follow the star, or the screenshot argues with
        // itself: a sunlit frame under three sentences about a dim red dwarf.
        let card = sky.hostDescription
        if !card.isEmpty { setPlaceCard(card) }
    }
    /// A shutter speed written the way a dial writes one.
    static func reviewSpeedText(_ seconds: Float) -> String {
        ObservatoryMetalView.speedText(seconds)
    }
    /// Share of the developed frame pinned to white.
    var reviewClippedFraction: Float { sky.clippedFraction() }
    /// Turn the camera right round, which is what broke it: with the sun out
    /// of frame the reading falls, and handing the shutter back to a dial
    /// sitting on four seconds blew the same daylight out all over again.
    /// Two draws, because the meter reads the frame before the one it
    /// informs -- the first turns the camera, the second is metered for it.
    func reviewLookAway() {
        sky.turnAround()
        reviewDraw()
        reviewDraw()
    }

    /// Review harness: land again, and take a whole night's turn in one step.
    func reviewReland() { showLandingGame(); reviewLandAtChosenSpot() }
    func reviewSleep() { _ = sky.sleep(); sky.finishTurn() }
    /// Sine of the altitude of the host star and of the galaxy's bulge.
    var reviewStarAltitude: Float { sky.starAltitude }
    var reviewGalaxyAltitude: Float { sky.galaxyAltitude }
    /// What is actually in front of the camera, and what is in the richest
    /// direction there is. A sky that photographs empty is either aimed at
    /// nothing or drawing nothing, and only this tells the two apart.
    var reviewSkyCensus: String {
        let ahead = sky.starsWithin(25, of: sky.viewDirection)
        let bulge = sky.starsWithin(25, of: sky.heart)
        return String(format: "census: up %d · ahead %d (flux %.0f) · at the bulge %d (flux %.0f)",
                      sky.starsUp, ahead.count, ahead.flux, bulge.count, bulge.flux)
    }
    var reviewStarsAhead: Int { sky.starsWithin(25, of: sky.viewDirection).count }
    var reviewStarsUp: Int { sky.starsUp }

    /// Put the camera back to a live viewfinder at a given dial setting, so
    /// the preview curve can be photographed the way the exposures are. The
    /// shutter stays shut: this is what you see BEFORE pressing it.
    func reviewViewfinder(seconds: Float) {
        sky.endExposure()
        sky.dismissReview()
        dial.select(seconds: Double(seconds))
        sky.exposureSeconds = max(0.2, min(60, seconds))
        sky.reviewFrameSeconds = 0
        shutter.isExposing = false
    }
    /// Movement used to throw the frame away. It must not any more: the plate
    /// is a real integral, so swinging the lens writes trails into the light
    /// already gathered rather than discarding it.
    @discardableResult
    func reviewKeepsLightWhileMoving(for elapsed: Float) -> Float {
        let gathered = sky.advanceExposure(elapsed: elapsed, moving: true)
        sky.reviewFrameSeconds = (sky.reviewFrameSeconds ?? 0) + gathered
        return sky.progressFraction
    }
    @objc private func goBack() { stop(); onBack?() }
    private func applyExposure(_ seconds: Double) {
        sky.exposureSeconds = Float(seconds)
    }
}

private struct ObservatoryGPUStar {
    var direction: SIMD4<Float>
    var color: SIMD4<Float>
}
private struct ObservatoryUniforms {
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var forward: SIMD4<Float>
    var optics: SIMD4<Float> // aspect, tan(half FOV), drawable width, height
    var exposure: SIMD4<Float>
    /// Where the camera pointed on the PREVIOUS frame. A star is drawn as the
    /// capsule swept between its old and new screen positions, which is what
    /// turns a moved camera into a trail rather than a dotted line.
    var prevRight: SIMD4<Float> = SIMD4(1, 0, 0, 0)
    var prevUp: SIMD4<Float> = SIMD4(0, 1, 0, 0)
    var prevForward: SIMD4<Float> = SIMD4(0, 0, -1, 0)
    /// xyz galactic plane normal, w dust opacity
    var plane: SIMD4<Float> = SIMD4(0, 1, 0, 0)
    /// airglow, light pollution, noise, seed
    var sky: SIMD4<Float> = SIMD4(1, 1, 0.012, 0) // airglow, horizon, noise, grain seed
    /// Extinction per airmass (R G B), w = airglow falloff
    var air: SIMD4<Float> = SIMD4(0.10, 0.16, 0.28, 9.5)
    var airglowColour: SIMD4<Float> = SIMD4(0.00048, 0.00092, 0.00062, 0)
    var horizonColour: SIMD4<Float> = SIMD4(0.00082, 0.00058, 0.00038, 0)
    var zenithColour: SIMD4<Float> = SIMD4(0.000115, 0.000140, 0.000240, 0)
    /// The ground under the probe's feet, in galaxy coordinates: which way is
    /// east, which way is north, which way is up. Everything to do with the
    /// skyline, with how much air a ray crossed, and with where the sun
    /// stands is measured in this frame rather than against the simulation's
    /// own +Y, which belongs to the galaxy and not to any planet in it.
    var east: SIMD4<Float> = SIMD4(1, 0, 0, 0)
    var north: SIMD4<Float> = SIMD4(0, 0, -1, 0)
    var zenith: SIMD4<Float> = SIMD4(0, 1, 0, 0)
    /// xyz the host star's direction, w its angular RADIUS in radians
    var sun: SIMD4<Float> = SIMD4(0, -1, 0, 0.00465)
    /// xyz photosphere hue, w its radiance
    var sunTint: SIMD4<Float> = SIMD4(1, 0.96, 0.90, 4000)
    /// x sunlight arriving (Earth = 1), y sky radiance per Earth-sunlight
    var sunLight: SIMD4<Float> = SIMD4(1, 320, 0, 0)
    /// The engineering panel's numbers, packed four to a register. Every
    /// frame overwrites these from `ObservatoryTuning.current`; the values
    /// here are only what a bare struct starts life with. See
    /// `ObservatoryTuning` for what each one does.
    var tune0: SIMD4<Float> = SIMD4(0.115, 2.5, 1.6, 1) // gain, white, bleed, grain
    var tune1: SIMD4<Float> = SIMD4(1.25, 1, 100_000, 0.34) // gamma, scale, ceiling, flux
    var tune2: SIMD4<Float> = SIMD4(0.55, 0.35, 0.16, 120) // base, slope, reach, spike on
    var tune3: SIMD4<Float> = SIMD4(1400, 1, 3, 1)    // spike full, meteors, preview floor, preview lift
}

private final class ObservatoryMetalView: MTKView, MTKViewDelegate {
    var onProgress: ((Float, Bool, Shutter) -> Void)?
    /// What the dial is set to. Not necessarily what the shutter does: see
    /// `shutterSeconds`.
    var exposureSeconds: Float = 4 { didSet { accumulated = 0 } }

    // ---- the light meter -------------------------------------------
    // The dial runs from a quarter of a second to a minute, and those stops
    // are right for a night sky -- which is the only sky this camera was
    // ever pointed at while it was being built. Then someone slept until
    // sunrise on a world one AU from a Sun-like star, and every stop on the
    // dial returned the same white rectangle. That is not a bug in the dial.
    // A quarter of a second does exactly that to a sunlit landscape on any
    // camera ever made; daylight wants a thousandth, and the dial does not
    // go there.
    //
    // So the camera meters, and when the light is past anything the dial can
    // hold it picks the speed itself and says so. It does not do that at
    // night: a night sky here meters at around seven seconds, and clamping
    // those stops would have made 15, 30 and 60 all mean seven and taken the
    // star trails with them. Those stops are the photographer's.
    //
    // Engaging on the reading alone was not enough, though. The meter reads
    // the frame, and a frame with the sun in it is a great deal brighter
    // than the same daylight with the sun behind you -- so turning away
    // dropped the reading back over the line, handed the camera to a dial
    // still sitting on four seconds, and blew the picture out again. A
    // camera does not do that. Daylight is daylight whichever way it is
    // pointed, so once the light has asked for a speed the dial cannot
    // reach, the meter keeps the shutter until the light has genuinely gone
    // -- three stops past the floor, which no daylight reaches and no night
    // misses -- and in between it simply follows the light, above the floor
    // as readily as below it.

    /// The dial's shortest stop, and the line the meter takes over at.
    static let dialFloorSeconds: Float = 0.25
    /// And the line it gives the dial back at: three stops slower, so that
    /// turning away from the sun cannot hand a four-second dial a sunlit
    /// landscape. Nothing in daylight meters this slow; nothing at night
    /// meters faster.
    static let dialReturnSeconds: Float = 2
    /// The fastest the shutter is allowed to go. Every camera has one.
    static let fastestShutterSeconds: Float = 1.0 / 8000
    /// Developed value the meter aims the average of the frame at. Middle
    /// grey, the card every light meter has been calibrated against since
    /// they were needles -- and middle grey is not half way up. It is about
    /// a fifth of the way, because the develop pass raises everything to
    /// 1/2.2 afterwards and a fifth comes out of that at very nearly half.
    /// Aiming at 0.5 before the gamma lands the average at 0.73 on screen,
    /// which is a photograph of a sunny day taken a stop and a half too
    /// slow: exactly the complaint this meter exists to answer.
    private static let meterTarget: Float = 0.2

    /// Log-average scene luminance from the last frame the meter saw, in the
    /// same linear units the plate integrates. Zero means "not yet read".
    private var meterKey: Float = 0

    /// Dark enough that a lit screen would cost you the sky.
    ///
    /// Not "the sun is down": the twilight after sunset is still bright
    /// enough to read by, and on a world that receives half a percent of
    /// Earth's daylight the whole *day* meters darker than our dusk. The
    /// meter is the honest instrument here -- it is already measuring the
    /// light falling on this landscape -- so the question is simply what
    /// exposure the scene is asking for. Latched on the same two lines the
    /// shutter uses, so the chrome cannot flicker between red and blue while
    /// the view drifts past a bright horizon.
    private(set) var isDark = true

    /// Whether the meter is holding the shutter. Latched, with the two lines
    /// above for edges: it takes over when the light asks for a speed the
    /// dial has not got, and does not let go until the light has fallen far
    /// past anything daylight does.
    private var autoHolds = false

    /// The exposure the light is asking for, unsnapped -- or nil before the
    /// first reading.
    // An incident-light estimate: same daylight exposure for every camera bearing.
    // Dim suns still select the dial's 1/4-second stop rather than a night exposure.
    private var daylightShutter: Float? {
        guard site.altitude(of: site.sun) > 0 else { return nil }
        let tune = ObservatoryTuning.current
        let light = max(Float(host?.insolation ?? 1) * tune.dayScale / 320, 0.00001)
        return max(Self.fastestShutterSeconds, min(Self.dialFloorSeconds, (1.0 / 30) / light))
    }
    private var meteredSeconds: Float? {
        if let daylightShutter { return daylightShutter }
        guard meterKey > 0 else { return nil }
        let tune = ObservatoryTuning.current
        let gain = max(tune.plateGain, 1e-5)
        let white = max(tune.whitePoint, 0.05)
        // Invert the extended Reinhard the develop pass applies, so the
        // meter aims at a developed value rather than at a raw one and
        // follows the white point if it is ever retuned.
        //   dev = E(1 + E/k^2) / (1 + E)  ->  E^2/k^2 + E(1-dev) - dev = 0
        let d = Self.meterTarget
        let k2 = white * white
        let e = 0.5 * k2 * ((1 - d) * (1 - d) + 4 * d / k2).squareRoot() - 0.5 * k2 * (1 - d)
        let wanted = e / max(meterKey * gain, 1e-9)
        return wanted.isFinite ? wanted : nil
    }

    /// Decide who is holding the shutter, once per reading.
    private func updateAutoHold() {
        guard let wanted = meteredSeconds else { autoHolds = false; return }
        if wanted <= Self.dialFloorSeconds { autoHolds = true }
        else if wanted > Self.dialReturnSeconds { autoHolds = false }
        isDark = isDark ? wanted > Self.dialFloorSeconds : wanted >= Self.dialReturnSeconds
    }

    /// The shutter the light is asking for, or nil while the dial is still in
    /// charge. Reported to the interface so the reading on the dial is the
    /// speed the camera will actually use.
    var autoShutter: Float? {
        if let daylightShutter { return Self.snap(daylightShutter) }
        guard autoHolds, let wanted = meteredSeconds else { return nil }
        return Self.snap(max(wanted, Self.fastestShutterSeconds))
    }

    /// The speeds a shutter dial has been marked in since they were marked at
    /// all. Snapping to them costs under a sixth of a stop and buys a reading
    /// a person recognises: "1/30" is a shutter speed, "1/29" is a number a
    /// computer printed. It runs past the dial's floor at the slow end,
    /// because a metered shutter does: look away from the sun and the same
    /// daylight asks for a stop or two more.
    private static let fastStops: [Float] = [
        1.0/8000, 1.0/4000, 1.0/2000, 1.0/1000, 1.0/500, 1.0/250,
        1.0/125, 1.0/60, 1.0/30, 1.0/15, 1.0/8, 1.0/4, 1.0/2, 1, 2,
    ]
    private static func snap(_ seconds: Float) -> Float {
        // Nearest in log space, which is how stops are spaced.
        fastStops.min { abs(log2($0 / seconds)) < abs(log2($1 / seconds)) } ?? seconds
    }

    /// A shutter speed written the way one is written: "4" and "0.25" on the
    /// dial's own ground, "1/250" below it.
    static func speedText(_ seconds: Float) -> String {
        if seconds >= 1 { return String(format: "%.0f", seconds) }
        if seconds >= 0.5 { return String(format: "%.1f", seconds) }
        if seconds >= Self.dialFloorSeconds { return String(format: "%.2f", seconds) }
        return "1/" + String(Int((1 / max(seconds, 1e-6)).rounded()))
    }

    /// The shutter that actually opens: the dial, unless the light is past
    /// anything on it. Everything downstream -- the plate, the progress ring,
    /// the grain -- is driven from here rather than from the dial.
    var shutterSeconds: Float {
        min(exposureSeconds, autoShutter ?? .greatestFiniteMagnitude)
    }

    /// How much the viewfinder brightens the live picture over what the
    /// shutter would actually record. A compressed preview of the dial while
    /// the dial is in charge -- 0.25 s looks like 1.3 s of light, 60 s like
    /// 34 s of it, so every stop does something visible -- and exactly 1 the
    /// moment the meter takes over, where the correct exposure is already on
    /// the screen and lifting it would only blow it out.
    var previewLift: Float {
        guard autoShutter == nil else { return 1 }
        let tune = ObservatoryTuning.current
        return max(1, tune.previewFloor * pow(max(exposureSeconds, 0.01), -0.4))
    }

    /// Forget the reading. Landing somewhere else, or turning the planet
    /// through a sunrise, changes the light by orders of magnitude, and a
    /// meter that eased into that would spend a second showing the wrong
    /// exposure for the wrong sky.
    ///
    /// A reading may already be in flight when this is called from outside
    /// the draw -- pressing the button that moves the probe, for one -- and
    /// that reading belongs to the sky being left behind. It is marked to be
    /// thrown away rather than disarmed, because the frame carrying it is
    /// still writing to the texture and encoding another pass over the top
    /// of it would be a race.
    func resetMeter() {
        meterKey = 0
        autoHolds = false
        meterStale = meterArmed
    }

    /// Take the reading off the frame that has just landed.
    ///
    /// One frame of lag, which is what a real meter has as well: it reports
    /// the light that was there a moment ago. It only runs while the shutter
    /// is shut, because that is when the plate holds instantaneous radiance
    /// -- and because a camera meters before it opens, not during.
    @discardableResult
    private func pollMeter() -> Bool {
        // A diagnostic waits for the reading rather than catching it if it
        // happens to have landed. Live, a frame that misses the readback
        // simply meters on the next one; in a review it would mean the
        // shutter depends on how fast the machine running it is, which is
        // how the same check came back 1/30 on one run and 1/15 on the
        // next.
        if reviewFrameSeconds != nil { lastCommand?.waitUntilCompleted() }
        guard meterArmed, let meterTexture, lastCommand?.status == .completed else { return false }
        meterArmed = false
        if meterStale { meterStale = false; return false }
        var pixel = SIMD4<Float>(repeating: 0)
        withUnsafeMutableBytes(of: &pixel) { raw in
            meterTexture.getBytes(raw.baseAddress!, bytesPerRow: 16,
                                  from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        let key = pixel.x
        guard key.isFinite, key > 0 else { return false }
        let first = meterKey <= 0
        // Eased, so that panning past a bright horizon does not make the
        // whole sky pump; a sunrise still takes hold within a second. The
        // first reading after a reset lands whole, because there is nothing
        // to ease from -- and so does every reading under a diagnostic,
        // where a number that depends on how many frames have gone by is no
        // use to a check.
        meterKey = first || reviewFrameSeconds != nil
            ? key : meterKey + (key - meterKey) * 0.25
        updateAutoHold()
        return first
    }
    private var queue: MTLCommandQueue?
    private var lastCommand: MTLCommandBuffer?
    private(set) var renderError: String?
    func drawForReview() -> Bool {
        layoutSubtreeIfNeeded()
        guard bounds.width > 0, bounds.height > 0 else {
            renderError = "The observatory drawable has no size."
            return false
        }
        let scale = window?.backingScaleFactor ?? 1
        drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        lastCommand = nil
        draw()
        guard let command = lastCommand else {
            if renderError == nil { renderError = "No observatory frame was encoded; check drawable/window availability." }
            return false
        }
        command.waitUntilCompleted()
        if command.status != .completed {
            renderError = command.error?.localizedDescription ?? "Observatory GPU frame did not complete."
            return false
        }
        // The meter reads a frame that has already landed, so the frame just
        // rendered is the one being measured, not the one it informs. Live
        // that is a frame of lag and invisible. Here it would mean a still
        // captured at the shutter chosen for whatever was on screen before,
        // so the viewfinder is drawn again once the reading arrives. Only
        // while the shutter is shut: with it open, a second pass would lay
        // the same seconds onto the plate twice.
        if pollMeter(), shutterState == .idle { return drawForReview() }
        CATransaction.flush()
        return true
    }
    private var skyPipeline: MTLRenderPipelineState?
    private var starPipeline: MTLRenderPipelineState?
    private var downPipeline: MTLRenderPipelineState?
    private var blurPipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var meterPipeline: MTLRenderPipelineState?
    /// One pixel, read back on the CPU: the meter's last reading.
    private var meterTexture: MTLTexture?
    /// True while a frame carrying a fresh meter reading is still in flight.
    private var meterArmed = false
    /// True when the reading in flight was taken before the sky changed.
    private var meterStale = false
    /// Linear HDR plate, then four octaves of bleed.
    private var hdr: MTLTexture?
    private var mip: [MTLTexture] = []
    private var mipTemp: [MTLTexture] = []
    private var plateSize: CGSize = .zero
    /// Normal of the plane the stars lie in, for the dust lane.
    private var planeNormal = SIMD4<Float>(0, 1, 0, 0)
    /// Fixed for the life of one exposure.
    private var grainSeed: Int = Int.random(in: 0..<9973)
    /// This planet's air. Fixed at landing.
    var atmosphere = Atmosphere.all[1]
    /// Vertical half-FOV tangent — swapped by the focal-length toggle.
    /// Default matches roughly a 21mm lens on a full-frame sensor.
    var halfFovTan: Float = 0.5714 { didSet { needsDisplay = true } }
    private var starsBuffer: MTLBuffer?
    private var starCount = 0
    /// The exposure plate: radiance INTEGRATED over the open shutter. 32-bit
    /// float because a 30 s frame at 60 fps sums 1800 increments, and in
    /// 16-bit the later ones fall below the running total's precision and
    /// simply stop registering.
    private var accum: MTLTexture?
    private var shown: MTLTexture?
    private var accumPipeline: MTLRenderPipelineState?
    private var meteorPipeline: MTLRenderPipelineState?
    private var needsAccumClear = true
    private var pendingCapture = false
    private var capturing = false
    /// The self-check drives real exposures; it must not leave real files in
    /// the user's Pictures folder behind it.
    var savesPhotos = true
    /// Diagnostics advance the clock in jumps rather than at 60 fps. With this
    /// set, one rendered frame lays down that many seconds of light, so a
    /// review screenshot shows the exposure the check asked for instead of the
    /// microseconds the harness actually spent.
    var reviewFrameSeconds: Float?
    /// Basis of the previous frame, for the swept star trails.
    private var prevBasis: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)?
    /// Name the saved file is built from, and where the picture goes.
    var photoBaseName = "Night sky"
    var onPhotoSaved: ((NSImage, URL) -> Void)?
    var onPhotoFailed: ((String) -> Void)?

    // ---- meteors -------------------------------------------------------
    /// One streak, as the GPU sees it: the arc swept during THIS frame only.
    /// Under an open shutter those per-frame arcs lay down end to end and
    /// become a single continuous streak on the plate -- the same way the
    /// real thing records.
    private struct MeteorGPU {
        var a: SIMD4<Float>
        var b: SIMD4<Float>
        var tint: SIMD4<Float>   // rgb + brightness
    }
    private struct MeteorLive {
        var from: SIMD3<Float>
        var to: SIMD3<Float>
        var start: Double
        var duration: Double
        var brightness: Float
        var tint: SIMD3<Float>
    }
    private var meteors: [MeteorLive] = []
    private var nextMeteor: Double = 0
    private var meteorBuffer: MTLBuffer?
    private var meteorCount = 0
    private static let meteorSlots = 12
    /// Roughly one every half-minute to minute, as asked. Short-circuited by
    /// GALAXYSIM_METEORRATE so the effect can be checked without waiting.
    private static var meteorGap: ClosedRange<Double> = {
        if let v = ProcessInfo.processInfo.environment["GALAXYSIM_METEORRATE"],
           let d = Double(v), d > 0.2 { return (d * 0.6)...(d * 1.4) }
        return 28.0...64.0
    }()
    /// GALAXYSIM_AUTOPAN=<radians per second> drifts the view while the
    /// shutter is open, so a trailed exposure can be produced and inspected
    /// without a hand on the mouse.
    private static let autoPan: Float =
        Float(ProcessInfo.processInfo.environment["GALAXYSIM_AUTOPAN"] ?? "") ?? 0
    var reviewDirection: SIMD3<Float> { site.east * (sin(yaw)*cos(pitch)) + site.north * (cos(yaw)*cos(pitch)) + site.zenith*sin(pitch) }
    var reviewPose: SIMD4<Float> { SIMD4(yaw, pitch, galaxyAltitude, site.spin) }
    private var yaw: Float = 0
    private var pitch: Float = 0.35

    // ---- where the probe is standing ------------------------------
    /// The direction of the galaxy's brightest quarter, in galaxy
    /// coordinates. Everything about the landing is arranged around it.
    private(set) var heart = SIMD3<Float>(1, 0, 0)
    /// Every eighth star, kept on the CPU. A screenshot cannot tell an empty
    /// patch of sky from a broken renderer; this can.
    private var census: [(d: SIMD3<Float>, b: Float)] = []
    /// Which way is up here, which way the planet turns, where its star is.
    var galaxyHeart: SIMD3<Float> { heart }
    private(set) var site = LandingSite(axis: SIMD3(0, 1, 0), zenith0: SIMD3(0, 1, 0),
                                        east0: SIMD3(1, 0, 0), north0: SIMD3(0, 0, -1),
                                        sun: SIMD3(0, -1, 0))
    /// The star this planet belongs to: how far out we stand, and how it
    /// looks from there.
    private(set) var host: HostStar?

    // Photography lighting transition; the camera and ground remain fixed.
    private var sunFrom = SIMD3<Float>(0, -1, 0)
    private var sunTo = SIMD3<Float>(0, 1, 0)
    private var spinPhase: Float = 1          // 1 = standing still
    private var spinDuration: Float = 5.5
    /// True while the sunlight is transitioning.
    var isTurning: Bool { spinPhase < 1 }
    /// Called once the turn has eased to a stop, with a line about it.
    var onTurnEnded: ((String) -> Void)?
    private var accumulated: Float = 0
    private var lastTime = CACurrentMediaTime()
    private var lastMovement = -Double.infinity
    private var lastUIUpdate = -Double.infinity
    private var dragging = false
    var progressFraction: Float { min(accumulated / max(shutterSeconds, 1e-4), 1) }
    /// Begin a new exposure: reset the accumulation and pick fresh grain.
    func beginExposure() {
        accumulated = 0
        grainSeed = Int.random(in: 0..<9973)
        needsAccumClear = true
        shutterState = .exposing
    }

    /// Finish a hand-held exposure early. The plate keeps whatever light was
    /// gathered and drops into the developed state so the composite shader
    /// applies grain, vignetting and chromatic aberration.
    func endExposure() {
        guard shutterState == .exposing else { return }
        finishExposure()
    }

    /// Throw away whatever is on the plate without developing or saving it.
    /// Turning the ground or moving to another spot under an open shutter
    /// does not produce a photograph, it ruins one.
    func abandonExposure() {
        shutterState = .idle
        accumulated = 0
        needsAccumClear = true
    }

    /// Set the probe down somewhere else on the planet: a new pole, a new
    /// latitude, a new time of night, and the camera already facing the
    /// galaxy. The sky itself is untouched -- these are the same stars from
    /// the same star, seen by someone standing somewhere else.
    func reland() {
        var rng = SystemRandomNumberGenerator()
        land(at: LandingSite.choose(heart: heart, rng: &rng), horizonFirst: false)
    }

    /// Adopt the pad's heading without changing where the camera is looking.
    func prepareNavigation(heading: SIMD3<Float>) {
        let forward = site.east * sin(yaw) + site.north * cos(yaw)
        site = LandingSite(axis: site.axis, zenith0: site.zenith,
                           east0: simd_normalize(simd_cross(heading, site.zenith)),
                           north0: heading, sun: site.sun, dayLength: site.dayLength)
        yaw = atan2(simd_dot(forward, site.east), simd_dot(forward, site.north))
    }

    /// Parallel-transport the camera with the ship, including turns in place.
    func navigate(at chosen: LandingSite, heading: SIMD3<Float>) {
        abandonExposure(); dismissReview()
        site = LandingSite(axis: site.axis, zenith0: chosen.zenith,
                           east0: simd_normalize(simd_cross(heading, chosen.zenith)),
                           north0: heading, sun: site.sun, dayLength: site.dayLength)
        lastMovement = CACurrentMediaTime()
    }

    func land(at chosen: LandingSite, horizonFirst: Bool = true) {
        site = chosen
        let opening = site.aim(at: heart)
        yaw = opening.yaw
        pitch = horizonFirst ? 0.18 : max(-0.05, min(1.40, opening.pitch))
        spinPhase = 1
        abandonExposure()
        dismissReview()
        resetMeter()
        grainSeed = Int.random(in: 0..<9973)
        meteors.removeAll()
        nextMeteor = 0
        prevBasis = nil
        lastMovement = CACurrentMediaTime()
    }

    /// Move the sun for photography without rotating the galaxy or camera.
    @discardableResult
    func sleep() -> String {
        let wantsDaylight = site.altitude(of: site.sun) <= 0.01
        sunFrom = site.sun
        let horizontal = site.east * sin(yaw) + site.north * cos(yaw)
        sunTo = simd_normalize(horizontal * 0.8 + site.zenith * (wantsDaylight ? 0.6 : -0.6))
        spinPhase = 0
        spinDuration = 2.0
        abandonExposure()
        dismissReview()
        meteors.removeAll()
        prevBasis = nil
        return wantsDaylight ? "Bringing your star above the horizon" : "Returning to night"
    }

    /// Stop the light source where it is.
    func stopTurning() {
        guard spinPhase < 1 else { return }
        spinPhase = 1
        lastMovement = CACurrentMediaTime()
    }

    /// Finish the lighting transition immediately for deterministic reviews.
    func finishTurn() {
        guard spinPhase < 1 else { return }
        spinPhase = 1
        site.sun = sunTo
        prevBasis = nil
        resetMeter()
    }

    /// Review harness: put a Sun-like star one AU away overhead.
    ///
    /// The star a landing gets is whichever one the explorer clicked, and the
    /// review has been clicking dim ones: a planet that had to back off from
    /// a red dwarf receives a fraction of a percent of Earth's daylight, and
    /// the dial handles that without complaint. The ordinary case -- a G star
    /// at one AU, the case a child is most likely to pick on purpose -- was
    /// never in the review until it turned up as a white rectangle.
    /// Point the camera at the opposite horizon.
    func turnAround() { yaw += .pi; lastMovement = CACurrentMediaTime() }

    /// The three sentences on the card, so a review that changes the star can
    /// change them with it.
    var hostDescription: String { host?.description ?? "" }

    func useSunlikeHost() {
        for index in 0..<4096 {
            let p = StellarProfile.make(index: index,
                                        population: ParticleKind.oldDisk.rawValue)
            guard abs(p.temperature - 5772) < 1, abs(p.solarLuminosity - 1) < 0.01 else { continue }
            host = HostStar(profile: p)
            resetMeter()
            return
        }
    }

    /// Keep the developed frame readable on the CPU, for the checks that ask
    /// what actually came out rather than only whether a frame came out.
    var keepsReadableFrame = false

    /// What share of the developed frame is pinned to white.
    ///
    /// A screenshot cannot be asserted on, and "the picture is a white
    /// rectangle" is not something a frame-completed check can see. This is
    /// the one number that would have caught it.
    func clippedFraction() -> Float {
        guard let shown else { return 0 }
        lastCommand?.waitUntilCompleted()
        let w = shown.width, h = shown.height
        guard w > 0, h > 0 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            shown.getBytes(raw.baseAddress!, bytesPerRow: w * 4,
                           from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var clipped = 0, counted = 0
        // Every eighth pixel each way. A sixty-fourth of the frame settles a
        // fraction to well under a percent and keeps the check quick.
        for y in stride(from: 0, to: h, by: 8) {
            for x in stride(from: 0, to: w, by: 8) {
                let i = (y * w + x) * 4
                counted += 1
                if bytes[i] > 248 && bytes[i + 1] > 248 && bytes[i + 2] > 248 { clipped += 1 }
            }
        }
        return counted > 0 ? Float(clipped) / Float(counted) : 0
    }

    /// Sines of altitude: positive is above the skyline.
    var starAltitude: Float { site.altitude(of: site.sun) }
    var galaxyAltitude: Float { site.altitude(of: heart) }
    /// Is the host star up right now?
    var starIsUp: Bool { starAltitude > 0 }

    /// Where the camera is looking, in galaxy coordinates.
    var viewDirection: SIMD3<Float> {
        simd_normalize(site.east * (sin(yaw) * cos(pitch))
                       + site.zenith * sin(pitch)
                       + site.north * (cos(yaw) * cos(pitch)))
    }
    /// How much sky there is in a given direction: how many of the thinned
    /// stars fall within `degrees` of it, and how much light they carry.
    /// The screenshots cannot distinguish "aimed at an empty patch" from
    /// "the stars stopped drawing", and that difference matters.
    func starsWithin(_ degrees: Float, of direction: SIMD3<Float>) -> (count: Int, flux: Float) {
        let d = simd_normalize(direction)
        let limit = cos(degrees * .pi / 180)
        var count = 0
        var flux: Float = 0
        for star in census where simd_dot(star.d, d) >= limit {
            count += 1
            flux += star.b
        }
        return (count * 8, flux * 8)
    }
    /// Stars above the skyline, by the same thinned count.
    var starsUp: Int { census.reduce(0) { $0 + (site.altitude(of: $1.d) > 0 ? 8 : 0) } }

    /// Pull the developed frame off the GPU and write it to disk as a PNG.
    /// Runs on the command buffer's completion handler, so it is off the
    /// render thread by the time it touches the filesystem.
    private func writePhoto(from texture: MTLTexture) {
        let w = texture.width, h = texture.height
        guard w > 0, h > 0 else { capturing = false; return }
        let rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result: (NSImage, URL)? = Self.encodePNG(
                bytes: bytes, width: w, height: h, rowBytes: rowBytes,
                baseName: self.photoBaseName)
            DispatchQueue.main.async {
                self.capturing = false
                if let (image, url) = result { self.onPhotoSaved?(image, url) }
                else { self.onPhotoFailed?("The picture could not be saved.") }
            }
        }
    }

    /// The drawable is BGRA8; `byteOrder32Little` + `noneSkipFirst` is what
    /// reads those bytes back as RGB in the order Core Graphics expects.
    private static func encodePNG(bytes: [UInt8], width: Int, height: Int,
                                  rowBytes: Int, baseName: String) -> (NSImage, URL)? {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: rowBytes,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let folder = pictures.appendingPathComponent("GalaxySim", isDirectory: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safe = baseName.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
        let url = folder.appendingPathComponent("\(safe) \(stamp.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url)
        } catch { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        return (image, url)
    }

    /// What the camera is doing.
    ///
    /// The sky used to brighten by itself whenever you held still, which meant
    /// there was never a moment of taking a photograph. A camera in the dark
    /// shows you a dim viewfinder and nothing else until you press the button.
    enum Shutter { case idle, exposing, developed }
    private(set) var shutterState: Shutter = .idle
    /// How long the finished frame stays on screen before the viewfinder
    /// comes back, the way a camera holds a shot for review after the
    /// shutter closes. Touching the controls cuts it short.
    static let reviewSeconds = 2.8
    private var developedAt = -Double.infinity

    /// Drop the frozen frame and return to the live viewfinder.
    func dismissReview() {
        guard shutterState == .developed else { return }
        shutterState = .idle
        accumulated = 0
        needsAccumClear = true
    }

    /// Returns the seconds of light this actually gathered, which is not the
    /// same as the seconds offered: the last frame of an exposure is clipped
    /// to whatever was left on the dial. The plate is weighted by the number
    /// that comes back, so it ends up holding exactly the exposure asked for.
    @discardableResult
    func advanceExposure(elapsed: Float, moving: Bool) -> Float {
        // Moving no longer abandons the frame. The plate is a real integral
        // now, so swinging the lens during a 30 s exposure does what it does
        // on a real camera: it writes the star field across the frame as
        // trails. Throwing the exposure away on movement was the only reason
        // that could not happen.
        guard shutterState == .exposing else { return 0 }
        let before = accumulated
        let full = max(shutterSeconds, 1e-4)
        accumulated = min(full, accumulated + max(0, elapsed))
        if accumulated >= full { finishExposure() }
        return accumulated - before
    }

    /// The plate is full (or the shutter was let go): freeze it and hand the
    /// developed frame to whoever wants to save it.
    private func finishExposure() {
        guard shutterState == .exposing else { return }
        shutterState = .developed
        developedAt = CACurrentMediaTime()
        pendingCapture = savesPhotos
    }

    /// A fresh streak. Meteors enter high and travel a chord across the sky;
    /// the colour leans to the metal that is burning -- sodium yellow, iron
    /// orange, magnesium blue-white.
    private func makeMeteor(now: Double) -> MeteorLive {
        func unit() -> SIMD3<Float> {
            let z = Float.random(in: 0.08...0.95)          // start well above the skyline
            let a = Float.random(in: 0..<Float.pi * 2)
            let r = (1 - z * z).squareRoot()
            return SIMD3(r * cos(a), z, r * sin(a))
        }
        let from = unit()
        // Travel a chord of 0.3-1.0 rad in a random direction on the sphere.
        let ref: SIMD3<Float> = abs(from.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let t1 = simd_normalize(simd_cross(ref, from))
        let t2 = simd_cross(from, t1)
        let a = Float.random(in: 0..<Float.pi * 2)
        let arc = Float.random(in: 0.30...1.00)
        let dir = t1 * cos(a) + t2 * sin(a)
        let to = simd_normalize(from * cos(arc) + dir * sin(arc))
        let palette: [SIMD3<Float>] = [
            SIMD3(1.00, 0.94, 0.78),   // common: iron/nickel white
            SIMD3(1.00, 0.78, 0.36),   // sodium yellow
            SIMD3(0.72, 1.00, 0.70),   // magnesium green
            SIMD3(1.00, 0.55, 0.30),   // slow, orange
        ]
        // Why this is thousands of times a star's number, and not a mistake:
        // a star sits on the same pixel for the whole exposure, so 4 seconds
        // of its light lands there. A meteor crosses that pixel in about
        // three milliseconds. For the streak to leave a mark comparable to a
        // bright star's dot, its instantaneous brightness has to exceed that
        // star's by roughly the ratio of those two times -- which is what a
        // real fireball, at magnitude -4 against magnitude +4 stars, actually
        // does. It also means a meteor is relatively fainter in a 60 s frame
        // than in a 4 s one, exactly as meteor photographers find.
        return MeteorLive(from: from, to: to, start: now,
                          duration: Double.random(in: 0.35...1.15),
                          brightness: Float.random(in: 4_000...26_000),
                          tint: palette.randomElement() ?? SIMD3(1, 1, 1))
    }

    /// Advance the streaks and pack the arc each one covers during this frame.
    private func updateMeteors(now: Double, dt: Double) {
        // The first streak should not be a special case: arriving on the
        // planet starts the same clock every later one runs on, so the
        // diagnostic rate applies to it too.
        if nextMeteor == 0 { nextMeteor = now + Double.random(in: Self.meteorGap) * 0.35 }
        if now >= nextMeteor {
            nextMeteor = now + Double.random(in: Self.meteorGap)
            if meteors.count < Self.meteorSlots { meteors.append(makeMeteor(now: now)) }
        }
        meteors.removeAll { now > $0.start + $0.duration }
        guard let meteorBuffer else { meteorCount = 0; return }
        let ptr = meteorBuffer.contents().bindMemory(to: MeteorGPU.self,
                                                     capacity: Self.meteorSlots)
        var n = 0
        for m in meteors where n < Self.meteorSlots {
            let u1 = Float((now - m.start) / m.duration)
            let u0 = Float((now - dt - m.start) / m.duration)
            guard u1 > 0 else { continue }
            let c0 = max(0, min(1, u0)), c1 = max(0, min(1, u1))
            let d0 = simd_normalize(simd_mix(m.from, m.to, SIMD3(repeating: c0)))
            let d1 = simd_normalize(simd_mix(m.from, m.to, SIMD3(repeating: c1)))
            // Brightest in the middle of the fall, as ablation peaks there.
            let mid = (c0 + c1) * 0.5
            let env = powf(sinf(Float.pi * mid), 0.7)
            ptr[n] = MeteorGPU(a: SIMD4(d0, 0), b: SIMD4(d1, 0),
                               tint: SIMD4(m.tint, m.brightness * env))
            n += 1
        }
        meteorCount = n
    }

    init(stars: [ObservatoryStar], profile: StellarProfile) {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.002, 0.003, 0.008, 1)
        preferredFramesPerSecond = 60
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = true
        delegate = self
        setAccessibilityLabel("Night sky. Drag to look around, then hold still to gather starlight.")
        guard let device else { renderError = "Metal device unavailable"; showFailure("This night sky needs Metal graphics."); return }
        queue = device.makeCommandQueue()
        let valid = stars.prefix(900_000).filter {
            allFinite($0.direction) && simd_length_squared($0.direction) > 1e-12
                && allFinite($0.color) && $0.brightness.isFinite && $0.brightness > 0
        }
        let packed = valid.map { star in
            ObservatoryGPUStar(direction: SIMD4(simd_normalize(star.direction), 0),
                color: SIMD4(simd_clamp(star.color, SIMD3(repeating: 0), SIMD3(repeating: 1)),
                             min(star.brightness, PlanetObservatoryView.brightnessCeiling)))
        }
        starCount = packed.count

        // Find the plane the stars lie in, so the dust lane can follow the
        // galaxy rather than being drawn at an arbitrary angle. The normal is
        // the least-variance axis of the direction distribution: for a disc
        // seen from inside, that is the pole.
        if valid.count > 32 {
            var m = simd_float3x3(0)
            // Where the sky is richest, by counting rather than averaging.
            //
            // The obvious trick -- average a few hundred thousand unit
            // directions and call the result the bulge -- is wrong, and
            // wrong in a way that looks plausible until you photograph it.
            // A star sitting a little off the disc's midplane sees far more
            // of the galaxy on one side than the other, and that up/down
            // asymmetry is much larger than the excess toward the centre.
            // The mean therefore points very nearly along the disc's normal:
            // straight out of the galaxy, at the emptiest patch of sky
            // there is. A landing built around it opened on 416 stars where
            // an evenly-spread sky would have shown 28,000.
            //
            // So: bin the directions, smooth over the width of a camera's
            // view, and take the peak. Equal-area bins, because that is what
            // makes a count a density -- longitude is uniform and so is the
            // cosine, which is what `y` already is for a unit vector.
            let azBins = 64, yBins = 32
            var histogram = [Float](repeating: 0, count: azBins * yBins)
            census.reserveCapacity(valid.count / 8 + 1)
            for (index, star) in valid.enumerated() {
                let d = simd_normalize(star.direction)
                if index % 8 == 0 { census.append((d, star.brightness)) }
                let az = (atan2(d.z, d.x) + .pi) / (2 * .pi)
                let ay = (d.y + 1) * 0.5
                let i = min(azBins - 1, max(0, Int(az * Float(azBins))))
                let j = min(yBins - 1, max(0, Int(ay * Float(yBins))))
                histogram[j * azBins + i] += 1
                m += simd_float3x3(SIMD3(d.x*d.x, d.x*d.y, d.x*d.z),
                                   SIMD3(d.y*d.x, d.y*d.y, d.y*d.z),
                                   SIMD3(d.z*d.x, d.z*d.y, d.z*d.z))
            }
            func binDirection(_ i: Int, _ j: Int) -> SIMD3<Float> {
                let az = (Float(i) + 0.5) / Float(azBins) * 2 * .pi - .pi
                let y = (Float(j) + 0.5) / Float(yBins) * 2 - 1
                let r = (max(0, 1 - y * y)).squareRoot()
                return SIMD3(r * cos(az), y, r * sin(az))
            }
            var centres = [SIMD3<Float>]()
            centres.reserveCapacity(azBins * yBins)
            for j in 0..<yBins { for i in 0..<azBins { centres.append(binDirection(i, j)) } }
            // A 25-degree cone: about what the camera takes in, so the peak
            // is the best PICTURE rather than the single densest pixel.
            let cone = cos(25 * Float.pi / 180)
            var best = 0
            var bestScore: Float = -1
            for a in 0..<centres.count {
                var score: Float = 0
                for b in 0..<centres.count where simd_dot(centres[a], centres[b]) >= cone {
                    score += histogram[b]
                }
                if score > bestScore { bestScore = score; best = a }
            }
            // Centre it properly: the mean of the stars actually in that
            // cone, which lands on the middle of the glow instead of on a
            // bin edge.
            var centroid = SIMD3<Float>(repeating: 0)
            for star in census where simd_dot(star.d, centres[best]) >= cone { centroid += star.d }
            if simd_length_squared(centroid) > 1e-8 {
                heart = simd_normalize(centroid)
            } else if simd_length_squared(centres[best]) > 1e-8 {
                heart = simd_normalize(centres[best])
            }
            let inv = 1 / Float(valid.count)
            m = m * inv
            // inverse power iteration: repeatedly pull a vector toward the
            // smallest eigenvector by subtracting the dominant components
            var v = SIMD3<Float>(0, 1, 0)
            for _ in 0..<64 {
                let mv = m * v
                var next = v - mv * 1.4
                let len = simd_length(next)
                if len < 1e-6 { next = SIMD3(0, 1, 0) } else { next /= len }
                v = next
            }
            planeNormal = SIMD4(simd_normalize(v), 0.85)
        }

        // The probe picks its own pole rather than borrowing the galaxy's,
        // and lands facing the galaxy. Before this the planet's zenith was
        // the simulation's +Y axis, the disc lies close to its XZ plane, and
        // so the best half of the sky spent its time behind the hills.
        host = HostStar(profile: profile)
        var rng = SystemRandomNumberGenerator()
        site = LandingSite.choose(heart: heart, rng: &rng)
        let opening = site.aim(at: heart)
        yaw = opening.yaw
        pitch = max(-0.05, min(1.40, opening.pitch))
        if !packed.isEmpty {
            starsBuffer = packed.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
        }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let sky = MTLRenderPipelineDescriptor()
            sky.vertexFunction = library.makeFunction(name: "skyVertex")
            sky.fragmentFunction = library.makeFunction(name: "nightSky")
            // Sky and stars accumulate into a linear HDR plate; only the
            // final composite writes display pixels.
            sky.colorAttachments[0].pixelFormat = .rgba16Float
            skyPipeline = try device.makeRenderPipelineState(descriptor: sky)
            let points = MTLRenderPipelineDescriptor()
            points.vertexFunction = library.makeFunction(name: "nightStarVertex")
            points.fragmentFunction = library.makeFunction(name: "nightStarFragment")
            points.colorAttachments[0].pixelFormat = .rgba16Float
            points.colorAttachments[0].isBlendingEnabled = true
            points.colorAttachments[0].sourceRGBBlendFactor = .one
            points.colorAttachments[0].destinationRGBBlendFactor = .one
            points.colorAttachments[0].sourceAlphaBlendFactor = .zero
            points.colorAttachments[0].destinationAlphaBlendFactor = .one
            starPipeline = try device.makeRenderPipelineState(descriptor: points)

            func post(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: "skyVertex")
                d.fragmentFunction = library.makeFunction(name: fragment)
                d.colorAttachments[0].pixelFormat = format
                return try device.makeRenderPipelineState(descriptor: d)
            }
            let acc = MTLRenderPipelineDescriptor()
            acc.vertexFunction = library.makeFunction(name: "skyVertex")
            acc.fragmentFunction = library.makeFunction(name: "obsAccumulate")
            acc.colorAttachments[0].pixelFormat = .rgba32Float
            acc.colorAttachments[0].isBlendingEnabled = true
            acc.colorAttachments[0].sourceRGBBlendFactor = .one
            acc.colorAttachments[0].destinationRGBBlendFactor = .one
            acc.colorAttachments[0].sourceAlphaBlendFactor = .zero
            acc.colorAttachments[0].destinationAlphaBlendFactor = .one
            accumPipeline = try device.makeRenderPipelineState(descriptor: acc)

            let met = MTLRenderPipelineDescriptor()
            met.vertexFunction = library.makeFunction(name: "meteorVertex")
            met.fragmentFunction = library.makeFunction(name: "meteorFragment")
            met.colorAttachments[0].pixelFormat = .rgba16Float
            met.colorAttachments[0].isBlendingEnabled = true
            met.colorAttachments[0].sourceRGBBlendFactor = .one
            met.colorAttachments[0].destinationRGBBlendFactor = .one
            met.colorAttachments[0].sourceAlphaBlendFactor = .zero
            met.colorAttachments[0].destinationAlphaBlendFactor = .one
            meteorPipeline = try device.makeRenderPipelineState(descriptor: met)
            meteorBuffer = device.makeBuffer(
                length: MemoryLayout<MeteorGPU>.stride * Self.meteorSlots,
                options: .storageModeShared)

            meterPipeline = try post("obsMeter", .rgba32Float)
            downPipeline = try post("obsDown", .rgba16Float)
            blurPipeline = try post("obsBlur", .rgba16Float)
            compositePipeline = try post("obsComposite", colorPixelFormat)
        } catch {
            renderError = error.localizedDescription
            showFailure("The night sky could not open. You can return to the galaxy.")
            print("Planet observatory Metal: \(error)")
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func allFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
    private func showFailure(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 450)
        ])
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        // Reaching for the view is the same as saying you are done looking at
        // the last frame, so the viewfinder comes back immediately.
        dismissReview()
        dragging = true
        lastMovement = CACurrentMediaTime()
    }
    override func mouseDragged(with event: NSEvent) {
        yaw -= Float(event.deltaX) * 0.004
        pitch = max(-0.10, min(1.48, pitch + Float(event.deltaY) * 0.004))
        lastMovement = CACurrentMediaTime()
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        lastMovement = CACurrentMediaTime()
    }
    override func scrollWheel(with event: NSEvent) {
        // Trackpad momentum keeps sending deltas for a second after the
        // fingers lift. Live that is pleasant; with the shutter open it would
        // write trails nobody asked for, so an open shutter only follows a
        // hand that is still on the glass.
        if shutterState == .exposing && event.momentumPhase != [] { return }
        dismissReview()
        yaw -= Float(event.scrollingDeltaX) * 0.002
        pitch = max(-0.10, min(1.48, pitch + Float(event.scrollingDeltaY) * 0.002))
        lastMovement = CACurrentMediaTime()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    /// Allocate the HDR plate and the bleed pyramid.
    private func ensurePlates(_ size: CGSize) {
        guard size != plateSize, size.width > 1, size.height > 1, let device else { return }
        plateSize = size
        func make(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: max(w,1), height: max(h,1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let w = Int(size.width), h = Int(size.height)
        hdr = make(w, h)
        if let d = device as MTLDevice? {
            let a = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: max(w,1), height: max(h,1), mipmapped: false)
            a.usage = [.renderTarget, .shaderRead]
            a.storageMode = .private
            accum = d.makeTexture(descriptor: a)
            needsAccumClear = true
            // The composite lands here first so the finished frame can be
            // read back and written to disk; it is then copied to the
            // drawable. A drawable cannot be read after it is presented.
            let c = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorPixelFormat, width: max(w,1), height: max(h,1), mipmapped: false)
            c.usage = [.renderTarget, .shaderRead]
            c.storageMode = .managed
            shown = d.makeTexture(descriptor: c)
        }
        if meterTexture == nil, let d = device as MTLDevice? {
            // One pixel, and managed so the CPU may read it. It does not
            // depend on the drawable size, so it outlives every resize.
            let m = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
            m.usage = [.renderTarget, .shaderRead]
            m.storageMode = .managed
            meterTexture = d.makeTexture(descriptor: m)
        }
        mip.removeAll(); mipTemp.removeAll()
        var lw = w, lh = h
        for _ in 0..<4 {
            lw = max(1, lw/2); lh = max(1, lh/2)
            if let a = make(lw, lh), let b = make(lw, lh) { mip.append(a); mipTemp.append(b) }
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let queue,
              let skyPipeline, let starPipeline,
              let downPipeline, let blurPipeline, let compositePipeline,
              let command = queue.makeCommandBuffer() else { return }
        ensurePlates(drawableSize)
        guard let hdr, mip.count == 4 else { return }
        pollMeter()

        let time = CACurrentMediaTime()
        let dt = reviewFrameSeconds ?? Float(min(max(time - lastTime, 0), 0.1))
        lastTime = time
        let moving = dragging || time - lastMovement < 0.12
        if shutterState == .developed, time - developedAt > Self.reviewSeconds {
            dismissReview()
        }
        // Seconds of light this frame lays down. It comes from the shutter
        // rather than from the frame clock, so the frame that closes the
        // shutter still contributes -- gating on the state afterwards dropped
        // it, and an exposure shorter than one frame collected nothing at all.
        // Under a diagnostic the progress is driven by the check itself, so
        // advancing it here as well would count those seconds twice.
        let gathered: Float
        if let synthetic = reviewFrameSeconds {
            gathered = shutterState == .idle ? 0 : synthetic
        } else {
            gathered = advanceExposure(elapsed: dt, moving: moving)
        }
        let fraction = progressFraction
        updateMeteors(now: time, dt: Double(dt))

        if Self.autoPan != 0, shutterState == .exposing {
            yaw += Self.autoPan * dt
            lastMovement = time
        }

        // Ease the light source across the sky without moving the camera.
        if spinPhase < 1 {
            spinPhase = min(1, spinPhase + dt / max(spinDuration, 0.01))
            let eased = 1 - pow(1 - spinPhase, 3)
            let rotation = simd_quatf(from: sunFrom, to: sunTo)
            site.sun = simd_slerp(simd_quatf(angle: 0, axis: site.zenith), rotation, eased).act(sunFrom)
            lastMovement = time
            if spinPhase >= 1 {
                // Sunrise: a hundred thousand times the light there was at
                // the start of the turn. Ease into that and the first second
                // after dawn is metered for the night it just left.
                resetMeter()
                let risen = site.altitude(of: site.sun) > 0
                onTurnEnded?(risen
                    ? "Your star is up"
                    : "Night again")
            }
        }

        // The camera stands on the ground, so its basis is built in the
        // ground's frame rather than against the simulation's +Y axis.
        let east = site.east, north = site.north, zenith = site.zenith
        let forward = simd_normalize(east * (sin(yaw) * cos(pitch))
                                     + zenith * sin(pitch)
                                     + north * (cos(yaw) * cos(pitch)))
        let right = simd_normalize(east * cos(yaw) - north * sin(yaw))
        let up = simd_cross(right, forward)

        // A trail is a record of the camera having moved, so a camera that did
        // not move must leave none. Below a third of a pixel at the frame
        // centre there was no movement -- only the last bits of a float -- and
        // the previous basis is snapped to the current one so the stars are
        // drawn as points, exactly as they were before any of this existed.
        let stored = prevBasis ?? (right, up, forward)
        prevBasis = (right, up, forward)
        let pxPerRadian = Float(drawableSize.height) * 0.5 / max(halfFovTan, 1e-3)
        let swing = (simd_length(forward - stored.2) + simd_length(right - stored.0))
                  * pxPerRadian
        let prev = swing > 0.33 ? stored : (right, up, forward)
        let tune = ObservatoryTuning.current
        var uniforms = ObservatoryUniforms(
            right: SIMD4(right, 0), up: SIMD4(up, 0), forward: SIMD4(forward, 0),
            optics: SIMD4(Float(drawableSize.width / max(drawableSize.height, 1)),
                          halfFovTan, Float(drawableSize.width), Float(drawableSize.height)),
            // x seconds, y fraction, z viewfinder/photo blend, w unused
            exposure: SIMD4(shutterSeconds, fraction,
                            shutterState == .idle ? 0 : 1, 0),
            prevRight: SIMD4(prev.0, 0),
            prevUp: SIMD4(prev.1, 0),
            prevForward: SIMD4(prev.2, 0),
            plane: SIMD4(planeNormal.x, planeNormal.y, planeNormal.z,
                         planeNormal.w * tune.dustScale),
            // A longer shutter gathers more airglow and more noise, exactly as
            // it gathers more starlight.
            sky: SIMD4((0.55 + 0.45 * fraction) * atmosphere.airglowStrength
                         * tune.airglowScale,
                       0.85,
                       0.004 + 0.016 * sqrt(shutterSeconds / 30),
                       // Grain belongs to the EXPOSURE, not to the frame. It
                       // was reseeded 12 times a second, which turned a
                       // photograph's fixed grain into live television static.
                       // It now only changes when a new exposure begins.
                       Float(grainSeed)),
            air: SIMD4(atmosphere.extinction, atmosphere.airglowFalloff),
            airglowColour: SIMD4(atmosphere.airglow, 0),
            horizonColour: SIMD4(atmosphere.horizonGlow, 0),
            zenithColour: SIMD4(atmosphere.zenith, 0),
            east: SIMD4(east, 0), north: SIMD4(north, 0), zenith: SIMD4(zenith, 0),
            sun: SIMD4(site.sun, Float(host?.angularRadius ?? 0.00465)),
            // A photosphere's radiance depends on temperature and nothing
            // else. The clamp is the plate's: half floats stop at 65504, and
            // a 35,000 K surface asks for a great deal more than that.
            sunTint: SIMD4(host?.chroma ?? SIMD3(1, 0.96, 0.90),
                           min(Float(host?.surfaceBrightness ?? 1) * tune.sunDiscScale,
                               60_000)),
            sunLight: SIMD4(Float(host?.insolation ?? 1), tune.dayScale, 0, 0),
            tune0: SIMD4(tune.plateGain, tune.whitePoint, tune.bleedScale, tune.grainScale),
            tune1: SIMD4(tune.starGamma, tune.starScale, tune.starCeiling, tune.fluxScale),
            tune2: SIMD4(tune.sizeBase, tune.sizeSlope, tune.sizeReach, tune.spikeOnset),
            tune3: SIMD4(tune.spikeFull, tune.meteorScale, tune.previewFloor,
                         previewLift))

        // ---- pass 1: sky and stars into the linear plate
        let plate = MTLRenderPassDescriptor()
        plate.colorAttachments[0].texture = hdr
        plate.colorAttachments[0].loadAction = .clear
        plate.colorAttachments[0].storeAction = .store
        plate.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let e = command.makeRenderCommandEncoder(descriptor: plate) {
            e.setRenderPipelineState(skyPipeline)
            e.setFragmentBytes(&uniforms, length: MemoryLayout<ObservatoryUniforms>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if let starsBuffer, starCount > 0 {
                e.setRenderPipelineState(starPipeline)
                e.setVertexBuffer(starsBuffer, offset: 0, index: 0)
                e.setVertexBytes(&uniforms, length: MemoryLayout<ObservatoryUniforms>.stride, index: 1)
                // six vertices per star: quads, so the sprite can carry
                // diffraction spikes and power-law wings
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: starCount * 6)
            }
            if let meteorPipeline, let meteorBuffer, meteorCount > 0 {
                e.setRenderPipelineState(meteorPipeline)
                e.setVertexBuffer(meteorBuffer, offset: 0, index: 0)
                e.setVertexBytes(&uniforms, length: MemoryLayout<ObservatoryUniforms>.stride, index: 1)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meteorCount * 6)
            }
            e.endEncoding()
        }

        // ---- pass 1b: integrate onto the plate
        // This is the whole exposure. While the shutter is open every frame's
        // radiance is added in, weighted by how long that frame lasted, so
        // the plate holds a genuine time integral. Anything that moved during
        // those seconds -- the star field under a swung camera, a meteor --
        // is written across the frame exactly where it was, when it was.
        if needsAccumClear || gathered > 0, let accum {
            let a = MTLRenderPassDescriptor()
            a.colorAttachments[0].texture = accum
            a.colorAttachments[0].loadAction = needsAccumClear ? .clear : .load
            a.colorAttachments[0].storeAction = .store
            a.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let e = command.makeRenderCommandEncoder(descriptor: a) {
                if gathered > 0, let accumPipeline {
                    e.setRenderPipelineState(accumPipeline)
                    e.setFragmentTexture(hdr, index: 0)
                    var weight = gathered
                    e.setFragmentBytes(&weight, length: MemoryLayout<Float>.stride, index: 0)
                    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                e.endEncoding()
            }
            needsAccumClear = false
        }

        // Idle shows the live view; once the shutter opens, what you see IS
        // the plate, filling up in front of you.
        let exposed: MTLTexture = (shutterState == .idle ? hdr : (accum ?? hdr))

        // ---- pass 2: bleed pyramid
        func full(_ pipe: MTLRenderPipelineState, to dst: MTLTexture,
                  from textures: [MTLTexture], bytes: UnsafeRawPointer, length: Int) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = dst
            d.colorAttachments[0].loadAction = .dontCare
            d.colorAttachments[0].storeAction = .store
            guard let e = command.makeRenderCommandEncoder(descriptor: d) else { return }
            e.setRenderPipelineState(pipe)
            for (i, t) in textures.enumerated() { e.setFragmentTexture(t, index: i) }
            e.setFragmentBytes(bytes, length: length, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        for level in 0..<4 {
            let src = level == 0 ? exposed : mip[level - 1]
            var texel = SIMD2<Float>(1 / Float(src.width), 1 / Float(src.height))
            full(downPipeline, to: mip[level], from: [src],
                 bytes: &texel, length: MemoryLayout<SIMD2<Float>>.stride)
            let bw = Float(mip[level].width), bh = Float(mip[level].height)
            var h = SIMD2<Float>(1 / bw, 0)
            full(blurPipeline, to: mipTemp[level], from: [mip[level]],
                 bytes: &h, length: MemoryLayout<SIMD2<Float>>.stride)
            var v = SIMD2<Float>(0, 1 / bh)
            full(blurPipeline, to: mip[level], from: [mipTemp[level]],
                 bytes: &v, length: MemoryLayout<SIMD2<Float>>.stride)
        }

        // ---- pass 2b: meter the frame
        // Only while the shutter is shut. Open, the plate holds a running
        // integral rather than the light arriving now, and re-metering it
        // would change the shutter half way through the exposure it is busy
        // making. The reading taken before the press is the one used, which
        // is what a camera does.
        if shutterState == .idle, !meterArmed,
           let meterPipeline, let meterTexture {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = meterTexture
            d.colorAttachments[0].loadAction = .dontCare
            d.colorAttachments[0].storeAction = .store
            if let e = command.makeRenderCommandEncoder(descriptor: d) {
                e.setRenderPipelineState(meterPipeline)
                e.setFragmentTexture(mip[3], index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                e.endEncoding()
            }
            // The GPU writes to its own copy of a managed texture; without
            // this the CPU reads whatever was in the shared buffer before.
            if let blit = command.makeBlitCommandEncoder() {
                blit.synchronize(resource: meterTexture)
                blit.endEncoding()
            }
            meterArmed = true
        }

        // ---- pass 3: develop, into a texture we are allowed to read back
        let target: MTLTexture = shown ?? drawable.texture
        let finalPass = MTLRenderPassDescriptor()
        finalPass.colorAttachments[0].texture = target
        finalPass.colorAttachments[0].loadAction = .dontCare
        finalPass.colorAttachments[0].storeAction = .store
        if let e = command.makeRenderCommandEncoder(descriptor: finalPass) {
            e.setRenderPipelineState(compositePipeline)
            e.setFragmentTexture(exposed, index: 0)
            for i in 0..<4 { e.setFragmentTexture(mip[i], index: i + 1) }
            e.setFragmentBytes(&uniforms, length: MemoryLayout<ObservatoryUniforms>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        // ---- pass 4: show it, and keep a copy if a photograph was taken
        var saveNow = false
        if let shown, let blit = command.makeBlitCommandEncoder() {
            blit.copy(from: shown, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: min(shown.width, drawable.texture.width),
                                          height: min(shown.height, drawable.texture.height),
                                          depth: 1),
                      to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            if keepsReadableFrame && !(pendingCapture && !capturing) {
                blit.synchronize(resource: shown)
            }
            if pendingCapture && !capturing {
                // The GPU writes to its own copy of a managed texture; without
                // this the CPU reads whatever was in the shared buffer before.
                blit.synchronize(resource: shown)
                saveNow = true
                capturing = true
                pendingCapture = false
            }
            blit.endEncoding()
        }
        if saveNow, let shown {
            command.addCompletedHandler { [weak self] _ in
                self?.writePhoto(from: shown)
            }
        }

        command.present(drawable)
        lastCommand = command
        command.commit()
        if time - lastUIUpdate > 0.08 {
            lastUIUpdate = time
            onProgress?(fraction, moving, shutterState)
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    // ===============================================================
    //  Observatory: a long-exposure photograph of the sky, not a plot
    //  of bright dots.
    //
    //  This view is static and unconstrained by frame budget, so it can
    //  afford the whole chain a real camera imposes: atmospheric
    //  extinction, an optical point spread with diffraction spikes,
    //  light bleeding between photosites, a saturating per-channel film
    //  response, and sensor noise. Making stars "brighter" is what a
    //  plot does; a photograph makes them BIGGER and BLEED, because the
    //  wings of their point spread clear the noise floor.
    // ===============================================================

    struct U {
        float4 right, up, forward, optics, exposure;
        float4 prevRight, prevUp, prevForward;
        float4 plane;     // xyz galactic plane normal, w dust strength
        float4 sky;       // airglow, horizon, noise, grain seed
        float4 air;       // extinction R G B per airmass, w airglow falloff
        float4 airglowColour, horizonColour, zenithColour;
        float4 east, north, zenith;   // the ground, in galaxy coordinates
        float4 sun;                   // xyz direction, w angular radius
        float4 sunTint;               // xyz photosphere hue, w its radiance
        float4 sunLight;              // x sunlight (Earth = 1), y sky per unit
        // Engineering-panel tuning, live from the sliders.
        float4 tune0;     // plate gain, white point, bleed, grain
        float4 tune1;     // star gamma, star scale, ceiling, core concentration
        float4 tune2;     // disc base, disc slope, exposure swell, spikes start
        float4 tune3;     // spikes full, meteor brightness
    };
    struct Star { float4 direction, color; };
    struct Screen { float4 position [[position]]; float2 uv; };
    struct StarOut {
        float4 position [[position]];
        float2 segA;           // trail start, in window pixels
        float2 segB;           // trail end, in window pixels
        float3 color;
        float  flux;           // linear, already extinguished
        float  spike;          // how strongly this star shows spikes
        float  invR;           // 1 / point-spread radius, pixels
    };
    struct Meteor { float4 a, b, tint; };
    struct MeteorOut {
        float4 position [[position]];
        float2 segA;
        float2 segB;
        float3 color;
        float  flux;
        float  invR;
    };

    // ---- shared projection helpers --------------------------------
    static float2 winFromNDC(float2 n, float2 size) {
        return float2((n.x * 0.5f + 0.5f) * size.x, (0.5f - n.y * 0.5f) * size.y);
    }
    static float2 ndcFromWin(float2 w, float2 size) {
        return float2(w.x / size.x * 2.0f - 1.0f, 1.0f - w.y / size.y * 2.0f);
    }
    static float2 projectDir(float3 d, float3 r, float3 up, float3 f,
                             float aspect, float halfTan, thread float &z) {
        z = dot(d, f);
        return float2(dot(d, r) / (aspect * halfTan), dot(d, up) / halfTan)
             / max(z, 1e-4f);
    }
    /// Build the quad that covers the capsule swept from A to B, both in
    /// window pixels, with `pad` of point-spread around it.
    static float2 sweptCorner(float2 A, float2 B, float pad, float2 local) {
        float2 seg = B - A;
        float len = length(seg);
        float2 dir = len > 1e-3f ? seg / len : float2(1, 0);
        float2 nrm = float2(-dir.y, dir.x);
        return (A + B) * 0.5f
             + dir * local.x * (len * 0.5f + pad)
             + nrm * local.y * pad;
    }

    constant float2 kQuad[6] = {
        float2(-1,-1), float2(1,-1), float2(-1,1),
        float2(-1, 1), float2(1,-1), float2( 1,1)
    };

    float ridge(float azimuth, constant U &u) {
        // Anchor the landscape to world directions, not the ship heading.
        // Smooth position phases give travel parallax without pole seams.
        float3 direction = u.east.xyz * sin(azimuth) + u.north.xyz * cos(azimuth);
        float phase = dot(u.zenith.xyz, float3(2.1f, 3.7f, 1.3f));
        return 0.012f + 0.025f*sin(dot(direction, float3(5,3,2)) + phase)
            + 0.014f*sin(dot(direction, float3(7,-11,6)) + phase*2.1f)
            + 0.005f*sin(dot(direction, float3(-23,17,29)) + phase*3.7f);
    }

    /// Integer bit-mix (a Wang/xorshift finalizer). Uncorrelated between
    /// neighbouring pixels, unlike a sin-based hash.
    float grainHash(uint x) {
        x ^= x >> 16; x *= 0x7FEB352Du;
        x ^= x >> 15; x *= 0x846CA68Bu;
        x ^= x >> 16;
        return float(x) * (1.0f / 4294967296.0f);
    }
    float hash21(float2 p) {
        return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f);
    }
    float vnoise2(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f*f*(3.0f-2.0f*f);
        return mix(mix(hash21(i), hash21(i+float2(1,0)), f.x),
                   mix(hash21(i+float2(0,1)), hash21(i+float2(1,1)), f.x), f.y);
    }
    float2 equirect(float3 d) {
        return float2(atan2(d.x, -d.z) / (2.0f*M_PI_F) + 0.5f,
                      0.5f - asin(clamp(d.y,-1.0f,1.0f)) / M_PI_F);
    }

    float fbm2(float2 p) {
        float s = 0, a = 0.5f;
        for (int i = 0; i < 5; ++i) { s += a*vnoise2(p); p *= 2.03f; a *= 0.5f; }
        return s;
    }

    // ---------------------------------------------------------------
    //  Atmosphere
    // ---------------------------------------------------------------

    /// Kasten-Young airmass: how much atmosphere the light crossed.
    /// 1 at the zenith, ~38 at the horizon, which is why low stars die.
    float airmass(float sinAltitude) {
        float h = asin(clamp(sinAltitude, -1.0f, 1.0f)) * 57.29578f;   // MSL has no degrees()
        if (h < -2.0f) return 40.0f;
        return 1.0f / (max(sinAltitude, 0.0f)
                     + 0.50572f * pow(max(h + 6.07995f, 0.01f), -1.6364f));
    }

    /// Per-channel transmission. Blue is scattered out roughly three times
    /// harder than red, so stars do not merely dim toward the horizon --
    /// they REDDEN, exactly as the setting sun does.
    float3 extinction(float X, float3 k) {
        return exp(-0.921034f * k * min(X, 12.0f));     // 10^(-0.4 k X)
    }

    /// A galaxy direction expressed in the observer's own frame:
    /// x east, y straight up, z north.
    ///
    /// Altitude, airmass, the skyline and the sun's height are all questions
    /// about where the GROUND is, and the ground is not the simulation's +Y
    /// axis -- that axis belongs to the galaxy, and a planet's pole has no
    /// reason to agree with it. Measuring in this frame is what lets the
    /// probe land with the galaxy overhead instead of underfoot, and what
    /// makes the whole sky wheel when the planet turns.
    float3 localDir(float3 d, constant U &u) {
        return float3(dot(d, u.east.xyz), dot(d, u.zenith.xyz), dot(d, u.north.xyz));
    }
    /// ...and back, for anything born above this ground rather than out in
    /// the galaxy: a meteor belongs to the air, so it is stored locally and
    /// stays put while the stars sweep past it.
    float3 galaxyDir(float3 l, constant U &u) {
        return l.x * u.east.xyz + l.y * u.zenith.xyz + l.z * u.north.xyz;
    }

    vertex Screen skyVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        // uv is TEXTURE space: y = 0 at the top. The plate is rendered once
        // and then resampled several times by the bleed and composite passes,
        // so the coordinate written must be the coordinate read back, or the
        // whole image returns upside down -- which is what put the ground
        // along the top of the frame.
        return { float4(p*2-1, 0, 1), float2(p.x, 1.0f - p.y) };
    }

    // ---------------------------------------------------------------
    //  Sky background
    // ---------------------------------------------------------------
    fragment float4 nightSky(Screen in [[stage_in]], constant U &u [[buffer(0)]]) {

        float2 xy = (float2(in.uv.x, 1.0f - in.uv.y) * 2 - 1)
                  * float2(u.optics.x, 1) * u.optics.y;
        float3 ray = normalize(u.forward.xyz + u.right.xyz*xy.x + u.up.xyz*xy.y);
        // `ray` points out into the galaxy; `direction` is the same ray seen
        // from the ground, and every altitude below is that frame's y.
        float3 direction = localDir(ray, u);
        float azimuth = atan2(direction.x, direction.z);
        float horizon = ridge(azimuth, u);
        float edge = direction.y - horizon;

        // No procedural dust, gas or glow here.
        //
        // An earlier version painted nebulosity with 3D noise and a smoothed
        // density map. It looked like noise, because it was. The galaxy's
        // glow, its dark lanes and its soft edges are all emergent: they come
        // from the summed point-spread wings of a very large number of real
        // stars passing through the same HDR -> bleed -> film chain the main
        // renderer uses. Supplying enough stars produces them for free and
        // correctly; faking them does not.
        float3 galaxy = float3(0);

        // ---- atmosphere ----------------------------------------------
        float X = airmass(max(direction.y, 0.0f));
        galaxy *= extinction(X, u.air.xyz);

        float glowBand = exp(-max(direction.y, 0.0f) * u.air.w);
        float ripple = 0.75f + 0.25f * fbm2(float2(azimuth * 2.2f, direction.y * 9.0f));
        float3 airglow = u.airglowColour.rgb * glowBand * ripple * u.sky.x;

        // The sky is a gradient between two chemistries' worth of colour:
        // overhead you look through the least air, at the skyline through the
        // most. That single fact is what makes an oxygen sky blue overhead
        // and red at the horizon, and a thin-CO2 sky the other way about.
        // The exponent biases the blend toward the horizon, where the path
        // length actually changes fastest.
        float alt = pow(clamp(direction.y, 0.0f, 1.0f), 0.55f);
        float3 base = mix(u.horizonColour.rgb, u.zenithColour.rgb, alt);

        // ---- the star this planet belongs to -------------------------
        //
        // A photograph of a night sky always raises the same question: what
        // becomes of all this when the sun comes up? The answer is not the
        // same on every planet, which is the whole reason the host star is
        // drawn at all. Scattered daylight is linear in the light arriving,
        // so a world around a feeble red dwarf keeps its galaxy in the
        // daytime, while a world around a Sun-like star loses every last
        // star in it -- as Earth does, every morning.
        float cosSun = dot(ray, u.sun.xyz);              // angle to the star
        float sunUp = dot(u.sun.xyz, u.zenith.xyz);      // sine of its altitude
        float3 sunTrans = extinction(airmass(max(sunUp, 0.0f)), u.air.xyz);
        // Twilight is not a fade-out: the sky stays lit for a while after
        // the disc has set, because the air overhead is still in sunlight.
        float daylit = u.sunLight.x * smoothstep(-0.22f, 0.10f, sunUp);
        // The air scatters in its own colour, tinted by the colour of the
        // light it was handed. A red star really does give a red sky.
        float3 hue = base / max(max(base.r, max(base.g, base.b)), 1e-9f);
        float3 dayHue = mix(hue, u.sunTint.rgb, 0.45f);
        float rayleigh = 0.72f + 0.28f * cosSun * cosSun;
        float lowSky = pow(clamp(1.0f - direction.y, 0.0f, 1.0f), 2.0f);
        float3 daylight = dayHue * (daylit * u.sunLight.y) * sunTrans * rayleigh
                        * (0.55f + 0.45f * lowSky);

        // The disc. Its brightness per unit area comes from temperature
        // alone: a star's surface is no dimmer seen from further away, it is
        // only smaller, so every one of these over-exposes the plate and
        // what actually differs between them is WIDTH. Limb darkening comes
        // free and is real -- the rim of a stellar disc shows cooler, higher
        // gas, which is why the Sun's edge is visibly darker than its middle.
        float phi = acos(clamp(cosSun, -1.0f, 1.0f));
        float pxAngle = 2.0f * u.optics.y / max(u.optics.w, 1.0f);
        float drawR = max(u.sun.w, pxAngle);
        // Smaller than a pixel: drawn one pixel wide and dimmed by exactly
        // the area it gained, so the light it lays down is still its own.
        float shrink = (u.sun.w * u.sun.w) / (drawR * drawR);
        float disc = 1.0f - smoothstep(drawR - pxAngle * 0.5f, drawR + pxAngle * 0.5f, phi);
        float mu = sqrt(max(1.0f - pow(min(phi / max(drawR, 1e-7f), 1.0f), 2.0f), 0.0f));
        float3 discLight = u.sunTint.rgb * (u.sunTint.w * shrink * disc
                                            * (0.40f + 0.60f * mu)) * sunTrans;
        // The aureole: forward-scattered light in a tight halo, which is the
        // reason you cannot look anywhere near a sun even on a clear day.
        float aureole = 0.85f * exp(-phi * 24.0f) + 0.10f * exp(-phi * 5.0f);
        float3 glow = dayHue * (daylit * u.sunLight.y * aureole * 3.0f) * sunTrans;

        float3 skyColour = base + airglow + galaxy + daylight + discLight + glow;

        // The ground is lit by the sky above it, so it carries the planet's
        // own colour rather than a fixed grey -- and by the star, once the
        // star is up, or the foreground would stay midnight-black at noon.
        float3 ground = u.horizonColour.rgb * 0.10f
                      + dayHue * (daylit * u.sunLight.y * 0.22f) * sunTrans;
        float foreground = ridge(azimuth+1.7f, u)*0.7f - 0.10f;
        ground *= mix(0.40f, 1.0f,
                      smoothstep(foreground-0.002f, foreground+0.002f, direction.y));

        float3 rgb = mix(ground, skyColour, smoothstep(-0.0010f, 0.0010f, edge));
        // The plate is 16-bit float. A hot photosphere can ask for millions;
        // half stops at 65504 and turns the pixel into a NaN on the way past.
        return float4(min(rgb, float3(50000.0f)), 1);
    }

    // ---------------------------------------------------------------
    //  Stars
    // ---------------------------------------------------------------
    vertex StarOut nightStarVertex(device const Star *stars [[buffer(0)]],
                                   constant U &u [[buffer(1)]], uint vid [[vertex_id]]) {
        uint id = vid / 6u;
        int corner = int(vid % 6u);
        Star star = stars[id];
        float3 d = star.direction.xyz;

        StarOut out;

        float2 size = float2(u.optics.z, u.optics.w);
        float zNow, zPrev;
        float2 nNow  = projectDir(d, u.right.xyz, u.up.xyz, u.forward.xyz,
                                  u.optics.x, u.optics.y, zNow);
        float2 nPrev = projectDir(d, u.prevRight.xyz, u.prevUp.xyz, u.prevForward.xyz,
                                  u.optics.x, u.optics.y, zPrev);
        // Two azimuths, because two different things are being asked. The
        // skyline belongs to the planet, so it is measured against the
        // ground; the dust lane belongs to the galaxy, so it must not swim
        // about when the planet turns.
        float3 L = localDir(d, u);
        float azimuth = atan2(L.x, L.z);
        float galAz = atan2(d.x, d.z);
        bool below = L.y < ridge(azimuth, u) + 0.001f;
        if (zNow <= 0.0f || below) {
            out.position = float4(0,0,-2,1);
            out.color = float3(0); out.flux = 0; out.spike = 0;
            out.segA = out.segB = float2(0); out.invR = 1.0f;
            return out;
        }

        // ---- atmosphere
        float X = airmass(L.y);
        float3 trans = extinction(X, u.air.xyz);

        // ---- interstellar dust: a dark lane through the galactic plane,
        // the feature that makes a Milky Way photograph read as one.
        float planeDist = abs(dot(d, u.plane.xyz));
        float lane = exp(-planeDist * planeDist * 260.0f);
        float2 dustUV = float2(galAz * 1.6f, d.y * 5.0f);
        float clumps = fbm2(dustUV * 2.4f);
        float dust = lane * smoothstep(0.35f, 0.85f, clumps) * u.plane.w;
        float3 dustTrans = exp(-dust * float3(1.5f, 2.1f, 3.0f));

        // The ceiling is high on purpose. Real starlight spans a range no
        // display can hold, and cutting it at a low value is what makes a
        // synthetic sky read as haze: thousands of different stars all pinned
        // to the same value, none of them able to burn a highlight. Here only
        // the extreme tail is clipped, so the brightest few are thousands of
        // times the sky and expose to white while the faint ones stay faint.
        // The curve first, then the ceiling. Raising the exponent widens the
        // gap between the brightest stars and the rest, which is what lets a
        // few of them over-expose while the crowd stays faint; the ceiling is
        // deliberately far above white, because clipping the top of the range
        // is exactly what turns a sky into flat haze.
        float brightness = pow(max(star.color.w, 0.0f), u.tune1.x) * u.tune1.y;
        brightness = clamp(brightness, 0.0f, u.tune1.z);

        // No shutter factor here any more. The plate integrates radiance
        // over time in its own pass, so scaling flux by the shutter setting
        // as well would count the exposure twice -- a 30 s frame would come
        // out 30x too bright on top of being 30x longer. What a star emits
        // does not depend on how long you choose to look at it.
        float3 flux = brightness * trans * dustTrans;
        float lum = dot(flux, float3(0.2126f, 0.7152f, 0.0722f));

        // ---- apparent size
        // A star is a point source; its disc in a photograph is the point
        // spread, and a brighter star looks bigger only because more of its
        // wings clear the noise floor. Size therefore grows with the LOG of
        // flux, not with flux itself.
        float pixelScale = clamp(u.optics.w / 900.0f, 0.7f, 2.4f);
        // A longer exposure does make a star's disc grow, because more of its
        // point-spread wings climb above the noise floor -- but only weakly,
        // as the log here. The brightness itself comes from the integral.
        float reach = 1.0f + u.tune2.z * log2(1.0f + u.exposure.x);
        // Small. With hundreds of thousands of stars the glow comes from
        // their overlapping wings, not from each one being large -- which is
        // exactly how the main renderer gets its look.
        float radiusPx = (u.tune2.x + u.tune2.y * log2(1.0f + lum * 1.2f)) * pixelScale * reach;
        radiusPx = clamp(radiusPx, 0.7f, 26.0f);

        // Spikes belong to the few genuinely brilliant points, not to every
        // star: a lens only throws a visible diffraction pattern when a source
        // vastly over-exposes its own core. Putting them on everything is the
        // single most artificial thing a synthetic sky can do.
        out.spike = smoothstep(u.tune2.w, max(u.tune3.x, u.tune2.w + 1e-3f), lum);

        float2 B = winFromNDC(nNow, size);
        float2 A = (zPrev > 0.02f) ? winFromNDC(nPrev, size) : B;
        float2 seg = B - A;
        float segLen = length(seg);
        // A hard flick of the view must not smear one star across the whole
        // plate; past this the trail is clipped rather than drawn wrong.
        const float kMaxSmear = 260.0f;
        if (segLen > kMaxSmear) { A = B - seg * (kMaxSmear / segLen); segLen = kMaxSmear; }

        float2 W = sweptCorner(A, B, radiusPx * 1.25f, kQuad[corner]);
        out.position = float4(ndcFromWin(W, size), 0.5f, 1.0f);
        out.segA = A;
        out.segB = B;
        out.invR = 1.0f / max(radiusPx, 0.35f);

        // Energy is conserved twice over: spreading the same light across a
        // bigger disc must not brighten the star, and neither must smearing
        // it along a trail. A star dragged across 40 px in one frame lays
        // down the same total light as one that held still.
        float spread = radiusPx / (radiusPx + segLen);
        out.flux = lum / (radiusPx * radiusPx) * u.tune1.w * pixelScale * pixelScale * spread;
        float3 chroma = lum > 1e-8f ? flux / lum : float3(1);
        // push saturation a little: sensors record more colour than the eye
        // sees at night, which is why astrophotographs look so colourful
        float grey = dot(chroma, float3(0.2126f, 0.7152f, 0.0722f));
        out.color = mix(float3(grey), chroma, 1.45f);
        return out;
    }

    fragment float4 nightStarFragment(StarOut in [[stage_in]]) {
        // Distance from this pixel to the trail, in units of the point-spread
        // radius. With a stationary camera the segment has zero length and
        // this reduces exactly to the old radial sprite.
        float2 AB = in.segB - in.segA;
        float t = clamp(dot(in.position.xy - in.segA, AB) / max(dot(AB, AB), 1e-6f),
                        0.0f, 1.0f);
        float2 p = (in.position.xy - (in.segA + AB * t)) * in.invR;
        float r2 = dot(p, p);
        if (r2 > 1.0f) discard_fragment();

        // Seeing disc plus the broad wings every real optic has. The wings
        // are a power law, not a gaussian: that slow falloff is what makes
        // bright stars bleed into their neighbours.
        float core  = exp(-r2 * 34.0f);
        float halo  = 0.055f / (1.0f + r2 * 70.0f);
        float wings = 0.008f / (1.0f + r2 * 10.0f);

        // Four-vane diffraction spikes, as a telescope spider produces.
        float2 a = p;
        float2 b = float2(p.x + p.y, p.x - p.y) * 0.70710678f;
        float sp = 0.0f;
        if (in.spike > 0.001f) {
            sp += exp(-a.x*a.x*2200.0f) * exp(-r2*2.4f);
            sp += exp(-a.y*a.y*2200.0f) * exp(-r2*2.4f);
            sp += 0.30f * exp(-b.x*b.x*3200.0f) * exp(-r2*3.0f);
            sp += 0.30f * exp(-b.y*b.y*3200.0f) * exp(-r2*3.0f);
        }

        float light = core + halo + wings + sp * 0.16f * in.spike;
        float3 rgb = in.color * in.flux * light;
        return float4(rgb, 0);
    }

    // ---------------------------------------------------------------
    //  Meteors
    //
    //  A meteor is drawn as the arc it covers during THIS frame only -- a
    //  short dash, not a whole streak. Live, that dash reads as something
    //  falling. Under an open shutter the dashes are integrated onto the
    //  plate end to end and become one continuous streak, which is exactly
    //  how a meteor lands on real film: it is not an object in the picture,
    //  it is a record of where it was while the shutter was open.
    // ---------------------------------------------------------------
    vertex MeteorOut meteorVertex(device const Meteor *ms [[buffer(0)]],
                                  constant U &u [[buffer(1)]],
                                  uint vid [[vertex_id]]) {
        uint id = vid / 6u;
        int corner = int(vid % 6u);
        Meteor m = ms[id];

        MeteorOut out;
        float2 size = float2(u.optics.z, u.optics.w);
        float zA, zB;
        // A meteor burns in this planet's air, so it is held in the
        // planet's frame and turns with the ground. Only the projection
        // needs it back in galaxy coordinates, where the camera lives.
        float3 ga = galaxyDir(m.a.xyz, u);
        float3 gb = galaxyDir(m.b.xyz, u);
        float2 nA = projectDir(ga, u.right.xyz, u.up.xyz, u.forward.xyz,
                               u.optics.x, u.optics.y, zA);
        float2 nB = projectDir(gb, u.right.xyz, u.up.xyz, u.forward.xyz,
                               u.optics.x, u.optics.y, zB);
        // Both ends must be in front of the camera, and above the skyline.
        float azA = atan2(m.a.x, m.a.z), azB = atan2(m.b.x, m.b.z);
        bool hidden = zA <= 0.02f || zB <= 0.02f
                   || m.a.y < ridge(azA, u) || m.b.y < ridge(azB, u);
        if (hidden || m.tint.w <= 0.0f) {
            out.position = float4(0, 0, -2, 1);
            out.color = float3(0); out.flux = 0;
            out.segA = out.segB = float2(0); out.invR = 1.0f;
            return out;
        }

        float pixelScale = clamp(u.optics.w / 900.0f, 0.7f, 2.4f);
        float radiusPx = 2.1f * pixelScale;
        float2 A = winFromNDC(nA, size);
        float2 B = winFromNDC(nB, size);
        float segLen = length(B - A);

        float2 W = sweptCorner(A, B, radiusPx * 3.0f, kQuad[corner]);
        out.position = float4(ndcFromWin(W, size), 0.4f, 1.0f);
        out.segA = A;
        out.segB = B;
        out.invR = 1.0f / max(radiusPx, 0.35f);
        out.color = m.tint.rgb;
        // Same conservation as the stars: a faster meteor covers more pixels
        // this frame and is correspondingly fainter along its length.
        out.flux = m.tint.w * 0.02f * u.tune3.y * (radiusPx / (radiusPx + segLen));
        return out;
    }

    fragment float4 meteorFragment(MeteorOut in [[stage_in]]) {
        float2 AB = in.segB - in.segA;
        float t = clamp(dot(in.position.xy - in.segA, AB) / max(dot(AB, AB), 1e-6f),
                        0.0f, 1.0f);
        float2 p = (in.position.xy - (in.segA + AB * t)) * in.invR;
        float r2 = dot(p, p);
        if (r2 > 9.0f) discard_fragment();
        // Hot narrow core in a soft glow, and a slight fade toward the tail.
        float core = exp(-r2 * 2.6f);
        float glow = 0.09f / (1.0f + r2 * 3.0f);
        float taper = mix(0.55f, 1.0f, t);
        return float4(in.color * in.flux * (core + glow) * taper, 0);
    }

    // ---------------------------------------------------------------
    //  Post: bleed, develop, grain
    // ---------------------------------------------------------------
    /// Add one frame's radiance to the exposure plate, weighted by how long
    /// that frame lasted. Blending is additive, so the plate ends up holding
    /// the integral of radiance over the time the shutter was open.
    fragment float4 obsAccumulate(Screen in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  constant float &weight [[buffer(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        return float4(src.sample(s, in.uv).rgb * weight, 0.0f);
    }

    fragment float4 obsDown(Screen in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            constant float2 &texel [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 c = src.sample(s, in.uv + texel*float2(-1,-1)).rgb
                 + src.sample(s, in.uv + texel*float2( 1,-1)).rgb
                 + src.sample(s, in.uv + texel*float2(-1, 1)).rgb
                 + src.sample(s, in.uv + texel*float2( 1, 1)).rgb;
        return float4(c * 0.25f, 1);
    }

    /// The light meter: one pass in, one pixel out.
    ///
    /// A log-average of the frame, which is the reading every camera meter
    /// has taken since they stopped being needles -- and here it matters more
    /// than usual. A star's disc is SUPPOSED to burn out: its surface is as
    /// bright from a light-year away as it is close up, so no exposure that
    /// shows a landscape can also hold a photosphere below white. A plain
    /// average would be dragged up by that disc and would take the sunlit
    /// ground under it down to black. A geometric mean cannot be: the disc is
    /// a few taps out of sixty-four, and a few taps can only move a log sum a
    /// few taps' worth. The sun burns out and the daylight comes out right,
    /// which is what a photograph of a sunny day looks like.
    ///
    /// It reads the smallest bleed mip, where each texel already averages a
    /// sixteen-pixel block and has been blurred on top, so the taps cannot
    /// flicker as a star crosses one while the camera turns. Centre-weighted,
    /// because what you are pointing at should count for more than the
    /// corners.
    fragment float4 obsMeter(Screen in [[stage_in]],
                             texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float sum = 0.0f, weight = 0.0f;
        for (int j = 0; j < 8; ++j) {
            for (int i = 0; i < 8; ++i) {
                float2 uv = (float2(i, j) + 0.5f) / 8.0f;
                float2 c = (uv - 0.5f) * 2.0f;
                float w = 1.0f - 0.55f * clamp(dot(c, c), 0.0f, 1.0f);
                float3 rgb = src.sample(s, uv).rgb;
                float L = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
                sum += w * log(max(L, 1e-5f));
                weight += w;
            }
        }
        return float4(exp(sum / max(weight, 1e-5f)), 0, 0, 1);
    }

    fragment float4 obsBlur(Screen in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            constant float2 &dir [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        const float w[5] = {0.2270270f,0.1945946f,0.1216216f,0.0540541f,0.0162162f};
        float3 sum = src.sample(s, in.uv).rgb * w[0];
        for (int i = 1; i < 5; ++i) {
            float2 o = dir * float(i) * 1.45f;
            sum += src.sample(s, in.uv + o).rgb * w[i];
            sum += src.sample(s, in.uv - o).rgb * w[i];
        }
        return float4(sum, 1);
    }

    fragment float4 obsComposite(Screen in [[stage_in]],
                                 texture2d<float> scene [[texture(0)]],
                                 texture2d<float> m0 [[texture(1)]],
                                 texture2d<float> m1 [[texture(2)]],
                                 texture2d<float> m2 [[texture(3)]],
                                 texture2d<float> m3 [[texture(4)]],
                                 constant U &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);

        float shot = u.exposure.z;          // 0 = viewfinder, 1 = photograph

        // ---- chromatic aberration -----------------------------------
        // Lateral CA: a simple lens focuses short wavelengths slightly
        // closer than long ones, so the three channels land at very
        // slightly different scales. It is zero on the axis and grows
        // toward the corners, which is why it is invisible in the middle
        // of a frame and obvious at the edges.
        float2 c = in.uv - 0.5f;
        float ca = 0.0016f * shot;
        float3 lin;
        lin.r = scene.sample(s, 0.5f + c * (1.0f + ca)).r;
        lin.g = scene.sample(s, in.uv).g;
        lin.b = scene.sample(s, 0.5f + c * (1.0f - ca)).b;

        // Bleed, in LINEAR light before exposure: only in this order can an
        // over-exposed core go white while its halo keeps the star's colour.
        float3 bleed = (m0.sample(s, in.uv).rgb * 0.080f
                      + m1.sample(s, in.uv).rgb * 0.036f
                      + m2.sample(s, in.uv).rgb * 0.014f
                      + m3.sample(s, in.uv).rgb * 0.005f) * u.tune0.z;

        // ---- how much light was actually collected -------------------
        // The plate holds different quantities in the two states, and the
        // dial has to mean the same thing in both. Exposing, it already holds
        // radiance INTEGRATED over the open shutter, so the seconds are baked
        // in and the factor is 1. Idle, it holds INSTANT radiance, so it is
        // multiplied by the dial setting -- which is exposure simulation, the
        // thing a live view does so that turning the dial actually changes the
        // picture in front of you instead of only the one you take.
        // The viewfinder is a COMPRESSED preview of the dial, not a floor
        // under it. A floor (max(seconds, 3)) made the bottom half of the
        // dial do nothing at all: 0.25 s and 3 s previewed identically, so
        // the picture only began to change past the floor and the dial felt
        // broken below it. A power curve keeps every step of the dial
        // visible while still lifting the short end enough to aim by --
        // 0.25 s previews like 1.3 s of light, 60 s like 34 s of it.
        //
        // The lift belongs to the DIAL, though, and it is the dial's alone.
        // It exists so a dark frame can be aimed; all it does to a sunlit
        // one is hand back the white rectangle it was already handing back.
        // So the moment the meter takes the shutter the lift is 1 and the
        // viewfinder becomes the photograph, which is what a viewfinder is
        // supposed to be. The camera works out which of the two it is and
        // sends the factor down ready-made, because that decision is made of
        // things -- a reading, a latch -- that live on the other side.
        float t = max(u.exposure.x, 1e-6f);
        float preview = t * max(u.tune3.w, 1.0f);
        float seconds = mix(preview, 1.0f, shot);
        float3 E = (lin + bleed) * max(u.tune0.x, 1e-5f) * seconds;

        // Extended Reinhard. The old response was E^n/(E^n+K^n): it lifted a
        // nearly black sky to mid grey and, being asymptotic, could never
        // reach 1 -- so no star ever burnt out, however long the shutter was
        // open, and every exposure came back the same hazy grey. This one is
        // LINEAR near zero, so a short exposure really is dark, and it hits
        // exactly 1.0 at E = kWhite, so a bright star given enough time does
        // expose to white while its bleed halo keeps the star's colour.
        float kWhite = max(u.tune0.y, 0.05f);
        float3 Ec = max(E, 0.0f);
        float3 dev = Ec * (1.0f + Ec / (kWhite * kWhite)) / (1.0f + Ec);

        // ---- sensor grain --------------------------------------------
        // Integer bit-mix at full pixel resolution; a sin-based hash
        // correlates along lines and bands rather than granulating. The seed
        // is fixed for the whole exposure, so the grain in a finished
        // photograph holds still.
        uint2 pix = uint2(in.uv * float2(u.optics.z, u.optics.w));
        uint seed = pix.x * 1973u + pix.y * 9277u + uint(u.sky.w) * 26699u;
        float g = grainHash(seed) - 0.5f;
        float3 chroma = float3(grainHash(seed ^ 0x9E3779B9u),
                               grainHash(seed ^ 0x85EBCA6Bu),
                               grainHash(seed ^ 0xC2B2AE35u)) - 0.5f;
        float lum = dot(dev, float3(0.2126f, 0.7152f, 0.0722f));
        // Noise has two parts, as a sensor does: a small constant read noise,
        // and shot noise that follows the square root of the signal. Scaling
        // it by the signal matters now that a short exposure is genuinely
        // dark -- a flat amount of grain would bury a 0.25 s frame in static
        // while being invisible in a 60 s one.
        float grainAmt = u.sky.z * u.tune0.w * (0.35f + 0.65f * shot)
                       * (0.02f + 0.60f * sqrt(max(lum, 0.0f)));
        dev += (g * 0.55f + chroma * 0.45f) * grainAmt
             * (1.0f - smoothstep(0.0f, 0.5f, lum));

        dev = clamp(dev, 0.0f, 1.0f);
        dev = pow(dev, float3(1.0f/2.2f));

        // ---- vignetting ----------------------------------------------
        // Natural falloff of a real lens, stronger in the photograph than in
        // the viewfinder. Slightly cooler in the corners, as less oblique
        // light makes it through the stack.
        float r2 = dot(c, c);
        float vig = 1.0f - (0.34f + 0.42f * shot) * r2 - 0.28f * shot * r2 * r2;
        dev *= clamp(vig, 0.0f, 1.0f);
        dev.b *= 1.0f + 0.05f * shot * r2;

        return float4(dev, 1);
    }
    """
}

// MARK: - Atmospheres

/// A planet's air, as the camera sees it.
///
/// Every world in this galaxy gets its own sky rather than one generic night.
/// The parameters are the ones that actually change a photograph: how hard the
/// air scatters (and therefore how fast stars redden toward the horizon), what
/// the airglow is made of, and how much light the ground throws back up.
struct Atmosphere {
    var name: String
    /// Extinction in magnitudes per airmass, R G B. Blue always suffers most;
    /// a thicker or dustier air raises all three and widens the gap.
    var extinction: SIMD3<Float>
    /// Airglow emission colour and strength. Earth's is oxygen green; other
    /// chemistries give other colours.
    var airglow: SIMD3<Float>
    var airglowStrength: Float
    /// How tightly the glow hugs the horizon. Thin air keeps it low.
    var airglowFalloff: Float
    /// Scattered light near the horizon.
    var horizonGlow: SIMD3<Float>
    /// The faint floor of the sky: unresolved light and zodiacal dust.
    var zenith: SIMD3<Float>

    // Each entry is a specific real chemistry, and the sky is painted as a
    // gradient from `horizonGlow` at the skyline to `zenith` overhead, with
    // the `airglow` emission band laid over the lower sky.
    //
    // These radiances are not free parameters. Each was derived by choosing
    // the colour the sky should APPEAR in the viewfinder and inverting the
    // develop chain (plate gain -> saturating response -> gamma) to find the
    // radiance that produces it. The previous table was physically sensible
    // but every world landed within 1-4 sRGB steps of every other one once
    // the 5.5% viewfinder gain had crushed it, which is why the variation was
    // invisible no matter how far apart the numbers looked on paper.
    //
    // Physics used:
    //   * Rayleigh scattering goes as 1/lambda^4 -> Earth's sky is blue,
    //     stars redden through thick air, and horizon light warms.
    //   * Mie scattering (dust, aerosols) is wavelength-flat -> Martian
    //     iron dust reads butterscotch across the whole spectrum.
    //   * Methane absorbs 619nm/725nm bands strongly -> ice-giant skies
    //     read cyan; a Titan-like methane haze absorbs blue instead.
    //   * Airglow emission lines: OI 557.7nm green (Earth), OI 630nm red
    //     (aurora, Mars), N2+ 391nm violet, SO2 UV -> yellow secondary.
    static let all: [Atmosphere] = [
        // N2/O2 -- Rayleigh blue zenith, warm scattered horizon. Our sky.
        Atmosphere(name: "Nitrogen-oxygen",
                   extinction: SIMD3(0.100000, 0.170000, 0.320000),
                   airglow: SIMD3(0.000358, 0.001194, 0.000537), airglowStrength: 1.0,
                   airglowFalloff: 9.5,
                   horizonGlow: SIMD3(0.007148, 0.000109, 0.000018),
                   zenith: SIMD3(0.000047, 0.000185, 0.001850)),

        // Thin CO2 over iron dust -- Mars: rusty zenith, cold blue horizon glow.
        Atmosphere(name: "Carbon dioxide, thin",
                   extinction: SIMD3(0.220000, 0.320000, 0.460000),
                   airglow: SIMD3(0.000347, 0.000146, 0.000069), airglowStrength: 1.25,
                   airglowFalloff: 6.5,
                   horizonGlow: SIMD3(0.000029, 0.002091, 0.002633),
                   zenith: SIMD3(0.001850, 0.000185, 0.000065)),

        // Dense CO2 -- Venus-like: heavy ochre, no blue survives the path.
        Atmosphere(name: "Carbon dioxide, thick",
                   extinction: SIMD3(0.300000, 0.340000, 0.440000),
                   airglow: SIMD3(0.001539, 0.001201, 0.000400), airglowStrength: 1.15,
                   airglowFalloff: 5.0,
                   horizonGlow: SIMD3(0.009514, 0.002607, 0.000046),
                   zenith: SIMD3(0.003815, 0.001344, 0.000088)),

        // NH3 with photochemical haze -- pale yellow-green, Jovian cream at the horizon.
        Atmosphere(name: "Ammonia",
                   extinction: SIMD3(0.200000, 0.200000, 0.340000),
                   airglow: SIMD3(0.000535, 0.000744, 0.000283), airglowStrength: 1.3,
                   airglowFalloff: 6.0,
                   horizonGlow: SIMD3(0.005433, 0.002969, 0.000079),
                   zenith: SIMD3(0.001501, 0.001850, 0.000185)),

        // Tholin smog -- Titan butterscotch, deepening to orange low down.
        Atmosphere(name: "Methane haze",
                   extinction: SIMD3(0.260000, 0.360000, 0.660000),
                   airglow: SIMD3(0.001421, 0.000966, 0.000313), airglowStrength: 1.5,
                   airglowFalloff: 5.5,
                   horizonGlow: SIMD3(0.011455, 0.001204, 0.000029),
                   zenith: SIMD3(0.002251, 0.000630, 0.000065)),

        // CH4 absorbs 619/725nm -- red is eaten, leaving a cyan sky.
        Atmosphere(name: "Methane, ice giant",
                   extinction: SIMD3(0.360000, 0.220000, 0.140000),
                   airglow: SIMD3(0.000141, 0.000516, 0.000782), airglowStrength: 1.15,
                   airglowFalloff: 8.5,
                   horizonGlow: SIMD3(0.000023, 0.002709, 0.004831),
                   zenith: SIMD3(0.000032, 0.000725, 0.002251)),

        // SO2 photochemistry over sulfur frost -- Io yellow.
        Atmosphere(name: "Sulfur haze",
                   extinction: SIMD3(0.200000, 0.180000, 0.420000),
                   airglow: SIMD3(0.001311, 0.001128, 0.000288), airglowStrength: 1.35,
                   airglowFalloff: 6.5,
                   horizonGlow: SIMD3(0.009514, 0.002181, 0.000023),
                   zenith: SIMD3(0.003513, 0.002251, 0.000065)),

        // Strong field, constant precipitation -- OI 557.7nm curtains over a dark sky.
        Atmosphere(name: "Aurora-lit",
                   extinction: SIMD3(0.080000, 0.130000, 0.240000),
                   airglow: SIMD3(0.000221, 0.000651, 0.000455), airglowStrength: 2.1,
                   airglowFalloff: 4.5,
                   horizonGlow: SIMD3(0.000055, 0.007345, 0.001414),
                   zenith: SIMD3(0.000032, 0.000277, 0.000829)),

        // Cl2 -- a sickly yellow-green air. Exotic and rare.
        Atmosphere(name: "Chlorine",
                   extinction: SIMD3(0.160000, 0.100000, 0.240000),
                   airglow: SIMD3(0.000341, 0.000853, 0.000307), airglowStrength: 1.4,
                   airglowFalloff: 7.0,
                   horizonGlow: SIMD3(0.001251, 0.006417, 0.000453),
                   zenith: SIMD3(0.000396, 0.001850, 0.000277)),

        // Retained primordial envelope -- faint H-alpha rose.
        Atmosphere(name: "Hydrogen-helium",
                   extinction: SIMD3(0.060000, 0.080000, 0.130000),
                   airglow: SIMD3(0.000424, 0.000119, 0.000186), airglowStrength: 0.85,
                   airglowFalloff: 7.5,
                   horizonGlow: SIMD3(0.001935, 0.000096, 0.000492),
                   zenith: SIMD3(0.000396, 0.000065, 0.000277)),

        // Barely an exosphere -- starlight almost undimmed, sky almost black.
        Atmosphere(name: "Near-vacuum",
                   extinction: SIMD3(0.040000, 0.070000, 0.140000),
                   airglow: SIMD3(0.000016, 0.000021, 0.000041), airglowStrength: 0.45,
                   airglowFalloff: 14.5,
                   horizonGlow: SIMD3(0.000020, 0.000024, 0.000099),
                   zenith: SIMD3(0.000007, 0.000009, 0.000032)),
    ]

    /// Deterministic per planet, so revisiting the same world finds the same
    /// air rather than a fresh roll.
    /// A world's air belongs to the world, so the same star must give the same
    /// sky every time you visit it. String.hashValue cannot do this: Swift
    /// seeds it per process, so it would have handed the same planet a
    /// different chemistry on every launch. This is FNV-1a over the bytes of
    /// the name, which does not change between runs or between machines.
    static func forPlanet(name: String) -> Atmosphere {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in name.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return all[Int(h % UInt64(all.count))]
    }
}

// MARK: - Camera controls

/// Curved shutter-time dial, in the manner of a phone camera's lens ring.
///
/// The ticks are laid out on a large circle whose centre sits far below the
/// view, so only the top of the arc is visible and the scale appears to curve
/// away at both ends. Spacing is logarithmic, which is how photographic stops
/// work: each labelled stop is a fixed multiple of the last, so equal travel
/// along the dial always means the same ratio of light.
final class ExposureDial: NSView {

    /// Labelled stops, with the plain-language note that sits under each.
    private let stops: [(seconds: Double, note: String)] = [
        (0.25, "blink"), (0.5, ""), (1, "quick"), (2, ""), (4, "steady"),
        (8, ""), (15, "patient"), (30, ""), (60, "deep"),
    ]

    var onSelect: ((Float) -> Void)?

    /// The speed the camera has taken for itself, when the light is past
    /// anything the dial holds. nil while the dial is in charge -- which is
    /// every night, and is why the dial looks and behaves exactly as it did
    /// until the sun comes up.
    var autoSeconds: Float? {
        didSet { if autoSeconds != oldValue { needsDisplay = true } }
    }

    /// Continuous position in log2(seconds); the pointer always reads this.
    private var position: Double = 2          // log2(4 s)
    private var dragAnchor: Double?
    private var dragStartX: CGFloat = 0

    private var minPos: Double { log2(stops.first!.seconds) }
    private var maxPos: Double { log2(stops.last!.seconds) }

    var seconds: Double { pow(2, position) }
    override var isFlipped: Bool { false }

    /// Radius of the imaginary ring. Large relative to the view, so the arc
    /// is shallow and the labels stay readable.
    private var radius: CGFloat { bounds.height * 3.4 }
    private var centre: NSPoint { NSPoint(x: bounds.midX, y: bounds.maxY - radius) }
    /// The disc the face occupies, in the dial's own coordinates. Most of it
    /// is below the view: only the top of the ring shows.
    var faceRect: NSRect {
        NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
    }
    /// Degrees of arc per doubling of exposure time.
    private let degreesPerStop: CGFloat = 11

    func select(seconds s: Double) {
        position = min(max(log2(max(s, 0.01)), minPos), maxPos)
        needsDisplay = true
    }

    // MARK: input

    override func mouseDown(with event: NSEvent) {
        dragAnchor = position
        dragStartX = convert(event.locationInWindow, from: nil).x
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let x = convert(event.locationInWindow, from: nil).x
        // Convert pixels travelled into arc degrees, then into stops.
        let degrees = Double((x - dragStartX) / radius) * 180 / .pi
        position = min(max(anchor - degrees / Double(degreesPerStop), minPos), maxPos)
        needsDisplay = true
        onSelect?(Float(seconds))
    }
    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        snapToNearestStop()
    }
    override func scrollWheel(with event: NSEvent) {
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
              ? event.scrollingDeltaX : event.scrollingDeltaY
        guard abs(d) > 0.3 else { return }
        position = min(max(position - Double(d) * 0.02, minPos), maxPos)
        needsDisplay = true
        onSelect?(Float(seconds))
    }

    /// Settle onto a labelled stop, the way a detented ring does.
    private func snapToNearestStop() {
        var best = position
        var bestDelta = Double.greatestFiniteMagnitude
        for stop in stops {
            let p = log2(stop.seconds)
            if abs(p - position) < bestDelta { bestDelta = abs(p - position); best = p }
        }
        position = best
        needsDisplay = true
        onSelect?(Float(seconds))
    }

    // MARK: drawing

    /// Where a given exposure sits on the arc, as an angle from the pointer.
    private func angle(for pos: Double) -> CGFloat {
        CGFloat(pos - position) * degreesPerStop * .pi / 180
    }

    private func point(_ theta: CGFloat, _ r: CGFloat) -> NSPoint {
        NSPoint(x: centre.x + sin(theta) * r, y: centre.y + cos(theta) * r)
    }

    /// Two decimals below half a second, where "%.1f" rounded the 0.25 stop
    /// to 0.2 and printed a number the dial cannot actually be set to.
    private func label(_ v: Double) -> String {
        if v < 0.5 { return String(format: "%.2f", v) }
        if v < 1 { return String(format: "%.1f", v) }
        return String(format: "%.0f", v)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rim = radius
        // While the camera is metering for itself the stops are not doing
        // anything, and the dial says so by going quiet rather than by
        // pretending. Turning it still works -- the moment the light drops
        // back into its range it takes over again.
        let dim: Double = autoSeconds == nil ? 1 : 0.35

        // ---- the face: a disc rising from below, so the scale reads as the
        // edge of a ring rather than a flat strip. Glassy — the sky reads
        // faintly through it, and a soft radial highlight suggests a curved
        // piece of dark glass rather than a painted plate.
        let face = NSBezierPath(ovalIn: faceRect)
        ctx.saveGState()
        face.addClip()
        // Smoked, not frosted. A white wash at any alpha is a grey disc
        // hanging in a black sky; black at a low alpha is invisible at night
        // and still holds the scale up against a bright horizon by day.
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [
                                    NSColor(calibratedWhite: 0, alpha: 0.18).cgColor,
                                    NSColor(calibratedWhite: 0, alpha: 0.55).cgColor,
                                 ] as CFArray,
                                 locations: [0, 1]) {
            let top = NSPoint(x: centre.x, y: centre.y + rim)
            let bot = NSPoint(x: centre.x, y: centre.y - rim)
            ctx.drawLinearGradient(grad, start: top, end: bot, options: [])
        }
        ctx.restoreGState()
        // Bright inner rim so the arc still reads against a dim sky.
        KidsStyle.lamp(1, alpha: 0.22).setStroke()
        face.lineWidth = 1
        face.stroke()

        // ---- minor ticks every quarter stop, majors at the labelled stops
        let quarter = 0.25
        var p = minPos
        while p <= maxPos + 1e-6 {
            let th = angle(for: p)
            if abs(th) < 0.62 {
                let isMajor = stops.contains { abs(log2($0.seconds) - p) < 1e-6 }
                let len: CGFloat = isMajor ? 15 : 8
                let fade = 1 - Double(abs(th) / 0.62)
                let alpha = (isMajor ? 0.85 : 0.35) * (0.25 + 0.75 * fade) * dim
                KidsStyle.lamp(1, alpha: alpha).setStroke()
                let path = NSBezierPath()
                path.move(to: point(th, rim - 4))
                path.line(to: point(th, rim - 4 - len))
                path.lineWidth = isMajor ? 2 : 1
                path.stroke()
            }
            p += quarter
        }

        // ---- labelled stops, rotated to stand on the arc
        for stop in stops {
            let sp = log2(stop.seconds)
            let th = angle(for: sp)
            guard abs(th) < 0.56 else { continue }
            let selected = abs(sp - position) < 0.01
            let fade = 1 - Double(abs(th) / 0.56)
            let alpha = (selected ? 1.0 : 0.55) * (0.25 + 0.75 * fade) * dim

            ctx.saveGState()
            let anchor = point(th, rim - 44)
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: -th)

            let text = label(stop.seconds) as NSString
            let f = KidsStyle.font(selected ? 19 : 15, selected ? .bold : .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: f,
                .foregroundColor: (selected ? KidsStyle.readout
                                            : KidsStyle.lamp(1)).withAlphaComponent(alpha)]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attrs)

            if !stop.note.isEmpty {
                let n = stop.note.uppercased() as NSString
                let na: [NSAttributedString.Key: Any] = [
                    .font: KidsStyle.font(8.5, .semibold),
                    .foregroundColor: KidsStyle.lamp(1, alpha: alpha * 0.42)]
                let ns = n.size(withAttributes: na)
                n.draw(at: NSPoint(x: -ns.width / 2, y: -size.height / 2 - 12), withAttributes: na)
            }
            ctx.restoreGState()
        }

        // ---- the pointer, and the value it is reading
        let tip = point(0, rim - 1)
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: tip.x, y: tip.y - 9))
        tri.line(to: NSPoint(x: tip.x - 6, y: tip.y + 2))
        tri.line(to: NSPoint(x: tip.x + 6, y: tip.y + 2))
        tri.close()
        KidsStyle.readout.withAlphaComponent(CGFloat(dim)).setFill()
        tri.fill()

        // The reading is the speed the shutter will actually use, which is
        // the dial's unless the light has taken it away.
        let amber = KidsStyle.readout
        let used = autoSeconds ?? Float(seconds)
        let value = (ObservatoryMetalView.speedText(used) + " s") as NSString
        let va: [NSAttributedString.Key: Any] = [
            .font: KidsStyle.font(13.5, .bold),
            .foregroundColor: amber]
        let vs = value.size(withAttributes: va)
        if autoSeconds == nil {
            value.draw(at: NSPoint(x: bounds.midX - vs.width / 2, y: bounds.minY + 2),
                       withAttributes: va)
        } else {
            // "AUTO" beside the number, not instead of it: what matters is
            // that the camera is on a speed, and which one.
            let tag = "AUTO" as NSString
            let ta: [NSAttributedString.Key: Any] = [
                .font: KidsStyle.font(9.5, .semibold),
                .foregroundColor: amber.withAlphaComponent(0.60)]
            let ts = tag.size(withAttributes: ta)
            let gap: CGFloat = 6
            let left = bounds.midX - (vs.width + gap + ts.width) / 2
            value.draw(at: NSPoint(x: left, y: bounds.minY + 2), withAttributes: va)
            tag.draw(at: NSPoint(x: left + vs.width + gap,
                                 y: bounds.minY + 2 + (vs.height - ts.height) / 2),
                     withAttributes: ta)
        }
    }
}

/// Frosted glass under the exposure dial. The dial is a big disc of dark
/// glass laid over the sky; blurring what is behind it is what makes it read
/// as glass rather than as a hole cut in the picture, and it stops the stars
/// under the scale from competing with the numbers printed on it.
private final class DialGlassView: NSView {
    /// `NSVisualEffectView` rather than a `CIGaussianBlur` in
    /// `backgroundFilters`: the filter route is quietly ignored once the
    /// thing behind the layer is a `CAMetalLayer`, which here it always is.
    private let frosted = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        frosted.blendingMode = .withinWindow      // blur the sky, not the desktop
        frosted.material = .hudWindow
        frosted.state = .active
        frosted.appearance = NSAppearance(named: .darkAqua)
        frosted.wantsLayer = true
        frosted.layer?.masksToBounds = true
        // Every material carries a tint, and a tint over a night sky is
        // milk. Measured against black, `.hudWindow` lifts the picture by
        // sRGB 0.101 -- linear 0.0102 -- so the layer subtracts exactly that
        // much back off. The lift is a constant, so taking it away leaves
        // black where the sky was black and keeps the blurred light that is
        // actually there: a bright horizon behind the disc loses about 7% of
        // its brightness, a dark sky loses all of the milk.
        let clear = CIFilter(name: "CIColorMatrix")
        clear?.setValue(CIVector(x: -0.0102, y: -0.0102, z: -0.0102, w: 0),
                        forKey: "inputBiasVector")
        frosted.layer?.filters = clear.map { [$0] }
        addSubview(frosted)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        frosted.frame = bounds
        // Square by construction, so a corner radius of half the side is a
        // circle -- cheaper than a shape mask and it follows the frame.
        frosted.layer?.cornerRadius = bounds.width / 2
    }
    /// Purely decorative: the dial above it owns every touch in this area.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Round shutter button with the exposure drawn as a ring around it.
///
/// A real film shutter opens for as long as you hold it. This one does the
/// same: press to begin gathering light, release to develop the plate.
final class ShutterButton: NSView {
    /// One press. Opens the shutter, or closes it early if it is already open.
    var onPress: (() -> Void)?
    /// 0…1 of the current exposure.
    var progress: CGFloat = 1
    /// Whether the shutter is currently open. The button shows a stop square
    /// while it is, so the one control never leaves you guessing which press
    /// you are about to make.
    var isExposing: Bool = false
    private var isHeld: Bool = false
    private var flashAmount: CGFloat = 0
    private var flashTimer: Timer?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isHeld = true
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        isHeld = false
        needsDisplay = true
        // Fire only if the finger lifted on the button, as every other button
        // on the machine behaves; sliding off is how you change your mind.
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside { onPress?() }
    }

    /// Brief white pulse, the way a camera acknowledges the press.
    func flash() {
        flashAmount = 1
        flashTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.flashAmount -= 0.08
            if self.flashAmount <= 0 { self.flashAmount = 0; timer.invalidate() }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        flashTimer = t
    }

    deinit { flashTimer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)

        // outer ring: the track
        KidsStyle.lamp(1, alpha: 0.22).setStroke()
        let track = NSBezierPath(ovalIn: r)
        track.lineWidth = 3
        track.stroke()

        // progress arc, clockwise from the top
        if progress > 0.001 {
            let path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY),
                           radius: r.width / 2,
                           startAngle: 90,
                           endAngle: 90 - 360 * Double(min(progress, 1)),
                           clockwise: true)
            (KidsStyle.nightVision ? KidsStyle.accentOnNight
                : NSColor(calibratedRed: 0.55, green: 0.80, blue: 1, alpha: 0.95)).setStroke()
            path.lineWidth = 3
            path.stroke()
        }

        // the button itself — a touch smaller and dimmer while pressed, so
        // the shutter reads as a physical bulb the finger is squeezing.
        let squeeze: CGFloat = isHeld ? 2 : 0
        let inner = r.insetBy(dx: 9 + squeeze, dy: 9 + squeeze)
        let base: CGFloat = isHeld ? 0.72 : 0.88
        let white = base + 0.12 * flashAmount
        KidsStyle.lamp(white).setFill()
        if isExposing {
            // A rounded stop square while the plate is filling: the same
            // press that started it will end it.
            let stop = inner.insetBy(dx: inner.width * 0.22, dy: inner.height * 0.22)
            NSBezierPath(roundedRect: stop, xRadius: 3, yRadius: 3).fill()
            KidsStyle.lamp(white, alpha: 0.30).setStroke()
            let ring = NSBezierPath(ovalIn: inner)
            ring.lineWidth = 2
            ring.stroke()
        } else {
            NSBezierPath(ovalIn: inner).fill()
        }
    }
}

/// Small round toggle that cycles through a set of focal lengths, in the
/// manner of a phone camera's lens picker. Sits next to the shutter; each
/// tap advances to the next lens.
final class FocalLengthToggle: NSView {
    /// (millimetres on a full-frame sensor, vertical-half-FOV tangent).
    private let lenses: [(mm: Int, tan: Float)] = [
        (15,  0.8003),   // wide
        (21,  0.5714),
        (35,  0.3428),
        (90,  0.1333),
        (135, 0.0889),   // tight
    ]
    private var index: Int = 1   // starts at 21mm — matches the old default FOV
    var onChange: ((Int, Float) -> Void)?

    var currentMM: Int { lenses[index].mm }
    var currentHalfFovTan: Float { lenses[index].tan }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        index = (index + 1) % lenses.count
        needsDisplay = true
        onChange?(lenses[index].mm, lenses[index].tan)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        KidsStyle.lamp(1, alpha: 0.20).setStroke()
        let ring = NSBezierPath(ovalIn: r)
        ring.lineWidth = 1.5
        ring.stroke()
        let inner = r.insetBy(dx: 5, dy: 5)
        KidsStyle.lamp(0.08, alpha: 0.72).setFill()
        NSBezierPath(ovalIn: inner).fill()

        let label = "\(currentMM)" as NSString
        let a: [NSAttributedString.Key: Any] = [
            .font: KidsStyle.font(15.5, .bold),
            .foregroundColor: KidsStyle.lamp(0.92)]
        let sz = label.size(withAttributes: a)
        label.draw(at: NSPoint(x: bounds.midX - sz.width / 2,
                               y: bounds.midY - sz.height / 2 - 4), withAttributes: a)
        let unit = "mm" as NSString
        let ua: [NSAttributedString.Key: Any] = [
            .font: KidsStyle.font(8.5, .medium),
            .foregroundColor: KidsStyle.lamp(0.55)]
        let uz = unit.size(withAttributes: ua)
        unit.draw(at: NSPoint(x: bounds.midX - uz.width / 2,
                              y: bounds.midY + sz.height / 2 - 6), withAttributes: ua)
    }
}

// MARK: - Save confirmation

/// The shot you just took, shown small in the corner and then gone.
///
/// A camera's post-shot review exists to answer one question -- did that come
/// out? -- so this shows the actual saved pixels rather than a checkmark, and
/// removes itself before it can become clutter.
private final class PhotoToast: NSView {
    private let frameView = NSView()
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "Saved")
    private var hideWork: DispatchWorkItem?
    /// Matches the camera's own review window, so the corner clears at the
    /// same moment the viewfinder comes back.
    private static let hold = ObservatoryMetalView.reviewSeconds

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
        isHidden = true

        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = 8
        frameView.layer?.masksToBounds = true
        frameView.layer?.borderWidth = 1
        frameView.layer?.borderColor = KidsStyle.lamp(1, alpha: 0.22).cgColor
        frameView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: frameView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: frameView.bottomAnchor)
        ])

        caption.font = KidsStyle.font(11.5, .semibold)
        caption.textColor = KidsStyle.chromeInk
        caption.alignment = .center

        let stack = NSStackView(views: [frameView, caption])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 16:10-ish, small enough to leave the sky alone.
            frameView.widthAnchor.constraint(equalToConstant: 168),
            frameView.heightAnchor.constraint(equalToConstant: 105)
        ])
        setAccessibilityLabel("Saved photograph")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(image: NSImage?, caption text: String) {
        imageView.image = image
        caption.stringValue = text
        setAccessibilityLabel(text + " photograph")

        hideWork?.cancel()
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.45
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.alphaValue < 0.01 else { return }
                self.isHidden = true
                self.imageView.image = nil
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: work)
    }
}
