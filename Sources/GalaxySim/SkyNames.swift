import Foundation

/// What to call a star, and what to call a galaxy.
///
/// Every star in here used to be "Lumen 190001", which is not what the sky is
/// like. Real star names come from three different centuries and it shows:
///
///   * The bright ones have PROPER NAMES, most of them Arabic, a few Greek or
///     Latin, given by people who could see them from a rooftop and needed to
///     say which one they meant. Rigel, Betelgeuse, Vega, Altair. Nobody
///     numbers a star you can see.
///   * The next ones down have BAYER LETTERS — a Greek letter and the
///     constellation they sit in, roughly in order of brightness within it.
///     Beta Lyrae. That system is four hundred years old and stops working
///     around the limit of the naked eye, because that is where Bayer stopped.
///   * Everything fainter has a CATALOGUE NUMBER, because there are too many
///     to name and nobody has ever seen most of them: HD 190001, Gliese 581,
///     LHS 1140. The overwhelming majority of stars are in this class, and the
///     overwhelming majority of stars are red dwarfs, so a faint red star
///     reading "Wolf 2209" is not a worse name than "Vega" — it is the
///     correct kind of name, and the reason for that is worth noticing.
///   * A handful of faint stars carry a person's name instead — Barnard's
///     Star, Kapteyn's Star, van Maanen's Star. Those are the ones that moved:
///     each was picked out because it shifted against the background, which
///     means it is close, and being close is the only reason anyone looked.
///
/// So the naming here is drawn from the star's own physics: brilliant stars
/// get names, dim ones get numbers, and a few of the dim ones get the name of
/// whoever would have noticed them. Some of the names are real and some are
/// invented, which is the honest way round for an imagined galaxy — the card
/// says as much.
///
/// And once in a while a star comes out called Kevin. Somebody named a
/// research ship Boaty McBoatface; the sky can take it.
enum SkyNames {

    // MARK: - Stars

    /// What the sky calls this star. Deterministic in the particle's identity,
    /// so the same star has the same name every time it is looked at, across
    /// runs and across restarts.
    static func star(index: Int, population: UInt32, solarMass: Double,
                     temperature: Double, isGiant: Bool, isRemnant: Bool) -> String {
        // A stream of its own. Seeding this from the same number the star's
        // physics came from would tie the two together -- every G star in the
        // galaxy drawing the same name -- so the mix is different here.
        var rng = GalaxyModels.RNG(seed: UInt64(bitPattern: Int64(index)) &* 0xD6E8_FEB8_6659_FD93
            &+ UInt64(population) &* 0x2545_F491_4F6C_DD1D &+ 0x5EED)

        // Which register the star belongs in. This is the whole idea: it is
        // decided by what the star IS, the way it is in the real sky.
        let tier: Tier
        if isRemnant { tier = .remnant }
        else if isGiant || solarMass >= 2 || temperature >= 7_500 { tier = .brilliant }
        else if solarMass >= 0.85 { tier = .solar }
        else { tier = .faint }

        // One star in seventy or so is a joke, and the joke fits the star:
        // the patient little red ones get Slow Cooker, the short-lived blue
        // monsters get Big Trouble. A child who finds one has found
        // something, which is the point of putting them there.
        if rng.uniform() < 0.014 { return pick(fun(for: tier), &rng) }

        switch tier {
        case .brilliant:
            // Bright enough to have been named by somebody. A quarter of them
            // still fall to a catalogue, because plenty of bright stars do.
            let r = rng.uniform()
            if r < 0.45 { return pick(properReal, &rng) }
            if r < 0.72 { return pick(properInvented, &rng) }
            if r < 0.90 { return bayer(&rng) }
            return catalogue(bright: true, &rng)
        case .solar:
            let r = rng.uniform()
            if r < 0.18 { return pick(properReal + properInvented, &rng) }
            if r < 0.34 { return bayer(&rng) }
            return catalogue(bright: true, &rng)
        case .faint:
            let r = rng.uniform()
            if r < 0.05 { return pick(properInvented, &rng) }
            if r < 0.12 { return pick(discoverers, &rng) + "'s Star" }
            return catalogue(bright: false, &rng)
        case .remnant:
            let r = rng.uniform()
            if r < 0.10 { return pick(properInvented, &rng) }
            if r < 0.20 { return pick(discoverers, &rng) + "'s Star" }
            return remnantCatalogue(&rng)
        }
    }

    private enum Tier { case brilliant, solar, faint, remnant }

    /// Real proper names, all of them stars you can walk outside and see.
    private static let properReal = [
        "Rigel", "Bellatrix", "Alnitak", "Alnilam", "Mintaka", "Saiph", "Meissa",
        "Vega", "Altair", "Deneb", "Achernar", "Canopus", "Regulus", "Spica",
        "Antares", "Arcturus", "Capella", "Procyon", "Aldebaran", "Fomalhaut",
        "Algol", "Elnath", "Alphard", "Adhara", "Wezen", "Mirzam", "Aludra",
        "Naos", "Avior", "Shaula", "Sargas", "Atria", "Hadar", "Menkent",
        "Mirach", "Almach", "Alpheratz", "Schedar", "Caph", "Ruchbah", "Mizar",
        "Alcor", "Alkaid", "Dubhe", "Merak", "Phecda", "Megrez", "Thuban",
        "Kochab", "Pherkad", "Rasalhague", "Rastaban", "Eltanin", "Vindemiatrix",
        "Zubeneschamali", "Unukalhai", "Sabik", "Tarazed", "Albireo", "Sadr",
        "Gienah", "Algieba", "Denebola", "Zosma", "Enif", "Markab", "Scheat",
        "Homam", "Sadalsuud", "Sadalmelik", "Skat", "Nunki", "Kaus Australis",
        "Alnasl", "Ascella", "Polis", "Izar", "Muphrid", "Seginus", "Nekkar",
        "Cor Caroli", "Chara", "Diadem", "Alderamin", "Alfirk", "Errai",
        "Matar", "Biham", "Sheratan", "Hamal", "Mesarthim", "Botein",
    ]

    /// Invented, in the same registers the real ones come from: the long
    /// Arabic-descended names, the short Latin ones, a few that simply sound
    /// like something you would point at.
    private static let properInvented = [
        "Ashenar", "Velorix", "Thurayn", "Menkaris", "Zubeneth", "Sabikar",
        "Orithane", "Vesperin", "Kaurel", "Sindrala", "Yildiran", "Aurelith",
        "Calibrand", "Tessarin", "Maravel", "Ninsura", "Halvane", "Sorrelex",
        "Amberlin", "Solane", "Helion", "Caldera Prime", "Nyxalar", "Quillon",
        "Emberis", "Ostrava", "Tanaquil", "Verrow", "Ilmaris", "Sepharin",
        "Crandal", "Othane", "Bellune", "Cirrathan", "Dunmire", "Espera",
        "Farrowen", "Galathi", "Hesperine", "Ithavel", "Jorvane", "Kestrine",
        "Lumithar", "Morrowin", "Nautilon", "Ophira", "Pallaris", "Quenvar",
        "Rosalind's Lamp", "Sableth", "Torvane", "Umbriel's Eye", "Vantoria",
        "Wrenneth", "Xanthera", "Yarrowen", "Zephyrane", "Ardashir", "Belmara",
    ]

    /// People whose names ended up on faint, fast-moving stars. The real
    /// convention: these are the stars somebody noticed shifting.
    private static let discoverers = [
        "Barnard", "Kapteyn", "Luyten", "van Maanen", "Teegarden", "Innes",
        "Groombridge", "Lalande", "Piazzi", "Bradley", "Struve", "Herschel",
        "Cannon", "Leavitt", "Fleming", "Maury", "Payne", "Rubin", "Burnell",
        "Hoshino", "Okoye", "Varga", "Nakamura", "Osei", "Lindqvist", "Marek",
    ]

    /// Greek letters and constellations, the four-hundred-year-old middle
    /// register. The constellations are real: this is an imagined galaxy, but
    /// a child who looks up "Lyra" should find something.
    private static let greek = [
        "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta",
        "Iota", "Kappa", "Lambda", "Mu", "Nu", "Xi", "Omicron", "Pi", "Rho",
        "Sigma", "Tau", "Upsilon", "Phi", "Chi", "Psi", "Omega",
    ]
    private static let constellations = [
        "Lyrae", "Cygni", "Aquilae", "Orionis", "Carinae", "Velorum", "Draconis",
        "Ursae Majoris", "Ursae Minoris", "Cassiopeiae", "Andromedae", "Persei",
        "Aurigae", "Geminorum", "Leonis", "Virginis", "Librae", "Scorpii",
        "Sagittarii", "Capricorni", "Aquarii", "Piscium", "Arietis", "Tauri",
        "Cancri", "Bootis", "Coronae Borealis", "Herculis", "Ophiuchi", "Serpentis",
        "Pegasi", "Ceti", "Eridani", "Columbae", "Puppis", "Hydrae", "Corvi",
        "Centauri", "Lupi", "Arae", "Pavonis", "Tucanae", "Gruis", "Phoenicis",
    ]

    private static func bayer(_ rng: inout GalaxyModels.RNG) -> String {
        pick(greek, &rng) + " " + pick(constellations, &rng)
    }

    /// A catalogue number in [1, span).
    private static func num(_ span: Int, _ rng: inout GalaxyModels.RNG) -> Int {
        1 + Int(Double(rng.uniform()) * Double(span - 1))
    }

    /// Catalogue designations. The prefix and the size of the number are not
    /// decoration: HD is a survey of bright stars and runs to six digits,
    /// Gliese is a list of near neighbours and runs to three, Kepler and TOI
    /// number the stars somebody went looking at for planets. Picking the
    /// prefix by how bright the star is keeps all of that true.
    private static func catalogue(bright: Bool, _ rng: inout GalaxyModels.RNG) -> String {
        if bright {
            switch Int(Double(rng.uniform()) * 5) {
            case 0: return "HD \(num(359_000, &rng))"
            case 1: return "HIP \(num(118_000, &rng))"
            case 2: return "HR \(num(9_100, &rng))"
            case 3: return "Kepler-\(num(1_800, &rng))"
            default: return "TOI-\(num(6_400, &rng))"
            }
        }
        switch Int(Double(rng.uniform()) * 7) {
        case 0: return "Gliese \(num(900, &rng))"
        case 1: return "GJ \(num(1_290, &rng))"
        case 2: return "Wolf \(num(1_600, &rng))"
        case 3: return "Ross \(num(900, &rng))"
        case 4: return "LHS \(num(3_800, &rng))"
        case 5: return "LP \(num(900, &rng))-\(num(600, &rng))"
        default: return "2MASS J" + position(&rng)
        }
    }

    /// Right ascension and declination, written the way a survey writes them:
    /// hours and minutes of RA, then signed degrees and arcminutes. This is
    /// why the faint stars' names look like coordinates -- they are.
    private static func position(_ rng: inout GalaxyModels.RNG) -> String {
        let hours = Int(Double(rng.uniform()) * 24)
        let minutes = Int(Double(rng.uniform()) * 60)
        let sign = rng.uniform() < 0.5 ? "+" : "-"
        let degrees = Int(Double(rng.uniform()) * 90)
        let arcmin = Int(Double(rng.uniform()) * 60)
        return String(format: "%02d%02d%@%02d%02d", hours, minutes, sign, degrees, arcmin)
    }

    /// White dwarfs are catalogued by where they are in the sky, which is why
    /// a real one is called WD 1856+534 and not anything nicer.
    private static func remnantCatalogue(_ rng: inout GalaxyModels.RNG) -> String {
        "WD " + position(&rng)
    }

    /// The jokes, matched to the star. A red dwarf that will still be burning
    /// when the galaxies have finished merging really is a slow cooker.
    private static func fun(for tier: Tier) -> [String] {
        switch tier {
        case .brilliant:
            return ["Big Trouble", "The Blowtorch", "Fireworks", "Showoff",
                    "The Lighthouse", "Loud Blue Gary", "Absolute Unit"]
        case .solar:
            return ["Almost Home", "Second Breakfast", "Kevin", "Sunny Jim",
                    "Not Our Sun", "Toasty", "Perfectly Ordinary Steve"]
        case .faint:
            return ["Slow Cooker", "Nightlight", "The Patient One", "Ember",
                    "Old Smoulder", "Tiny", "Still Going", "Bob"]
        case .remnant:
            return ["Cinders", "The Cooling Coal", "Last Ember", "Retired",
                    "Used To Be Somebody"]
        }
    }

    // MARK: - Galaxies

    /// What to call a galaxy nobody has ever catalogued, because it does not
    /// exist. Real galaxies mostly have numbers, a famous handful have
    /// nicknames, and the nicknames are always for what they look like -- the
    /// Pinwheel, the Sombrero, the Cigar. So the nicknames here follow the
    /// shape too: a spiral gets a wheel, an elliptical gets an ember, an
    /// irregular gets something that has clearly been dropped.
    static func galaxy(seed: UInt64, index: Int, type: GalaxyType) -> String {
        var rng = GalaxyModels.RNG(seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(index) &* 0x2545_F491 &+ 0xDA1A_5EED)
        let r = Double(rng.uniform())
        if r < 0.012 { return pick(["Galaxy McGalaxyface", "The Big Smudge",
                                    "Thousand Billion Suns Ltd"], &rng) }
        if r < 0.45 { return pick(nicknames(for: type), &rng) }
        switch Int(Double(rng.uniform()) * 5) {
        case 0: return "NGC \(1 + Int(Double(rng.uniform()) * 7_839))"
        case 1: return "IC \(1 + Int(Double(rng.uniform()) * 5_385))"
        case 2: return "UGC \(1 + Int(Double(rng.uniform()) * 12_920))"
        case 3: return "Messier \(1 + Int(Double(rng.uniform()) * 109))"
        default: return "PGC \(1 + Int(Double(rng.uniform()) * 73_000))"
        }
    }

    private static func nicknames(for type: GalaxyType) -> [String] {
        switch type {
        case .sa, .sb, .sc, .sbb, .sbc:
            return ["The Silverwheel", "The Firewheel", "The Spindrift",
                    "The Long Arm", "The Catherine Wheel", "The Slow Whirl",
                    "The Hourglass", "The Scatterwheel", "Starfall"]
        case .e0, .e5, .s0:
            return ["The Ember", "Old Gold", "The Quiet Giant", "The Cinder",
                    "The Amber Ball", "The Sleeper", "The Long Afternoon"]
        case .irr, .dwarf:
            return ["The Splash", "The Tadpole", "The Sparkler", "Scattergood",
                    "The Loose Change", "The Crumb", "The Stray"]
        case .ring:
            return ["The Bullseye", "The Ripple", "The Smoke Ring", "The Quoit"]
        }
    }

    // MARK: - Drawing from a list

    private static func pick(_ list: [String], _ rng: inout GalaxyModels.RNG) -> String {
        guard !list.isEmpty else { return "Unnamed" }
        return list[min(list.count - 1, Int(Double(rng.uniform()) * Double(list.count)))]
    }
}
