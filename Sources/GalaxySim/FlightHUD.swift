import AppKit
import simd

/// Flight controls shaped like the two things a thumb already knows: a
/// throttle strip on the left and a stick on the right.
///
/// ---------------------------------------------------------------------
/// EVERYTHING IS REACHABLE WITHOUT A KEYBOARD
/// ---------------------------------------------------------------------
/// W/S/A/D still fly the ship, but they are the shortcut and not the
/// interface. Two pads sit where two thumbs land on a tablet held in both
/// hands, and follow / pause / back are pills in the corner. Everything is
/// at least `KidsStyle.touchTarget` across.
///
/// The left pad is the speed gauge and the speed control at once, and it is
/// *relative*: put a thumb anywhere on it and slide up to gain speed, down to
/// brake. It used to be absolute — wherever you touched became the speed —
/// which meant the first touch always yanked the ship, and there is no way to
/// put a thumb down gently on a control like that. There is no + and − any
/// more, because sliding does their job without needing two more targets.
///
/// The right pad is a stick with a ring around it: push it to steer (left and
/// right *and* up and down), and turn the ring to roll. The stick reports a
/// *held* vector which the host reads once per frame in its flight
/// integrator, exactly the way it reads held keys — no timers, frame-rate
/// independent for free. The ring reports how far it was just turned, which
/// the ship takes as momentum rather than as an angle: wind it and let go and
/// the ship keeps rolling, then coasts to a stop.
///
/// Nothing here moves the ship itself. Every control states an intention and
/// the ship takes its time about it — see `FlightCamera`'s inertia section.
final class FlightHUD: NSView {
    var onClearTarget: (() -> Void)?
    var hasStarTarget = false { didSet { clearTargetButton.isHidden = !hasStarTarget || !controlsVisible; needsLayout = true } }
    private let clearTargetButton = PillButton(title: "Clear star", symbol: "xmark.circle")
    var onExit: (() -> Void)?
    var onPause: (() -> Void)?
    var onRecenter: (() -> Void)?
    var onSpeed: ((Float) -> Void)?
    /// Radians of ring travel. Not an angle to roll to: the ring is a heavy
    /// flywheel, and this is how hard it was just pushed.
    var onRoll: ((Float) -> Void)?

    var controlsVisible = true {
        didSet {
            subviews.forEach { $0.isHidden = !controlsVisible }
            clearTargetButton.isHidden = !controlsVisible || !hasStarTarget
            if !controlsVisible { releaseSteering() }
            needsDisplay = true
        }
    }

    private let title = NSTextField(labelWithString: "LUMEN  ·  CITY AMONG THE STARS")
    private let plate = NSTextField(labelWithString: Version.long)
    private let explain = NSTextField(labelWithString: "")
    private let velocity = NSTextField(labelWithString: "Cruise")
    private let help = NSTextField(labelWithString:
        "slide the left pad for speed   ·   push the stick to steer   ·   turn its ring to roll   ·   drag the sky to look")
    private let energy = ThrottleStrip()
    private let stick = ShipStick()

    private let pauseButton = PillButton(title: "Pause", symbol: "pause.fill")
    private let followButton = PillButton(title: "Follow", symbol: "scope")
    private let backButton = PillButton(title: "Back", symbol: "chevron.left")

    /// Held on-screen steering, −1…1 each. Read once per frame by the host
    /// alongside the held keys; never applied here, because this view has no
    /// idea how long a frame lasted.
    var padYaw: Float { stick.vector.x }
    var padPitch: Float { stick.vector.y }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        title.font = KidsStyle.font(11, .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.55)
        velocity.font = KidsStyle.font(17, .bold)
        velocity.textColor = KidsStyle.ink
        help.font = KidsStyle.font(11, .medium)
        help.textColor = NSColor.white.withAlphaComponent(0.45)
        help.alignment = .center
        plate.font = KidsStyle.font(9.5, .medium)
        plate.textColor = NSColor.white.withAlphaComponent(0.30)
        plate.toolTip = "Unix time plus three hundred years. It is when this build was switched on."
        // The one line that explains the picture rather than the controls, so
        // it is brighter than the help and sits above it.
        explain.font = KidsStyle.font(12, .semibold)
        explain.textColor = KidsStyle.accentOnNight.withAlphaComponent(0.92)
        explain.alignment = .center
        for f in [title, plate, velocity, help, explain] {
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }

        // ---- left pad: the gauge you slide -----------------------------
        energy.setAccessibilityLabel("Spaceship speed")
        energy.identifier = NSUserInterfaceItemIdentifier("flight.speed")
        energy.toolTip = "Put a thumb on it and slide up to speed up, down to brake. W and S also work."
        energy.onChange = { [weak self] fraction in
            self?.onSpeed?(FlightHUD.beta(at: fraction))
        }
        addSubview(energy)

        // ---- right pad: steer with the stick, roll with the ring -------
        stick.identifier = NSUserInterfaceItemIdentifier("flight.stick")
        stick.setAccessibilityLabel("Steer the spaceship")
        stick.toolTip = "Push to steer up, down, left and right. Turn the outer ring to roll. A and D also steer."
        stick.onRoll = { [weak self] radians in self?.onRoll?(radians) }
        addSubview(stick)

        // ---- the three things that are decisions, not steering --------
        pauseButton.identifier = NSUserInterfaceItemIdentifier("flight.pause")
        pauseButton.toolTip = "Freeze this moment. Space also pauses and resumes."
        pauseButton.onTap = { [weak self] in self?.onPause?() }
        followButton.identifier = NSUserInterfaceItemIdentifier("flight.follow")
        followButton.toolTip = "Swing the camera back behind the ship. C does the same."
        followButton.setAccessibilityLabel("Look from behind the ship again")
        followButton.onTap = { [weak self] in self?.onRecenter?() }
        backButton.identifier = NSUserInterfaceItemIdentifier("flight.exit")
        backButton.toolTip = "Stop flying and go back to the galaxy. Esc does the same."
        backButton.setAccessibilityLabel("Leave the ship")
        backButton.onTap = { [weak self] in self?.onExit?() }
        clearTargetButton.identifier = NSUserInterfaceItemIdentifier("flight.clearStar")
        clearTargetButton.onTap = { [weak self] in self?.onClearTarget?() }
        clearTargetButton.isHidden = true
        for b in [followButton, pauseButton, backButton, clearTargetButton] { addSubview(b) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Stop steering without a mouse-up. Losing the window, hiding the
    /// controls or leaving the ship all have to do this, or the ship keeps
    /// turning on its own with nothing on screen to explain why.
    func releaseSteering() {
        stick.release()
        energy.release()
    }

    // MARK: review hooks

    /// Everything the review harness drives by hand, in one place.
    func reviewControl(_ name: String) -> NSControl? {
        subviews.compactMap { $0 as? NSControl }
            .first { $0.identifier?.rawValue == name }
    }
    var reviewPauseTitle: String { pauseButton.title }
    var reviewThrottleFraction: CGFloat { energy.fraction }
    /// The explanation is the one line here that is worth reading, so a
    /// window narrow enough to clip it is a bug, not a cosmetic detail.
    var reviewExplanationFits: Bool {
        guard let font = explain.font, explain.frame.width > 0 else { return false }
        let widest = [0.5, 0.8, 0.95, 0.999]
            .map { FlightHUD.explanation(beta: Float($0)) }
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return widest <= explain.frame.width
    }
    /// Slide the throttle by a number of points, positive being upward.
    func reviewThrottleSlide(_ points: CGFloat) { energy.slideForReview(points) }
    func reviewSteer(x: Float, y: Float) { stick.holdForReview(SIMD2(x, y)) }
    func reviewRollDrag(_ radians: Float) { stick.rollForReview(radians) }

    /// The controls take clicks; everywhere else the drag belongs to the
    /// camera, which is what makes looking around feel unobstructed.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard controlsVisible, let hit = super.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let v = candidate, v !== self {
            if v is NSControl { return v }
            candidate = v.superview
        }
        return nil
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let margin: CGFloat = 26

        // ---- corner pills, laid out from the right edge inward --------
        var x = w - margin
        for pill in [backButton, pauseButton, followButton, clearTargetButton] where !pill.isHidden {
            let size = pill.intrinsicContentSize
            x -= size.width
            pill.frame = NSRect(x: x, y: 18, width: size.width, height: size.height)
            x -= 10
        }

        // Both pads hug the bottom corners: that is where thumbs are when a
        // tablet is held in two hands, and it leaves the middle of the sky —
        // the part worth looking at — completely clear.
        let barW: CGFloat = 72
        let barH = min(240, max(132, h * 0.34))
        let barY = h - margin - barH
        energy.frame = NSRect(x: margin + 4, y: barY, width: barW, height: barH)

        let side = min(212, max(168, h * 0.28)).rounded()
        stick.frame = NSRect(x: w - margin - side, y: h - margin - side,
                             width: side, height: side)

        velocity.frame = NSRect(x: margin + 4, y: barY - 30, width: min(340, w - 80), height: 26)

        let helpLeft = energy.frame.maxX + 24
        let helpWidth = max(0, stick.frame.minX - 24 - helpLeft)
        help.frame = NSRect(x: helpLeft, y: h - 28, width: helpWidth, height: 18)
        explain.frame = NSRect(x: helpLeft, y: h - 50, width: helpWidth, height: 18)
        title.frame = NSRect(x: margin + 4, y: 22, width: max(0, x - margin - 16), height: 18)
        plate.frame = NSRect(x: margin + 4, y: 42, width: max(0, x - margin - 16), height: 14)
    }

    // MARK: speed mapping

    /// The bar is LINEAR in beta: a full bar is light speed, half a bar is
    /// half light speed. The old slider used a logarithmic warp so that the
    /// travel was spent where the optics change most, which is defensible for
    /// an expert control and unreadable as a gauge — it put 0.5c at one
    /// segment out of sixteen. Fine control near c belongs on W and S, which
    /// step by the remaining gap to c; the gauge should just tell the truth.
    static func beta(at fraction: Float) -> Float {
        Relativity.clampBeta(min(max(fraction, 0), 1))
    }

    static func throttlePosition(beta: Float) -> Float {
        min(max(Relativity.clampBeta(beta), 0), 1)
    }

    func update(flight: FlightCamera, paused: Bool = false) {
        let name = flight.beta < 0.8 ? "Cruise" : (flight.beta < 0.98 ? "Warp" : "Extreme")
        let wanted = paused ? "Resume" : "Pause"
        if pauseButton.title != wanted {
            pauseButton.title = wanted
            pauseButton.symbolName = paused ? "play.fill" : "pause.fill"
            pauseButton.setAccessibilityLabel(paused ? "Resume flight" : "Pause flight")
            // The pill measures itself from its own title, so a longer word
            // has to move the pills beside it.
            needsLayout = true
        }
        velocity.stringValue = paused
            ? "Paused  ·  \(name)"
            : String(format: flight.beta >= 0.999 ? "%@  ·  %.2f%% light speed" : "%@  ·  %.1f%% light speed", name, flight.beta * 100)
        energy.fraction = CGFloat(Self.throttlePosition(beta: flight.beta))
        energy.commanded = CGFloat(Self.throttlePosition(beta: flight.commandedBeta))
        energy.paused = paused
        explain.stringValue = Self.explanation(beta: flight.beta)
        energy.setAccessibilityValue(String(format: "%.1f percent of light speed",
                                            flight.beta * 100))
    }

    /// Why the sky did that.
    ///
    /// It is the question the picture asks at speed, and "everything went to a
    /// small dot" looks exactly like a bug until someone says otherwise. All
    /// three effects are real and all three are in the render: aberration
    /// moves where light *seems* to come from, Doppler changes its colour,
    /// and beaming changes how bright it is.
    static func explanation(beta: Float) -> String {
        switch beta {
        case ..<0.30:
            return ""
        case ..<0.62:
            return "The stars ahead are going blue — you are running into their light."
        case ..<0.90:
            return "The sky is crowding ahead. That is aberration: you meet light head on."
        case ..<0.985:
            return "Aberration has squeezed most of the sky into that spot. Behind you it is dark and red."
        default:
            return "The whole sky is now one small dot ahead. Not a bug — this is what this speed looks like."
        }
    }

    override func draw(_ dirtyRect: NSRect) {}
}

// MARK: - Throttle strip

/// Segmented vertical energy meter, driven by a *relative* slide.
///
/// Touching it does nothing until you move: the value changes by how far the
/// thumb travelled, not by where it landed. That is what lets you rest a
/// thumb on it at 0.9c without the ship immediately dropping to whatever
/// speed your thumb happened to be over.
private final class ThrottleStrip: NSControl, TouchTarget {
    /// What the ship has got to.
    var fraction: CGFloat = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    /// Where the thumb has asked it to get to. The two are different for as
    /// long as the ship takes to accelerate, which at this size of ship is
    /// most of the time — so the gauge has to show both or the pad looks
    /// broken.
    var commanded: CGFloat = 0 { didSet { if commanded != oldValue { needsDisplay = true } } }
    var paused = false { didSet { needsDisplay = true } }
    var onChange: ((Float) -> Void)?

    private let segments = 16
    private var dragStartY: CGFloat = 0
    private var dragStartFraction: CGFloat = 0
    private var dragging = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: input

    override func mouseDown(with event: NSEvent) {
        dragStartY = convert(event.locationInWindow, from: nil).y
        // The thumb picks up the *target*, not the speed the ship happens to
        // have reached: otherwise every touch during a burn would throw away
        // the rest of it.
        dragStartFraction = commanded
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        slide(to: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseUp(with event: NSEvent) { dragging = false }

    /// Flipped view: y grows downward, and the bar fills upward, so sliding
    /// the thumb *up* has to raise the fraction.
    private func slide(to y: CGFloat) {
        // The whole strip is one full range of speed. Any shorter and the
        // control gets twitchy; any longer and you run out of pad.
        let f = dragStartFraction + (dragStartY - y) / max(bounds.height, 1)
        onChange?(Float(min(max(f, 0), 1)))
    }

    func release() { dragging = false }

    func slideForReview(_ points: CGFloat) {
        dragStartY = 0
        dragStartFraction = commanded
        dragging = true
        slide(to: -points)
        dragging = false
    }

    // MARK: drawing

    /// Cool at the bottom, hot at the top — the same reading as a heat gauge,
    /// so which end is "more" needs no legend.
    private func colour(for level: CGFloat) -> NSColor {
        let stops: [(CGFloat, NSColor)] = [
            (0.00, NSColor(calibratedRed: 0.20, green: 0.70, blue: 1.00, alpha: 1)),
            (0.55, NSColor(calibratedRed: 0.35, green: 1.00, blue: 0.85, alpha: 1)),
            (0.80, NSColor(calibratedRed: 1.00, green: 0.88, blue: 0.35, alpha: 1)),
            (1.00, NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.40, alpha: 1)),
        ]
        for i in 1..<stops.count where level <= stops[i].0 {
            let (a, ca) = stops[i - 1], (b, cb) = stops[i]
            let t = (level - a) / max(b - a, 0.0001)
            return NSColor(calibratedRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
                           green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
                           blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
                           alpha: 1)
        }
        return stops.last!.1
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let inset: CGFloat = 10
        let cells = r.insetBy(dx: inset, dy: inset)
        let gap: CGFloat = 3
        let cellH = (cells.height - gap * CGFloat(segments - 1)) / CGFloat(segments)
        let lit = fraction * CGFloat(segments)

        // outer casing
        let casing = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 0.05, alpha: 0.80).setFill()
        casing.fill()
        NSColor.white.withAlphaComponent(dragging ? 0.42 : 0.22).setStroke()
        casing.lineWidth = 1.5
        casing.stroke()

        var topLit: NSRect?
        for i in 0..<segments {
            // index 0 is the TOP cell, so invert to fill from the bottom
            let level = CGFloat(segments - i) / CGFloat(segments)
            let cell = NSRect(x: cells.minX, y: cells.minY + CGFloat(i) * (cellH + gap),
                              width: cells.width, height: cellH)
            let path = NSBezierPath(roundedRect: cell, xRadius: 3, yRadius: 3)

            let filled = CGFloat(segments - i) <= lit
            if filled {
                let c = colour(for: level)
                (paused ? c.withAlphaComponent(0.35) : c).setFill()
                path.fill()
                if topLit == nil {
                    topLit = cell
                    if !paused {
                        c.withAlphaComponent(0.35).setFill()
                        NSBezierPath(roundedRect: cell.insetBy(dx: -3, dy: -3),
                                     xRadius: 5, yRadius: 5).fill()
                    }
                }
            } else {
                NSColor.white.withAlphaComponent(0.07).setFill()
                path.fill()
            }
        }

        // The thumb grip, drawn at the TARGET rather than at the speed. This
        // is the part you drag, and it runs ahead of the bar while the ship
        // is still working its way up to it.
        let ty = cells.maxY - commanded * cells.height
        let marker = NSRect(x: r.minX + 3, y: ty - 4, width: r.width - 6, height: 8)
        let knob = NSBezierPath(roundedRect: marker, xRadius: 4, yRadius: 4)
        (paused ? KidsStyle.accentOnNight.withAlphaComponent(0.4) : KidsStyle.accentOnNight).setFill()
        knob.fill()
        NSColor(calibratedWhite: 0.05, alpha: 0.75).setStroke()
        let grip = NSBezierPath()
        for k in 0..<2 {
            let y = marker.midY - 2 + CGFloat(k) * 4
            grip.move(to: NSPoint(x: marker.midX - 12, y: y))
            grip.line(to: NSPoint(x: marker.midX + 12, y: y))
        }
        grip.lineWidth = 1.5
        grip.lineCapStyle = .round
        grip.stroke()

        // Which way is faster, in the only two glyphs that need no reading.
        NSColor.white.withAlphaComponent(0.4).setStroke()
        for (y, dir) in [(r.minY + 5.5, CGFloat(1)), (r.maxY - 5.5, CGFloat(-1))] {
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: r.midX - 6, y: y + 2.5 * dir))
            chevron.line(to: NSPoint(x: r.midX, y: y - 2.5 * dir))
            chevron.line(to: NSPoint(x: r.midX + 6, y: y + 2.5 * dir))
            chevron.lineWidth = 2
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.stroke()
        }
    }
}

// MARK: - Ship stick

/// A thumbstick with a roll ring around it.
///
/// The knob is *relative-origin*: wherever you put the thumb down becomes the
/// centre, and the vector is measured from there. A fixed centre only works
/// when you can see the control while you reach for it, which is exactly what
/// is not true of a thumb on the edge of a tablet.
///
/// The ring is 1:1 angular drag — turn it thirty degrees and the sky turns
/// thirty degrees, like a steering wheel. Rolling is not a rate, because
/// unlike steering there is no such thing as "keep rolling" that anyone
/// wants; you turn until the horizon looks right and stop.
final class ShipStick: NSControl, TouchTarget {
    /// x = yaw (right positive), y = pitch (nose up positive), −1…1.
    private(set) var vector = SIMD2<Float>(0, 0) { didSet { needsDisplay = true } }
    var onRoll: ((Float) -> Void)?

    private enum Grab { case none, knob, ring }
    private var grab = Grab.none
    private var origin = NSPoint.zero
    private var ringAngle: CGFloat = 0     // where the finger was last, radians
    private var ringTurned: CGFloat = 0    // accumulated, for the drawn ticks

    /// Deliberately NOT flipped, so +y is up and the stick's maths reads the
    /// way the pilot's does.
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: geometry

    private var centre: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private var ringOuter: CGFloat { min(bounds.width, bounds.height) / 2 - 2 }
    private var ringThickness: CGFloat { 24 }
    private var ringInner: CGFloat { ringOuter - ringThickness }
    private var innerRadius: CGFloat { ringInner - 7 }
    private var knobRadius: CGFloat { max(22, innerRadius * 0.42) }
    private var travel: CGFloat { max(12, innerRadius - knobRadius) }

    // MARK: input

    /// A square frame around a round control: the corners belong to the sky,
    /// so a drag that starts just outside the ring looks around instead of
    /// rolling the ship by accident.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard hypot(p.x - centre.x, p.y - centre.y) <= ringOuter else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let d = hypot(p.x - centre.x, p.y - centre.y)
        if d > ringInner {
            grab = .ring
            ringAngle = atan2(p.y - centre.y, p.x - centre.x)
        } else {
            grab = .knob
            // Clamp the origin inward so that a thumb landing near the rim
            // still has a full push available in every direction.
            origin = clampedOrigin(p)
            vector = .zero
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch grab {
        case .none: break
        case .knob:
            var v = SIMD2<Float>(Float((p.x - origin.x) / travel),
                                 Float((p.y - origin.y) / travel))
            let len = simd_length(v)
            if len > 1 { v /= len }
            vector = v
        case .ring:
            let now = atan2(p.y - centre.y, p.x - centre.x)
            var delta = now - ringAngle
            // Shortest way round, so crossing the top of the ring does not
            // snap the ship through a full turn.
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            ringAngle = now
            ringTurned += delta
            // Dragging the ring clockwise turns the picture clockwise: the
            // ring is the view, not the ship. Direct manipulation is the one
            // roll convention nobody has to be taught.
            onRoll?(Float(delta))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) { release() }

    private func clampedOrigin(_ p: NSPoint) -> NSPoint {
        let dx = p.x - centre.x, dy = p.y - centre.y
        let limit = max(0, innerRadius - travel)
        let d = hypot(dx, dy)
        guard d > limit, d > 0 else { return p }
        return NSPoint(x: centre.x + dx / d * limit, y: centre.y + dy / d * limit)
    }

    /// Self-centring: let go and the ship stops turning, which is the only
    /// behaviour that makes a stick safe to drop.
    func release() {
        grab = .none
        vector = .zero
        needsDisplay = true
    }

    func holdForReview(_ v: SIMD2<Float>) {
        grab = .knob
        origin = centre
        let len = simd_length(v)
        vector = len > 1 ? v / len : v
    }

    func rollForReview(_ radians: Float) {
        ringTurned += CGFloat(radians)
        onRoll?(radians)
        needsDisplay = true
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = centre
        func circle(_ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        // ---- roll ring -------------------------------------------------
        let ring = circle(ringOuter)
        ring.append(circle(ringInner).reversed)
        ring.windingRule = .evenOdd
        NSColor(calibratedWhite: 0.05, alpha: 0.82).setFill()
        ring.fill()
        NSColor.white.withAlphaComponent(grab == .ring ? 0.45 : 0.20).setStroke()
        let outline = circle(ringOuter); outline.lineWidth = 1.5; outline.stroke()
        let inline = circle(ringInner); inline.lineWidth = 1; inline.stroke()

        // Ticks that turn with the drag, so the ring visibly grips.
        let tickColour = grab == .ring ? KidsStyle.accentOnNight : NSColor.white.withAlphaComponent(0.30)
        tickColour.setStroke()
        for i in 0..<24 {
            let a = ringTurned + CGFloat(i) * .pi / 12
            let major = i % 6 == 0
            let r0 = ringInner + (major ? 3 : 7)
            let r1 = ringOuter - (major ? 3 : 7)
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
            tick.line(to: NSPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
            tick.lineWidth = major ? 2.5 : 1.5
            tick.lineCapStyle = .round
            tick.stroke()
        }

        // ---- stick well ------------------------------------------------
        let well = circle(innerRadius)
        NSColor(calibratedWhite: 0.04, alpha: 0.72).setFill()
        well.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        well.lineWidth = 1
        well.stroke()

        // Four chevrons: this pad goes up and down as well as left and right,
        // which is the whole point of replacing the two turn buttons.
        NSColor.white.withAlphaComponent(0.34).setStroke()
        for i in 0..<4 {
            let a = CGFloat(i) * .pi / 2
            let r = innerRadius - 9
            let tip = NSPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            let back = NSPoint(x: c.x + cos(a) * (r - 6), y: c.y + sin(a) * (r - 6))
            let nx = -sin(a) * 5, ny = cos(a) * 5
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: back.x + nx, y: back.y + ny))
            chevron.line(to: tip)
            chevron.line(to: NSPoint(x: back.x - nx, y: back.y - ny))
            chevron.lineWidth = 2
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.stroke()
        }

        // ---- knob ------------------------------------------------------
        let base = grab == .knob ? origin : c
        let knob = NSPoint(x: base.x + CGFloat(vector.x) * travel,
                           y: base.y + CGFloat(vector.y) * travel)
        let accent = KidsStyle.accentOnNight
        func knobCircle(_ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: knob.x - r, y: knob.y - r, width: r * 2, height: r * 2))
        }
        accent.withAlphaComponent(simd_length(vector) > 0.02 ? 0.30 : 0.16).setFill()
        knobCircle(knobRadius + 5).fill()
        accent.withAlphaComponent(0.92).setFill()
        knobCircle(knobRadius).fill()
        NSColor.white.withAlphaComponent(0.75).setStroke()
        let rim = knobCircle(knobRadius); rim.lineWidth = 1.5; rim.stroke()
        NSColor(calibratedWhite: 0.05, alpha: 0.55).setFill()
        knobCircle(max(3, knobRadius * 0.22)).fill()
    }
}
