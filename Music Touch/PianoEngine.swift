import AVFoundation

/// A soft, reverberant piano built from the system General MIDI sound bank.
///
/// Each note zone has its own sampler so a zone can fade out on its own while
/// other zones keep ringing (the sampler's expression controller is global per instance).
@MainActor
final class PianoEngine {
    /// Total time a struck note rings: it holds for the first part, then fades to silence.
    var noteLength: TimeInterval = PianoEngine.defaultNoteLength {
        didSet { noteLength = min(max(noteLength, Self.noteLengthRange.lowerBound), Self.noteLengthRange.upperBound) }
    }

    static let defaultNoteLength: TimeInterval = 2.0
    static let noteLengthRange: ClosedRange<TimeInterval> = 0.5...8.0

    /// Fraction of `noteLength` spent at full level before the fade begins.
    private let holdFraction = 0.4
    private let fadeStep: TimeInterval = 0.025

    private let engine = AVAudioEngine()
    private var samplers: [AVAudioUnitSampler] = []
    private let tone = AVAudioUnitEQ(numberOfBands: 1)
    private let reverb = AVAudioUnitReverb()

    private var generations = [Int](repeating: 0, count: NoteZone.count)
    private var holdItems = [DispatchWorkItem?](repeating: nil, count: NoteZone.count)
    private var fadeTimers = [Timer?](repeating: nil, count: NoteZone.count)
    private var pauseWorkItem: DispatchWorkItem?
    private var wantsRunning = false
    private(set) var instrumentLoaded = false

    private static let soundBankURL = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    init() {
        engine.attach(tone)
        engine.attach(reverb)

        do {
            for _ in 0..<NoteZone.count {
                let sampler = AVAudioUnitSampler()
                engine.attach(sampler)
                try engine.connectNode(sampler, to: tone, format: nil)
                samplers.append(sampler)
            }
            try engine.connectNode(tone, to: reverb, format: nil)
            try engine.connectNode(reverb, to: engine.mainMixerNode, format: nil)
        } catch {
            NSLog("Music Touch: could not wire the audio graph: \(error)")
        }

        // Roll off the top end for a felt-piano softness.
        let band = tone.bands[0]
        band.filterType = .lowPass
        band.frequency = 3400
        band.bandwidth = 0.9
        band.bypass = false
        tone.globalGain = 0

        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = 42

        engine.mainMixerNode.outputVolume = 0.9

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }

        loadInstrument()
    }

    private func loadInstrument() {
        do {
            for sampler in samplers {
                try sampler.loadSoundBankInstrument(
                    at: Self.soundBankURL,
                    program: 0, // Acoustic Grand Piano
                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                    bankLSB: UInt8(kAUSampler_DefaultBankLSB)
                )
            }
            instrumentLoaded = true
        } catch {
            instrumentLoaded = false
            NSLog("Music Touch: could not load the system piano: \(error)")
        }
    }

    func start() {
        wantsRunning = true
        pauseWorkItem?.cancel()
        pauseWorkItem = nil
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            NSLog("Music Touch: audio engine failed to start: \(error)")
        }
    }

    /// Lets the current notes and reverb finish, then pauses the engine.
    func stopAfterTail() {
        wantsRunning = false
        pauseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.wantsRunning else { return }
            self.engine.pause()
        }
        pauseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + noteLength + 4.0, execute: item)
    }

    func play(zone: Int, velocity: UInt8 = 92) {
        guard engine.isRunning, samplers.indices.contains(zone) else { return }
        let sampler = samplers[zone]
        let note = NoteZone.midiNote(for: zone)

        generations[zone] += 1
        let generation = generations[zone]
        holdItems[zone]?.cancel()
        fadeTimers[zone]?.invalidate()
        fadeTimers[zone] = nil

        sampler.sendController(11, withValue: 127, onChannel: 0) // back to full level
        sampler.stopNote(note, onChannel: 0)
        sampler.startNote(note, withVelocity: velocity, onChannel: 0)

        let hold = noteLength * holdFraction
        let fade = noteLength - hold
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generations[zone] == generation else { return }
            self.beginFade(zone: zone, note: note, duration: fade, generation: generation)
        }
        holdItems[zone] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: item)
    }

    /// Ramps the zone's expression controller down to silence, then releases the note.
    private func beginFade(zone: Int, note: UInt8, duration: TimeInterval, generation: Int) {
        let sampler = samplers[zone]
        let steps = max(8, Int((duration / fadeStep).rounded()))
        var step = 0
        let timer = Timer(timeInterval: duration / Double(steps), repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.generations[zone] == generation else {
                    timer.invalidate()
                    return
                }
                step += 1
                let progress = min(1.0, Double(step) / Double(steps))
                let value = UInt8((127.0 * (1.0 - progress)).rounded())
                sampler.sendController(11, withValue: value, onChannel: 0)
                if progress >= 1.0 {
                    timer.invalidate()
                    self.fadeTimers[zone] = nil
                    sampler.stopNote(note, onChannel: 0)
                }
            }
        }
        fadeTimers[zone] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleConfigurationChange() {
        guard wantsRunning, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            NSLog("Music Touch: audio engine failed to restart: \(error)")
        }
    }
}
