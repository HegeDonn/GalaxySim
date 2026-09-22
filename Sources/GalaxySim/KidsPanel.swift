import AppKit

// =====================================================================
// MARK: - Kids Mode panel
//
// The playful counterpart to ControlPanel ("90s Engineer Mode"). Same
// closure-based contract so the host can swap one for the other, but the
// surface is all big icon buttons: nothing to configure, everything to
// poke at. Anything advanced lives behind the hamburger, which the host
// answers by revealing the engineer panel.
//
// ---------------------------------------------------------------------
// THERE IS NO SIDEBAR
// ---------------------------------------------------------------------
// Kids mode is meant to be *looked through*. Everything therefore floats
// over the render view in small clusters that hug the edges, and the
// middle of the screen — where the galaxies are — stays empty. No opaque
// panel, no vibrancy slab: each individual control carries its own
// rounded night-sky plate, exactly like the hotbar chips.
//
// ---------------------------------------------------------------------
// HOW THE HOST INSTALLS IT  (two views, both siblings of the Metal view)
// ---------------------------------------------------------------------
//   1. `KidsPanel` itself is a FULL-BLEED TRANSPARENT OVERLAY. Add it
//      above the Metal view and pin ALL FOUR EDGES to the render view:
//
//          let kids = KidsPanel(sceneNames: names)
//          kids.translatesAutoresizingMaskIntoConstraints = false
//          view.addSubview(kids)
//          NSLayoutConstraint.activate([
//              kids.topAnchor.constraint(equalTo: metalView.topAnchor),
//              kids.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
//              kids.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
//              kids.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
//          ])
//
//      It paints nothing, has no intrinsic size (`noIntrinsicMetric` on
//      both axes, so a stray width constraint cannot squeeze it) and
//      returns nil from `hitTest` everywhere except on an actual control
//      — so dragging the sky still works straight through it.
//
//      Its children place themselves: title + hamburger + fly at the top
//      left, the encounter picker at the top centre, and the transport /
//      Place-Go-Clear cluster plus the status line at the bottom centre.
//
//   2. `KidsPanel.bottomBar` — the floating galaxy hotbar (chips + tilt
//      stepper + hint pill). Add it as a SIBLING as before and pin only
//      its centreX (to the render view) and its bottom (to the window);
//      it sizes itself from its intrinsic content and wraps its chips
//      onto a second row rather than ever overhanging the window.
//
//      The panel WATCHES the hotbar's frame and lifts its own bottom
//      cluster to sit just above it, so the two never overlap no matter
//      what bottom margin the host chooses or how tall the bar grows.
//
// Both views share one piece of state (`selectedType`, `selectedTilt`,
// `placeMode`), owned by `KidsPanel` and pushed to the hotbar by `sync*`.
// =====================================================================

/// Night-sky slab colour shared by every floating control. The hotbar
/// hangs over the starfield in *both* appearances, so it is deliberately
/// dark in light mode too — a light plate would blow out the galaxy
/// artwork drawn on top of it.
private func nightFill(_ lift: CGFloat = 0) -> NSColor { KidsStyle.night(lift) }

/// Document view that grows downward from the top; without `isFlipped`
/// a short content stack anchors to the bottom of the scroll view.
private final class FlippedDoc: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Rounded grouping box

/// Soft translucent card used to group related controls.
private final class RoundedBox: NSView {
    var cornerRadius: CGFloat = 20
    var fillAlpha: CGFloat = 0.06

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.labelColor.withAlphaComponent(fillAlpha).setFill()
        p.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

// MARK: - Chunky button

/// A large, finger-sized button drawn by hand: rounded slab, an icon and
/// an optional caption. AppKit's bezels cap out well below the size this
/// UI wants, and `NSButton` gives no clean "selected" look, so we draw.
final class ChunkyButton: NSControl {

    enum Style { case plain, primary, ghost }

    var style: Style = .plain { didSet { needsDisplay = true } }
    /// Artwork is drawn as-is; symbols are tinted to the foreground colour.
    var iconIsArtwork = false
    /// Night-sky slab behind the icon. The galaxy artwork is bright and
    /// additive, so it needs a dark ground in every appearance and in the
    /// selected state — otherwise it vanishes on a light or accent fill.
    var darkPlate = false { didSet { needsDisplay = true } }
    var icon: NSImage? { didSet { needsDisplay = true } }
    /// Drawn when `icon` is nil — the graceful fallback for a missing symbol.
    var glyph: String? { didSet { needsDisplay = true } }
    var caption: String = "" { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 16
    var iconInset: CGFloat = 10
    var isSelected = false { didSet { needsDisplay = true } }
    /// Extra inset on the drawn slab. The view keeps its layout size and
    /// the artwork grows or shrinks inside it, which is how the hotbar
    /// scales the armed chip up without disturbing the row.
    var plateInset: CGFloat = 0 { didSet { needsDisplay = true } }
    /// 0…1 soft accent halo drawn *outside* the slab. Needs `plateInset`
    /// headroom to be visible; the hotbar animates this to pulse.
    var glowAmount: CGFloat = 0 { didSet { needsDisplay = true } }
    var onTap: (() -> Void)?
    /// Hold-to-act, for controls that steer rather than choose: told when
    /// the finger goes down and when it leaves. Nothing here repeats on a
    /// timer — the caller reads the held state once per frame, which is
    /// what a flight integrator wants anyway.
    var onHoldChanged: ((Bool) -> Void)?
    private(set) var isHeld = false

    private var pressed = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracker: NSTrackingArea?

    init(minHeight: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        wantsLayer = true
    }

    /// Manual-layout flavour: carries no constraints of its own, because the
    /// hotbar's chip strip positions its chips by hand (a grid that reflows
    /// between one and two rows is far simpler to drive with frames).
    init(manualSize: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: manualSize))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// SF Symbol with a text fallback, so the button is never blank.
    func setSymbol(_ name: String, fallback: String, pointSize: CGFloat,
                   weight: NSFont.Weight = .bold) {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: fallback)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize,
                                                                weight: weight))
        icon = img
        glyph = (img == nil) ? fallback : nil
        if img == nil { toolTip = toolTip ?? fallback }
    }

    // MARK: drawing

    private var foreground: NSColor {
        if darkPlate || isSelected || style == .primary { return .white }
        return .white
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5 + plateInset, dy: 1.5 + plateInset)
        guard r.width > 6, r.height > 6 else { return }
        let radius = min(cornerRadius, min(r.width, r.height) / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

        let accent = KidsStyle.accent

        // ---- halo (hotbar pulse). Concentric fading strokes: cheap, and
        // unlike a CG shadow it needs no offscreen pass to sit *behind* a
        // translucent slab.
        if glowAmount > 0.005 {
            let steps = 3
            for i in stride(from: steps, through: 1, by: -1) {
                let e = CGFloat(i) * 1.6
                let g = NSBezierPath(roundedRect: r.insetBy(dx: -e, dy: -e),
                                     xRadius: radius + e, yRadius: radius + e)
                g.lineWidth = 2.6
                let falloff = 1 - CGFloat(i - 1) / CGFloat(steps)
                accent.withAlphaComponent(0.22 * glowAmount * falloff).setStroke()
                g.stroke()
            }
        }

        var fill: NSColor
        switch style {
        case .primary: fill = accent.withAlphaComponent(pressed ? 1.0 : (hovering ? 0.95 : 0.85))
        case .plain:   fill = KidsStyle.button(pressed ? 0.12 : (hovering ? 0.06 : 0))
        case .ghost:   fill = KidsStyle.button(pressed ? 0.12 : (hovering ? 0.06 : 0))
        }
        if isSelected { fill = accent.withAlphaComponent(pressed ? 1.0 : 0.92) }
        if darkPlate {
            fill = isSelected ? KidsStyle.accent : KidsStyle.button(pressed ? 0.12 : (hovering ? 0.06 : 0))
        }
        fill.setFill()
        path.fill()

        if isSelected {
            (darkPlate ? accent : NSColor.white.withAlphaComponent(0.85)).setStroke()
            path.lineWidth = darkPlate ? 3.5 : 3
        } else {
            let base: CGFloat = style == .ghost ? 0.0 : 0.12
            (darkPlate ? NSColor.white.withAlphaComponent(hovering ? 0.35 : 0.16)
                       : NSColor.labelColor.withAlphaComponent(base)).setStroke()
            path.lineWidth = 1
        }
        path.stroke()

        // ---- caption along the bottom, icon above it
        var iconRect = r.insetBy(dx: iconInset, dy: iconInset)
        if !caption.isEmpty {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: KidsPanel.roundedFont(14, .semibold),
                .foregroundColor: foreground.withAlphaComponent(isSelected ? 1.0 : 0.85),
                .paragraphStyle: para,
            ]
            let h: CGFloat = 18
            NSAttributedString(string: caption, attributes: attrs)
                .draw(in: NSRect(x: r.minX + 3, y: r.minY + 6, width: r.width - 6, height: h))
            iconRect = NSRect(x: r.minX + iconInset, y: r.minY + 6 + h + 2,
                              width: r.width - iconInset * 2,
                              height: max(r.height - (6 + h + 2) - 6, 8))
        }

        if let img = icon {
            let s = min(min(iconRect.width / img.size.width,
                            iconRect.height / img.size.height), 1.0)
            let sz = NSSize(width: img.size.width * s, height: img.size.height * s)
            let dr = NSRect(x: iconRect.midX - sz.width / 2,
                            y: iconRect.midY - sz.height / 2,
                            width: sz.width, height: sz.height)
            if iconIsArtwork {
                img.draw(in: dr)
            } else {
                KidsPanel.tinted(img, foreground).draw(in: dr)
            }
        } else if let g = glyph {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let size = min(iconRect.height * 0.62, 26)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: KidsPanel.roundedFont(max(size, 11), .bold),
                .foregroundColor: foreground,
                .paragraphStyle: para,
            ]
            let str = NSAttributedString(string: g, attributes: attrs)
            let th = str.size().height
            str.draw(in: NSRect(x: r.minX + 2, y: iconRect.midY - th / 2,
                                width: r.width - 4, height: th + 2))
        }
    }

    // MARK: interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracker { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracker = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent)  { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        setHeld(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
        setHeld(pressed)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        setHeld(false)
        if inside { onTap?() }
    }

    private func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        onHoldChanged?(held)
    }

    /// Drop the hold without a mouse-up: window deactivation and hiding the
    /// controls both have to stop the ship turning.
    func releaseHold() {
        pressed = false
        setHeld(false)
    }

    /// The UI review presses the real controls rather than their closures.
    func simulateTap() { onTap?() }
    /// Press and release a hold control without a mouse, keeping `isHeld`
    /// honest so `releaseHold` behaves as it would after a real press.
    func simulateHold(_ held: Bool) { setHeld(held) }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Page dots

/// Position-in-list indicator for the encounter picker.
private final class DotsView: NSView {
    var count = 0   { didSet { needsDisplay = true } }
    var index = 0   { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 10) }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }
        let d: CGFloat = 6, gap: CGFloat = 7
        let total = CGFloat(count) * d + CGFloat(max(count - 1, 0)) * gap
        var x = bounds.midX - total / 2
        for i in 0..<count {
            let on = (i == index)
            let s = on ? d + 3 : d
            let r = NSRect(x: x - (s - d) / 2, y: bounds.midY - s / 2, width: s, height: s)
            (on ? KidsStyle.accent
                : NSColor.labelColor.withAlphaComponent(0.25)).setFill()
            NSBezierPath(ovalIn: r).fill()
            x += d + gap
        }
    }
}

// MARK: - Galaxy icon drawing

/// Hand-drawn, cached Core Graphics thumbnails — one recognisable shape
/// per `GalaxyType`. Warm core, cool blue outskirts, transparent ground.
enum GalaxyIcon {

    private static var cache: [String: NSImage] = [:]

    static func image(for type: GalaxyType, size: CGFloat = 76) -> NSImage {
        let key = "\(type.rawValue)-\(Int(size))"
        if let c = cache[key] { return c }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            draw(type: type, in: ctx, size: size)
            return true
        }
        cache[key] = img
        return img
    }

    // -- deterministic noise so an icon looks the same every launch

    private struct RNG {
        var s: UInt64
        mutating func u() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 11) & 0x1F_FFFF_FFFF_FFFF) / Double(0x20_0000_0000_0000)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * u() }
        mutating func gauss() -> Double {
            let u1 = max(u(), 1e-6), u2 = u()
            return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
    }

    /// Radius fraction -> star colour: warm white core, orange mid,
    /// pale blue arms, deep blue rim.
    private static func color(_ t: Double) -> (CGFloat, CGFloat, CGFloat) {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (1.00, 0.96, 0.86)),
            (0.30, (1.00, 0.80, 0.48)),
            (0.62, (0.86, 0.86, 1.00)),
            (1.00, (0.44, 0.68, 1.00)),
        ]
        let x = min(max(t, 0), 1)
        for i in 1..<stops.count where x <= stops[i].0 {
            let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
            let f = (x - t0) / max(t1 - t0, 1e-6)
            return (CGFloat(c0.0 + (c1.0 - c0.0) * f),
                    CGFloat(c0.1 + (c1.1 - c0.1) * f),
                    CGFloat(c0.2 + (c1.2 - c0.2) * f))
        }
        let c = stops[stops.count - 1].1
        return (CGFloat(c.0), CGFloat(c.1), CGFloat(c.2))
    }

    private static func star(_ ctx: CGContext, _ p: CGPoint, _ r: CGFloat,
                             _ t: Double, _ alpha: CGFloat) {
        let (cr, cg, cb) = color(t)
        ctx.setFillColor(red: cr, green: cg, blue: cb, alpha: alpha)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    private static func glow(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat,
                             _ rgb: (CGFloat, CGFloat, CGFloat), _ a: CGFloat) {
        guard r > 0.5 else { return }
        let space = CGColorSpaceCreateDeviceRGB()
        let inner = CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, a])!
        let outer = CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, 0])!
        guard let grad = CGGradient(colorsSpace: space,
                                    colors: [inner, outer] as CFArray,
                                    locations: [0, 1]) else { return }
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                               endCenter: c, endRadius: r, options: [])
    }

    // -- the eleven shapes

    private static func draw(type: GalaxyType, in ctx: CGContext, size: CGFloat) {
        let c = CGPoint(x: size / 2, y: size / 2)
        let R = size / 2
        let unit = size / 76            // star radii were tuned at 76pt
        var rng = RNG(s: 0x9E37_79B9_7F4A_7C15 &+ UInt64(abs(type.rawValue.hashValue % 9973)))

        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)

        switch type {
        case .sa:   // two tight arms hugging a fat bulge
            spiral(ctx, c, R, unit, &rng, arms: 2, turns: 0.92, spread: 0.24,
                   bulge: 0.42, bar: 0, armStars: 175, knots: 0, armWeight: 0.85)
        case .sb:   // the Milky Way look
            spiral(ctx, c, R, unit, &rng, arms: 2, turns: 0.78, spread: 0.55,
                   bulge: 0.20, bar: 0, armStars: 200, knots: 6)
        case .sc:   // three wide-open flocculent arms, barely any bulge
            spiral(ctx, c, R, unit, &rng, arms: 3, turns: 0.44, spread: 1.10,
                   bulge: 0.09, bar: 0, armStars: 205, knots: 12)
        case .sbb:  // straight bar, arms curling off the tips
            spiral(ctx, c, R, unit, &rng, arms: 2, turns: 0.45, spread: 0.38,
                   bulge: 0.14, bar: 0.48, armStars: 170, knots: 5)
        case .sbc:  // longer bar, arms barely wound
            spiral(ctx, c, R, unit, &rng, arms: 2, turns: 0.30, spread: 0.85,
                   bulge: 0.10, bar: 0.62, armStars: 165, knots: 10)
        case .e0:
            elliptical(ctx, c, R, unit, &rng, flatten: 1.0, tilt: 0, stars: 470, scale: 0.95)
        case .e5:
            elliptical(ctx, c, R, unit, &rng, flatten: 0.42, tilt: -0.40, stars: 440, scale: 1.10)
        case .s0:
            lenticular(ctx, c, R, unit, &rng)
        case .irr:
            irregular(ctx, c, R, unit, &rng)
        case .dwarf:
            elliptical(ctx, c, R, unit, &rng, flatten: 0.88, tilt: 0.2, stars: 165,
                       scale: 0.46, dim: 0.6)
        case .ring:
            ring(ctx, c, R, unit, &rng)
        }

        ctx.restoreGState()
    }

    private static func spiral(_ ctx: CGContext, _ c: CGPoint, _ R: CGFloat, _ unit: CGFloat,
                               _ rng: inout RNG, arms: Int, turns: Double, spread: Double,
                               bulge: Double, bar: Double, armStars: Int, knots: Int,
                               armWeight: Double = 1.0) {
        let bulgeR = R * CGFloat(bulge)
        // clamped so the halo always fades out inside the icon's frame —
        // otherwise the rectangle edge becomes visible on the fat-bulge types
        glow(ctx, c, min(max(bulgeR * 2.6, R * 0.30), R * 0.88), (1.0, 0.86, 0.60), 0.55)

        // faint disk haze so the arms sit on something
        glow(ctx, c, R * 0.95, (0.45, 0.60, 1.0), 0.12)

        // bulge / core
        let bulgeStars = Int(60 + 340 * bulge)
        for _ in 0..<bulgeStars {
            let s = Double(max(bulgeR, R * 0.05)) * 0.55
            let p = CGPoint(x: c.x + CGFloat(rng.gauss() * s), y: c.y + CGFloat(rng.gauss() * s))
            let t = Double(hypot(p.x - c.x, p.y - c.y) / R)
            star(ctx, p, unit * CGFloat(rng.range(0.8, 1.4)), t * 0.5, 0.85)
        }

        // bar — the whole point of the SB types, so make it read loudly
        let barLen = R * CGFloat(bar)
        if bar > 0 {
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.scaleBy(x: 1, y: 0.24)
            glow(ctx, .zero, barLen * 1.15, (1.0, 0.84, 0.55), 0.75)
            ctx.restoreGState()
            for _ in 0..<280 {
                let x = rng.range(-1, 1)
                let taper = 1 - 0.45 * abs(x)           // fat in the middle
                let px = c.x + CGFloat(x) * barLen
                let py = c.y + CGFloat(rng.gauss() * taper) * R * 0.070
                star(ctx, CGPoint(x: px, y: py), unit * CGFloat(rng.range(1.0, 1.7)),
                     abs(x) * 0.26, 0.95)
            }
        }

        // arms
        let rStart = bar > 0 ? barLen * 1.02 : R * CGFloat(max(bulge, 0.10))
        let rEnd = R * 0.94
        for k in 0..<arms {
            let base = Double(k) * 2 * .pi / Double(arms)
            for i in 0..<armStars {
                let f = Double(i) / Double(armStars - 1)
                let t = Foundation.pow(f, 0.85)
                let r = Double(rStart) + t * Double(rEnd - rStart)
                let theta = base + turns * 2 * .pi * t
                    + rng.gauss() * spread * 0.10 / (0.35 + t)
                let rr = r + rng.gauss() * Double(R) * 0.030 * (0.5 + spread)
                let p = CGPoint(x: c.x + CGFloat(rr * Foundation.cos(theta)),
                                y: c.y + CGFloat(rr * Foundation.sin(theta)))
                star(ctx, p, unit * CGFloat(rng.range(0.75, 1.35) * armWeight),
                     Double(rr) / Double(R), CGFloat(0.92 * armWeight))
            }
        }

        // bright star-forming knots on the arms
        for j in 0..<knots {
            let k = j % max(arms, 1)
            let base = Double(k) * 2 * .pi / Double(arms)
            let t = rng.range(0.25, 1.0)
            let r = Double(rStart) + t * Double(rEnd - rStart)
            let theta = base + turns * 2 * .pi * t
            let p = CGPoint(x: c.x + CGFloat(r * Foundation.cos(theta)),
                            y: c.y + CGFloat(r * Foundation.sin(theta)))
            glow(ctx, p, unit * 5, (0.60, 0.78, 1.0), 0.75)
        }

        // scattered halo
        for _ in 0..<70 {
            let a = rng.range(0, 2 * .pi)
            let r = Double(R) * rng.range(0.25, 1.0)
            let p = CGPoint(x: c.x + CGFloat(r * Foundation.cos(a)),
                            y: c.y + CGFloat(r * Foundation.sin(a)))
            star(ctx, p, unit * 0.7, r / Double(R), 0.35)
        }
    }

    private static func elliptical(_ ctx: CGContext, _ c: CGPoint, _ R: CGFloat, _ unit: CGFloat,
                                   _ rng: inout RNG, flatten: Double, tilt: Double,
                                   stars: Int, scale: Double, dim: CGFloat = 1) {
        let sigma = Double(R) * 0.30 * scale
        glow(ctx, c, CGFloat(sigma * 2.6), (1.0, 0.84, 0.62), 0.55 * dim)
        let ct = Foundation.cos(tilt), st = Foundation.sin(tilt)
        for _ in 0..<stars {
            var x = rng.gauss() * sigma
            var y = rng.gauss() * sigma * flatten
            let rx = x * ct - y * st, ry = x * st + y * ct
            x = rx; y = ry
            let p = CGPoint(x: c.x + CGFloat(x), y: c.y + CGFloat(y))
            let t = min(hypot(x, y) / (Double(R) * 0.9), 1)
            // ellipticals are old and red: bias the ramp toward the warm end
            star(ctx, p, unit * CGFloat(rng.range(0.75, 1.3)), t * 0.45,
                 (0.55 + 0.4 * CGFloat(1 - t)) * dim)
        }
    }

    private static func lenticular(_ ctx: CGContext, _ c: CGPoint, _ R: CGFloat,
                                   _ unit: CGFloat, _ rng: inout RNG) {
        // featureless lens: wide razor-thin disk + a small hard bright bulge.
        // Tilted the other way from E5 so the two never get confused.
        let tilt = 0.26, thin = 0.15
        let ct = Foundation.cos(tilt), st = Foundation.sin(tilt)
        func place(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: c.x + CGFloat(x * ct - y * st), y: c.y + CGFloat(x * st + y * ct))
        }

        // lens-shaped haze
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(tilt))
        ctx.scaleBy(x: 1, y: CGFloat(thin * 1.9))
        glow(ctx, .zero, R * 0.98, (0.80, 0.84, 1.0), 0.45)
        ctx.restoreGState()

        for _ in 0..<760 {                       // smooth disk, sharp-ish edge, no arms
            let u = rng.u()
            let r = Double(R) * (0.05 + 0.93 * Foundation.pow(u, 0.55))
            let ang = rng.range(0, 2 * .pi)
            let px = r * Foundation.cos(ang)
            let py = r * Foundation.sin(ang) * thin + rng.gauss() * Double(R) * 0.012
            star(ctx, place(px, py), unit * CGFloat(rng.range(0.6, 1.05)),
                 min(r / Double(R), 1) * 0.85, 0.55)
        }
        glow(ctx, c, R * 0.30, (1.0, 0.90, 0.68), 0.85)
        for _ in 0..<210 {                       // compact round bulge
            let s = Double(R) * 0.11
            star(ctx, place(rng.gauss() * s, rng.gauss() * s * 0.85),
                 unit * CGFloat(rng.range(0.9, 1.5)), 0.06, 0.95)
        }
    }

    private static func irregular(_ ctx: CGContext, _ c: CGPoint, _ R: CGFloat,
                                  _ unit: CGFloat, _ rng: inout RNG) {
        // no core, no symmetry: a handful of blue clumps scattered around
        let clumps = 5
        for i in 0..<clumps {
            let a = Double(i) / Double(clumps) * 2 * .pi + rng.range(-0.55, 0.55)
            let d = Double(R) * rng.range(0.26, 0.58)
            let cc = CGPoint(x: c.x + CGFloat(d * Foundation.cos(a)),
                             y: c.y + CGFloat(d * Foundation.sin(a)))
            let s = Double(R) * rng.range(0.10, 0.19)
            glow(ctx, cc, CGFloat(s * 2.4), (0.60, 0.78, 1.0), 0.45)
            for _ in 0..<110 {
                let p = CGPoint(x: cc.x + CGFloat(rng.gauss() * s),
                                y: cc.y + CGFloat(rng.gauss() * s))
                star(ctx, p, unit * CGFloat(rng.range(0.8, 1.45)),
                     rng.range(0.55, 1.0), 0.85)
            }
        }
        for _ in 0..<110 {                       // loose stragglers between them
            let a = rng.range(0, 2 * .pi)
            let r = Double(R) * rng.range(0.15, 0.95)
            star(ctx, CGPoint(x: c.x + CGFloat(r * Foundation.cos(a)),
                              y: c.y + CGFloat(r * Foundation.sin(a))),
                 unit * 0.85, rng.range(0.4, 1.0), 0.5)
        }
    }

    private static func ring(_ ctx: CGContext, _ c: CGPoint, _ R: CGFloat,
                             _ unit: CGFloat, _ rng: inout RNG) {
        glow(ctx, c, R * 0.26, (1.0, 0.86, 0.60), 0.75)     // nucleus
        for _ in 0..<110 {
            let s = Double(R) * 0.075
            star(ctx, CGPoint(x: c.x + CGFloat(rng.gauss() * s), y: c.y + CGFloat(rng.gauss() * s)),
                 unit * CGFloat(rng.range(0.9, 1.5)), 0.08, 0.9)
        }
        let rr = Double(R) * 0.76
        for _ in 0..<620 {                                   // the ring itself
            let a = rng.range(0, 2 * .pi)
            let r = rr + rng.gauss() * Double(R) * 0.055
            let p = CGPoint(x: c.x + CGFloat(r * Foundation.cos(a)),
                            y: c.y + CGFloat(r * Foundation.sin(a)))
            star(ctx, p, unit * CGFloat(rng.range(0.8, 1.45)), 0.85, 0.9)
        }
        for i in 0..<7 {                                     // knots around the rim
            let a = Double(i) / 7 * 2 * .pi + 0.3
            let p = CGPoint(x: c.x + CGFloat(rr * Foundation.cos(a)),
                            y: c.y + CGFloat(rr * Foundation.sin(a)))
            glow(ctx, p, unit * 6, (0.55, 0.75, 1.0), 0.65)
        }
    }
}

// =====================================================================
// MARK: - Floating hotbar
// =====================================================================

/// Container whose *own* area is transparent to the mouse. The hotbar
/// floats over the render view, so a click that lands in the gap between
/// two chips must reach the sky (and drop a galaxy) rather than being
/// eaten by an invisible rectangle.
private class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Same trick for the stacks that arrange the hotbar's rows.
private final class PassThroughStack: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Reflowing grid of galaxy chips. Lays its chips out by hand so it can
/// drop from one row to two (or more, if someone really squeezes) the
/// instant the available width stops fitting them — the bar is never
/// allowed to overhang the window and clip.
private final class ChipStrip: PassThroughView {

    var slotWidth: CGFloat = 64
    var slotHeight: CGFloat = 72
    var gap: CGFloat = 6

    private(set) var chips: [NSView] = []

    /// Width the host view can spare, pushed in by `KidsHotbar`.
    var availableWidth: CGFloat = 100_000 {
        didSet {
            guard abs(oldValue - availableWidth) > 0.5 else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    func setChips(_ views: [NSView]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = views
        chips.forEach { addSubview($0) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var columns: Int {
        let n = chips.count
        guard n > 0 else { return 0 }
        let fits = max(Int((availableWidth + gap) / (slotWidth + gap)), 1)
        if fits >= n { return n }                 // one comfortable row
        let half = Int(ceil(Double(n) / 2))       // otherwise aim for two
        return max(min(fits, half), 1)
    }

    private var rowCount: Int {
        let c = columns
        return c > 0 ? Int(ceil(Double(chips.count) / Double(c))) : 0
    }

    override var intrinsicContentSize: NSSize {
        let c = columns, rows = rowCount
        guard c > 0, rows > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        return NSSize(width: CGFloat(c) * slotWidth + CGFloat(c - 1) * gap,
                      height: CGFloat(rows) * slotHeight + CGFloat(rows - 1) * gap)
    }

    override func layout() {
        super.layout()
        let c = columns, rows = rowCount
        guard c > 0, rows > 0 else { return }
        let totalH = CGFloat(rows) * slotHeight + CGFloat(rows - 1) * gap
        var y = bounds.midY + totalH / 2 - slotHeight      // top row first
        var i = 0
        while i < chips.count {
            let end = min(i + c, chips.count)
            let n = end - i
            let w = CGFloat(n) * slotWidth + CGFloat(n - 1) * gap
            var x = (bounds.midX - w / 2).rounded()
            for k in i..<end {
                chips[k].frame = NSRect(x: x, y: y.rounded(),
                                        width: slotWidth, height: slotHeight)
                x += slotWidth + gap
            }
            y -= slotHeight + gap
            i = end
        }
    }
}

/// Small dark capsule carrying one line of text — the place-mode hint.
private final class HintPill: NSView {

    var text: String = "" {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    private var attrs: [NSAttributedString.Key: Any] {
        [.font: KidsPanel.roundedFont(13, .semibold),
         .foregroundColor: NSColor.white.withAlphaComponent(0.93)]
    }

    override var intrinsicContentSize: NSSize {
        let w = NSAttributedString(string: text, attributes: attrs).size().width
        return NSSize(width: ceil(w) + 50, height: 34)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        nightFill().setFill(); p.fill()
        KidsStyle.accent.withAlphaComponent(0.55).setStroke()
        p.lineWidth = 1.5; p.stroke()

        let d: CGFloat = 8
        KidsStyle.accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + 15, y: r.midY - d / 2,
                                    width: d, height: d)).fill()

        let str = NSAttributedString(string: text, attributes: attrs)
        let h = str.size().height
        str.draw(at: NSPoint(x: r.minX + 33, y: r.midY - h / 2))
    }
}

/// Tilt read-out: the number, plus a little disc that squashes from
/// face-on to edge-on so the angle means something without reading it.
private final class TiltReadout: NSView {

    var degrees: Float = 0 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 104, height: 52) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        nightFill().setFill(); p.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        p.lineWidth = 1; p.stroke()

        // squashed disc
        let cx = r.minX + 27, cy = r.midY
        let rad: CGFloat = 14
        let squash = max(CGFloat(Foundation.cos(Double(degrees) * .pi / 180)), 0.07)
        let e = NSRect(x: cx - rad, y: cy - rad * squash,
                       width: rad * 2, height: rad * 2 * squash)
        let disc = NSBezierPath(ovalIn: e)
        KidsStyle.accent.withAlphaComponent(0.35).setFill(); disc.fill()
        NSColor.white.withAlphaComponent(0.88).setStroke()
        disc.lineWidth = 2; disc.stroke()

        let cap = NSAttributedString(string: "TILT", attributes: [
            .font: KidsPanel.roundedFont(9, .heavy),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ])
        cap.draw(at: NSPoint(x: r.minX + 50, y: r.midY + 2))

        let val = NSAttributedString(string: "\(Int(degrees.rounded()))°", attributes: [
            .font: KidsPanel.roundedFont(17, .heavy),
            .foregroundColor: NSColor.white,
        ])
        val.draw(at: NSPoint(x: r.minX + 50, y: r.midY - 16))
    }
}

/// The floating galaxy hotbar: hint line, chip grid, tilt stepper and an
/// exit button. Owns no state — `KidsPanel` pushes everything in.
private final class KidsHotbar: PassThroughView {


    private let strip = ChipStrip()
    private let hint = HintPill()
    private let readout = TiltReadout()
    private var row: PassThroughStack!
    private let controlsRow = PassThroughStack()
    private var leadingControls: [NSView] = []
    private var trailingControls: [NSView] = []
    private var compactLayout: Bool?
    private var chips: [ChunkyButton] = []

    private var placeMode = false
    private var selectedIndex = 0
    private var pulse: Timer?
    private var phase: CGFloat = 0
    private var frameObserver: NSObjectProtocol?

    init(chips: [ChunkyButton]) {
        super.init(frame: .zero)
        self.chips = chips
        translatesAutoresizingMaskIntoConstraints = false
        build()
        strip.setChips(chips)
        syncChips()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pulse?.invalidate()
        if let o = frameObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: construction

    /// Everything on ONE line.
    ///
    /// This was three stacked rows — hint, chips, then a tilt stepper — which
    /// ate a quarter of the window height and still looked like a panel. The
    /// stepper is now a single segmented plate (‹ / value / ›) rather than
    /// three buttons, and the host injects transport and place actions into
    /// the same row, so the whole UI is one strip across the bottom.
    private func build() {
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.text = "tap the sky to drop it"
        hint.isHidden = true

        strip.translatesAutoresizingMaskIntoConstraints = false

        row = PassThroughStack(views: [strip])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let column = PassThroughStack(views: [hint, row])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Host injects transport / action plates so they share the one row.
    func insertLeading(_ views: [NSView]) {
        leadingControls = views
        compactLayout = nil
        refreshLayout()
    }
    func appendTrailing(_ views: [NSView]) {
        trailingControls = views
        compactLayout = nil
        refreshLayout()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let observer = frameObserver { NotificationCenter.default.removeObserver(observer) }
        superview?.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
            object: superview, queue: .main) { [weak self] _ in self?.refreshLayout() }
        refreshLayout()
    }

    private func refreshLayout() {
        guard let parent = superview else { return }
        let width = parent.bounds.width
        let compact = placeMode && width < 1480
        strip.availableWidth = max(64, width - (compact ? 64 : 620))
        if compactLayout != compact {
            for v in row.arrangedSubviews { row.removeArrangedSubview(v); v.removeFromSuperview() }
            for v in controlsRow.arrangedSubviews { controlsRow.removeArrangedSubview(v); v.removeFromSuperview() }
            controlsRow.orientation = .horizontal
            controlsRow.alignment = .centerY
            controlsRow.spacing = 12
            row.orientation = compact ? .vertical : .horizontal
            row.alignment = compact ? .centerX : .centerY
            row.spacing = 12
            if compact {
                row.addArrangedSubview(strip)
                for v in leadingControls + trailingControls { controlsRow.addArrangedSubview(v) }
                row.addArrangedSubview(controlsRow)
            } else {
                for v in leadingControls + (placeMode ? [strip] : []) + trailingControls { row.addArrangedSubview(v) }
            }
            compactLayout = compact
        }
        needsLayout = true
    }

    // MARK: hotbar state

    func setPlaceMode(_ on: Bool) {
        placeMode = on
        hint.isHidden = !on
        strip.isHidden = !on
        compactLayout = nil
        refreshLayout()
        syncChips()
        if on { startPulse() } else { stopPulse() }
    }

    func setHint(_ text: String) { hint.text = text }

    func setChipsSelected(_ index: Int) {
        selectedIndex = index
        syncChips()
    }


    private func syncChips() {
        for (i, c) in chips.enumerated() {
            c.isSelected = (i == selectedIndex)
            c.plateInset = 2
            c.glowAmount = (i == selectedIndex && placeMode) ? 0.5 + 0.5 * sin(phase) : 0
            c.needsDisplay = true
        }
    }

    private func startPulse() {
        stopPulse()
        // Breathes only while placing, so nothing animates when idle.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.18
            self.syncChips()
        }
        RunLoop.main.add(t, forMode: .common)
        pulse = t
    }

    private func stopPulse() {
        pulse?.invalidate(); pulse = nil
        phase = 0
        syncChips()
    }
}

// MARK: - Kids panel
//
// INSTALL CONTRACT
//   The panel is a transparent, full-bleed overlay. Pin all four edges to the
//   render view; it paints no background and returns nil from hitTest for
//   empty areas, so the sky beneath stays draggable:
//
//       view.addSubview(kids)
//       kids.topAnchor      == metalView.topAnchor
//       kids.bottomAnchor   == metalView.bottomAnchor
//       kids.leadingAnchor  == metalView.leadingAnchor
//       kids.trailingAnchor == metalView.trailingAnchor
//
//   `bottomBar` is a SEPARATE view: add it over the render view and pin only
//   its centreX and bottom. It sizes itself.
final class KidsPanel: NSView {

    /// The panel covers the whole render view but is mostly empty, so a click
    /// that lands on nothing must reach the sky beneath — otherwise the view
    /// would stop responding to camera drags and galaxy placement.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    // MARK: callbacks

    var onScene:            ((Int) -> Void)?
    var onPlayPause:        ((Bool) -> Void)?
    var onRestart:          (() -> Void)?
    var onSpeed:            ((Float) -> Void)?
    var onPlaceType:        ((GalaxyType) -> Void)?
    var onPlaceModeChanged: ((Bool) -> Void)?
    var onAutoOrbit:        (() -> Void)?
    var onClear:            (() -> Void)?
    var onHamburger:        (() -> Void)?
    var onFlyMode:          (() -> Void)?
    var onTiltChanged:      ((Float) -> Void)?

    /// Lets the host supply real rendered thumbnails instead of the drawn
    /// icons. Re-renders the chip grid when assigned.
    var iconOverride: ((GalaxyType) -> NSImage?)? {
        didSet { refreshTypeIcons() }
    }

    // MARK: state

    private(set) var placeMode = false
    private(set) var selectedType: GalaxyType = .sb
    private(set) var isPlaying = true

    private let sceneNames: [String]
    private var sceneIndex = 0

    private let speeds: [Float] = [0.25, 1, 3]
    private var speedIndex = 1

    /// Tilt of the galaxy about to be placed, 0° (face-on) … 90° (edge-on)
    /// in 15° notches — coarse on purpose, so an arrow tap always makes a
    /// visible difference.
    private(set) var selectedTilt: Float = 30
    private(set) var selectedRoll: Float = 0

    func rotatePlacement(dx: Float, dy: Float) {
        selectedTilt = min(max(selectedTilt + dy * 0.5, 0), 180)
        selectedRoll = (selectedRoll + dx * 0.5).truncatingRemainder(dividingBy: 360)
        onTiltChanged?(selectedTilt)
    }

    // MARK: views

    private let backdrop = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let stack = NSStackView()

    private var encounterCenter: NSLayoutConstraint?
    func reserveInspectorSpace(_ reserved: Bool) {
        encounterCenter?.constant = reserved ? -190 : 0
    }
    private let sceneLabel = NSTextField(labelWithString: "")
    private let dots = DotsView()
    private let statusLabel = NSTextField(labelWithString: "Pick a crash and press play!")
    private var playButton: ChunkyButton!
    private var placeButton: ChunkyButton!
    private var statusBottomConstraint: NSLayoutConstraint?
    private var statusView: NSView?
    private var speedButtons: [ChunkyButton] = []
    private var speedChunk: SegmentedChunk!
    private var typeButtons: [ChunkyButton] = []

    private var hotbar: KidsHotbar!
    private var pickedLabel = NSTextField(labelWithString: "")
    private var pickedChip: ChunkyButton!

    /// Floating hotbar meant to be added over the render view and pinned to
    /// the bottom of the WINDOW, not inside the sidebar. It sizes itself —
    /// the host only needs to pin `centerXAnchor` and `bottomAnchor`.
    var bottomBar: NSView { hotbar }

    // MARK: init

    init(sceneNames: [String]) {
        self.sceneNames = sceneNames.isEmpty ? ["Encounter"] : sceneNames
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildHotbar()
        build()
        syncScene()
        syncSpeed()
        syncPlay()
        syncTypes()
        syncPlace()
        syncTilt(notify: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - small helpers

    static func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        KidsStyle.font(size, weight)
    }

    /// Recolour a template-ish symbol image to `color`.
    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = KidsPanel.roundedFont(10, .heavy)
        l.textColor = .tertiaryLabelColor
        return l
    }

    private func card(_ content: NSView, inset: CGFloat = 12, radius: CGFloat = 22) -> NSView {
        let box = RoundedBox()
        box.cornerRadius = radius
        box.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
        ])
        return box
    }

    private func hstack(_ views: [NSView], spacing: CGFloat = 10,
                        distribution: NSStackView.Distribution = .fill) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = spacing
        s.distribution = distribution
        s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.spacing = spacing
        s.alignment = .centerX
        s.distribution = .fill
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    // MARK: - construction

    private func build() {
        // No backdrop, no scroll view, no column. The panel is a transparent
        // full-bleed overlay and its children sit at the edges, because a
        // 300pt opaque sidebar spent most of its area hiding the thing you
        // came to look at.
        wantsLayer = true
        layer?.backgroundColor = .clear

        // ---- top left: just the settings hamburger. The fly button used to
        // live here too, which buried the most exciting thing in the app next
        // to a menu icon; it now sits at the end of the bottom bar as its own
        // accented plate.
        let topLeft = PassThroughStack(views: [burgerButton()])
        topLeft.orientation = .horizontal
        topLeft.spacing = 8
        topLeft.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topLeft)

        // ---- top centre: which encounter you are watching
        let enc = encounterCard()
        enc.translatesAutoresizingMaskIntoConstraints = false
        addSubview(enc)

        // Transport and place-actions are injected into the hotbar's own row
        // (see `insertLeading` / `appendTrailing`) so the entire UI is a
        // single strip, rather than a stack of bars eating the bottom third.
        hotbar.insertLeading([transportCard()])
        hotbar.appendTrailing([buildCard(), flySeparator(), flyButton()])

        let status = statusRow()
        statusView = status
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)

        // The host pins `bottomBar` itself; leave room for it.
        let hotbarRoom: CGFloat = 104
        statusBottomConstraint = status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(hotbarRoom + 14))

        encounterCenter = enc.centerXAnchor.constraint(equalTo: centerXAnchor)
        NSLayoutConstraint.activate([
            topLeft.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            topLeft.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            enc.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            encounterCenter!,

            status.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusBottomConstraint!,
        ])
    }

    private func flyButton() -> ChunkyButton {
        let b = ChunkyButton(minHeight: 72)
        b.widthAnchor.constraint(equalToConstant: 76).isActive = true
        b.heightAnchor.constraint(equalToConstant: 72).isActive = true
        b.cornerRadius = 18
        b.style = .primary
        b.caption = "Fly"
        b.toolTip = "Jump to light speed and fly through it"
        b.icon = WarpIcon.image(size: 26)
        b.iconIsArtwork = true
        b.onTap = { [weak self] in self?.onFlyMode?() }
        return b
    }

    /// A little air before the fly button, so it reads as its own thing
    /// rather than the fourth item in the place-actions group.
    private func flySeparator() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return v
    }

    private func burgerButton() -> ChunkyButton {
        let b = ChunkyButton(minHeight: 44)
        b.widthAnchor.constraint(equalToConstant: 46).isActive = true
        b.cornerRadius = 14
        b.toolTip = "Grown-up controls"
        b.setSymbol("line.3.horizontal", fallback: "≡", pointSize: 19)
        b.onTap = { [weak self] in self?.onHamburger?() }
        return b
    }

    /// Adds a row that spans the full panel width.
    private func addFull(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.leadingAnchor.constraint(equalTo: stack.leadingAnchor,
                                   constant: stack.edgeInsets.left).isActive = true
        v.trailingAnchor.constraint(equalTo: stack.trailingAnchor,
                                    constant: -stack.edgeInsets.right).isActive = true
    }

    // ---- header: title, fly, hamburger

    private func headerRow() -> NSView {
        let title = NSTextField(labelWithString: "Galaxy Crash")
        title.font = KidsPanel.roundedFont(20, .heavy)
        title.textColor = .labelColor
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fly = ChunkyButton(minHeight: 44)
        fly.widthAnchor.constraint(equalToConstant: 46).isActive = true
        fly.cornerRadius = 14
        fly.toolTip = "Fly through it"
        fly.setSymbol("airplane.departure", fallback: "🚀", pointSize: 19)
        fly.onTap = { [weak self] in self?.onFlyMode?() }

        let burger = ChunkyButton(minHeight: 44)
        burger.widthAnchor.constraint(equalToConstant: 46).isActive = true
        burger.cornerRadius = 14
        burger.toolTip = "Grown-up controls"
        burger.setSymbol("line.3.horizontal", fallback: "≡", pointSize: 19)
        burger.onTap = { [weak self] in self?.onHamburger?() }

        // The plate. Unix time plus three hundred years, because the ship is
        // going to places it takes that long to talk about.
        let plate = NSTextField(labelWithString: Version.short)
        plate.font = KidsPanel.roundedFont(9.5, .medium)
        plate.textColor = .tertiaryLabelColor
        plate.toolTip = Version.long

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        return hstack([title, plate, spacer, fly, burger], spacing: 8)
    }

    // ---- encounter: < name > plus dots

    private func encounterCard() -> NSView {
        let prev = ChunkyButton(minHeight: 56)
        prev.widthAnchor.constraint(equalToConstant: 48).isActive = true
        prev.cornerRadius = 16
        prev.toolTip = "Previous encounter"
        prev.setSymbol("chevron.left", fallback: "‹", pointSize: 20)
        prev.onTap = { [weak self] in self?.step(-1) }

        let next = ChunkyButton(minHeight: 56)
        next.widthAnchor.constraint(equalToConstant: 48).isActive = true
        next.cornerRadius = 16
        next.toolTip = "Next encounter"
        next.setSymbol("chevron.right", fallback: "›", pointSize: 20)
        next.onTap = { [weak self] in self?.step(1) }

        sceneLabel.font = KidsPanel.roundedFont(16, .bold)
        sceneLabel.alignment = .center
        sceneLabel.textColor = .labelColor
        sceneLabel.maximumNumberOfLines = 2
        sceneLabel.lineBreakMode = .byTruncatingTail
        sceneLabel.cell?.wraps = true
        sceneLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sceneLabel.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = hstack([prev, sceneLabel, next], spacing: 8)
        dots.translatesAutoresizingMaskIntoConstraints = false
        dots.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let col = vstack([row, dots], spacing: 8)
        row.leadingAnchor.constraint(equalTo: col.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: col.trailingAnchor).isActive = true
        dots.leadingAnchor.constraint(equalTo: col.leadingAnchor).isActive = true
        dots.trailingAnchor.constraint(equalTo: col.trailingAnchor).isActive = true
        return card(col)
    }

    // ---- transport: play/pause, restart, three speeds

    /// Transport as two compact plates: play+restart, and a three-way speed.
    ///
    /// The speed used to be three separate buttons. As one segmented plate it
    /// costs a third of the width and reads as one choice instead of three.
    private func transportCard() -> NSView {
        playButton = ChunkyButton(minHeight: 72)
        playButton.style = .primary
        playButton.cornerRadius = 18
        playButton.widthAnchor.constraint(equalToConstant: 76).isActive = true
        playButton.heightAnchor.constraint(equalToConstant: 72).isActive = true
        playButton.toolTip = "Play / pause"
        playButton.onTap = { [weak self] in self?.togglePlay() }

        let restart = ChunkyButton(minHeight: 72)
        restart.widthAnchor.constraint(equalToConstant: 76).isActive = true
        restart.heightAnchor.constraint(equalToConstant: 72).isActive = true
        restart.cornerRadius = 18
        restart.caption = "Restart"
        restart.toolTip = "Start over"
        restart.setSymbol("arrow.counterclockwise", fallback: "↺", pointSize: 20)
        restart.onTap = { [weak self] in self?.onRestart?() }

        speedChunk = SegmentedChunk(segments: [
            .init(symbol: "tortoise.fill", fallback: "S", text: nil, caption: nil,
                  width: 44, tip: "Slow motion", action: { [weak self] in self?.pickSpeed(0) }),
            .init(symbol: "figure.walk", fallback: "N", text: nil, caption: nil,
                  width: 44, tip: "Normal speed", action: { [weak self] in self?.pickSpeed(1) }),
            .init(symbol: "hare.fill", fallback: "F", text: nil, caption: nil,
                  width: 44, tip: "Fast forward", action: { [weak self] in self?.pickSpeed(2) }),
        ])
        speedChunk.height = 72
        speedChunk.selectedIndex = speedIndex

        let row = PassThroughStack(views: [playButton, restart, speedChunk])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    // ---- the floating hotbar (galaxy chips + tilt stepper)

    /// Builds the chips and the hotbar that owns them. Called before
    /// `build()` because the sidebar's "make your own" card shows a small
    /// echo of whichever chip is armed.
    private func buildHotbar() {
        typeButtons = GalaxyType.allCases.map { type in
            // Manual layout: the strip positions these itself so it can
            // reflow between one and two rows.
            let b = ChunkyButton(manualSize: NSSize(width: 64, height: 72))
            b.cornerRadius = 20
            b.iconIsArtwork = true
            b.darkPlate = true
            b.iconInset = 4
            b.plateInset = 2
            b.caption = type.rawValue
            b.toolTip = type.displayName
            b.icon = GalaxyIcon.image(for: type)
            b.onTap = { [weak self] in self?.pickType(type) }
            return b
        }

        hotbar = KidsHotbar(chips: typeButtons)

    }

    // ---- build your own: what's armed, place mode, go, clear

    /// Place / Go! / Clear as a horizontal row beside the transport.
    ///
    /// The armed-chip echo and the "Make your own" heading are gone: the
    /// hotbar already shows what is armed, much more clearly, and repeating it
    /// here only cost screen.
    private func buildCard() -> NSView {
        placeButton = ChunkyButton(minHeight: 72)
        placeButton.widthAnchor.constraint(equalToConstant: 76).isActive = true
        placeButton.heightAnchor.constraint(equalToConstant: 72).isActive = true
        placeButton.cornerRadius = 18
        placeButton.caption = "Creation"
        placeButton.toolTip = "Enter Creation: choose a galaxy, Shift-drag to rotate, click to place. Click Creation again to finish."
        placeButton.setSymbol("hand.raised.fill", fallback: "✋", pointSize: 17)
        placeButton.onTap = { [weak self] in self?.togglePlace() }

        let clear = ChunkyButton(minHeight: 72)
        clear.widthAnchor.constraint(equalToConstant: 76).isActive = true
        clear.heightAnchor.constraint(equalToConstant: 72).isActive = true
        clear.cornerRadius = 18
        clear.caption = "Clear"
        clear.toolTip = "Remove the galaxies you placed"
        clear.setSymbol("trash.fill", fallback: "🗑", pointSize: 17)
        clear.onTap = { [weak self] in self?.clearTapped() }

        let row = PassThroughStack(views: [placeButton, clear])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        // `pickedChip` / `pickedLabel` are still referenced by the sync code,
        // so keep them alive but off screen rather than unpicking that thread.
        pickedChip = ChunkyButton(minHeight: 1)
        pickedChip.isHidden = true
        return row
    }

    // ---- status

    private func statusRow() -> NSView {
        statusLabel.font = KidsPanel.roundedFont(12, .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.cell?.wraps = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return statusLabel
    }

    func alignStatusWithHotbar() {
        guard let statusView else { return }
        statusBottomConstraint?.isActive = false
        statusBottomConstraint = statusView.bottomAnchor.constraint(equalTo: hotbar.topAnchor, constant: -12)
        statusBottomConstraint?.isActive = true
    }

    override func layout() {
        super.layout()
        // labels wrap against the live panel width
        let inner = max(bounds.width - 2 * (stack.edgeInsets.left + 24), 60)
        sceneLabel.preferredMaxLayoutWidth = max(inner - 112, 60)
        statusLabel.preferredMaxLayoutWidth = inner + 24
        pickedLabel.preferredMaxLayoutWidth = max(inner - 68, 60)
    }

    // MARK: - actions

    private func step(_ delta: Int) {
        let n = sceneNames.count
        sceneIndex = ((sceneIndex + delta) % n + n) % n
        syncScene()
        onScene?(sceneIndex)
    }

    private func togglePlay() {
        isPlaying.toggle()
        syncPlay()
        onPlayPause?(isPlaying)
    }

    private func pickSpeed(_ i: Int) {
        speedIndex = min(max(i, 0), speeds.count - 1)
        syncSpeed()
        onSpeed?(speeds[speedIndex])
    }

    private func pickType(_ type: GalaxyType) {
        selectedType = type
        syncTypes()
        onPlaceType?(type)
        // picking a galaxy *is* the intent to place one
        if !placeMode {
            placeMode = true
            syncPlace()
            onPlaceModeChanged?(true)
        }
        updateStatus("Click the sky to drop a \(type.rawValue)!")
    }

    private func togglePlace() {
        placeMode.toggle()
        syncPlace()
        onPlaceModeChanged?(placeMode)
        updateStatus(placeMode ? "Click the sky to drop a \(selectedType.rawValue)!"
                               : "Drag to look around.")
    }


    private func clearTapped() {
        onClear?()
        updateStatus("All cleared. Pick a galaxy!")
    }

    // MARK: - state sync

    private func syncScene() {
        sceneLabel.stringValue = sceneNames[sceneIndex]
        dots.count = sceneNames.count
        dots.index = sceneIndex
        needsLayout = true
    }

    private func syncPlay() {
        playButton.setSymbol(isPlaying ? "pause.fill" : "play.fill",
                             fallback: isPlaying ? "⏸" : "▶", pointSize: 26)
        playButton.toolTip = isPlaying ? "Pause" : "Play"
        playButton.caption = isPlaying ? "Pause" : "Play"
    }

    private func syncSpeed() {
        for (i, b) in speedButtons.enumerated() { b.isSelected = (i == speedIndex) }
        speedChunk?.selectedIndex = speedIndex
    }

    private func syncTypes() {
        let index = GalaxyType.allCases.firstIndex(of: selectedType) ?? 0
        hotbar.setChipsSelected(index)
        pickedChip.icon = iconOverride?(selectedType) ?? GalaxyIcon.image(for: selectedType)
        pickedLabel.stringValue = selectedType.displayName
        needsLayout = true
    }

    private func syncPlace() {
        placeButton.isSelected = placeMode
        placeButton.caption = "Creation"
        pickedChip.isSelected = placeMode
        hotbar.setPlaceMode(placeMode)
        needsLayout = true
        hotbar.setHint(placeMode ? "Click to create \(selectedType.rawValue) · Shift-drag to rotate"
                                 : "tap the sky to drop it")
    }

    private func syncTilt(notify: Bool) {
        if notify {
            onTiltChanged?(selectedTilt)
            updateStatus(selectedTilt == 0 ? "Lying flat — 0° tilt."
                                           : "Tipped over \(Int(selectedTilt))°.")
        }
    }

    private func refreshTypeIcons() {
        for (i, b) in typeButtons.enumerated() {
            let t = GalaxyType.allCases[i]
            b.icon = iconOverride?(t) ?? GalaxyIcon.image(for: t)
        }
        pickedChip?.icon = iconOverride?(selectedType) ?? GalaxyIcon.image(for: selectedType)
    }

    // MARK: - host-facing updates

    /// Mirrors `ControlPanel.setPlaying`: pushes the state *and* reports it,
    /// so the host's space-bar path (`setPlaying(sim.isPaused)`) keeps working.
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        syncPlay()
        onPlayPause?(playing)
    }

    func setSceneIndex(_ index: Int) {
        guard !sceneNames.isEmpty else { return }
        sceneIndex = min(max(index, 0), sceneNames.count - 1)
        syncScene()
    }

    func updateStatus(_ text: String) {
        statusLabel.stringValue = text
        needsLayout = true
    }

    /// Convenience for hosts that want to force place mode off (e.g. after a
    /// galaxy is dropped). Fires `onPlaceModeChanged` only on a real change.
    func setPlaceMode(_ on: Bool) {
        guard on != placeMode else { return }
        placeMode = on
        syncPlace()
        onPlaceModeChanged?(on)
    }
}

// MARK: - Segmented chunk

/// One plate, several independent tap targets.
///
/// Exists so the bottom bar can be a single row. A tilt stepper as three
/// separate buttons (◀ / value / ▶) costs three plates and three gaps; as one
/// segmented plate it costs one, and it reads better — the arrows are visibly
/// part of the thing they modify. Same for the three speed settings.
final class SegmentedChunk: NSView {

    struct Segment {
        var symbol: String?
        var fallback: String
        var text: String?          // drawn instead of a symbol
        var caption: String?       // small line under the value
        var width: CGFloat
        var tip: String?
        var action: () -> Void
    }

    private var segments: [Segment] = []
    private var images: [NSImage?] = []
    private var hovered: Int? = nil
    private var tracking: NSTrackingArea?

    /// Index of the segment drawn as selected, if any.
    var selectedIndex: Int? = nil { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 18
    var height: CGFloat = 56

    override var isFlipped: Bool { true }

    init(segments: [Segment]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        set(segments)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ segs: [Segment]) {
        segments = segs
        images = segs.map { s in
            guard let name = s.symbol else { return nil }
            return NSImage(systemSymbolName: name, accessibilityDescription: s.fallback)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17,
                                                                     weight: .semibold))
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Update only the text of one segment, without disturbing layout.
    func setText(_ text: String, at index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].text = text
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segments.reduce(0) { $0 + $1.width }, height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited,
                                         .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    private func index(at p: NSPoint) -> Int? {
        var x: CGFloat = 0
        for (i, s) in segments.enumerated() {
            if p.x >= x && p.x < x + s.width { return i }
            x += s.width
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hovered { hovered = i; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) {
            segments[i].action()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let plate = NSBezierPath(roundedRect: r, xRadius: cornerRadius, yRadius: cornerRadius)
        KidsStyle.button().setFill()
        plate.fill()
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
        plate.lineWidth = 1
        plate.stroke()

        var x: CGFloat = 0
        for (i, seg) in segments.enumerated() {
            let cell = NSRect(x: x, y: 0, width: seg.width, height: r.height)

            if selectedIndex == i {
                let sel = NSBezierPath(roundedRect: cell.insetBy(dx: 3, dy: 3),
                                       xRadius: cornerRadius - 4, yRadius: cornerRadius - 4)
                KidsStyle.accent.withAlphaComponent(0.92).setFill()
                sel.fill()
            } else if hovered == i {
                let h = NSBezierPath(roundedRect: cell.insetBy(dx: 3, dy: 3),
                                     xRadius: cornerRadius - 4, yRadius: cornerRadius - 4)
                NSColor(calibratedWhite: 1, alpha: 0.09).setFill()
                h.fill()
            }

            // divider between segments
            if i > 0 && selectedIndex != i && selectedIndex != i - 1 {
                NSColor(calibratedWhite: 1, alpha: 0.09).setFill()
                NSBezierPath(rect: NSRect(x: x, y: 12, width: 1, height: r.height - 24)).fill()
            }

            let fg = NSColor.white.withAlphaComponent(selectedIndex == i ? 1.0 : 0.82)
            if let img = images[i] {
                img.isTemplate = true
                let side = min(cell.height * 0.42, 22)
                let box = NSRect(x: cell.midX - side / 2,
                                 y: cell.midY - side / 2 - (seg.caption == nil ? 0 : 5),
                                 width: side, height: side)
                fg.set()
                KidsPanel.tinted(img, fg).draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            } else if let t = seg.text ?? (images[i] == nil ? seg.fallback : nil) {
                let f = KidsPanel.roundedFont(seg.caption == nil ? 17 : 16, .bold)
                let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: fg]
                let size = (t as NSString).size(withAttributes: a)
                (t as NSString).draw(at: NSPoint(x: cell.midX - size.width / 2,
                                                 y: cell.midY - size.height / 2
                                                    - (seg.caption == nil ? 0 : 6)),
                                     withAttributes: a)
            }

            if let cap = seg.caption {
                let f = KidsPanel.roundedFont(9, .semibold)
                let a: [NSAttributedString.Key: Any] = [
                    .font: f, .foregroundColor: NSColor.white.withAlphaComponent(0.45)]
                let size = (cap as NSString).size(withAttributes: a)
                (cap as NSString).draw(at: NSPoint(x: cell.midX - size.width / 2,
                                                   y: cell.maxY - size.height - 7),
                                       withAttributes: a)
            }
            x += seg.width
        }
    }
}

// MARK: - Light-speed icon

/// Hand-drawn "jump to light speed" glyph.
///
/// `airplane.departure` was standing in for this and read as an airport
/// departures board. This is the thing everyone actually pictures: a ship
/// silhouette with the starfield stretched into streaks behind it, the
/// streaks longer and brighter toward the centre of the jump.
enum WarpIcon {
    static func image(size: CGFloat = 30) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        defer { img.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

        let c = CGPoint(x: size * 0.62, y: size * 0.5)
        ctx.setLineCap(.round)

        // --- star streaks, radiating back from the ship
        // Deterministic angles rather than random: an icon must look the same
        // every time it is drawn.
        let streaks: [(angle: CGFloat, len: CGFloat, w: CGFloat, a: CGFloat)] = [
            (  0, 0.46, 0.075, 0.95),
            ( 16, 0.36, 0.060, 0.70),
            (-16, 0.36, 0.060, 0.70),
            ( 33, 0.26, 0.050, 0.45),
            (-33, 0.26, 0.050, 0.45),
            ( 52, 0.17, 0.042, 0.28),
            (-52, 0.17, 0.042, 0.28),
        ]
        for s in streaks {
            let rad = s.angle * .pi / 180
            // streaks point BACKWARD (to the left) from the ship
            let dir = CGVector(dx: -cos(rad), dy: sin(rad))
            let start = CGPoint(x: c.x + dir.dx * size * 0.14,
                                y: c.y + dir.dy * size * 0.14)
            let end = CGPoint(x: c.x + dir.dx * size * (0.14 + s.len),
                              y: c.y + dir.dy * size * (0.14 + s.len))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(s.a).cgColor)
            ctx.setLineWidth(size * s.w)
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()
        }

        // --- ship: a clean swept delta pointing into the jump
        let nose = CGPoint(x: size * 0.93, y: size * 0.5)
        let tail = size * 0.30
        let span = size * 0.20
        let p = CGMutablePath()
        p.move(to: nose)
        p.addLine(to: CGPoint(x: nose.x - tail, y: c.y + span))
        // a notch in the trailing edge reads as a ship rather than a triangle
        p.addLine(to: CGPoint(x: nose.x - tail * 0.62, y: c.y))
        p.addLine(to: CGPoint(x: nose.x - tail, y: c.y - span))
        p.closeSubpath()

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(p)
        ctx.fillPath()

        return img
    }
}
