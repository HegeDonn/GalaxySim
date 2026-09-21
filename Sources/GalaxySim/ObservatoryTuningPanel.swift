import AppKit

/// The engineering panel: one slider per number in `ObservatoryTuning`, live
/// over the sky, with a way to keep what you found.
///
/// It is deliberately not part of the camera. The dial, the shutter and the
/// focal-length toggle are the instrument a visitor uses; this is the bench it
/// was built on, and it stays behind the `E` key so it never stands between a
/// child and the sky. Press E again and it is gone.
final class ObservatoryTuningPanel: NSView {

    /// Fires whenever a value moves, so the sky can redraw immediately.
    var onChange: ((ObservatoryTuning) -> Void)?

    private var rows: [String: TuningRow] = [:]
    private let footer = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let presets = NSSegmentedControl()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.94).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor

        let title = NSTextField(labelWithString: "Engineering")
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        let hint = NSTextField(labelWithString: "E hides this · values are live")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        let head = NSStackView(views: [title, hint])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 2

        // The presets sit above the sliders, not instead of them: picking one
        // fills every row in, so it doubles as a starting point for a tweak
        // rather than a separate mode you have to leave.
        presets.segmentStyle = .rounded
        presets.segmentCount = ObservatoryTuning.presets.count
        presets.trackingMode = .selectOne
        for (i, preset) in ObservatoryTuning.presets.enumerated() {
            presets.setLabel(preset.name, forSegment: i)
            presets.setWidth(88, forSegment: i)
            (presets.cell as? NSSegmentedCell)?.setToolTip(preset.blurb, forSegment: i)
        }
        presets.target = self
        presets.action = #selector(pickPreset)
        presets.font = .systemFont(ofSize: 10)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)

        var lastGroup = ""
        for field in ObservatoryTuning.fields {
            if field.group != lastGroup {
                lastGroup = field.group
                let header = NSTextField(labelWithString: field.group.uppercased())
                header.font = .systemFont(ofSize: 9, weight: .heavy)
                header.textColor = NSColor(calibratedRed: 0.55, green: 0.85,
                                           blue: 0.97, alpha: 1)
                stack.addArrangedSubview(header)
            }
            let row = TuningRow(field: field)
            row.onEdit = { [weak self] value in self?.apply(field: field, value: value) }
            rows[field.key] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 250).isActive = true
        }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.controlSize = .mini
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        // A stack view inside a clip view has to be pinned on three sides and
        // left free on the fourth; without this it reports no height at all
        // and the panel comes up as a title with nothing under it.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])

        let save = button("Save as defaults", #selector(saveValues))
        let reset = button("Reset", #selector(resetValues))
        let copy = button("Copy Swift", #selector(copyValues))
        let buttons = NSStackView(views: [save, reset, copy])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        footer.font = .systemFont(ofSize: 10)
        footer.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        footer.lineBreakMode = .byTruncatingMiddle
        footer.stringValue = ""

        let column = NSStackView(views: [head, presets, scroll, buttons, footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            presets.widthAnchor.constraint(equalToConstant: 268),
            scroll.widthAnchor.constraint(equalToConstant: 268),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            footer.widthAnchor.constraint(equalToConstant: 268),
        ])
        // Wants to be tall enough for the whole list, yields to the window
        // when there is not room for it, and scrolls for the rest.
        let tall = scroll.heightAnchor.constraint(equalToConstant: 620)
        tall.priority = .defaultHigh
        tall.isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    /// Reflect the live values into every row. Called on open, and after a
    /// reset, so the panel never disagrees with the picture.
    func refresh() {
        for field in ObservatoryTuning.fields {
            rows[field.key]?.value = ObservatoryTuning.current[keyPath: field.path]
        }
        let match = ObservatoryTuning.current.matchingPreset
        presets.selectedSegment = ObservatoryTuning.presets.firstIndex { $0.name == match?.name } ?? -1
        if footer.stringValue.isEmpty || footer.stringValue.hasPrefix("Sky:") {
            footer.stringValue = "Sky: " + (match?.name ?? "your own settings")
        }
    }

    @objc private func pickPreset() {
        let index = presets.selectedSegment
        guard ObservatoryTuning.presets.indices.contains(index) else { return }
        let preset = ObservatoryTuning.presets[index]
        ObservatoryTuning.current = preset.values
        footer.stringValue = "Sky: " + preset.name
        refresh()
        onChange?(ObservatoryTuning.current)
    }

    /// Used by the hamburger menu, which picks presets without opening this.
    func selectPreset(named name: String) {
        guard let index = ObservatoryTuning.presets.firstIndex(where: { $0.name == name })
        else { return }
        presets.selectedSegment = index
        pickPreset()
    }

    private func apply(field: ObservatoryTuning.Field, value: Float) {
        ObservatoryTuning.current[keyPath: field.path] = value
        let match = ObservatoryTuning.current.matchingPreset
        presets.selectedSegment = ObservatoryTuning.presets.firstIndex { $0.name == match?.name } ?? -1
        footer.stringValue = "Sky: " + (match?.name ?? "your own settings")
        onChange?(ObservatoryTuning.current)
    }

    @objc private func saveValues() {
        switch ObservatoryTuning.current.save() {
        case .success(let url):
            footer.stringValue = "Saved · \(url.path)"
        case .failure(let error):
            footer.stringValue = "Not saved · \(error.localizedDescription)"
        }
    }

    @objc private func resetValues() {
        ObservatoryTuning.current = .builtIn
        refresh()
        onChange?(ObservatoryTuning.current)
        footer.stringValue = "Back to the sky the app ships with"
    }

    @objc private func copyValues() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ObservatoryTuning.current.swiftLiteral, forType: .string)
        footer.stringValue = "Swift on the clipboard"
    }
}

/// One labelled slider with a typeable number beside it.
///
/// Ranges that span decades are swept in log space: a linear slider from 20 to
/// a million would spend nineteen twentieths of its travel above 50 000, which
/// makes the useful end of it unusable.
private final class TuningRow: NSView {

    var onEdit: ((Float) -> Void)?

    private let field: ObservatoryTuning.Field
    private let slider = NSSlider()
    private let number = NSTextField()
    private var updating = false

    var value: Float = 0 {
        didSet {
            updating = true
            slider.doubleValue = Double(toSlider(value))
            number.stringValue = format(value)
            updating = false
        }
    }

    init(field: ObservatoryTuning.Field) {
        self.field = field
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: field.title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        label.toolTip = field.blurb

        number.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        number.alignment = .right
        number.isBordered = false
        number.drawsBackground = false
        number.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        number.target = self
        number.action = #selector(typed)
        number.toolTip = "Type an exact value"

        slider.minValue = 0
        slider.maxValue = 1
        slider.controlSize = .mini
        slider.target = self
        slider.action = #selector(slid)
        slider.toolTip = field.blurb

        let head = NSStackView(views: [label, NSView(), number])
        head.orientation = .horizontal
        head.spacing = 4
        let column = NSStackView(views: [head, slider])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            head.widthAnchor.constraint(equalTo: column.widthAnchor),
            slider.widthAnchor.constraint(equalTo: column.widthAnchor),
            number.widthAnchor.constraint(equalToConstant: 62),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func toSlider(_ v: Float) -> Float {
        let clamped = min(max(v, field.min), field.max)
        if field.log {
            let lo = log(max(field.min, 1e-6)), hi = log(field.max)
            return (log(max(clamped, 1e-6)) - lo) / (hi - lo)
        }
        return (clamped - field.min) / (field.max - field.min)
    }
    private func fromSlider(_ t: Float) -> Float {
        if field.log {
            let lo = log(max(field.min, 1e-6)), hi = log(field.max)
            return exp(lo + (hi - lo) * t)
        }
        return field.min + (field.max - field.min) * t
    }
    private func format(_ v: Float) -> String {
        if abs(v) >= 1000 { return String(format: "%.0f", v) }
        if abs(v) >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.3f", v)
    }

    @objc private func slid() {
        guard !updating else { return }
        let v = fromSlider(Float(slider.doubleValue))
        number.stringValue = format(v)
        onEdit?(v)
    }
    @objc private func typed() {
        guard let typed = Float(number.stringValue.replacingOccurrences(of: ",", with: ".")) else {
            number.stringValue = format(fromSlider(Float(slider.doubleValue)))
            return
        }
        // Typing is the escape hatch from the slider's range: a number outside
        // it is honoured, and the slider simply pins to its end.
        value = typed
        onEdit?(typed)
    }
}

/// The corner button that opens the sky menu: three bars in a soft circle.
///
/// Drawn rather than labelled because every other control over this sky is
/// drawn — a system-bezelled button in the corner would be the one piece of
/// chrome sitting on top of the night instead of floating in it.
final class SkyMenuButton: NSView {

    var onPress: (() -> Void)?

    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Choose a sky, or open all the numbers")
        toolTip = "Choose a sky · E for all the numbers"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let circle = NSBezierPath(ovalIn: inset)
        NSColor(calibratedWhite: pressed ? 0.26 : (hovering ? 0.20 : 0.14),
                alpha: hovering || pressed ? 0.92 : 0.72).setFill()
        circle.fill()
        NSColor(calibratedWhite: 1, alpha: hovering ? 0.30 : 0.16).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let width = inset.width * 0.42
        let x = inset.midX - width / 2
        NSColor(calibratedWhite: 0.94, alpha: 0.92).setStroke()
        let bars = NSBezierPath()
        bars.lineWidth = 1.6
        bars.lineCapStyle = .round
        for offset in [-5.0, 0.0, 5.0] as [CGFloat] {
            bars.move(to: NSPoint(x: x, y: inset.midY + offset))
            bars.line(to: NSPoint(x: x + width, y: inset.midY + offset))
        }
        bars.stroke()
    }
}
