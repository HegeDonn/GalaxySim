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

    /// The user's own accent, as chosen in System Settings.
    static var accent: NSColor { .controlAccentColor }

    /// The same accent lifted toward white, for small text and hairlines
    /// that sit *on* a night plate. A saturated accent at 10 points on
    /// near-black is legible in a mockup and not on a screen.
    static let accentOnNight: NSColor = {
        let fallback = NSColor(srgbRed: 0.55, green: 0.85, blue: 0.97, alpha: 1)
        guard let a = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return fallback }
        func lift(_ c: CGFloat) -> CGFloat { min(1, c * 0.55 + 0.45) }
        return NSColor(srgbRed: lift(a.redComponent), green: lift(a.greenComponent),
                       blue: lift(a.blueComponent), alpha: 1)
    }()

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
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
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
    var fontSize: CGFloat = 14 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onTap: (() -> Void)?

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
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: KidsStyle.font(fontSize, .semibold),
         .foregroundColor: isProminent ? NSColor.white : KidsStyle.ink]
    }

    override var intrinsicContentSize: NSSize {
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
            KidsStyle.night(pressed ? 0.10 : (hovering ? 0.05 : 0)).setFill()
        }
        path.fill()
        (isProminent ? NSColor.white.withAlphaComponent(0.25)
                     : NSColor.white.withAlphaComponent(hovering ? 0.34 : 0.16)).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = NSAttributedString(string: title, attributes: titleAttributes)
        let textSize = text.size()
        let symbolWidth = symbol.map { $0.size.width + 8 } ?? 0
        var x = (r.midX - (textSize.width + symbolWidth) / 2).rounded()
        if let symbol {
            let tint = KidsStyle.ink
            let dr = NSRect(x: x, y: (r.midY - symbol.size.height / 2).rounded(),
                            width: symbol.size.width, height: symbol.size.height)
            KidsPanel.tinted(symbol, isProminent ? .white : tint).draw(in: dr)
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
