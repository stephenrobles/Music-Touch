import AppKit
import Observation
import OSLog
import ServiceManagement

let log = Logger(subsystem: "fm.beard.MusicTouch", category: "app")

/// Settings and live state for the utility, shared by the menu, Settings window, and overlay.
@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    /// The Mac App Store build runs in the App Sandbox, which cannot install the lid-logo helper.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    var canControlLidLogo: Bool { !Self.isSandboxed }

    private enum Keys {
        static let orientation = "orientation"
        static let showsGuides = "showsGuides"
        static let pulsesLogo = "pulsesLogo"
        static let noteLength = "noteLength"
        static let keyRoot = "keyRoot"
        static let scaleMode = "scaleMode"
        static let zoneCount = "zoneCount"
    }

    var isEnabled = false {
        didSet { applyEnabled() }
    }

    var orientation: ZoneOrientation = ZoneOrientation(rawValue: UserDefaults.standard.string(forKey: Keys.orientation) ?? "") ?? .vertical {
        didSet {
            UserDefaults.standard.set(orientation.rawValue, forKey: Keys.orientation)
            overlay.orientation = orientation
        }
    }

    /// The key the zones play in.
    var keyRoot: KeyRoot = KeyRoot(rawValue: UserDefaults.standard.integer(forKey: Keys.keyRoot)) ?? .c {
        didSet {
            UserDefaults.standard.set(keyRoot.rawValue, forKey: Keys.keyRoot)
            applyScale()
        }
    }

    /// Major or minor.
    var scaleMode: ScaleMode = ScaleMode(rawValue: UserDefaults.standard.string(forKey: Keys.scaleMode) ?? "") ?? .major {
        didSet {
            UserDefaults.standard.set(scaleMode.rawValue, forKey: Keys.scaleMode)
            applyScale()
        }
    }

    /// How many zones share the screen, 8 (one octave) to 12.
    var zoneCount: Int = {
        let stored = UserDefaults.standard.integer(forKey: Keys.zoneCount)
        return Scale.degreeRange.contains(stored) ? stored : Scale.defaultDegrees
    }() {
        didSet {
            UserDefaults.standard.set(zoneCount, forKey: Keys.zoneCount)
            applyScale()
        }
    }

    var scale: Scale { Scale(root: keyRoot, mode: scaleMode, degrees: zoneCount) }

    var showsGuides = UserDefaults.standard.bool(forKey: Keys.showsGuides) {
        didSet {
            UserDefaults.standard.set(showsGuides, forKey: Keys.showsGuides)
            overlay.showsGuides = showsGuides
        }
    }

    var pulsesLogo = UserDefaults.standard.bool(forKey: Keys.pulsesLogo) {
        didSet {
            UserDefaults.standard.set(pulsesLogo, forKey: Keys.pulsesLogo)
            logo.setPulsing(isEnabled && pulsesLogo)
        }
    }

    /// Seconds a note rings before it has faded to silence.
    var noteLength: Double = {
        let stored = UserDefaults.standard.double(forKey: Keys.noteLength)
        return stored > 0 ? stored : PianoEngine.defaultNoteLength
    }() {
        didSet {
            UserDefaults.standard.set(noteLength, forKey: Keys.noteLength)
            piano.noteLength = noteLength
        }
    }

    var launchesAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchesAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Music Touch: launch at login change failed: \(error)")
                launchesAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    /// Mirrors the helper's installation state for the Settings window.
    private(set) var logoHelperInstalled = false
    private(set) var logoHelperRunning = false
    var logoHelperMessage: String?

    var hasTouchscreen: Bool {
        NSScreen.screens.contains { $0.touchCapabilities.contains(.multiTouch) }
    }

    var pianoLoaded: Bool { piano.instrumentLoaded }
    var audioRunning: Bool { piano.isRunning }

    /// Where the piano is playing, refreshed when the system's default output changes.
    private(set) var audioOutputName = ""

    /// The most recent note input, for the Settings › Status diagnostics.
    struct LastInput {
        var source: StrikeSource
        var zone: Int
        var date: Date
    }

    private(set) var lastInput: LastInput?

    /// Raw coordinates of the last finger-down, to check touch mapping on real hardware.
    private(set) var lastTouchDiagnostic = "No touch yet"

    var lastInputDescription: String {
        guard let lastInput else { return "None yet" }
        let time = lastInput.date.formatted(date: .omitted, time: .standard)
        let names = scale.names
        let name = names.indices.contains(lastInput.zone) ? names[lastInput.zone] : "zone \(lastInput.zone + 1)"
        return "\(lastInput.source.rawValue) · \(name) · \(time)"
    }

    @ObservationIgnored let overlay = OverlayController()
    @ObservationIgnored let piano = PianoEngine()
    @ObservationIgnored let logo = LidLogoController()
    @ObservationIgnored let updater = AppUpdater()
    @ObservationIgnored private var hotKey: GlobalHotKey?

    private init() {
        overlay.orientation = orientation
        overlay.showsGuides = showsGuides
        piano.noteLength = noteLength
        applyScale()
        overlay.onTouchDiagnostic = { [weak self] line in
            self?.lastTouchDiagnostic = line
            log.info("touch \(line, privacy: .public)")
        }
        audioOutputName = piano.outputDeviceName
        piano.onOutputDeviceChange = { [weak self] in
            guard let self else { return }
            self.audioOutputName = self.piano.outputDeviceName
            log.info("audio output is now \(self.audioOutputName, privacy: .public)")
        }
        overlay.onStrike = { [weak self] zone, _, source in
            self?.strike(zone: zone, from: source)
        }
        hotKey = GlobalHotKey(keyCode: GlobalHotKey.toggleKeyCode, modifiers: GlobalHotKey.toggleModifiers) { [weak self] in
            self?.toggle()
        }
        refreshHelperStatus()
    }

    func toggle() {
        isEnabled.toggle()
    }

    /// Called when the app is about to quit so the lid logo is never left dark.
    func shutdown() {
        overlay.hide()
        logo.restore()
    }

    func refreshHelperStatus() {
        logoHelperInstalled = logo.isHelperInstalled
        logoHelperRunning = logo.isHelperRunning
    }

    func installLogoHelper() {
        do {
            try logo.installHelper()
            logoHelperMessage = nil
        } catch {
            logoHelperMessage = error.localizedDescription
        }
        // launchd needs a moment to bring the daemon up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshHelperStatus()
            if let self, self.pulsesLogo, self.isEnabled {
                self.logo.setPulsing(true)
            }
        }
        refreshHelperStatus()
    }

    func uninstallLogoHelper() {
        do {
            try logo.uninstallHelper()
            logoHelperMessage = nil
        } catch {
            logoHelperMessage = error.localizedDescription
        }
        refreshHelperStatus()
    }

    private func applyScale() {
        let scale = self.scale
        piano.scale = scale
        overlay.scale = scale
        log.info("scale is now \(scale.title, privacy: .public): \(scale.names.joined(separator: " "), privacy: .public)")
    }

    private func applyEnabled() {
        log.info("Music Touch \(self.isEnabled ? "on" : "off", privacy: .public)")
        if isEnabled {
            piano.start()
            audioOutputName = piano.outputDeviceName
            log.info("audio engine \(self.piano.isRunning ? "running" : "NOT running", privacy: .public) on \(self.audioOutputName, privacy: .public)")
            overlay.show()
            logo.setPulsing(pulsesLogo)
        } else {
            overlay.hide()
            piano.stopAfterTail()
            logo.setPulsing(false)
        }
    }

    private func strike(zone: Int, from source: StrikeSource) {
        log.debug("strike zone \(zone) \(self.scale.names[zone], privacy: .public) via \(source.rawValue, privacy: .public)")
        lastInput = LastInput(source: source, zone: zone, date: .now)
        piano.play(zone: zone)
        if pulsesLogo {
            logo.noteStruck(litFor: piano.holdLength)
        }
    }
}
