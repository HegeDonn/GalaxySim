import AppKit
import MetalKit

/// One look for the whole card. Before this existed the card mixed a
/// monospaced data table, a system-font story, a bezelled push button and a
/// hand-drawn chart, so it read as four unrelated widgets stacked up.
///
/// It is now a thin dialect of `KidsStyle` rather than a palette of its own:
/// same SF Rounded type, same accent, same night plates as the first screen
/// and the galaxy picker. Clicking a star used to age the app by a decade,
/// and the type was the largest part of why.
enum StarCardStyle {
    static let accent = KidsStyle.accentOnNight
    static let ink = KidsStyle.ink
    static let body = KidsStyle.body
    static let faint = KidsStyle.faint
    static let panel = KidsStyle.panel
    static let hairline = KidsStyle.hairline
    static let corner: CGFloat = 14
    static let sectionFont = KidsStyle.font(10.5, .heavy)
    static let bodyFont = KidsStyle.font(12.5, .regular)
    /// Rounded rather than monospaced-digit. The values here are short
    /// sentences ("83× smaller than our Sun"), not a column of figures, so
    /// the alignment monospacing buys was never visible — and rounded
    /// digits are what the rest of the app uses.
    static let valueFont = KidsStyle.font(13.5, .semibold)
    static let tinyFont = KidsStyle.font(9.5, .medium)

    static func sectionLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithAttributedString: NSAttributedString(
            string: text.uppercased(),
            attributes: [.font: sectionFont, .foregroundColor: accent, .kern: 1.2]))
    }

    /// "83×", "9×", "1.4×" -- never more precision than the reader needs.
    static func times(_ value: Double) -> String {
        if value >= 10 { return String(format: "%.0f×", value) }
        if value >= 2 { return String(format: "%.1f×", value) }
        return String(format: "%.2f×", value)
    }

    /// Group thousands so 35000 reads as a temperature, not a serial number.
    static func grouped(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    /// A soft halo around a body, painted as stacked rings.
    ///
    /// The obvious implementation -- one NSGradient from the colour to the same
    /// colour at alpha 0 -- does not work here twice over. Its radial draw is
    /// clipped to the rect you hand it, so it printed a square box around every
    /// star, and the fade toward a fully transparent stop darkens on the way
    /// out, so the halo came through as a dirty brown wash rather than light.
    /// Concentric rings at a fixed hue cannot do either.
    static func glow(at centre: NSPoint, radius: CGFloat, color: NSColor, strength: CGFloat = 0.45) {
        let steps = 16
        for step in stride(from: steps, through: 1, by: -1) {
            let t = CGFloat(step) / CGFloat(steps)
            let r = radius * t
            color.withAlphaComponent(strength * pow(1 - t, 1.5) * 0.16).setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r,
                                        width: r * 2, height: r * 2)).fill()
        }
    }

    static func panelBackground(_ rect: NSRect) {
        panel.setFill()
        NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
    }

    static func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor,
                     align: NSTextAlignment = .left) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attrs)
        var origin = point
        switch align {
        case .center: origin.x -= string.size().width / 2
        case .right: origin.x -= string.size().width
        default: break
        }
        string.draw(at: origin)
    }
}

/// Selection card. The host owns selection; this view only presents a stellar model.
/// Call setAnimating(false) when hidden so the portrait does not consume GPU time.
final class StarInspectorView: NSView {
    var onClose: (() -> Void)?
    var onVisitPlanet: (() -> Void)?
    private let scroll = NSScrollView()
    private let content = InspectorFlippedView()
    private let heading = NSTextField(labelWithString: "THE STAR YOU PICKED")
    private let nameLabel = NSTextField(labelWithString: "")
    private let typeLabel = NSTextField(labelWithString: "")
    private let sizeHeader = StarCardStyle.sectionLabel("Next to our Sun")
    private let statsHeader = StarCardStyle.sectionLabel("By the numbers")
    private let hrHeader = StarCardStyle.sectionLabel("The star family")
    private let storyHeader = StarCardStyle.sectionLabel("Its life story")
    private let compare = SunComparisonView(frame: .zero)
    private let stats = StatTableView(frame: .zero)
    private let story = NSTextField(wrappingLabelWithString: "")
    private let disclaimer = NSTextField(wrappingLabelWithString: StarInspectorView.disclaimerText(galaxy: ""))
    /// The names are drawn the way the sky draws them — bright stars get
    /// proper names, faint ones get catalogue numbers — and some of them are
    /// real names borrowed for an invented star, so the card says so.
    static func disclaimerText(galaxy: String) -> String {
        let where_ = galaxy.isEmpty ? "this part of the galaxy" : galaxy
        return "An example star for \(where_). Its name, its age and its future are illustrative, not measured."
    }
    private let closeButton = ChunkyButton(manualSize: NSSize(width: 36, height: 36))
    private let landButton = LandButtonView(frame: .zero)
    private let portrait = StellarPortraitView(frame: .zero)
    private let hr = StellarHRView(frame: .zero)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.025, green: 0.038, blue: 0.065, alpha: 0.97).cgColor
        layer?.cornerRadius = 18
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        addSubview(scroll)
        heading.font = StarCardStyle.sectionFont
        heading.textColor = StarCardStyle.accent
        nameLabel.font = KidsStyle.font(26, .bold)
        nameLabel.textColor = StarCardStyle.ink
        typeLabel.font = KidsStyle.font(12.5, .medium)
        typeLabel.textColor = StarCardStyle.faint
        stats.toolTip = "Brightness means total light emitted compared with the Sun, not how bright it looks from far away."
        compare.toolTip = "Both discs are drawn to the same scale, each in its own true colour. Our Sun is white, not yellow -- it only looks yellow after Earth's air scatters the blue out of it."
        story.font = StarCardStyle.bodyFont
        story.textColor = StarCardStyle.body
        disclaimer.font = StarCardStyle.tinyFont
        disclaimer.textColor = NSColor.white.withAlphaComponent(0.42)
        for view in [portrait, compare, stats, hr, sizeHeader, statsHeader, hrHeader, storyHeader, story, disclaimer] as [NSView] {
            content.addSubview(view)
        }
        for view in [heading, nameLabel, typeLabel] { addSubview(view) }
        addSubview(landButton)
        closeButton.darkPlate = true
        closeButton.cornerRadius = 18
        closeButton.iconInset = 10
        closeButton.setSymbol("xmark", fallback: "✕", pointSize: 13)
        closeButton.onTap = { [weak self] in self?.onClose?() }
        closeButton.setAccessibilityLabel("Close selected star")
        addSubview(closeButton)
        landButton.identifier = NSUserInterfaceItemIdentifier("star.visitPlanet")
        landButton.action = { [weak self] in self?.onVisitPlanet?() }
        setAccessibilityLabel("Selected star explorer")
    }
    required init?(coder: NSCoder) { fatalError() }
    func setAnimating(_ enabled: Bool) { portrait.isPlaying = enabled; portrait.rendersContinuously = enabled }

    func update(profile: StellarProfile) {
        nameLabel.stringValue = profile.name
        typeLabel.stringValue = profile.classification
        disclaimer.stringValue = Self.disclaimerText(galaxy: profile.galaxyName)
        // Ratios below 1 read terribly as "0.012 × our Sun", so they are
        // flipped and named: 83× smaller, 550× dimmer.
        func ratio(_ value: Double, _ more: String, _ less: String, same: String) -> String {
            if value > 1.04 { return "\(StarCardStyle.times(value)) \(more) than our Sun" }
            if value < 0.96 { return "\(StarCardStyle.times(1 / max(value, 1e-9))) \(less) than our Sun" }
            return "\(same) as our Sun"
        }
        stats.rows = [
            ("Size", ratio(profile.solarRadius, "wider", "smaller", same: "the same width")),
            ("Brightness", ratio(profile.solarLuminosity, "brighter", "dimmer", same: "just as bright")),
            ("Mass", ratio(profile.solarMass, "heavier", "lighter", same: "just as heavy")),
            ("Surface heat", "\(StarCardStyle.grouped(profile.temperature - 273.15)) °C")
        ]
        // Which galaxy the star is in, when the scene knows. In a collision
        // that answer changes meaning as the two discs mix, which is worth a
        // child noticing.
        if !profile.galaxyName.isEmpty { stats.rows.append(("Home galaxy", profile.galaxyName)) }
        compare.profile = profile
        landButton.tint = profile.color
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 6
        story.attributedStringValue = NSAttributedString(
            string: "\(profile.ageDescription)\n\(profile.remainingLifeDescription)\n\(profile.lifespanDescription)\n\(profile.fate)",
            attributes: [.font: StarCardStyle.bodyFont,
                         .foregroundColor: StarCardStyle.body,
                         .paragraphStyle: paragraph])
        portrait.setProfile(profile)
        hr.temperature = profile.temperature
        hr.luminosity = profile.solarLuminosity
        hr.needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = max(230, bounds.width - 40)
        // Identity and the one big action stay put; everything else scrolls.
        heading.frame = NSRect(x: 20, y: 16, width: w - 25, height: 14)
        // Names are no longer all the same length -- "Vega" and
        // "2MASS J1442-3515" share this line -- so the big type shrinks to fit
        // rather than truncating somebody's star to "2MASS J144...".
        let fitted = [26, 22, 19, 16].first { size in
            nameLabel.stringValue.size(withAttributes:
                [.font: KidsStyle.font(CGFloat(size), .bold)]).width <= w
        } ?? 16
        if nameLabel.font?.pointSize != CGFloat(fitted) {
            nameLabel.font = KidsStyle.font(CGFloat(fitted), .bold)
        }
        nameLabel.frame = NSRect(x: 20, y: 33, width: w, height: 30)
        typeLabel.frame = NSRect(x: 20, y: 64, width: w, height: 17)
        closeButton.frame = NSRect(x: bounds.width - 46, y: 12, width: 36, height: 36)
        let buttonHeight: CGFloat = 50
        landButton.frame = NSRect(x: 16, y: bounds.height - buttonHeight - 14,
                                  width: bounds.width - 32, height: buttonHeight)
        let top: CGFloat = 90
        let scrollHeight = max(1, bounds.height - top - buttonHeight - 26)
        scroll.frame = NSRect(x: 1, y: top, width: bounds.width - 2, height: scrollHeight)
        let cw = bounds.width - 2
        content.frame = NSRect(x: 0, y: 0, width: cw, height: 100)
        // Every block is measured and stacked, so nothing can be clipped by a
        // hardcoded height the way the story block used to be.
        func header(_ label: NSTextField, _ y: CGFloat) -> CGFloat {
            label.frame = NSRect(x: 20, y: y, width: w, height: 14)
            return y + 19
        }
        func measured(_ field: NSTextField) -> CGFloat {
            field.attributedStringValue.boundingRect(
                with: NSSize(width: w, height: 4000),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height.rounded(.up) + 6
        }
        var y: CGFloat = 2
        // On a short window the portrait would fill the whole visible area and
        // hide the fact that anything follows it, so it gives ground first. It
        // keeps a fixed 1.7 frame while it shrinks: the portrait renderer maps
        // the star into the drawable, so a frame that changes shape changes how
        // round the star looks, and a star that is round on one window and oval
        // on another is just a bug with extra steps.
        let portraitHeight = min(176, max(112, scrollHeight * 0.40)).rounded()
        let portraitWidth = min(cw - 20, portraitHeight * 1.7).rounded()
        portrait.frame = NSRect(x: ((cw - portraitWidth) / 2).rounded(), y: y,
                                width: portraitWidth, height: portraitHeight)
        y = portrait.frame.maxY + 14
        y = header(sizeHeader, y)
        compare.frame = NSRect(x: 18, y: y, width: cw - 36, height: 164)
        y = compare.frame.maxY + 18
        y = header(statsHeader, y)
        stats.frame = NSRect(x: 18, y: y, width: cw - 36, height: stats.fittingHeight)
        y = stats.frame.maxY + 18
        y = header(hrHeader, y)
        hr.frame = NSRect(x: 18, y: y, width: cw - 36, height: 186)
        y = hr.frame.maxY + 18
        y = header(storyHeader, y)
        story.frame = NSRect(x: 20, y: y, width: w, height: measured(story))
        y = story.frame.maxY + 14
        disclaimer.frame = NSRect(x: 20, y: y, width: w, height: measured(disclaimer))
        content.frame.size.height = disclaimer.frame.maxY + 16
    }
}

private final class InspectorFlippedView: NSView { override var isFlipped: Bool { true } }

/// Label/value rows in the card's own font. Replaces a monospaced block that
/// looked like console output next to everything else on the card.
private final class StatTableView: NSView {
    var rows: [(String, String)] = [] { didSet { needsDisplay = true } }
    private static let rowHeight: CGFloat = 30
    var fittingHeight: CGFloat { CGFloat(rows.count) * Self.rowHeight + 10 }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        StarCardStyle.panelBackground(bounds)
        var y: CGFloat = 5
        for (index, row) in rows.enumerated() {
            if index > 0 {
                StarCardStyle.hairline.setFill()
                NSRect(x: 13, y: y, width: bounds.width - 26, height: 1).fill()
            }
            StarCardStyle.draw(row.0, at: NSPoint(x: 14, y: y + 8),
                               font: StarCardStyle.bodyFont, color: StarCardStyle.faint)
            StarCardStyle.draw(row.1, at: NSPoint(x: bounds.width - 14, y: y + 6),
                               font: StarCardStyle.valueFont, color: StarCardStyle.ink, align: .right)
            y += Self.rowHeight
        }
    }
}

/// The Sun and the selected star drawn side by side at one shared scale, which
/// is the comparison the numbers alone cannot make. The two discs are always in
/// true proportion to each other; when one of them works out smaller than a few
/// pixels it is drawn as a minimum-size dot and the view says so, rather than
/// quietly cheating the scale to make it visible.
private final class SunComparisonView: NSView {
    var profile: StellarProfile? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        StarCardStyle.panelBackground(bounds)
        guard let profile else { return }
        let ratio = max(profile.solarRadius, 1e-6)
        let headline: String
        if ratio > 1.08 { headline = "This star is \(StarCardStyle.times(ratio)) wider than our Sun" }
        else if ratio < 0.93 { headline = "Our Sun is \(StarCardStyle.times(1 / ratio)) wider than this star" }
        else { headline = "This star is almost exactly Sun-sized" }
        StarCardStyle.draw(headline, at: NSPoint(x: bounds.midX, y: 11),
                           font: KidsStyle.font(11.5, .semibold),
                           color: StarCardStyle.ink, align: .center)

        let baseline = bounds.height - 34
        let largest = min(bounds.width * 0.42, baseline - 46)
        let scale = largest / max(1.0, ratio)
        let minimum: CGFloat = 4
        let sunSize = max(minimum, scale)
        let starSize = max(minimum, scale * CGFloat(ratio))
        if sunSize == minimum || starSize == minimum {
            StarCardStyle.draw("the little one is a dot — at true scale you could not see it",
                               at: NSPoint(x: bounds.midX, y: 27),
                               font: KidsStyle.font(9, .medium), color: StarCardStyle.faint, align: .center)
        }
        // The Sun gets the same blackbody treatment as every other star on the
        // card, so a solar twin really does look identical beside it. That means
        // it comes out white rather than the storybook yellow: the yellow is
        // Earth's atmosphere scattering the blue away, not the Sun's colour.
        let sunRGB = Relativity.blackbodyRGB(5772)
        let sunPeak = max(sunRGB.x, max(sunRGB.y, sunRGB.z))
        let sunColor = NSColor(srgbRed: CGFloat(sunRGB.x / sunPeak), green: CGFloat(sunRGB.y / sunPeak),
                               blue: CGFloat(sunRGB.z / sunPeak), alpha: 1)
        disc(NSPoint(x: bounds.width * 0.29, y: baseline - sunSize / 2), sunSize, sunColor)
        disc(NSPoint(x: bounds.width * 0.71, y: baseline - starSize / 2), starSize, profile.color)
        StarCardStyle.draw("our Sun", at: NSPoint(x: bounds.width * 0.29, y: baseline + 8),
                           font: StarCardStyle.tinyFont, color: StarCardStyle.faint, align: .center)
        StarCardStyle.draw("this star", at: NSPoint(x: bounds.width * 0.71, y: baseline + 8),
                           font: StarCardStyle.tinyFont, color: StarCardStyle.body, align: .center)
    }

    /// A lit sphere rather than a flat circle: soft halo, then a body shaded
    /// from an off-centre highlight so it reads as round at any size.
    private func disc(_ centre: NSPoint, _ size: CGFloat, _ color: NSColor) {
        let radius = size / 2
        StarCardStyle.glow(at: centre, radius: radius * 2.1, color: color, strength: 0.42)
        let body = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                               width: size, height: size))
        let bright = NSColor(calibratedRed: min(1, color.redComponent * 0.45 + 0.55),
                             green: min(1, color.greenComponent * 0.45 + 0.55),
                             blue: min(1, color.blueComponent * 0.45 + 0.55), alpha: 1)
        NSGradient(colors: [bright, color, color.blended(withFraction: 0.45, of: .black) ?? color])?
            .draw(in: body, relativeCenterPosition: NSPoint(x: -0.3, y: -0.35))
    }
}

/// The primary action. It used to be a stock rounded push button reading
/// "Watch its night sky", which looked like an OK/Cancel and invited nobody to
/// press it. Now it is a warm planet-shaped invitation in the star's own colour.
private final class LandButtonView: NSView {
    var action: (() -> Void)?
    var tint: NSColor = .systemTeal { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressing = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Land on the planet")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) { pressing = true }
    override func mouseUp(with event: NSEvent) {
        pressing = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let lift: CGFloat = pressing ? 0.0 : (hovering ? 0.10 : 0.05)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16)
        let top = NSColor(calibratedRed: 1.00, green: 0.76 + lift * 0.3, blue: 0.40, alpha: 1)
        let bottom = NSColor(calibratedRed: 0.95, green: 0.47 + lift * 0.2, blue: 0.29, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -90)
        NSColor.white.withAlphaComponent(pressing ? 0.10 : 0.28).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        // A little ringed world, tinted with the star it orbits.
        let centre = NSPoint(x: 34, y: bounds.midY)
        let radius: CGFloat = 11
        let planet = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                                 width: radius * 2, height: radius * 2))
        let lit = tint.blended(withFraction: 0.35, of: .white) ?? tint
        let dark = tint.blended(withFraction: 0.55, of: NSColor(calibratedRed: 0.1, green: 0.06, blue: 0.16, alpha: 1)) ?? tint
        NSGradient(colors: [lit, dark])?.draw(in: planet, relativeCenterPosition: NSPoint(x: -0.35, y: -0.35))
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: centre.x, yBy: centre.y)
        transform.rotate(byDegrees: -18)
        transform.concat()
        let ring = NSBezierPath(ovalIn: NSRect(x: -radius * 1.75, y: -radius * 0.42,
                                               width: radius * 3.5, height: radius * 0.84))
        ring.lineWidth = 2
        NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
        ring.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let ink = NSColor(calibratedRed: 0.17, green: 0.07, blue: 0.03, alpha: 1)
        StarCardStyle.draw("Land on the planet", at: NSPoint(x: 58, y: bounds.midY - 14),
                           font: KidsStyle.font(15.5, .bold), color: ink)
        StarCardStyle.draw("stand there and look up at the sky", at: NSPoint(x: 58, y: bounds.midY + 3),
                           font: KidsStyle.font(10.5, .medium),
                           color: ink.withAlphaComponent(0.72))
    }
}

/// Live procedural portrait of the selected star.
///
/// This is a mini deferred renderer. Each frame:
///   1. A compute kernel advances ~120k plasma parcels. They are not sprayed
///      isotropically -- the great majority belong to one of ~44 narrow jets,
///      so a stream reads as a stream. Gravity is deliberately steep (mu = 4,
///      surface escape speed 2.83) against launch speeds around 1.4-2.0, so
///      99% of parcels arc over and land within ~1.5 s, peaking near 1.5
///      stellar radii -- visibly pulled back down, not drifting away.
///   2. The surface + volumetric corona is drawn to an HDR rgba16Float
///      offscreen texture. Values above 1.0 are allowed.
///   3. Parcels are drawn additively over it. Each one is deliberately very
///      faint -- roughly 1/40th of the old intensity -- so brightness comes
///      from *density*, not from any single sprite. Sparse regions stay thin
///      and gaseous; where a stream bunches up the additive accumulation
///      climbs past 1.0 on its own and starts to glow.
///   4. Bright pixels are extracted, blurred separably, then added back in a
///      composite pass that tonemaps to the drawable.
private final class StellarPortraitView: MTKView, MTKViewDelegate {
    // --- Pipelines --------------------------------------------------
    private var starPipeline: MTLRenderPipelineState?
    private var particlePipeline: MTLRenderPipelineState?
    private var extractPipeline: MTLRenderPipelineState?
    private var blurPipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var particleComputePipeline: MTLComputePipelineState?
    private var queue: MTLCommandQueue?

    // --- Offscreen textures ----------------------------------------
    private var hdrTex: MTLTexture?
    private var brightTex: MTLTexture?
    private var blurTex: MTLTexture?
    private var currentSize: CGSize = .zero

    // --- Particle system -------------------------------------------
    /// One plasma parcel. Layout matches the Metal `Particle` struct byte for
    /// byte (each SIMD3 occupies 16 bytes on both sides, so stride is 64).
    /// `axis` is the local magnetic field vector -- its length encodes field
    /// strength, so the Lorentz term needs no extra per-particle scalar.
    private struct Particle {
        var pos: SIMD3<Float> = .zero
        var vel: SIMD3<Float> = .zero
        var axis: SIMD3<Float> = .zero
        var age: Float = 0
        var life: Float = 0
        var seed: Float = 0
        var kind: Float = 0
    }
    /// A narrow stream footpoint. Parcels are bound to a jet by index, so a
    /// jet's parcels share an origin and a launch direction to within a couple
    /// of degrees -- that tight correlation is what makes a visible stream
    /// instead of a uniform boil. Jets are born, brighten, and fade on their
    /// own schedule so the surface keeps changing.
    private struct Jet {
        var origin: SIMD3<Float> = .zero    // footpoint on the unit sphere
        var dir: SIMD3<Float> = .zero       // launch direction
        var axis: SIMD3<Float> = .zero      // local B; length = field strength
        var speed: Float = 0
        var spread: Float = 0               // angular jitter, radians
        var intensity: Float = 0            // lifecycle envelope, 0...1
        var pad: Float = 0
    }
    private var particleBuffer: MTLBuffer?
    private var jetBuffer: MTLBuffer?
    private let particleCount: Int = 120_000
    private let jetCount: Int = 44
    private var jets: [Jet] = []
    private var jetAges: [Float] = []
    private var jetLives: [Float] = []
    private var frameSeed: UInt32 = 1
    /// The sim is warmed up on the GPU for a few simulated seconds on the
    /// first frame, otherwise every parcel launches on the same tick and you
    /// see one synchronized shell expand before the population decorrelates.
    private var needsWarmup = true

    // --- Star params ------------------------------------------------
    private var starColor = SIMD3<Float>(1.0, 0.75, 0.35)
    private var remnant: Bool = false
    private var radiusScale: Float = 0.50
    private var activity: Float = 1.0
    private var granulation: Float = 1.0
    private var spinRate: Float = 0.03
    private let startTime = CACurrentMediaTime()
    private var lastPhysicsTime = CACurrentMediaTime()

    /// SCNView-shaped API kept so the outer inspector view is unchanged.
    var isPlaying: Bool { get { !isPaused } set { isPaused = !newValue } }
    var rendersContinuously: Bool { get { !isPaused } set { isPaused = !newValue } }

    init(frame: NSRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        framebufferOnly = true
        preferredFramesPerSecond = 30
        isPaused = false
        enableSetNeedsDisplay = false
        wantsLayer = true
        layer?.isOpaque = false
        delegate = self
        buildPipelines()
        seedJets()
        initParticles()
    }
    required init(coder: NSCoder) { fatalError() }

    // MARK: public API
    func setRemnant(_ r: Bool) { remnant = r }
    func setColor(_ c: NSColor) {
        let rgba = c.usingColorSpace(.sRGB) ?? c
        starColor = SIMD3<Float>(Float(rgba.redComponent),
                                 Float(rgba.greenComponent),
                                 Float(rgba.blueComponent))
    }
    func setProfile(_ p: StellarProfile) {
        setColor(p.color)
        setRemnant(p.isRemnant)
        let logR = log10f(max(Float(p.solarRadius), 0.05))
        let sizeS = max(0, min(1, (logR + 1.3) / 4.4))
        // Kept well under 1.0: arcs peak near 1.5 stellar radii (95th pct
        // 1.95), and that has to stay in frame or the effect is cropped.
        radiusScale = 0.26 + 0.24 * sizeS
        let hot = max(0, min(1, (Float(p.temperature) - 2800) / 27000))
        granulation = 0.55 + 1.15 * hot
        activity = 1.75 - 1.10 * hot
        // Swift's hashValue is seeded per process, so the same star would
        // spin at a different rate on every launch. Hash the name by hand.
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in p.name.utf8 { h = (h ^ UInt64(byte)) &* 0x1000_0000_01B3 }
        h ^= h >> 29
        let jitter = Float(Double(h % 1000) / 1000.0) - 0.5
        spinRate = 0.020 + 0.030 * hot + 0.010 * jitter
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: uniforms
    private struct Uniforms {
        var time: Float
        var radiusScale: Float
        var aspect: SIMD2<Float>
        var color: SIMD4<Float>      // rgb + remnant flag
        var params: SIMD4<Float>     // activity, granulation, spin, particleGain
        var extra: SIMD4<Float>      // jetCount, unused...
    }
    private struct BlurUniforms {
        var direction: SIMD2<Float>
        var texel: SIMD2<Float>
    }
    private struct ComputeUniforms {
        var dt: Float
        var time: Float
        var mu: Float
        var curlK: Float
        var frameSeed: UInt32
        var count: UInt32
        var jetCount: UInt32
        var pad1: UInt32
    }

    // MARK: jets
    private func randomSurfaceDirection() -> SIMD3<Float> {
        let z = Float.random(in: -1...1)
        let phi = Float.random(in: 0..<Float.pi * 2)
        let radial = sqrt(max(0, 1 - z * z))
        return SIMD3<Float>(radial * cos(phi), z, radial * sin(phi))
    }
    /// Build one jet. The launch direction is the footpoint normal tilted by
    /// up to ~35 degrees, which is what stops every stream from looking like a
    /// radial spike and gives the corona its raked, sheared look.
    private func makeJet() -> Jet {
        var j = Jet()
        let origin = randomSurfaceDirection()
        // Tangent basis at the footpoint, conditioned away from the poles.
        let ref: SIMD3<Float> = abs(origin.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let t1 = simd_normalize(simd_cross(ref, origin))
        let t2 = simd_cross(origin, t1)
        let a = Float.random(in: 0..<Float.pi * 2)
        let tangent = t1 * cos(a) + t2 * sin(a)
        // Tilt is measured from the local vertical. Three quarters of the
        // jets launch almost sideways (48-78 deg), which is what makes them
        // arc *across* the surface instead of shooting straight up: at that
        // angle a parcel travels a mean of 68 deg of arc and never gets
        // higher than ~1.4 radii. The rest are steeper for variety.
        let lowLoop = Float.random(in: 0...1) < 0.75
        let tilt: Float, speed: Float, field: Float
        if lowLoop {
            tilt  = Float.random(in: 0.84...1.36)        // 48-78 deg
            speed = Float.random(in: 1.45...1.85)
            field = Float.random(in: 0.55...1.05)
        } else {
            tilt  = Float.random(in: 0.21...0.70)        // 12-40 deg
            speed = Float.random(in: 1.50...1.95)
            field = Float.random(in: 0.25...0.70)
        }
        j.origin = origin
        j.dir = origin * cos(tilt) + tangent * sin(tilt)
        // Field horizontal at the footpoint and perpendicular to the launch
        // tangent, so v x B bends the stream within its arc plane. The sign
        // flips per jet so loops bow both ways rather than all leaning alike.
        let sign: Float = Bool.random() ? 1 : -1
        j.axis = simd_normalize(simd_cross(origin, tangent)) * field * sign
        j.speed = speed
        j.spread = Float.random(in: 0.012...0.045)       // narrow: ~0.7-2.6 deg
        j.intensity = 0
        return j
    }
    private func seedJets() {
        jets = (0..<jetCount).map { _ in makeJet() }
        jetLives = (0..<jetCount).map { _ in Float.random(in: 3.5...11.0) }
        // Stagger initial ages so jets don't all turn over together.
        jetAges = (0..<jetCount).map { i in Float.random(in: 0...jetLives[i]) }
        if let device {
            jetBuffer = device.makeBuffer(length: MemoryLayout<Jet>.stride * jetCount,
                                          options: .storageModeShared)
        }
    }
    /// Cheap CPU-side maintenance: 44 elements, once per frame.
    private func updateJets(dt: Float) {
        for i in jets.indices {
            jetAges[i] += dt
            if jetAges[i] >= jetLives[i] {
                jets[i] = makeJet()
                jetLives[i] = Float.random(in: 3.5...11.0)
                jetAges[i] = 0
            }
            // Envelope: ramp up, hold, ease out. Squared so most jets sit
            // faint and only a few are near full strength at any moment.
            let f = jetAges[i] / max(jetLives[i], 0.01)
            let env = smoothstepF(0.0, 0.18, f) * smoothstepF(1.0, 0.55, f)
            jets[i].intensity = env * env
        }
        guard let jetBuffer else { return }
        let ptr = jetBuffer.contents().bindMemory(to: Jet.self, capacity: jetCount)
        for i in 0..<jetCount { ptr[i] = jets[i] }
    }
    private func smoothstepF(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: particles
    /// One-time CPU seed. Deliberately minimal: every parcel is marked already
    /// expired (age >= life) so the GPU kernel gives it a proper launch on the
    /// first step. All the launch logic therefore lives in exactly one place,
    /// in Metal, instead of being duplicated here and drifting out of sync.
    private func initParticles() {
        guard let device else { return }
        let byteLen = MemoryLayout<Particle>.stride * particleCount
        guard let buf = device.makeBuffer(length: byteLen, options: .storageModeShared) else { return }
        let ptr = buf.contents().bindMemory(to: Particle.self, capacity: particleCount)
        for i in 0..<particleCount {
            var p = Particle()
            p.pos  = randomSurfaceDirection() * 1.005
            p.age  = 1.0
            p.life = 0.5          // age >= life -> respawn on the first step
            p.seed = Float.random(in: 0.15...1.0)
            ptr[i] = p
        }
        particleBuffer = buf
    }

    // MARK: pipelines
    private func buildPipelines() {
        guard let device = self.device else { return }
        queue = device.makeCommandQueue()
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            starPipeline      = try makePipeline(device: device, lib: lib,
                                                 vertex: "starVertex",
                                                 fragment: "starFragment",
                                                 format: .rgba16Float,
                                                 blend: false)
            particlePipeline  = try makePipeline(device: device, lib: lib,
                                                 vertex: "particleVertex",
                                                 fragment: "particleFragment",
                                                 format: .rgba16Float,
                                                 blend: true)
            extractPipeline   = try makePipeline(device: device, lib: lib,
                                                 vertex: "fsVertex",
                                                 fragment: "extractFragment",
                                                 format: .rgba16Float,
                                                 blend: false)
            blurPipeline      = try makePipeline(device: device, lib: lib,
                                                 vertex: "fsVertex",
                                                 fragment: "blurFragment",
                                                 format: .rgba16Float,
                                                 blend: false)
            compositePipeline = try makePipeline(device: device, lib: lib,
                                                 vertex: "fsVertex",
                                                 fragment: "compositeFragment",
                                                 format: colorPixelFormat,
                                                 blend: false)
            if let fn = lib.makeFunction(name: "particleUpdate") {
                particleComputePipeline = try device.makeComputePipelineState(function: fn)
            }
        } catch {
            NSLog("StellarPortraitView pipelines: \(error)")
        }
    }
    private func makePipeline(device: MTLDevice, lib: MTLLibrary,
                              vertex: String, fragment: String,
                              format: MTLPixelFormat, blend: Bool) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = lib.makeFunction(name: vertex)
        desc.fragmentFunction = lib.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = format
        if blend {
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .one
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .one
        }
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private func ensureTextures(size: CGSize) {
        guard let device, size.width > 0, size.height > 0,
              size != currentSize else { return }
        currentSize = size
        let w = Int(size.width), h = Int(size.height)
        let hdrDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        hdrDesc.usage = [.renderTarget, .shaderRead]
        hdrDesc.storageMode = .private
        hdrTex = device.makeTexture(descriptor: hdrDesc)
        let hw = max(1, w / 2), hh = max(1, h / 2)
        let halfDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: hw, height: hh, mipmapped: false)
        halfDesc.usage = [.renderTarget, .shaderRead]
        halfDesc.storageMode = .private
        brightTex = device.makeTexture(descriptor: halfDesc)
        blurTex   = device.makeTexture(descriptor: halfDesc)
    }

    // MARK: draw
    func draw(in view: MTKView) {
        guard let queue,
              let starPipeline, let particlePipeline, let extractPipeline,
              let blurPipeline, let compositePipeline,
              let rp = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let particleBuffer, let jetBuffer,
              let cb = queue.makeCommandBuffer() else { return }

        ensureTextures(size: drawableSize)
        guard let hdrTex, let brightTex, let blurTex else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastPhysicsTime, 0), 0.1))
        lastPhysicsTime = now
        if !remnant { updateJets(dt: needsWarmup ? 5.0 : dt) }
        frameSeed &+= 1

        // GPU physics: a compute pass reads and writes the particle buffer in
        // place. The command buffer's own ordering guarantees the vertex pass
        // below sees the updated data.
        if !remnant, let cp = particleComputePipeline,
           let cenc = cb.makeComputeCommandEncoder() {
            cenc.setComputePipelineState(cp)
            cenc.setBuffer(particleBuffer, offset: 0, index: 0)
            cenc.setBuffer(jetBuffer, offset: 0, index: 2)
            let tgWidth = min(64, cp.maxTotalThreadsPerThreadgroup)
            let grid = MTLSize(width: particleCount, height: 1, depth: 1)
            let group = MTLSize(width: tgWidth, height: 1, depth: 1)

            // On the first frame, run ~4 simulated seconds so streams have
            // already flown and landed several times and the population is
            // fully decorrelated before anything is shown.
            let steps = needsWarmup ? 160 : 1
            let stepDt: Float = needsWarmup ? 0.025 : dt
            for s in 0..<steps {
                var cu = ComputeUniforms(
                    dt: stepDt, time: Float(now - startTime),
                    mu: 4.0, curlK: 1.0,
                    frameSeed: frameSeed &+ UInt32(s),
                    count: UInt32(particleCount),
                    jetCount: UInt32(jetCount), pad1: 0)
                cenc.setBytes(&cu, length: MemoryLayout<ComputeUniforms>.stride, index: 1)
                cenc.dispatchThreads(grid, threadsPerThreadgroup: group)
            }
            needsWarmup = false
            cenc.endEncoding()
        }

        var u = Uniforms(
            time: Float(now - startTime),
            radiusScale: radiusScale,
            aspect: SIMD2(Float(drawableSize.width),
                          Float(max(drawableSize.height, 1))),
            color: SIMD4(starColor, remnant ? 1 : 0),
            params: SIMD4(activity, granulation, spinRate,
                          remnant ? 0 : 0.70 + 0.45 * activity),
            extra: SIMD4(Float(jetCount), 0, 0, 0))

        // Pass 1: star -> hdrTex
        let starPass = MTLRenderPassDescriptor()
        starPass.colorAttachments[0].texture = hdrTex
        starPass.colorAttachments[0].loadAction = .clear
        starPass.colorAttachments[0].storeAction = .store
        starPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cb.makeRenderCommandEncoder(descriptor: starPass) {
            enc.setRenderPipelineState(starPipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // Pass 2: particles additively into hdrTex
        if !remnant {
            let pPass = MTLRenderPassDescriptor()
            pPass.colorAttachments[0].texture = hdrTex
            pPass.colorAttachments[0].loadAction = .load
            pPass.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: pPass) {
                enc.setRenderPipelineState(particlePipeline)
                enc.setVertexBuffer(particleBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setVertexBuffer(jetBuffer, offset: 0, index: 2)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: 6 * particleCount)
                enc.endEncoding()
            }
        }

        // Pass 3: extract brights -> brightTex
        let ePass = MTLRenderPassDescriptor()
        ePass.colorAttachments[0].texture = brightTex
        ePass.colorAttachments[0].loadAction = .dontCare
        ePass.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: ePass) {
            enc.setRenderPipelineState(extractPipeline)
            enc.setFragmentTexture(hdrTex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // Pass 4a: horizontal blur brightTex -> blurTex
        let hw = max(1, Float(brightTex.width))
        let hh = max(1, Float(brightTex.height))
        var blurX = BlurUniforms(direction: SIMD2(1, 0),
                                 texel: SIMD2(1 / hw, 1 / hh))
        let hPass = MTLRenderPassDescriptor()
        hPass.colorAttachments[0].texture = blurTex
        hPass.colorAttachments[0].loadAction = .dontCare
        hPass.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: hPass) {
            enc.setRenderPipelineState(blurPipeline)
            enc.setFragmentTexture(brightTex, index: 0)
            enc.setFragmentBytes(&blurX, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        // Pass 4b: vertical blur blurTex -> brightTex
        var blurY = BlurUniforms(direction: SIMD2(0, 1),
                                 texel: SIMD2(1 / hw, 1 / hh))
        let vPass = MTLRenderPassDescriptor()
        vPass.colorAttachments[0].texture = brightTex
        vPass.colorAttachments[0].loadAction = .dontCare
        vPass.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: vPass) {
            enc.setRenderPipelineState(blurPipeline)
            enc.setFragmentTexture(blurTex, index: 0)
            enc.setFragmentBytes(&blurY, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // Pass 5: composite (HDR + bloom) -> drawable
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentTexture(hdrTex, index: 0)
            enc.setFragmentTexture(brightTex, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
    }

    // MARK: shaders
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct U {
        float  time;
        float  radiusScale;
        float2 aspect;
        float4 color;    // rgb + remnant flag (w>0.5)
        float4 params;   // x=activity, y=granulation, z=spin, w=particleGain
        float4 extra;    // x=jetCount
    };
    struct Particle {
        float3 pos;  float3 vel;  float3 axis;
        float  age;  float  life;  float seed;  float kind;
    };
    struct Jet {
        float3 origin;  float3 dir;  float3 axis;
        float  speed;   float spread;  float intensity;  float pad;
    };
    struct ComputeU {
        float dt;
        float time;
        float mu;
        float curlK;
        uint  frameSeed;
        uint  count;
        uint  jetCount;
        uint  pad1;
    };

    // kind: 0 = chromospheric haze, 1 = jet stream, 2 = eruption
    constant float KIND_HAZE     = 0.0;
    constant float KIND_STREAM   = 1.0;
    constant float KIND_ERUPTION = 2.0;

    // These must match the Swift structs of the same shape, or the buffer is
    // silently reinterpreted. Checked at shader compile time so a field added
    // on one side and not the other fails loudly instead of rendering garbage.
    static_assert(sizeof(Particle) == 64, "Particle must match Swift layout");
    static_assert(sizeof(Jet)      == 64, "Jet must match Swift layout");
    static_assert(sizeof(ComputeU) == 32, "ComputeU must match Swift layout");
    static_assert(sizeof(U)        == 64, "U must match Swift layout");

    struct V     { float4 pos [[position]]; float2 uv; };
    struct PartV { float4 pos [[position]]; float2 uv; float3 col; float glow; };
    struct BlurU { float2 dir; float2 texel; };

    // ---- 3D value noise ------------------------------------------------
    float h31(float3 p) {
        p = fract(p * float3(233.34, 851.73, 191.99));
        p += dot(p, p + 23.45);
        return fract(p.x * p.y * p.z);
    }
    float vn3(float3 p) {
        float3 i = floor(p), f = fract(p);
        float3 u = f * f * (3.0 - 2.0 * f);
        float c000 = h31(i);
        float c100 = h31(i + float3(1,0,0));
        float c010 = h31(i + float3(0,1,0));
        float c110 = h31(i + float3(1,1,0));
        float c001 = h31(i + float3(0,0,1));
        float c101 = h31(i + float3(1,0,1));
        float c011 = h31(i + float3(0,1,1));
        float c111 = h31(i + float3(1,1,1));
        float x00 = mix(c000, c100, u.x);
        float x10 = mix(c010, c110, u.x);
        float x01 = mix(c001, c101, u.x);
        float x11 = mix(c011, c111, u.x);
        return mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z);
    }
    float fbm3(float3 p) {
        float v = 0.0, a = 0.5, w = 1.0;
        for (int i = 0; i < 5; ++i) {
            v += a * vn3(p * w);
            w *= 2.03;
            a *= 0.5;
        }
        return v;
    }
    float3 warp3(float3 p, float t) {
        return p + float3(fbm3(p + t * 0.09),
                          fbm3(p.yzx + t * 0.11 + 5.7),
                          fbm3(p.zxy + t * 0.13 + 11.3)) - 0.5;
    }

    // ---- particle physics compute -------------------------------------
    // Cheap PCG hash. State should never be zero.
    static uint pcg(uint v) {
        uint s = v * 747796405u + 2891336453u;
        uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
        return (w >> 22u) ^ w;
    }
    static float rnd(thread uint &state) {
        state = pcg(state);
        return float(state) * (1.0 / 4294967296.0);
    }
    static float3 randSphereDir(thread uint &state) {
        float z = rnd(state) * 2.0 - 1.0;
        float phi = rnd(state) * 6.28318530718;
        float r = sqrt(max(0.0, 1.0 - z * z));
        return float3(r * cos(phi), z, r * sin(phi));
    }

    // Launch a parcel from the photosphere. With mu = 4 the escape speed at
    // the surface is 2.83, and jet speeds of 1.35-2.05 sit well below it,
    // so streams arc over and are pulled back within roughly 1.5 s.
    //
    // A parcel is bound to a jet by index, and inherits that jet's origin and
    // launch direction to within its (narrow) spread. That is the whole trick
    // behind the streams: correlation, not more particles.
    static void particleRespawn(thread Particle &p,
                                const device Jet *jets,
                                uint jetCount,
                                uint gid,
                                thread uint &state) {
        Jet j = jets[gid % max(jetCount, 1u)];

        float roll = rnd(state);
        float kind = (roll < 0.14) ? KIND_HAZE
                   : (roll < 0.988) ? KIND_STREAM
                                    : KIND_ERUPTION;

        float3 origin, launch;
        float speed, life, bScale;

        if (kind < 0.5) {
            // Chromospheric haze: isotropic, barely clears the surface. Gives
            // the limb a soft gaseous edge so the disc doesn't end on a hard
            // line, and it is the only isotropic population left.
            origin = randSphereDir(state);
            launch = origin;
            speed  = 0.30 + rnd(state) * 0.28;
            life   = 1.2 + rnd(state) * 1.0;
            bScale = 0.15;
        } else {
            // Stream: tight cone around the jet's footpoint and direction.
            origin = normalize(j.origin + randSphereDir(state) * j.spread);
            launch = normalize(j.dir    + randSphereDir(state) * j.spread * 1.4);
            speed  = j.speed * (0.90 + rnd(state) * 0.20);
            life   = 2.6 + rnd(state) * 1.6;
            bScale = 1.0;
            if (kind > 1.5) {          // rare eruption: clears escape speed
                speed *= 1.9;
                life   = 3.0 + rnd(state) * 1.5;
                bScale = 0.35;
            }
        }

        // Start a hair above the surface so the landing test can't fire on
        // the launch frame.
        p.pos  = origin * 1.005;
        p.vel  = launch * speed;
        p.axis = j.axis * bScale;
        p.age  = 0.0;
        p.life = life;
        p.seed = 0.15 + rnd(state) * 0.85;
        p.kind = kind;
    }

    kernel void particleUpdate(device Particle *ps [[buffer(0)]],
                               constant ComputeU &u [[buffer(1)]],
                               const device Jet *jets [[buffer(2)]],
                               uint gid [[thread_position_in_grid]]) {
        if (gid >= u.count) return;
        Particle p = ps[gid];
        uint state = gid * 1973u + u.frameSeed * 9277u + 137u;
        if (state == 0u) state = 1u;

        float dt = min(u.dt, 0.033);
        float r  = length(p.pos);

        // A parcel retires when it falls back onto the photosphere -- that is
        // the physical end of the arc, and it keeps the population in step
        // with the trajectories instead of cutting them off at apoapsis.
        bool landed  = (r < 1.0) && (p.age > 0.08);
        bool expired = (p.age >= p.life);
        bool strayed = (r > 3.0);
        if (landed || expired || strayed || r < 0.02) {
            particleRespawn(p, jets, u.jetCount, gid, state);
            ps[gid] = p;
            return;
        }

        p.age += dt;
        float3 rhat = p.pos / r;
        // Kepler gravity toward the centre, plus a Lorentz force from the
        // parcel's local field. v x B does no work, so it curves the path
        // without pumping energy in -- the arc stays bound.
        float3 gravity = (-u.mu / (r * r)) * rhat;
        float3 lorentz = cross(p.vel, p.axis) * u.curlK;
        // Semi-implicit Euler: velocity first, then position from the new
        // velocity. Symplectic, so orbits don't spiral outward over time.
        p.vel += (gravity + lorentz) * dt;
        p.pos += p.vel * dt;
        ps[gid] = p;
    }

    // ---- full-screen triangle vertex ----------------------------------
    // Shared helper for the full-screen triangle. Called from vertex entry
    // points below -- Metal forbids one `vertex` function calling another.
    static V makeFSVertex(uint id) {
        float2 p = float2((id << 1) & 2, id & 2);
        V v;
        v.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        v.uv  = p;
        return v;
    }
    vertex V fsVertex(uint id [[vertex_id]])   { return makeFSVertex(id); }
    vertex V starVertex(uint id [[vertex_id]]) { return makeFSVertex(id); }

    // ---- star surface + volumetric corona -----------------------------
    fragment float4 starFragment(V in [[stage_in]], constant U &u [[buffer(0)]]) {
        float  t          = u.time;
        float  R          = u.radiusScale;
        float  activity   = u.params.x;
        float  granulation= u.params.y;
        float  spinRate   = u.params.z;

        float2 xy = in.uv * 2.0 - 1.0;
        float aspect = u.aspect.x / u.aspect.y;
        xy.x *= aspect;

        float r  = length(xy);
        float rr = dot(xy, xy);

        float3 base = u.color.rgb;
        float3 hot  = base * float3(1.35, 1.05, 0.60);
        bool remnant = u.color.w > 0.5;

        float phi = t * spinRate;
        float cs = cos(phi), sn = sin(phi);

        float3 rgb = float3(0);
        float alpha = 0;
        float discMask = smoothstep(R + 0.006, R - 0.006, r);

        if (r < R + 0.02) {
            float2 sp = xy / R;
            float sd = min(dot(sp, sp), 1.0);
            float z  = sqrt(1.0 - sd);
            float3 n = float3(sp.x, sp.y, z);
            float3 nr = float3(n.x * cs - n.z * sn, n.y, n.x * sn + n.z * cs);

            float3 wp = warp3(nr * (2.6 * granulation), t);
            float g   = fbm3(wp * (2.4 * granulation));
            float hotSpots = pow(fbm3((nr + 5.0) * (5.5 * granulation) + t * 0.1), 3.0);
            float dark = smoothstep(0.28, 0.70, g);

            float zc   = clamp(z, 0.0, 1.0);
            float limb = pow(zc, 0.55);
            float rim  = pow(1.0 - zc, 3.2);

            // Kept close to 1.0 on purpose. The disc used to be pushed so far
            // into HDR that it clipped to flat white and swallowed all the
            // surface detail; now it sits just under the bloom threshold and
            // only the hot spots poke above it.
            // Granulation modulates *brightness*, not hue. The previous
            // version cross-faded toward a 30%-white core colour, which is
            // what turned the disc into grey-blue and tan mottling: every
            // mid-tone of the noise landed on a desaturated blend. Scaling a
            // single saturated base colour keeps the star's chroma intact at
            // every brightness, and only genuinely hot material adds white.
            float3 surf = base * (0.42 + 1.55 * dark);
            surf += hot * hotSpots * 2.2;
            surf *= (0.26 + 0.78 * limb);
            // Coloured limb rim -- the edge should read as the star's own
            // colour at full saturation, since that is the part the tonemap
            // will not push to white.
            surf += base * float3(1.30, 1.00, 0.72) * rim * 1.35;
            // Push the disc genuinely into HDR. The centre now sits well
            // above 1.0 so it rolls off to a white-hot core, while the
            // darker limb stays below and keeps its colour.
            surf *= 2.7;

            rgb += surf * discMask;
            alpha = max(alpha, discMask);
        }

        // Volumetric corona around the star
        float Rc = R * 2.6;
        if (rr < Rc * Rc && !remnant) {
            float root  = sqrt(Rc * Rc - rr);
            float camZ  = 3.5;
            float tNear = camZ - root;
            float tFar  = camZ + root;
            float discHit = R * R - rr;
            if (discHit > 0.0) tFar = min(tFar, camZ - sqrt(discHit));
            const int STEPS = 10;
            float dt2 = (tFar - tNear) / float(STEPS);
            if (dt2 > 0.0) {
                float3 accum = float3(0);
                for (int i = 0; i < STEPS; i++) {
                    float ts = tNear + (float(i) + 0.5) * dt2;
                    float3 pos = float3(xy, camZ - ts);
                    float3 rp = float3(pos.x * cs - pos.z * sn, pos.y,
                                       pos.x * sn + pos.z * cs);
                    float3 wp = warp3(rp * 2.4, t * 0.5);
                    float d = fbm3(wp * 2.0);
                    d = pow(clamp(d, 0.0, 1.0), 2.6);
                    float rl = length(pos);
                    float radial = exp(-max(rl - R, 0.0) * 3.4);
                    accum += hot * d * radial * dt2;
                }
                // Dialled well down: the particles are the corona now, this is
                // just a faint bed for them to sit in.
                float3 crown = accum * 1.10 * activity;
                rgb += crown * (1.0 - discMask);
                alpha = max(alpha, min(length(crown), 1.0));
            }
        }

        if (remnant) {
            float pt   = exp(-rr * 60.0);
            float wisp = exp(-rr * 10.0) * 0.20;
            rgb   = float3(2.5, 2.5, 3.0) * pt + float3(0.35, 0.5, 0.95) * wisp;
            alpha = clamp(pt + wisp, 0.0, 1.0);
        }
        return float4(rgb, alpha);
    }

    // ---- particles -----------------------------------------------------
    constant float2 kQuad[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2( 1, -1), float2( 1,  1), float2(-1,  1)
    };
    constant float2 kUV[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    vertex PartV particleVertex(const device Particle *ps [[buffer(0)]],
                                constant U &u [[buffer(1)]],
                                const device Jet *jets [[buffer(2)]],
                                uint vid [[vertex_id]]) {
        uint pid    = vid / 6u;
        uint corner = vid % 6u;
        Particle p  = ps[pid];

        PartV out;
        // World -> NDC. World is in "star radii" units where the surface
        // is at r = 1; scale to the visual disc size.
        float aspect = u.aspect.x / u.aspect.y;
        float3 world = p.pos * u.radiusScale;

        // Cull particles fully behind the visible disc.
        if (world.z < 0.0 && dot(world.xy, world.xy) < u.radiusScale * u.radiusScale * 0.95) {
            out.pos = float4(-2, -2, 0, 1);
            out.uv  = float2(0);
            out.col = float3(0);
            out.glow = 0;
            return out;
        }

        float r        = length(p.pos);
        float altitude = r - 1.0;
        float lifeFrac = clamp(p.age / max(p.life, 0.01), 0.0, 1.0);

        // Fade against geometry rather than age: parcels brighten as they
        // clear the photosphere and dim back into it as they land, so the
        // retire-on-impact rule never shows as a pop. Escapers dim with
        // distance before they reach the cull radius.
        float riseFade = smoothstep(0.0, 0.030, altitude);
        float endFade  = smoothstep(1.0, 0.75, lifeFrac);
        float farFade  = smoothstep(3.0, 1.9, r);
        float fade     = riseFade * endFade * farFade;

        // A stream inherits its jet's lifecycle envelope, so the whole stream
        // brightens and fades together instead of flickering per parcel.
        uint jc = uint(max(u.extra.x, 1.0));
        float jetEnv = jets[pid % jc].intensity;
        if (p.kind < 0.5) jetEnv = 0.55;          // haze ignores the jets

        // Deliberately tiny. A single parcel should be nearly invisible; what
        // you see is hundreds of them overlapping additively along a stream.
        float kindSize = (p.kind < 0.5) ? 0.75 : ((p.kind < 1.5) ? 1.0 : 1.5);
        float sizeW = 0.0045 * u.radiusScale * (0.6 + 0.5 * p.seed) * kindSize;
        float2 offW = kQuad[corner] * sizeW;
        float2 ndc  = float2((world.x + offW.x) / aspect,
                              world.y + offW.y);

        out.pos = float4(ndc, 0.5 - world.z * 0.02, 1.0);
        out.uv  = kUV[corner];

        // Slight forward bias so the near side reads brighter than the far.
        float depthBoost = 0.72 + 0.28 * clamp(world.z / max(u.radiusScale, 0.001), -1.0, 1.0);
        float kindGain = (p.kind < 0.5) ? 0.5 : ((p.kind < 1.5) ? 1.0 : 2.0);
        // ~1/40th of the old per-parcel intensity. Density does the work.
        float intensity = 0.115 * (0.55 + 0.45 * p.seed)
                        * fade * depthBoost * kindGain * jetEnv;

        // Freshly launched plasma is hottest; it cools as the arc plays out.
        float heat = exp(-lifeFrac * 2.4);
        // Only a modest push toward white at launch -- at 0.75 the whole
        // stream read as grey rather than as the star's own plasma.
        float3 tint = mix(u.color.rgb * float3(1.20, 0.94, 0.60),
                          float3(1.25, 1.15, 1.00), heat * 0.32);
        out.col  = tint * intensity * u.params.w;
        out.glow = fade;
        return out;
    }
    fragment float4 particleFragment(PartV in [[stage_in]]) {
        float2 d = in.uv * 2.0 - 1.0;
        float r2 = dot(d, d);
        // Tight core, almost no halo -- the glow is supposed to emerge from
        // overlapping parcels, not from each sprite carrying its own bloom.
        float core = exp(-r2 * 9.0);
        float halo = exp(-r2 * 2.6) * 0.10;
        float a = core + halo;
        return float4(in.col * a, a * in.glow);
    }

    // ---- bloom / composite --------------------------------------------
    static float acesScalar(float x) {
        return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
    }
    static float3 acesCurve(float3 x) {
        return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
    }
    fragment float4 extractFragment(V in [[stage_in]],
                                    texture2d<float, access::sample> hdr [[texture(0)]]) {
        constexpr sampler s(mag_filter::linear, min_filter::linear,
                            address::clamp_to_edge);
        float3 c = hdr.sample(s, float2(in.uv.x, in.uv.y)).rgb;
        // The threshold sits below the bright half of the disc on purpose:
        // the coloured glow bleeding off the limb is what sells "this thing
        // is genuinely luminous". Overexposure is prevented by the tonemap in
        // the composite, not by starving the bloom.
        float3 excess = max(c - 0.85, 0.0);
        return float4(excess * 1.15, 1.0);
    }
    fragment float4 blurFragment(V in [[stage_in]],
                                 texture2d<float, access::sample> src [[texture(0)]],
                                 constant BlurU &b [[buffer(0)]]) {
        constexpr sampler s(mag_filter::linear, min_filter::linear,
                            address::clamp_to_edge);
        // 9-tap gaussian, weights sum ~= 1.
        const float w0 = 0.227027;
        const float w1 = 0.194594;
        const float w2 = 0.121622;
        const float w3 = 0.054054;
        const float w4 = 0.016216;
        float2 uv = float2(in.uv.x, in.uv.y);
        float2 d1 = b.dir * b.texel * 1.6;
        float2 d2 = b.dir * b.texel * 4.0;
        float2 d3 = b.dir * b.texel * 7.4;
        float2 d4 = b.dir * b.texel * 12.0;
        float3 c  = src.sample(s, uv).rgb * w0;
        c += src.sample(s, uv + d1).rgb * w1;
        c += src.sample(s, uv - d1).rgb * w1;
        c += src.sample(s, uv + d2).rgb * w2;
        c += src.sample(s, uv - d2).rgb * w2;
        c += src.sample(s, uv + d3).rgb * w3;
        c += src.sample(s, uv - d3).rgb * w3;
        c += src.sample(s, uv + d4).rgb * w4;
        c += src.sample(s, uv - d4).rgb * w4;
        return float4(c, 1.0);
    }
    fragment float4 compositeFragment(V in [[stage_in]],
                                      texture2d<float, access::sample> hdr    [[texture(0)]],
                                      texture2d<float, access::sample> bloom  [[texture(1)]]) {
        constexpr sampler s(mag_filter::linear, min_filter::linear,
                            address::clamp_to_edge);
        float2 uv = float2(in.uv.x, in.uv.y);
        float3 c  = hdr.sample(s, uv).rgb;
        float3 bl = bloom.sample(s, uv).rgb;
        float3 hi = c + bl * 1.75;

        // Applying the ACES curve per channel is what bleached the star: the
        // channels compress independently, so as a blue star gets brighter
        // its red and green catch up and the hue slides to grey-white. Here
        // the curve is applied to *luminance* and the RGB ratio is carried
        // through unchanged, which preserves hue exactly at any brightness.
        // A 30% blend of the per-channel result is mixed back in so the very
        // core still blows out to white-hot the way a real overexposed
        // highlight does, instead of reading as flat saturated paint.
        const float3 W = float3(0.2126, 0.7152, 0.0722);
        float lum  = max(dot(hi, W), 1e-4);
        float mapped = acesScalar(lum);
        float3 byLum  = hi * (mapped / lum);
        float3 byChan = acesCurve(hi);
        float3 outc = mix(byLum, byChan, 0.30);

        // The curve still costs a little chroma on the way through; push it
        // back so the limb and corona stay unmistakably the star's colour.
        float ol = max(dot(outc, W), 1e-4);
        outc = mix(float3(ol), outc, 1.22);
        return float4(clamp(outc, 0.0, 1.0), 1.0);
    }
    """
}

/// Where the star sits among its relatives. The axes are the real H–R axes
/// (temperature falling to the right, luminosity on a log scale), but the chart
/// is meant to be read as a family portrait: every dot is a kind of star you
/// could actually meet, drawn in its true blackbody colour and sized by its
/// radius, so you can see what lives where without knowing the jargon. The
/// example set matches the archetypes StellarProfile hands out, and each one's
/// luminosity is computed from its own radius and temperature rather than
/// typed in, so a marker cannot drift away from the physics.
private final class StellarHRView: NSView {
    private struct Example {
        let name: String
        let temp: Double
        let radius: Double
        let dx: CGFloat
        let dy: CGFloat
        let align: NSTextAlignment
        var luminosity: Double { radius * radius * pow(temp / 5772, 4) }
    }
    private static let examples: [Example] = [
        Example(name: "blue giant", temp: 35000, radius: 9, dx: 8, dy: -4, align: .left),
        Example(name: "hot white star", temp: 21000, radius: 4.5, dx: 8, dy: -4, align: .left),
        Example(name: "white star", temp: 9000, radius: 1.8, dx: 8, dy: -4, align: .left),
        Example(name: "red giant", temp: 3900, radius: 40, dx: 0, dy: -13, align: .center),
        Example(name: "our Sun", temp: 5772, radius: 1, dx: -8, dy: -4, align: .right),
        Example(name: "orange dwarf", temp: 4500, radius: 0.7, dx: 0, dy: 8, align: .center),
        Example(name: "red dwarf", temp: 3200, radius: 0.23, dx: 0, dy: 8, align: .center),
        Example(name: "white dwarf", temp: 12000, radius: 0.012, dx: 0, dy: 8, align: .center)
    ]
    var temperature = 5772.0
    var luminosity = 1.0
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        StarCardStyle.panelBackground(bounds)
        let plot = NSRect(x: 38, y: 12, width: bounds.width - 50, height: bounds.height - 58)
        func point(_ t: Double, _ l: Double) -> NSPoint {
            let x = max(0, min(1, (log10(50000) - log10(max(2000, t))) / (log10(50000) - log10(2000))))
            let y = max(0, min(1, (6 - log10(max(0.0001, l))) / 10))
            return NSPoint(x: plot.minX + x * plot.width, y: plot.minY + y * plot.height)
        }
        // The main sequence: the crowded lane almost every star spends its life on.
        let sequence = NSBezierPath()
        sequence.move(to: point(40000, 500000))
        sequence.curve(to: point(5772, 1), controlPoint1: point(20000, 5000), controlPoint2: point(8000, 8))
        sequence.curve(to: point(2600, 0.0005), controlPoint1: point(4700, 0.18), controlPoint2: point(3200, 0.005))
        sequence.lineWidth = 12
        sequence.lineCapStyle = .round
        NSColor(calibratedRed: 0.35, green: 0.65, blue: 0.85, alpha: 0.16).setStroke()
        sequence.stroke()

        let tiny = KidsStyle.font(8.5, .medium)
        StarCardStyle.draw("brighter", at: NSPoint(x: 3, y: plot.minY), font: tiny, color: StarCardStyle.faint)
        StarCardStyle.draw("dimmer", at: NSPoint(x: 3, y: plot.maxY - 9), font: tiny, color: StarCardStyle.faint)
        StarCardStyle.draw("hotter", at: NSPoint(x: plot.minX, y: plot.maxY + 5), font: tiny, color: StarCardStyle.faint)
        StarCardStyle.draw("cooler", at: NSPoint(x: plot.maxX, y: plot.maxY + 5), font: tiny,
                           color: StarCardStyle.faint, align: .right)

        // The selected star is often one of the archetypes, so its ring lands on
        // top of that marker. Drop the example's name in that case: "your star"
        // says everything, and two labels in one spot says nothing.
        let here = point(temperature, luminosity)
        for example in Self.examples {
            let at = point(example.temp, example.luminosity)
            let crowded = hypot(at.x - here.x, at.y - here.y) < 18
            // Radius spans four decades, so the marker follows log radius --
            // otherwise a red giant would be the whole panel and a white dwarf
            // would be invisible.
            let size = CGFloat(max(2.0, min(7.0, 2.0 + 2.6 * (log10(example.radius) + 2) / 3)))
            let rgb = Relativity.blackbodyRGB(Float(example.temp))
            let peak = max(rgb.x, max(rgb.y, rgb.z))
            let colour = NSColor(srgbRed: CGFloat(rgb.x / peak), green: CGFloat(rgb.y / peak),
                                 blue: CGFloat(rgb.z / peak), alpha: 1)
            StarCardStyle.glow(at: at, radius: size * 2.4, color: colour, strength: 0.5)
            colour.setFill()
            NSBezierPath(ovalIn: NSRect(x: at.x - size, y: at.y - size,
                                        width: size * 2, height: size * 2)).fill()
            if !crowded {
                StarCardStyle.draw(example.name, at: NSPoint(x: at.x + example.dx, y: at.y + example.dy - 5),
                                   font: tiny, color: StarCardStyle.body, align: example.align)
            }
        }

        // The selected star last, so its ring is never buried by a neighbour.
        let selected = here
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: selected.x - 2.5, y: selected.y - 2.5, width: 5, height: 5)).fill()
        let ring = NSBezierPath(ovalIn: NSRect(x: selected.x - 8, y: selected.y - 8, width: 16, height: 16))
        ring.lineWidth = 2
        StarCardStyle.accent.setStroke()
        ring.stroke()
        let labelY = selected.y > plot.minY + 24 ? selected.y - 22 : selected.y + 12
        StarCardStyle.draw("your star", at: NSPoint(x: min(max(selected.x, plot.minX + 22), plot.maxX - 22), y: labelY),
                           font: KidsStyle.font(9.5, .bold), color: StarCardStyle.ink, align: .center)

        StarCardStyle.draw("every dot is a kind of star — yours wears the ring",
                           at: NSPoint(x: bounds.midX, y: bounds.height - 15),
                           font: KidsStyle.font(9, .medium), color: StarCardStyle.faint, align: .center)
    }
}
