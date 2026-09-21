import AppKit

/// A document view that grows downward from the top. Without this the
/// scroll view anchors short content to the bottom, leaving a gap above.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Translucent sidebar of native controls. Communicates upward through
/// closures so it knows nothing about the simulation.
final class ControlPanel: NSVisualEffectView {

    var onScene:       ((Int) -> Void)?
    var onPlayPause:   ((Bool) -> Void)?
    var onRestart:     (() -> Void)?
    var onSpeed:       ((Float) -> Void)?
    var onSolver:      ((SolverMode) -> Void)?
    var onBudget:      ((Int) -> Void)?
    var onVisuals:     ((RenderSettings) -> Void)?
    var onAudio:       ((Bool, Float) -> Void)?
    var onCamera:      ((Bool) -> Void)?
    var onExitEngineer: (() -> Void)?
    var onTrackVolume: ((AmbientAudio.Track, Float) -> Void)?
    var onSaveSettings: (() -> Bool)?
    var onResetSettings: (() -> Void)?
    /// (type, massScale, tiltDegrees) for the next placement
    var onPlaceModeChanged: ((Bool) -> Void)?
    var onAutoOrbit:   (() -> Void)?
    var onClearBuild:  (() -> Void)?

    private(set) var placeMode = false
    var selectedType: GalaxyType { GalaxyType.allCases[typePopup.indexOfSelectedItem] }
    var selectedMass: Float { Float(massSlider.doubleValue) }
    var selectedTilt: Float { Float(tiltSlider.doubleValue) }

    private let scenePopup   = NSPopUpButton()
    private let solverPopup  = NSPopUpButton()
    private let budgetPopup  = NSPopUpButton()
    private let playButton   = NSButton()
    private let restartButton = NSButton()
    private let timeLabel    = NSTextField(labelWithString: "0 Myr")
    private let statsLabel   = NSTextField(labelWithString: "")
    private let fpsLabel     = NSTextField(labelWithString: "")

    private var speedSlider    = NSSlider()
    private var exposureSlider = NSSlider()
    private var bloomSlider    = NSSlider()
    private var starSlider     = NSSlider()
    private var webSlider      = NSSlider()
    private var volumeSlider   = NSSlider()
    private var trackSliders: [AmbientAudio.Track: NSSlider] = [:]
    private let saveButton = NSButton()
    private let resetButton = NSButton()
    private let savedLabel = NSTextField(labelWithString: "")
    private var massSlider     = NSSlider()
    private var tiltSlider     = NSSlider()
    private let audioSwitch    = NSSwitch()
    private let orbitSwitch    = NSSwitch()
    private let typePopup      = NSPopUpButton()
    private let placeButton    = NSButton()
    private let builtLabel     = NSTextField(labelWithString: "no galaxies placed")

    private var visuals = RenderSettings()
    private(set) var isPlaying = true

    private let budgets = [50_000, 150_000, 300_000, 600_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000]

    init(sceneNames: [String], initialBudget: Int) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        translatesAutoresizingMaskIntoConstraints = false
        build(sceneNames: sceneNames, initialBudget: initialBudget)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Construction helpers

    private func header(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = .systemFont(ofSize: 9, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        return l
    }

    private func row(_ text: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let s = NSStackView(views: [l, control])
        s.orientation = .horizontal
        s.distribution = .fill
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return s
    }

    private func slider(_ min: Double, _ max: Double, _ value: Double,
                        _ action: Selector) -> NSSlider {
        let s = NSSlider(value: value, minValue: min, maxValue: max,
                         target: self, action: action)
        s.controlSize = .small
        s.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return s
    }

    private func build(sceneNames: [String], initialBudget: Int) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 15, bottom: 14, right: 15)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        let title = NSTextField(labelWithString: "90s ENGINEER MODE")
        title.font = .systemFont(ofSize: 13, weight: .bold)
        stack.addArrangedSubview(title)

        let back = NSButton(title: "◀ Simple mode", target: self,
                            action: #selector(exitEngineerTapped))
        back.bezelStyle = .rounded
        back.controlSize = .small
        stack.addArrangedSubview(back)

        // ---- encounter presets
        stack.addArrangedSubview(header("Encounter"))
        scenePopup.addItems(withTitles: sceneNames)
        scenePopup.target = self
        scenePopup.action = #selector(sceneChanged)
        scenePopup.controlSize = .small
        scenePopup.widthAnchor.constraint(equalToConstant: 205).isActive = true
        stack.addArrangedSubview(scenePopup)

        // ---- build your own
        stack.addArrangedSubview(header("Build your own"))
        typePopup.addItems(withTitles: GalaxyType.allCases.map(\.displayName))
        typePopup.selectItem(at: 2)
        typePopup.controlSize = .small
        typePopup.widthAnchor.constraint(equalToConstant: 205).isActive = true
        stack.addArrangedSubview(typePopup)

        massSlider = makeSlider(0.05, 2.5, 1.0, #selector(noop))
        stack.addArrangedSubview(row("Mass", massSlider))
        tiltSlider = makeSlider(0, 90, 25, #selector(noop))
        stack.addArrangedSubview(row("Tilt°", tiltSlider))

        placeButton.title = "Place mode: off"
        placeButton.bezelStyle = .rounded
        placeButton.controlSize = .small
        placeButton.target = self
        placeButton.action = #selector(placeToggled)
        placeButton.widthAnchor.constraint(equalToConstant: 205).isActive = true
        stack.addArrangedSubview(placeButton)

        let orbitBtn = NSButton(title: "Auto-orbit", target: self, action: #selector(autoOrbitTapped))
        orbitBtn.bezelStyle = .rounded; orbitBtn.controlSize = .small
        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearTapped))
        clearBtn.bezelStyle = .rounded; clearBtn.controlSize = .small
        let buildRow = NSStackView(views: [orbitBtn, clearBtn])
        buildRow.orientation = .horizontal; buildRow.spacing = 6
        stack.addArrangedSubview(buildRow)

        builtLabel.font = .systemFont(ofSize: 9)
        builtLabel.textColor = .tertiaryLabelColor
        builtLabel.lineBreakMode = .byWordWrapping
        builtLabel.maximumNumberOfLines = 4
        builtLabel.preferredMaxLayoutWidth = 205
        stack.addArrangedSubview(builtLabel)

        // ---- transport
        stack.addArrangedSubview(header("Transport"))
        playButton.title = "Pause"
        playButton.bezelStyle = .rounded
        playButton.target = self
        playButton.action = #selector(playPauseTapped)
        playButton.controlSize = .small
        restartButton.title = "Restart"
        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartTapped)
        restartButton.controlSize = .small
        let transport = NSStackView(views: [playButton, restartButton])
        transport.orientation = .horizontal
        transport.spacing = 6
        stack.addArrangedSubview(transport)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(timeLabel)

        speedSlider = makeSlider(0.1, 6, 1, #selector(speedChanged))
        stack.addArrangedSubview(row("Speed", speedSlider))

        // ---- solver
        stack.addArrangedSubview(header("Solver"))
        solverPopup.addItems(withTitles: SolverMode.allCases.map(\.displayName))
        solverPopup.target = self
        solverPopup.action = #selector(solverChanged)
        solverPopup.controlSize = .small
        solverPopup.widthAnchor.constraint(equalToConstant: 205).isActive = true
        stack.addArrangedSubview(solverPopup)

        budgetPopup.addItems(withTitles: budgets.map { $0 >= 1_000_000 ? "\($0 / 1_000_000)M stars" : "\($0 / 1000)k stars" })
        budgetPopup.selectItem(at: budgets.firstIndex(of: initialBudget) ?? 2)
        budgetPopup.target = self
        budgetPopup.action = #selector(budgetChanged)
        budgetPopup.controlSize = .small
        budgetPopup.widthAnchor.constraint(equalToConstant: 205).isActive = true
        stack.addArrangedSubview(budgetPopup)

        // ---- look
        stack.addArrangedSubview(header("Look"))
        exposureSlider = makeSlider(0.2, 3.0, Double(visuals.exposure), #selector(visualChanged))
        stack.addArrangedSubview(row("Exposure", exposureSlider))
        bloomSlider = makeSlider(0.0, 2.0, Double(visuals.psfStrength), #selector(visualChanged))
        stack.addArrangedSubview(row("Glow", bloomSlider))
        starSlider = makeSlider(0.2, 2.5, Double(visuals.starSize), #selector(visualChanged))
        stack.addArrangedSubview(row("Star size", starSlider))
        // non-linear: almost all the useful range is near zero
        webSlider = makeSlider(0, 1, sqrt(Double(visuals.webStrength) / 0.06), #selector(visualChanged))
        stack.addArrangedSubview(row("Cosmic web", webSlider))

        orbitSwitch.state = .on
        orbitSwitch.target = self
        orbitSwitch.action = #selector(orbitChanged)
        orbitSwitch.controlSize = .mini
        stack.addArrangedSubview(row("Auto-orbit cam", orbitSwitch))

        // ---- audio
        stack.addArrangedSubview(header("Ambience"))
        audioSwitch.state = .on
        audioSwitch.target = self
        audioSwitch.action = #selector(audioChanged)
        audioSwitch.controlSize = .mini
        stack.addArrangedSubview(row("Music", audioSwitch))
        volumeSlider = makeSlider(0, 1, 0.55, #selector(audioChanged))
        stack.addArrangedSubview(row("Master", volumeSlider))

        // One fader per layer, so the mix can be set to taste rather than
        // only turned down as a whole.
        for t in AmbientAudio.Track.allCases {
            let sl = makeSlider(0, 1, 1.0, #selector(trackVolumeChanged(_:)))
            sl.tag = Int(AmbientAudio.Track.allCases.firstIndex(of: t) ?? 0)
            trackSliders[t] = sl
            stack.addArrangedSubview(row(t.displayName, sl))
        }

        // ---- config
        stack.addArrangedSubview(header("Config"))
        let saveRow = NSStackView(views: [saveButton, resetButton])
        saveRow.orientation = .horizontal
        saveRow.spacing = 6
        saveButton.title = "Save settings"
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        resetButton.title = "Reset"
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        stack.addArrangedSubview(saveRow)

        savedLabel.font = .systemFont(ofSize: 9)
        savedLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(savedLabel)

        // ---- readouts
        stack.addArrangedSubview(header("Status"))
        for l in [fpsLabel, statsLabel] {
            l.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            l.textColor = .tertiaryLabelColor
            l.lineBreakMode = .byWordWrapping
            l.maximumNumberOfLines = 3
            l.preferredMaxLayoutWidth = 205
            stack.addArrangedSubview(l)
        }

        let hint = NSTextField(labelWithString:
            "drag orbit · scroll zoom · space play/pause · R restart · S screenshot")
        hint.font = .systemFont(ofSize: 9)
        hint.textColor = .quaternaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = 205
        stack.addArrangedSubview(hint)
    }

    private func makeSlider(_ lo: Double, _ hi: Double, _ v: Double,
                            _ action: Selector) -> NSSlider {
        let s = NSSlider(value: v, minValue: lo, maxValue: hi, target: self, action: action)
        s.controlSize = .small
        s.isContinuous = true
        s.widthAnchor.constraint(equalToConstant: 120).isActive = true
        return s
    }

    @objc private func noop() {}

    // MARK: Actions

    @objc private func exitEngineerTapped() { onExitEngineer?() }

    @objc private func trackVolumeChanged(_ sender: NSSlider) {
        let all = AmbientAudio.Track.allCases
        guard all.indices.contains(sender.tag) else { return }
        onTrackVolume?(all[sender.tag], Float(sender.doubleValue))
    }

    @objc private func saveTapped() {
        let ok = onSaveSettings?() ?? false
        savedLabel.stringValue = ok ? "Saved — restored on next launch."
                                    : "Could not save."
        // clear the confirmation so it does not look stale
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            self?.savedLabel.stringValue = ""
        }
    }

    @objc private func resetTapped() {
        onResetSettings?()
        savedLabel.stringValue = "Reset to defaults."
    }

    /// Push a loaded configuration into the controls, without firing their
    /// actions back at the host.
    func apply(_ s: Settings) {
        exposureSlider.doubleValue = Double(s.exposure)
        bloomSlider.doubleValue = Double(s.psfStrength)
        starSlider.doubleValue = Double(s.starSize)
        speedSlider.doubleValue = 1
        volumeSlider.doubleValue = Double(s.masterVolume)
        audioSwitch.state = s.audioEnabled ? .on : .off
        orbitSwitch.state = s.autoOrbit ? .on : .off
        if let i = SolverMode.allCases.firstIndex(of: s.solver) {
            solverPopup.selectItem(at: i)
        }
        syncBudget(s.particleBudget)
        for (t, sl) in trackSliders {
            sl.doubleValue = Double(s.trackVolumes[t.rawValue] ?? 1)
        }
    }

    var trackVolumeValues: [String: Float] {
        var out: [String: Float] = [:]
        for (t, sl) in trackSliders { out[t.rawValue] = Float(sl.doubleValue) }
        return out
    }

    @objc private func sceneChanged() { onScene?(scenePopup.indexOfSelectedItem) }

    @objc private func playPauseTapped() {
        isPlaying.toggle()
        playButton.title = isPlaying ? "Pause" : "Play"
        onPlayPause?(isPlaying)
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        playButton.title = playing ? "Pause" : "Play"
        onPlayPause?(playing)
    }

    @objc private func restartTapped() { onRestart?() }

    @objc private func speedChanged() { onSpeed?(Float(speedSlider.doubleValue)) }

    @objc private func solverChanged() {
        let m = SolverMode.allCases[solverPopup.indexOfSelectedItem]
        onSolver?(m)
    }

    @objc private func budgetChanged() {
        onBudget?(budgets[budgetPopup.indexOfSelectedItem])
    }

    @objc private func visualChanged() {
        visuals.exposure      = Float(exposureSlider.doubleValue)
        visuals.psfStrength = Float(bloomSlider.doubleValue)
        visuals.starSize      = Float(starSlider.doubleValue)
        let wv = webSlider.doubleValue
        visuals.webStrength   = Float(wv * wv * 0.06)
        onVisuals?(visuals)
    }

    @objc private func orbitChanged() { onCamera?(orbitSwitch.state == .on) }

    @objc private func audioChanged() {
        onAudio?(audioSwitch.state == .on, Float(volumeSlider.doubleValue))
    }

    @objc private func placeToggled() {
        placeMode.toggle()
        placeButton.title = placeMode ? "Place mode: ON (click sky)" : "Place mode: off"
        onPlaceModeChanged?(placeMode)
    }

    @objc private func autoOrbitTapped() { onAutoOrbit?() }
    @objc private func clearTapped()     { onClearBuild?() }

    func updateBuilt(_ description: String) { builtLabel.stringValue = description }

    // MARK: Updates from the host

    func updateTime(current: Float) {
        timeLabel.stringValue = String(format: "%.0f Myr", current)
    }

    func updateReadouts(fps: String, stats: String) {
        fpsLabel.stringValue = fps
        statsLabel.stringValue = stats
    }

    func syncBudget(_ budget: Int) {
        if let i = budgets.firstIndex(of: budget) { budgetPopup.selectItem(at: i) }
    }
}
