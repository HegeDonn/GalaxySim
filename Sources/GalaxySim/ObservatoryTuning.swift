import Foundation

/// Every number the night-sky camera's look depends on, in one place.
///
/// These used to be constants buried in the shader source, which meant that
/// finding a good sky was a compile-measure-guess loop. They are uniforms now,
/// so the engineering panel can move them while the picture is on screen, and
/// `save()` writes the result next to the app's other support files where the
/// next launch picks it up. The built-in values below stay the fallback: a
/// reset always has somewhere honest to go back to.
struct ObservatoryTuning: Codable, Equatable {

    // ---- exposure -------------------------------------------------
    /// Exposure units gathered per second of open shutter. The master
    /// brightness of everything; 1.0 is a mid-bright highlight.
    var plateGain: Float = 0.115
    /// Exposure that develops to pure white. Anything above it clips, which
    /// is what gives a photograph highlights rather than haze.
    var whitePoint: Float = 2.5

    // ---- stars ----------------------------------------------------
    /// Exponent on each star's flux. Above 1 it stretches the gap between the
    /// brightest stars and the rest; below 1 it flattens them together.
    var starGamma: Float = 1.25
    /// Overall star brightness, applied after the curve.
    var starScale: Float = 1
    /// Highest flux a star may carry. Low values flatten the top of the
    /// range into haze; this is deliberately far above white.
    var starCeiling: Float = 100_000
    /// Share of a star's light concentrated into its core rather than its
    /// wings. Raises peak brightness without making discs larger.
    var fluxScale: Float = 0.34
    /// Radius in pixels of the faintest star's disc.
    var sizeBase: Float = 0.55
    /// How fast a disc grows with the logarithm of brightness.
    var sizeSlope: Float = 0.35
    /// How much a longer exposure swells a disc, per doubling of seconds.
    var sizeReach: Float = 0.16
    /// Flux at which diffraction spikes begin to appear…
    var spikeOnset: Float = 120
    /// …and the flux at which they are fully drawn.
    var spikeFull: Float = 1400

    // ---- sky and sensor -------------------------------------------
    /// Glow bleeding out of bright cores into their surroundings.
    var bleedScale: Float = 1.6
    /// Sensor grain.
    var grainScale: Float = 1
    /// Airglow: the faint light of the planet's own atmosphere.
    var airglowScale: Float = 1
    /// Opacity of the dark dust lane through the galactic plane.
    var dustScale: Float = 1
    /// Meteor brightness.
    var meteorScale: Float = 1
    /// How much the live viewfinder brightens what the dial is set to. The
    /// photograph obeys the dial exactly; the view you frame with is lifted
    /// and compressed (`boost * seconds^0.6`) so that every step of the dial
    /// still changes it while the short end stays bright enough to aim by.
    /// The name is kept for files saved before it became a curve.
    var previewFloor: Float = 3

    // ---- the host star --------------------------------------------
    /// Radiance of the star's own surface, for a Sun-temperature star.
    /// Scaled by (T/5772)^4, so a hot star's disc is enormously brighter per
    /// unit area than a cool one's. Every stellar photosphere over-exposes
    /// this camera by a wide margin, which is correct: the difference you
    /// actually see between stars is their SIZE and the sky around them.
    var sunDiscScale: Float = 4000
    /// Sky radiance under one Earth's worth of sunlight. Everything daylit
    /// scales linearly from here, so a star delivering a thousandth of
    /// Earth's light gives a sky a thousandth as bright — which is how a
    /// planet around a red dwarf keeps its stars in the daytime.
    var dayScale: Float = 320

    /// A named whole sky, for anyone who wants a look rather than sliders.
    struct Preset {
        let name: String
        let blurb: String
        let values: ObservatoryTuning
    }

    /// Three skies. They differ in what they are FOR, not in quality: the
    /// first two are two honest readings of the same night, and the third
    /// stops pretending to be a camera at all.
    static let presets: [Preset] = [
        Preset(name: "Starry night",
               blurb: "Grainy film, plenty of stars, meteors that show off",
               values: starryNight),
        Preset(name: "Real photo",
               blurb: "Clean, dark, only the brightest stars burn out",
               values: realPhotograph),
        Preset(name: "Storybook sky",
               blurb: "Big glowing stars with spikes — not a real sky",
               values: storybookSky),
    ]

    /// Saved from the engineering panel and kept as the one the app opens
    /// with: a low white point so stars reach white early, a curve below 1 to
    /// bring the faint crowd up with them, and grain turned well past what a
    /// camera would give, which is what makes it read as film.
    static let starryNight: ObservatoryTuning = {
        var t = ObservatoryTuning()
        t.plateGain = 0.115
        t.whitePoint = 0.898333
        t.starGamma = 0.764226
        t.starScale = 0.673235
        t.starCeiling = 968.366
        t.fluxScale = 0.34
        t.sizeBase = 0.592656
        t.sizeSlope = 0.232945
        t.sizeReach = 0.286038
        t.spikeOnset = 120
        t.spikeFull = 1977.91
        t.bleedScale = 1.59379
        t.grainScale = 4.88866
        t.airglowScale = 0.994266
        t.dustScale = 0.543291
        t.meteorScale = 4.71279
        t.previewFloor = 3.19586
        return t
    }()

    /// The measured one: a quarter-second frame reads about 6 sRGB and a
    /// sixty-second frame about 76, with the brightest stars clipping to
    /// white from roughly fifteen seconds up. Nothing here is exaggerated.
    static let realPhotograph: ObservatoryTuning = {
        var t = ObservatoryTuning()
        t.plateGain = 0.115
        t.whitePoint = 2.5
        t.starGamma = 1.25
        t.starScale = 1
        t.starCeiling = 100_000
        t.fluxScale = 0.34
        t.sizeBase = 0.55
        t.sizeSlope = 0.35
        t.sizeReach = 0.16
        t.spikeOnset = 120
        t.spikeFull = 1400
        t.bleedScale = 1.6
        t.grainScale = 1
        t.airglowScale = 1
        t.dustScale = 1
        t.meteorScale = 1
        t.previewFloor = 3
        return t
    }()

    /// Deliberately not a photograph. Every star is a lamp with spikes and a
    /// halo, the dust lane is a black river, and the meteors never stop. It
    /// is the sky a picture book draws, and it is here because that is the
    /// sky most people picture when they think of one.
    static let storybookSky: ObservatoryTuning = {
        var t = ObservatoryTuning()
        t.plateGain = 0.16
        t.whitePoint = 0.7
        t.starGamma = 1.55
        t.starScale = 3
        t.starCeiling = 100_000
        t.fluxScale = 0.9
        t.sizeBase = 0.9
        t.sizeSlope = 0.85
        t.sizeReach = 0.5
        t.spikeOnset = 8
        t.spikeFull = 220
        t.bleedScale = 3.4
        t.grainScale = 0.4
        t.airglowScale = 1.8
        t.dustScale = 1.6
        t.meteorScale = 5
        t.previewFloor = 4
        return t
    }()

    /// What a reset goes back to, and what a first launch starts from.
    static let builtIn = starryNight

    /// The preset these values match exactly, if any. Sliders leave it nil,
    /// which is how the menu knows to stop ticking a name.
    var matchingPreset: Preset? {
        Self.presets.first { $0.values == self }
    }

    /// The live values. Changing this is what the panel's sliders do; the
    /// next frame reads it when it packs its uniforms.
    static var current = ObservatoryTuning.load()

    // MARK: persistence

    /// Read and written as a plain name-to-number map rather than through the
    /// synthesised Codable. With the synthesised one, adding a single new
    /// tunable would make every file saved before it fail to decode, and the
    /// sky someone had settled on would vanish without a word. This keeps
    /// whatever it recognises and leaves the rest at the shipped values.
    /// Spelled out because declaring a decoder suppresses the free one.
    init() {}

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Float].self)
        self = ObservatoryTuning()
        for field in Self.fields where raw[field.key] != nil {
            guard let value = raw[field.key], value.isFinite else { continue }
            self[keyPath: field.path] = value
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var raw: [String: Float] = [:]
        for field in Self.fields { raw[field.key] = self[keyPath: field.path] }
        try container.encode(raw)
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("GalaxySim/observatory-tuning.json")
    }

    /// Saved values if there are any, then any `GALAXYSIM_TUNE_<name>` in the
    /// environment on top, so a diagnostic can sweep one number without
    /// disturbing what was saved from the panel.
    static func load() -> ObservatoryTuning {
        var tuning = builtIn
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(ObservatoryTuning.self, from: data) {
            tuning = saved
        }
        let env = ProcessInfo.processInfo.environment
        // GALAXYSIM_SKY=<preset name> starts on one of the named skies
        // whatever is saved, which is how all three get captured side by side.
        if let wanted = env["GALAXYSIM_SKY"]?.lowercased(),
           let preset = presets.first(where: { $0.name.lowercased().hasPrefix(wanted) }) {
            tuning = preset.values
        }
        for field in fields {
            if let raw = env["GALAXYSIM_TUNE_" + field.key], let value = Float(raw) {
                tuning[keyPath: field.path] = value
            }
        }
        return tuning
    }

    /// Returns the path written, or the reason it could not be.
    @discardableResult
    func save() -> Result<URL, Error> {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
            return .success(url)
        } catch {
            return .failure(error)
        }
    }

    /// The same values as a Swift literal, for pasting back into the defaults
    /// above once a setting has proved itself.
    var swiftLiteral: String {
        Self.fields.map { field in
            "    var \(field.key): Float = \(Self.pretty(self[keyPath: field.path]))"
        }.joined(separator: "\n")
    }

    private static func pretty(_ v: Float) -> String {
        if v == v.rounded() && abs(v) < 1e7 { return String(format: "%.0f", v) }
        return String(format: "%g", v)
    }

    // MARK: the panel's description of itself

    /// One tunable: where it lives, what to call it, and the range a slider
    /// should sweep. `log` ranges are the ones that span decades, where a
    /// linear slider would spend all its travel in the top octave.
    struct Field {
        let key: String
        let path: WritableKeyPath<ObservatoryTuning, Float>
        let title: String
        let blurb: String
        let min: Float
        let max: Float
        let log: Bool
        let group: String
    }

    static let fields: [Field] = [
        Field(key: "plateGain", path: \.plateGain, title: "Exposure gain",
              blurb: "Brightness per second of open shutter",
              min: 0.002, max: 2, log: true, group: "Exposure"),
        Field(key: "whitePoint", path: \.whitePoint, title: "White point",
              blurb: "Exposure that burns out to pure white",
              min: 0.5, max: 80, log: true, group: "Exposure"),

        Field(key: "starGamma", path: \.starGamma, title: "Brightness curve",
              blurb: "Above 1 exaggerates the brightest stars",
              min: 0.4, max: 2.6, log: false, group: "Stars"),
        Field(key: "starScale", path: \.starScale, title: "Star brightness",
              blurb: "Overall level, applied after the curve",
              min: 0.02, max: 40, log: true, group: "Stars"),
        Field(key: "starCeiling", path: \.starCeiling, title: "Brightness ceiling",
              blurb: "Clipping the top of the range makes haze",
              min: 20, max: 1_000_000, log: true, group: "Stars"),
        Field(key: "fluxScale", path: \.fluxScale, title: "Core concentration",
              blurb: "Light packed into the core, not the wings",
              min: 0.01, max: 4, log: true, group: "Stars"),
        Field(key: "sizeBase", path: \.sizeBase, title: "Smallest disc",
              blurb: "Radius of the faintest star, in pixels",
              min: 0.2, max: 3, log: false, group: "Stars"),
        Field(key: "sizeSlope", path: \.sizeSlope, title: "Disc growth",
              blurb: "How fast discs grow with brightness",
              min: 0.05, max: 2, log: false, group: "Stars"),
        Field(key: "sizeReach", path: \.sizeReach, title: "Exposure swell",
              blurb: "Disc growth per doubling of seconds",
              min: 0, max: 0.8, log: false, group: "Stars"),
        Field(key: "spikeOnset", path: \.spikeOnset, title: "Spikes start",
              blurb: "Flux where diffraction spikes appear",
              min: 1, max: 20_000, log: true, group: "Stars"),
        Field(key: "spikeFull", path: \.spikeFull, title: "Spikes full",
              blurb: "Flux where spikes are fully drawn",
              min: 2, max: 60_000, log: true, group: "Stars"),

        Field(key: "bleedScale", path: \.bleedScale, title: "Bleed",
              blurb: "Glow spilling out of bright cores",
              min: 0, max: 5, log: false, group: "Sky & sensor"),
        Field(key: "grainScale", path: \.grainScale, title: "Grain",
              blurb: "Sensor noise",
              min: 0, max: 5, log: false, group: "Sky & sensor"),
        Field(key: "airglowScale", path: \.airglowScale, title: "Airglow",
              blurb: "The air's own faint light",
              min: 0, max: 5, log: false, group: "Sky & sensor"),
        Field(key: "dustScale", path: \.dustScale, title: "Dust lane",
              blurb: "Darkness of the lane through the galaxy",
              min: 0, max: 3, log: false, group: "Sky & sensor"),
        Field(key: "meteorScale", path: \.meteorScale, title: "Meteors",
              blurb: "Brightness of a passing streak",
              min: 0, max: 5, log: false, group: "Sky & sensor"),
        Field(key: "previewFloor", path: \.previewFloor, title: "Viewfinder boost",
              blurb: "How much brighter the live view is than the photo",
              min: 0.2, max: 12, log: false, group: "Sky & sensor"),

        Field(key: "sunDiscScale", path: \.sunDiscScale, title: "Star surface",
              blurb: "Radiance of the photosphere itself",
              min: 20, max: 200_000, log: true, group: "Daylight"),
        Field(key: "dayScale", path: \.dayScale, title: "Daylight",
              blurb: "Sky brightness under one Earth's sunlight",
              min: 1, max: 20_000, log: true, group: "Daylight"),
    ]
}
