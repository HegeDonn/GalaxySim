import AppKit

// =====================================================================
// MARK: - One look for the whole app
//
// The first screen and the galaxy picker were built in the kids idiom:
// SF Rounded type, dark night-sky plates floating over the starfield,
// and controls big enough to hit with a thumb. The star card and the
// planet observatory were built earlier and had drifted somewhere else
// — system type at 9 to 13 points, bezelled push buttons, a pale blue
// accent of their own — so clicking a star aged the app by a decade.
//
// Everything user-facing now takes its type, its plate colour and its
// accent from here. The one deliberate exception is ControlPanel and the
// observatory's tuning sliders: those are the engineer's view, they live
// behind the hamburger, and they are supposed to look like instruments.
//
// Sizes are the other half of it. `touchTarget` is the smallest thing
// anyone is asked to hit, because this may end up on a tablet one day
// and a 22-point bezel button is not a target, it is a dare.
// =====================================================================
enum KidsStyle {

    /// SF Rounded at any size. The whole visual identity rests on this
    /// one substitution more than on any colour.
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: d, size: size) ?? base
        }
        return base
    }

    /// Night-sky slab shared by every floating control. Deliberately dark
    /// in light appearance too: these plates hang over a starfield, and a
    /// light one would blow out the sky drawn behind and around it.
    static func night(_ lift: CGFloat = 0) -> NSColor {
        NSColor(srgbRed: 0.055 + lift, green: 0.065 + lift, blue: 0.105 + lift, alpha: 0.95)
    }

    /// Red-light mode for the screens where the point is the sky.
    ///
    /// Rods — the cells you see faint stars with — are nearly blind past
    /// about 620 nm, so deep red chrome can be perfectly readable without
    /// spending the dark adaptation that takes twenty minutes to build and
    /// one white button to destroy. It is why observatories, ships' bridges
    /// and aircraft cockpits have run on red light for a century, and it is
    /// the right palette for a person standing on a planet at night.
    ///
    /// A screen mode rather than a per-control flag: the observatory fills
    /// the window, so while it is up *everything* on screen is a night view.
    /// Turning it on or off repaints the app. Every colour below is read at
    /// draw time, so a control that is not asked to redraw keeps whichever
    /// palette it was last painted in -- which is how the galaxy screen came
    /// back from a planet with red buttons on it.
    static var nightVision = false {
        didSet {
            guard nightVision != oldValue else { return }
            for window in NSApplication.shared.windows { window.contentView?.repaintTree() }
        }
    }

    // The red-light tones below keep green and blue near zero on purpose.
    // Lift either one and the hue slides towards pink, which is exactly the
    // part of the spectrum the rods are still sensitive to — a pink control
    // is a white control wearing a hat.
    static var accent: NSColor {
        nightVision ? NSColor(srgbRed: 0.44, green: 0.025, blue: 0.015, alpha: 1)
                    : NSColor(srgbRed: 0.16, green: 0.48, blue: 0.82, alpha: 1)
    }
    static var accentOnNight: NSColor {
        nightVision ? NSColor(srgbRed: 0.98, green: 0.20, blue: 0.06, alpha: 1)
                    : NSColor(srgbRed: 0.62, green: 0.86, blue: 1, alpha: 1)
    }
    static func button(_ lift: CGFloat = 0) -> NSColor {
        nightVision
            ? NSColor(srgbRed: 0.155 + lift * 1.6, green: 0.011 + lift * 0.1,
                      blue: 0.008 + lift * 0.1, alpha: 0.94)
            : NSColor(srgbRed: 0.10 + lift, green: 0.25 + lift, blue: 0.42 + lift, alpha: 1)
    }

    /// A plain white-grey tone, or its red-light equivalent. Chrome drawn
    /// as bare `calibratedWhite` — rings, arcs, the shutter bulb — comes
    /// through here so red-light mode reaches it too. A white shutter the
    /// size of a thumb is the brightest object on a night screen and costs
    /// more dark adaptation than every label put together.
    static func lamp(_ white: CGFloat, alpha: CGFloat = 1) -> NSColor {
        nightVision ? NSColor(srgbRed: min(1, white * 1.02), green: white * 0.055,
                              blue: white * 0.025, alpha: alpha)
                    : NSColor(calibratedWhite: white, alpha: alpha)
    }

    /// The amber an instrument uses for the number it is reading out. Goes
    /// deeper into the red under red light, where amber is already halfway.
    static var readout: NSColor {
        nightVision ? NSColor(srgbRed: 1, green: 0.17, blue: 0.02, alpha: 1)
                    : NSColor(calibratedRed: 1, green: 0.78, blue: 0.20, alpha: 1)
    }

    /// Lettering *on* the chrome. White text on a red button costs exactly
    /// what the red button saved, so in night mode the type goes red too.
    static var chromeInk: NSColor {
        nightVision ? NSColor(srgbRed: 0.97, green: 0.18, blue: 0.06, alpha: 0.95) : ink
    }

    static let ink = NSColor.white
    static let body = NSColor.white.withAlphaComponent(0.84)
    static let faint = NSColor.white.withAlphaComponent(0.55)
    static let panel = NSColor.white.withAlphaComponent(0.05)
    static let hairline = NSColor.white.withAlphaComponent(0.10)

    static let corner: CGFloat = 16
    /// Nothing the user has to hit is smaller than this, on any axis.
    static let touchTarget: CGFloat = 44
}

/// Something the user is expected to hit, as opposed to read. Labels are
/// `NSControl`s too, so "every control" is not the question a layout check
/// wants to ask; "everything with a target on it" is.
protocol TouchTarget: NSControl {}

extension PillButton: TouchTarget {}
extension ChunkyButton: TouchTarget {}

// MARK: - Pill button

/// A wide rounded text button on a night plate: the kids counterpart to
/// `NSButton(bezelStyle: .rounded)`, which is where most of the app's
/// remaining "1998" came from. Draws itself for the same reason
/// `ChunkyButton` does — AppKit's bezels cap out far below the height a
/// finger wants, and they cannot be made to sit on a dark plate.
final class PillButton: NSControl {

    var title: String = "" {
        didSet { reloadSymbol(); invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    /// Optional SF Symbol drawn ahead of the title; falls back to nothing
    /// rather than to a blank box if the symbol is unavailable.
    var symbolName: String? {
        didSet { reloadSymbol(); invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    /// Filled with the accent instead of night: for the one action on a
    /// screen that the eye should land on first.
    var isProminent = false { didSet { needsDisplay = true } }
    var minHeight: CGFloat = KidsStyle.touchTarget { didSet { invalidateIntrinsicContentSize() } }
    var horizontalPadding: CGFloat = 18 { didSet { invalidateIntrinsicContentSize() } }
    var fontSize: CGFloat = 16 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Past this many characters a pill with a symbol drops its title and
    /// becomes a square icon. "Land somewhere else" set in a lozenge stops
    /// being a button and starts being a sentence you have to read before
    /// you can act on it; a pin glyph is understood at a glance and stops
    /// competing with the thing the screen is actually about. The words are
    /// not lost — they stay as the tooltip and the accessibility label.
    var iconOnlyOverLength = 14 { didSet { reloadSymbol(); invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onTap: (() -> Void)?

    /// True when this pill has given up its words.
    var isIconOnly: Bool { symbol != nil && title.count > iconOnlyOverLength }

    private var symbol: NSImage?
    private var pressed = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracker: NSTrackingArea?

    init(title: String, symbol: String? = nil) {
        super.init(frame: .zero)
        self.title = title
        self.symbolName = symbol
        reloadSymbol()
        wantsLayer = true
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func reloadSymbol() {
        guard let name = symbolName else { symbol = nil; return }
        symbol = NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: fontSize + 1,
                                                                 weight: .semibold))
        guard isIconOnly else { return }
        symbol = NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: fontSize + 6,
                                                                 weight: .semibold))
        toolTip = title
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: KidsStyle.font(fontSize, .semibold),
         .foregroundColor: isProminent ? NSColor.white : KidsStyle.chromeInk]
    }

    override var intrinsicContentSize: NSSize {
        if isIconOnly { return NSSize(width: minHeight, height: minHeight) }
        let textWidth = (title as NSString).size(withAttributes: titleAttributes).width
        let symbolWidth = symbol.map { $0.size.width + 8 } ?? 0
        return NSSize(width: (textWidth + symbolWidth + horizontalPadding * 2).rounded(.up),
                      height: minHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        guard r.width > 4, r.height > 4 else { return }
        let radius = min(KidsStyle.corner, r.height / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

        if isProminent {
            KidsStyle.accent.withAlphaComponent(pressed ? 1.0 : (hovering ? 0.95 : 0.85)).setFill()
        } else {
            KidsStyle.button(pressed ? 0.12 : (hovering ? 0.06 : 0)).setFill()
        }
        path.fill()
        (isProminent ? NSColor.white.withAlphaComponent(0.25)
                     : NSColor.white.withAlphaComponent(hovering ? 0.34 : 0.16)).setStroke()
        path.lineWidth = 1
        path.stroke()

        let tint = isProminent ? NSColor.white : KidsStyle.chromeInk
        if isIconOnly, let symbol {
            let side = min(symbol.size.width, symbol.size.height)
            let dr = NSRect(x: (r.midX - symbol.size.width / 2).rounded(),
                            y: (r.midY - symbol.size.height / 2).rounded(),
                            width: symbol.size.width, height: max(side, symbol.size.height))
            KidsPanel.tinted(symbol, tint).draw(in: dr)
            return
        }
        let text = NSAttributedString(string: title, attributes: titleAttributes)
        let textSize = text.size()
        let symbolWidth = symbol.map { $0.size.width + 8 } ?? 0
        var x = (r.midX - (textSize.width + symbolWidth) / 2).rounded()
        if let symbol {
            let dr = NSRect(x: x, y: (r.midY - symbol.size.height / 2).rounded(),
                            width: symbol.size.width, height: symbol.size.height)
            KidsPanel.tinted(symbol, tint).draw(in: dr)
            x += symbolWidth
        }
        text.draw(at: NSPoint(x: x, y: (r.midY - textSize.height / 2).rounded()))
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
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; pressed = true }
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onTap?() }
    }

    /// The UI review drives the visible controls rather than the closures
    /// behind them, so it needs a way in that does not fake a mouse.
    func simulateTap() { onTap?() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSView {
    /// Mark this view and everything under it as needing to be drawn again.
    /// Used when the palette changes underneath views that are already up.
    func repaintTree() {
        needsDisplay = true
        for view in subviews { view.repaintTree() }
    }
}
