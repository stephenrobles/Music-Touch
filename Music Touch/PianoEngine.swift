import AVFoundation
import CoreAudio
import OSLog

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

    /// How long a struck note rings at full level before it starts to fade.
    var holdLength: TimeInterval { noteLength * holdFraction }
    private let fadeStep: TimeInterval = 0.025

    private let engine = AVAudioEngine()
    private var samplers: [AVAudioUnitSampler] = []
    /// Sums the samplers. The EQ that follows has a single input bus, so connecting the
    /// samplers to it directly leaves only the last one wired up; a mixer gives each its own bus.
    private let sum = AVAudioMixerNode()
    private let tone = AVAudioUnitEQ(numberOfBands: 1)
    private let reverb = AVAudioUnitReverb()

    private var generations = [Int](repeating: 0, count: Scale.degreeRange.upperBound)
    private var holdItems = [DispatchWorkItem?](repeating: nil, count: Scale.degreeRange.upperBound)
    private var fadeTimers = [Timer?](repeating: nil, count: Scale.degreeRange.upperBound)
    private var pauseWorkItem: DispatchWorkItem?
    private var wantsRunning = false
    private(set) var instrumentLoaded = false

    /// True while the audio engine is running (it is started when Music Touch is turned on).
    var isRunning: Bool { engine.isRunning }

    /// Which notes the zones play. Notes already ringing keep their pitch when it changes.
    var scale: Scale = .default

    /// Called on the main thread when the system's default output device changes.
    var onOutputDeviceChange: (() -> Void)?

    /// Name of the device the engine plays through, for Settings › Status.
    var outputDeviceName: String {
        let id = engine.outputNode.auAudioUnit.deviceID
        guard id != 0 else { return "System default" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return "Device \(id)" }
        return name.takeRetainedValue() as String
    }

    private static let soundBankURL = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    init() {
        engine.attach(sum)
        engine.attach(tone)
        engine.attach(reverb)

        do {
            // One sampler per possible zone, so changing the zone count never rewires the graph.
            for _ in 0..<Scale.degreeRange.upperBound {
                let sampler = AVAudioUnitSampler()
                engine.attach(sampler)
                try engine.connectNode(sampler, to: sum, format: nil)
                samplers.append(sampler)
            }
            try engine.connectNode(sum, to: tone, format: nil)
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

        sum.outputVolume = 1
        engine.mainMixerNode.outputVolume = 0.9

        // Follow the system's default output device: whatever is chosen in Sound settings or the
        // menu bar (speakers, headphones, AirPods, a display) is where the piano plays.
        bindToDefaultOutputDevice()
        var defaultOutput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutput, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.handleDefaultOutputDeviceChange()
            }
        }

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
        bindToDefaultOutputDevice()
        do {
            try engine.start()
            log.info("audio engine started on \(self.outputDeviceName, privacy: .public), output format \(self.engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz")
        } catch {
            log.error("audio engine failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The device the system currently calls the default output, or 0 if there is none.
    private static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : 0
    }

    /// Points the output node at the current default device. Only valid while the engine is stopped.
    private func bindToDefaultOutputDevice() {
        let id = Self.defaultOutputDeviceID()
        guard id != 0, engine.outputNode.auAudioUnit.deviceID != id else { return }
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(id)
        } catch {
            log.error("could not select the default output device \(id): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The default output moved (headphones plugged in, AirPods connected, a display chosen):
    /// rebuild the engine on the new device so the next note comes out of it.
    private func handleDefaultOutputDeviceChange() {
        let wasRunning = engine.isRunning
        engine.stop()
        bindToDefaultOutputDevice()
        if wantsRunning || wasRunning {
            do {
                try engine.start()
            } catch {
                NSLog("Music Touch: audio engine failed to restart on the new output: \(error)")
            }
        }
        onOutputDeviceChange?()
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
        guard engine.isRunning, samplers.indices.contains(zone), scale.midiNotes.indices.contains(zone) else {
            log.error("play ignored: engine running \(self.engine.isRunning), instrument loaded \(self.instrumentLoaded), output \(self.outputDeviceName, privacy: .public)")
            return
        }
        let sampler = samplers[zone]
        let note = scale.midiNotes[zone]

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

    /// The engine stops itself when the output's format or device changes; bring it back.
    private func handleConfigurationChange() {
        guard wantsRunning, !engine.isRunning else { return }
        bindToDefaultOutputDevice()
        do {
            try engine.start()
        } catch {
            NSLog("Music Touch: audio engine failed to restart: \(error)")
        }
        onOutputDeviceChange?()
    }
}
