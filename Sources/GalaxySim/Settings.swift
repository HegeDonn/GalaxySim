import Foundation

/// Everything the engineer panel can change, persisted between launches.
///
/// Deliberately excludes anything the kids bar owns — which encounter is
/// loaded, which galaxy is armed, the tilt, play/pause. Those are what you are
/// *doing*, and restoring them on launch would be surprising. What is saved is
/// how the instrument is *configured*: look, solver, budget, mix.
struct Settings: Codable, Equatable {

    // --- look
    var exposure: Float = 1.0
    var psfStrength: Float = 1.0
    var starSize: Float = 1.05
    var filmK: Float = 1.0
    var filmN: Float = 0.85
    var halation: Float = 0.06
    var saturation: Float = 1.55
    var webStrength: Float = 0.00035
    var showBackgroundStars: Bool = true
    var brightness: Float = 4.0

    // --- physics
    var solverRaw: UInt32 = SolverMode.restricted.rawValue
    var particleBudget: Int = 400_000
    var theta: Float = 0.6
    var timeStep: Float = 0.5

    // --- camera
    var autoOrbit: Bool = true

    // --- audio
    var audioEnabled: Bool = true
    var masterVolume: Float = 0.55
    var trackVolumes: [String: Float] = [:]

    var solver: SolverMode {
        get { SolverMode(rawValue: solverRaw) ?? .restricted }
        set { solverRaw = newValue.rawValue }
    }

    // MARK: persistence

    private static let key = "GalaxySim.settings.v1"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: key) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            // A stored blob from an older layout should not stop the app
            // launching; fall back to defaults and let the next save replace it.
            NSLog("Settings: could not read saved config (%@) — using defaults",
                  error.localizedDescription)
            return Settings()
        }
    }

    @discardableResult
    func save() -> Bool {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: Self.key)
            return true
        } catch {
            NSLog("Settings: save failed (%@)", error.localizedDescription)
            return false
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// Where the file actually lives, for the "saved" confirmation text.
    static var storeDescription: String {
        (Bundle.main.bundleIdentifier ?? "GalaxySim") + " preferences"
    }
}
