import AppKit
import simd

/// A representative educational star, not an inferred age or the gravitational
/// mass of a galaxy tracer. Seeded by persistent particle index/population.
/// NASA science.nasa.gov/universe/stars/types/ and ESA Gaia HR diagram underpin
/// the evolutionary categories; values below are deliberately approximate.
struct StellarProfile {
    let name: String
    let classification: String
    let temperature: Double
    let solarMass: Double
    let solarRadius: Double
    let solarLuminosity: Double
    let ageDescription: String
    let lifespanDescription: String
    let remainingLifeDescription: String
    let fate: String
    let color: NSColor
    let isRemnant: Bool
    /// The galaxy this star belongs to, when the caller knows it.
    let galaxyName: String
    var planetSeed: UInt32 = 0

    static func make(index: Int, population: UInt32, galaxy: String = "") -> StellarProfile {
        var rng = GalaxyModels.RNG(seed: UInt64(index) &+ UInt64(population) * 0x9e3779b9)
        let u = Double(rng.uniform())
        let kind = population & 255
        let mass: Double, radius: Double, temp: Double, lifetime: Double
        let classification: String, fate: String
        let remnant = kind == ParticleKind.halo.rawValue && u < 0.20
        if remnant {
            mass = 0.6; radius = 0.012; temp = 9000 + Double(rng.uniform()) * 6000
            lifetime = 0
            classification = "White dwarf · stellar remnant"
            fate = "No core fusion remains. This Earth-sized remnant cools for billions of years. A close companion could change its fate."
        } else if kind == ParticleKind.bulge.rawValue && u < 0.25 {
            mass = 1.1; radius = 25 + Double(rng.uniform()) * 30; temp = 3900
            lifetime = 8e9
            classification = "K-type red giant"
            fate = "It will shed its outer layers and leave a white dwarf. The expanding gas may glow as a planetary nebula."
        } else {
            let spectral: String
            switch kind {
            case ParticleKind.youngDisk.rawValue:
                if u < 0.08 { spectral = "O"; mass = 25; radius = 9; temp = 35000; lifetime = 5e6 }
                else if u < 0.7 { spectral = "B"; mass = 9; radius = 4.5; temp = 21000; lifetime = 25e6 }
                else { spectral = "A"; mass = 2; radius = 1.8; temp = 9000; lifetime = 1e9 }
            case ParticleKind.bulge.rawValue, ParticleKind.halo.rawValue:
                if u < 0.6 { spectral = "M"; mass = 0.18; radius = 0.23; temp = 3200; lifetime = 3e11 }
                else { spectral = "K"; mass = 0.7; radius = 0.7; temp = 4500; lifetime = 3e10 }
            default:
                if u < 0.25 { spectral = "K"; mass = 0.7; radius = 0.7; temp = 4500; lifetime = 3e10 }
                else if u < 0.85 { spectral = "G"; mass = 1; radius = 1; temp = 5772; lifetime = 1e10 }
                else { spectral = "F"; mass = 1.3; radius = 1.35; temp = 6700; lifetime = 4e9 }
            }
            classification = "\(spectral)-type · main sequence"
            if mass >= 8 {
                fate = mass > 20
                    ? "After a short, brilliant life, core collapse may leave a black hole, sometimes following a supernova. Mass loss and companions matter."
                    : "After becoming a supergiant, it is expected to undergo a core-collapse supernova, usually leaving a neutron star."
            } else if mass < 0.3 {
                fate = "It can shine much longer than the universe has existed. Models predict an eventual helium white dwarf; none has had time to reach that stage."
            } else {
                fate = "It will become a red giant, shed its outer layers and leave a cooling white dwarf. It will not explode as a core-collapse supernova."
            }
        }
        let giant = classification.contains("giant")
        let age = giant ? 7.8e9 : min(13e9, lifetime * (0.12 + Double(rng.uniform()) * 0.68))
        let rgb = Relativity.blackbodyRGB(Float(temp))
        let peak = max(rgb.x, max(rgb.y, rgb.z))
        let c = rgb / max(peak, 0.001)
        // Named the way the sky names things -- see SkyNames -- so a brilliant
        // star gets a proper name and a red dwarf gets a catalogue number.
        let name = SkyNames.star(index: index, population: population, solarMass: mass,
                                 temperature: temp, isGiant: giant, isRemnant: remnant)
        return StellarProfile(name: name, classification: classification,
            temperature: temp, solarMass: mass, solarRadius: radius,
            solarLuminosity: radius * radius * pow(temp / 5772, 4),
            // Plain sentences, not field labels: the card is read by children as
            // often as by anyone else, and "Example fusion time left:" is not a
            // sentence anybody says out loud. The caveat that these are
            // illustrative values lives once, at the foot of the card.
            ageDescription: remnant ? "It has been cooling quietly for about half a billion years." : "It is about \(years(age)) old.",
            lifespanDescription: remnant ? "It will keep fading for billions of years to come." : "Stars like this one shine for about \(years(lifetime)) in all.",
            remainingLifeDescription: remnant ? "Its fire went out long ago — what you see is leftover heat." : "It still has roughly \(years(giant ? 2e8 : lifetime - age)) of fuel left.",
            fate: fate, color: NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1),
            isRemnant: remnant, galaxyName: galaxy, planetSeed: UInt32(truncatingIfNeeded: index) &* 2654435761 &+ population)
    }

    private static func years(_ value: Double) -> String {
        if value >= 1e9 { return String(format: "%.1f billion years", value / 1e9) }
        return String(format: "%.0f million years", value / 1e6)
    }
}
