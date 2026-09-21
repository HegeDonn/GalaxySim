import AVFoundation
import Foundation

/// Ambient bed built from real sampled instruments.
///
/// Earlier versions synthesised everything by hand — additive partials, a
/// leaky-integrator noise bed, hand-rolled bells. Getting that to sound
/// *musical* rather than merely correct turned out to be the hard part, and it
/// never did.
///
/// This plays General MIDI instead, through `AVAudioUnitSampler` loaded with
/// the sound bank macOS already ships at
/// `/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls`.
/// No dependency, no download, nothing to bundle — and the pads and bell
/// patches are professionally sampled, so they simply sound good.
///
/// The code is also much smaller: there is no DSP and no real-time thread to
/// respect. Notes are scheduled from an ordinary timer and the sampler handles
/// voicing, envelopes and release tails.
public final class AmbientAudio {

    // MARK: General MIDI programs
    private enum GM {
        static let padHalo: UInt8       = 94   // "Pad 7 (halo)" — the classic space pad
        static let padWarm: UInt8       = 89   // "Pad 2 (warm)"
        static let padSweep: UInt8      = 95   // "Pad 8 (sweep)" — moves under the others
        static let fxCrystal: UInt8     = 98   // "FX 3 (crystal)" — the sparkles
        static let fxAtmosphere: UInt8  = 99   // "FX 4 (atmosphere)"
        static let padChoir: UInt8      = 91   // "Pad 4 (choir)" — the gliding lead
    }

    /// GM percussion key numbers (the channel-10 map).
    private enum Drum {
        static let kick: UInt8      = 36
        static let snare: UInt8     = 38
        static let rim: UInt8       = 37
        static let clap: UInt8      = 39
        static let hatClosed: UInt8 = 42
        static let hatOpen: UInt8   = 46
        static let tomLow: UInt8    = 45
        static let tomMid: UInt8    = 47
        static let tomHigh: UInt8   = 50
        static let crash: UInt8     = 49
        static let ride: UInt8      = 51
    }

    private static let bankURL = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    // MARK: engine
    private let engine = AVAudioEngine()
    private let padA = AVAudioUnitSampler()     // sustained bed
    private let padB = AVAudioUnitSampler()     // slow counter-voice
    private let sparkle = AVAudioUnitSampler()  // points of light
    private let lead = AVAudioUnitSampler()     // the voice that glides
    private let drums = AVAudioUnitSampler()    // flight mode only
    private let reverb = AVAudioUnitReverb()
    private let drumVerb = AVAudioUnitReverb()
    private let mixer = AVAudioMixerNode()

    // MARK: musical state
    /// A minor pentatonic — A C D E G — spread over five octaves.
    ///
    /// The previous table was only A's and E's (roots and fifths), which had no
    /// harmonic colour at all. A true pentatonic contains NO semitone steps, so
    /// no two notes drawn from it can form a minor second or a tritone: any
    /// random combination is consonant by construction. That property is the
    /// whole reason to use it here, where notes are chosen at random.
    private let scale: [Int] = [
        33,                         // A1
        45, 48, 50, 52, 55,         // A2 C3 D3 E3 G3
        57, 60, 62, 64, 67,         // A3 C4 D4 E4 G4
        69, 72, 74, 76, 79,         // A4 C5 D5 E5 G5
        81, 84, 86, 88,             // A5 C6 D6 E6
    ]
    private var heldPadNotes: [Int] = []
    private var rng = SystemRandomNumberGenerator()

    /// 16th note at 124 BPM.
    static let step16: Double = 60.0 / 124.0 / 4.0

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ambient.sequencer", qos: .utility)
    private var tick = 0

    private var intensity: Float = 0
    private var smoothedIntensity: Float = 0
    private var running = false
    private var gliding = false

    /// Drums play only in flight. `flightTick` counts 16ths since take-off so
    /// the kit can build in rather than arriving fully formed.
    private var flightActive = false
    private var flightTick = 0

    public init() {
        engine.attach(padA); engine.attach(padB); engine.attach(lead); engine.attach(drums)
        engine.attach(sparkle); engine.attach(reverb); engine.attach(mixer)

        // Big hall: an ambient pad without a long tail sounds like a keyboard
        // demo, not like space.
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = 72

        let fmt = engine.outputNode.inputFormat(forBus: 0)
        for node in [padA, padB, sparkle, lead] {
            engine.connect(node, to: mixer, format: fmt)
        }

        // Drums bypass the reverb bus entirely and go to a short room of their
        // own. Everything else wants a 72% wet cathedral; a kick through that
        // is a wash with no transient left, which is why the kit was inaudible
        // under the pad even though it was playing.
        engine.attach(drumVerb)
        drumVerb.loadFactoryPreset(.smallRoom)
        drumVerb.wetDryMix = 18
        engine.connect(drums, to: drumVerb, format: fmt)
        engine.connect(drumVerb, to: engine.mainMixerNode, format: fmt)
        engine.connect(mixer, to: reverb, format: fmt)
        engine.connect(reverb, to: engine.mainMixerNode, format: fmt)

        load(padA, program: GM.padHalo)
        load(padB, program: GM.padSweep)
        load(sparkle, program: GM.fxCrystal)
        load(lead, program: GM.padChoir)

        // The percussion bank lives at a different bank MSB; program is
        // ignored there, the key number selects the instrument.
        try? drums.loadSoundBankInstrument(
            at: Self.bankURL, program: 0,
            bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB),
            bankLSB: UInt8(kAUSampler_DefaultBankLSB))

        // Widen the lead's pitch-bend range from the default +/-2 semitones to
        // +/-12, so a glide can travel a whole octave. RPN 0,0 is the standard
        // "pitch bend sensitivity" registered parameter.
        lead.sendController(101, withValue: 0, onChannel: 0)   // RPN MSB
        lead.sendController(100, withValue: 0, onChannel: 0)   // RPN LSB
        lead.sendController(6,   withValue: 12, onChannel: 0)  // semitones
        lead.sendController(38,  withValue: 0, onChannel: 0)   // cents

        // The DLS pads are sampled conservatively and the soft velocities used
        // here sit low in their range, so without real makeup gain the bed
        // renders at about 4% of full scale.
        // Applied through `applyGain` so the sliders and the defaults cannot
        // drift apart.
        for t in Track.allCases { applyGain(t) }
        mixer.outputVolume = 0.9
        engine.mainMixerNode.outputVolume = volume
    }

    private func load(_ s: AVAudioUnitSampler, program: UInt8) {
        try? s.loadSoundBankInstrument(at: Self.bankURL, program: program,
                                       bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                       bankLSB: UInt8(kAUSampler_DefaultBankLSB))
    }

    // MARK: public API

    /// The individually mixable layers.
    public enum Track: String, CaseIterable, Codable {
        case pads, glide, bells, drums

        public var displayName: String {
            switch self {
            case .pads:  return "Pads"
            case .glide: return "Glide"
            case .bells: return "Bells"
            case .drums: return "Drums"
            }
        }
    }

    /// Level per layer, 0...1, where 1 is the tuned default rather than
    /// maximum gain — so the shipped mix is what you get at 1.0 and the
    /// sliders trim from there.
    private var trackLevel: [Track: Float] = [
        .pads: 1, .glide: 1, .bells: 1, .drums: 1,
    ]

    /// Reference gains in dB, the balance arrived at by ear.
    private static let baseGain: [Track: Float] = [
        .pads: 10, .glide: 7, .bells: 8, .drums: 15,
    ]

    public func volume(for track: Track) -> Float { trackLevel[track] ?? 1 }

    public func setVolume(_ v: Float, for track: Track) {
        guard v.isFinite else { return }
        let clamped = min(max(v, 0), 1)
        trackLevel[track] = clamped
        applyGain(track)
    }

    private func applyGain(_ track: Track) {
        let level = trackLevel[track] ?? 1
        let base = Self.baseGain[track] ?? 0
        // Silence at zero; otherwise trim below the reference by up to 40 dB.
        let gain = level <= 0.001 ? Float(-90) : base + 40 * log10(level)
        switch track {
        case .pads:
            padA.overallGain = gain
            padB.overallGain = gain - 4      // keep the counter-voice underneath
        case .glide: lead.overallGain = gain
        case .bells: sparkle.overallGain = gain
        case .drums: drums.overallGain = gain
        }
    }

    public var volume: Float = 0.55 {
        didSet { engine.mainMixerNode.outputVolume = isEnabled ? volume : 0 }
    }

    public var isEnabled: Bool = true {
        didSet { engine.mainMixerNode.outputVolume = isEnabled ? volume : 0 }
    }

    /// 0 = galaxies far apart and calm, 1 = violent close passage.
    public func setIntensity(_ v: Float) {
        guard v.isFinite else { return }
        intensity = min(max(v, 0), 1)
    }

    /// Drums in, drums out. Called when the ship is entered or left.
    ///
    /// The kit is deliberately absent from the ambient bed: arriving as a
    /// separate layer is what makes climbing into the ship feel like an event
    /// rather than a camera change.
    public func setFlightMode(_ on: Bool) {
        guard on != flightActive else { return }
        flightActive = on
        flightTick = 0
        if on {
            // downbeat marker, so the groove starts ON something
            hit(Drum.crash, 74)
        }
    }

    /// Kept for API compatibility. This once drove a brown-noise bed, which
    /// was unpleasant to sit with; it no longer generates anything.
    public func setDispersal(_ dispersal: Float) {}

    public func start() {
        guard !running else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("AmbientAudio: %@", error.localizedDescription)
            return
        }
        running = true
        engine.mainMixerNode.outputVolume = isEnabled ? volume : 0
        startSequencer()
    }

    public func stop() {
        guard running else { return }
        running = false
        timer?.cancel(); timer = nil
        allNotesOff()
        engine.stop()
    }

    // MARK: sequencing

    private func startSequencer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 700 ms grid. Everything here moves slowly; this only has to be fine
        // enough that sparkles do not sound quantised.
        // A 16th note at 124 BPM. The pad events below are gated to wide
        // multiples of this, so raising the resolution costs nothing musically
        // but gives the drums a grid fine enough to swing on.
        t.schedule(deadline: .now() + 0.2, repeating: AmbientAudio.step16)
        t.setEventHandler { [weak self] in self?.step() }
        t.resume()
        timer = t
    }

    private func step() {
        guard running else { return }

        // Ease the intensity so a sudden jump never lurches the music.
        smoothedIntensity += (intensity - smoothedIntensity) * 0.011
        let k = smoothedIntensity
        tick += 1

        // ---- drums, flight only
        if flightActive {
            playDrums(step: flightTick, intensity: k)
            flightTick += 1
        }

        // ---- pad: re-voice a slow chord every ~11 s
        if tick % 96 == 1 {
            for n in heldPadNotes { padA.stopNote(UInt8(n), onChannel: 0) }
            heldPadNotes.removeAll(keepingCapacity: true)

            // Intensity raises the REGISTER, by choosing higher scale degrees —
            // it must never transpose chromatically. The old code added 2-6
            // semitones to this voice only, while the counter-voice and the
            // sparkles stayed put, so at higher intensity the pad sat a minor
            // second above everything else. That was the dissonance.
            let lowest = 1 + Int(k * 4)
            let rootIdx = min(lowest, scale.count - 6)
            var chosen = [scale[rootIdx]]
            let upperCount = 2 + Int(k * 2)
            for _ in 0..<upperCount {
                let i = Int.random(in: (rootIdx + 2)..<scale.count, using: &rng)
                let n = scale[i]
                if chosen.allSatisfy({ Self.spacingIsClean($0, n) }) {
                    chosen.append(n)
                }
            }
            for n in chosen {
                // soft velocities: pads should swell, not strike
                let vel = UInt8(60 + Int(k * 30) + Int.random(in: 0...10, using: &rng))
                padA.startNote(UInt8(min(n, 108)), withVelocity: vel, onChannel: 0)
            }
            heldPadNotes = chosen
        }

        // ---- counter-voice: a single slow note drifting underneath
        if tick % 144 == 29 {
            let n = scale[Int.random(in: 1...6, using: &rng)]
            padB.startNote(UInt8(n), withVelocity: UInt8(50 + Int(k * 22)), onChannel: 0)
            later(9) { [weak self] in self?.padB.stopNote(UInt8(n), onChannel: 0) }
        }

        // ---- gliding voice: sometimes, not always
        if tick % 56 == 24 && Double.random(in: 0...1, using: &rng) < 0.45 {
            glideNote(intensity: k)
        }

        // ---- sparkles: sparse points of light, denser as things get violent
        let chance = 0.10 + Double(k) * 0.40
        if tick % 6 == 0 && Double.random(in: 0...1, using: &rng) < chance {
            // No +12 here: the table already spans the high octaves, and the
            // old transposition could push a note out of the scale's top.
            let n = scale[Int.random(in: 11..<scale.count, using: &rng)]
            let vel = UInt8(44 + Int(k * 34) + Int.random(in: 0...16, using: &rng))
            sparkle.startNote(UInt8(n), withVelocity: vel, onChannel: 0)
            later(2.2) { [weak self] in self?.sparkle.stopNote(UInt8(n), onChannel: 0) }
        }
    }

    /// Occasionally sing a note that SLIDES to another note of the scale.
    ///
    /// Done with MIDI pitch bend on a dedicated voice rather than by
    /// retriggering: bending keeps one continuous tone, which is what makes it
    /// read as a slide rather than as two notes. The voice is its own sampler
    /// so the bend cannot drag the sustained pad off pitch with it.
    /// Whether two chord tones may sound together.
    ///
    /// The pentatonic already rules out minor seconds and tritones, but a
    /// major second low down is still rough: the two partials fall inside one
    /// critical band and beat against each other. Orchestration handles this
    /// by spreading voices at the bottom and letting them close up higher, and
    /// that is exactly what this enforces.
    private static func spacingIsClean(_ a: Int, _ b: Int) -> Bool {
        let gap = abs(a - b)
        if gap == 0 { return false }
        let lower = min(a, b)
        if lower < 52 { return gap >= 7 }   // below E3: a fifth apart or more
        if lower < 60 { return gap >= 5 }   // below C4: a fourth
        if lower < 72 { return gap >= 3 }   // below C5: a minor third
        return gap >= 2                     // up top anything in-scale is fine
    }

    private func glideNote(intensity k: Float) {
        guard !gliding else { return }

        // Pick two scale degrees within an octave of each other, so the bend
        // stays inside the +/-12 semitone range configured above.
        let fromIdx = Int.random(in: 5...13, using: &rng)
        var toIdx = fromIdx + Int.random(in: -4...4, using: &rng)
        toIdx = min(max(toIdx, 1), scale.count - 1)
        let from = scale[fromIdx]
        let semis = Float(scale[toIdx] - from)
        guard abs(semis) >= 1, abs(semis) <= 12 else { return }

        gliding = true
        let vel = UInt8(46 + Int(k * 24) + Int.random(in: 0...8, using: &rng))
        lead.startNote(UInt8(from), withVelocity: vel, onChannel: 0)

        // Ease in and out. A linear ramp sounds mechanical; a smoothstep
        // leaves and arrives gently, like a finger on a fretless string.
        let steps = 48
        let travel = Double.random(in: 1.6...3.2, using: &rng)
        let hold = Double.random(in: 0.8...2.0, using: &rng)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            later(travel * t) { [weak self] in
                guard let self else { return }
                let bend = 8192 + Int(Double(semis) / 12.0 * 8191.0 * eased)
                self.lead.sendPitchBend(UInt16(min(max(bend, 0), 16383)), onChannel: 0)
            }
        }
        later(travel + hold) { [weak self] in
            guard let self else { return }
            self.lead.stopNote(UInt8(from), onChannel: 0)
            // recentre for the next glide
            self.lead.sendPitchBend(8192, onChannel: 0)
            self.gliding = false
        }
    }

    private func hit(_ key: UInt8, _ velocity: UInt8) {
        drums.startNote(key, withVelocity: velocity, onChannel: 0)
        // Percussion samples are one-shots; the note-off only releases the
        // voice, so a short fixed gate is plenty.
        later(0.12) { [weak self] in self?.drums.stopNote(key, onChannel: 0) }
    }

    /// A driving, syncopated pattern in the C64 tradition — straight 16th
    /// hats with the kick pushed off the beat, which is where the groove
    /// comes from. It enters in layers over the first four bars so take-off
    /// has a lift to it.
    private func playDrums(step: Int, intensity k: Float) {
        let bar = step / 16
        let s16 = step % 16
        let beat = s16 % 4 == 0

        // --- layer 1 (immediately): hats, straight 16ths with accents
        if bar >= 0 {
            let accent = beat
            if s16 % 2 == 0 || bar >= 2 {
                hit(Drum.hatClosed, accent ? 82 : UInt8(46 + Int(k * 14)))
            }
            // open hat on the "and" of 4, the classic push into the next bar
            if s16 == 14 { hit(Drum.hatOpen, 74) }
        }

        // --- layer 2 (bar 1): the syncopated kick
        if bar >= 1 {
            // 1 . . .  . . x .  . . x .  . . . .   -> pushed off the beat
            if [0, 6, 10].contains(s16) { hit(Drum.kick, 104) }
            if bar >= 3 && s16 == 3 { hit(Drum.kick, 88) }
        }

        // --- layer 3 (bar 2): backbeat
        if bar >= 2 {
            if s16 == 4 || s16 == 12 { hit(Drum.snare, 100) }
            if bar >= 4 && s16 == 11 { hit(Drum.rim, 62) }
        }

        // --- layer 4 (bar 4): ride, and a tom fill every eight bars
        if bar >= 4 {
            if s16 % 4 == 2 { hit(Drum.ride, UInt8(52 + Int(k * 18))) }
            if bar % 8 == 7 {
                switch s16 {
                case 8:  hit(Drum.tomHigh, 96)
                case 10: hit(Drum.tomMid, 98)
                case 12: hit(Drum.tomLow, 102)
                case 14: hit(Drum.tomLow, 106)
                case 15: hit(Drum.crash, 92)
                default: break
                }
            }
        }
    }

    private func allNotesOff() {
        for n in heldPadNotes { padA.stopNote(UInt8(n), onChannel: 0) }
        heldPadNotes.removeAll()
        for s in [padA, padB, sparkle, lead, drums] {
            // CC 123 = all notes off
            s.sendController(123, withValue: 0, onChannel: 0)
        }
        lead.sendPitchBend(8192, onChannel: 0)
        gliding = false
    }

    // MARK: offline rendering, for the test harness

    /// Render `seconds` of audio to a WAV, driving the sequencer by hand.
    ///
    /// The live path is timer-driven, so plain manual rendering would capture
    /// silence between ticks. This advances the same `step()` on the offline
    /// clock instead, which makes the render deterministic as a bonus.
    internal func _renderOffline(seconds: Double, to path: String,
                                 intensityRamp: Bool) throws {
        let sr = 48000.0
        let engine = try _configureForOfflineRendering(sampleRate: sr,
                                                      maximumFrameCount: 4096)
        try engine.start()
        running = true

        let fmt = engine.manualRenderingFormat
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096)!
        let out = try AVAudioFile(forWriting: URL(fileURLWithPath: path),
                                  settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                             AVSampleRateKey: sr,
                                             AVNumberOfChannelsKey: 2,
                                             AVLinearPCMBitDepthKey: 24,
                                             AVLinearPCMIsFloatKey: false])

        let total = AVAudioFramePosition(sr * seconds)
        let framesPerStep = AVAudioFramePosition(sr * AmbientAudio.step16)
        var pos: AVAudioFramePosition = 0
        var nextStep: AVAudioFramePosition = 0
        var pending: [(AVAudioFramePosition, () -> Void)] = []

        offlineDefer = { [weak self] delay, work in
            guard self != nil else { return }
            pending.append((pos + AVAudioFramePosition(sr * delay), work))
        }

        while pos < total {
            if pos >= nextStep {
                if intensityRamp { setIntensity(Float(Double(pos) / Double(total))) }
                step()
                nextStep += framesPerStep
            }
            var i = 0
            while i < pending.count {
                if pending[i].0 <= pos { pending[i].1(); pending.remove(at: i) }
                else { i += 1 }
            }
            let n = AVAudioFrameCount(min(4096, total - pos))
            if try engine.renderOffline(n, to: buf) == .success {
                try out.write(from: buf)
            }
            pos += AVAudioFramePosition(n)
        }
        offlineDefer = nil
        running = false
        engine.stop()
        engine.disableManualRenderingMode()
    }

    /// When set, note-offs are scheduled on the offline clock instead of the
    /// wall clock, so a render is not at the mercy of real time.
    private var offlineDefer: ((Double, @escaping () -> Void) -> Void)?

    private func later(_ delay: Double, _ work: @escaping () -> Void) {
        if let d = offlineDefer { d(delay, work) }
        else { queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    internal func _configureForOfflineRendering(sampleRate: Double,
                                               maximumFrameCount: AVAudioFrameCount) throws -> AVAudioEngine {
        engine.stop()
        if engine.isInManualRenderingMode { engine.disableManualRenderingMode() }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw NSError(domain: "AmbientAudio", code: 1)
        }
        try engine.enableManualRenderingMode(.offline, format: fmt,
                                             maximumFrameCount: maximumFrameCount)
        return engine
    }
}
