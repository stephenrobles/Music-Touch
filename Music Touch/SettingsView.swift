import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Music Touch On", isOn: $state.isEnabled)
                LabeledContent("Keyboard shortcut", value: GlobalHotKey.toggleDescription)
                Picker("Orientation", selection: $state.orientation) {
                    ForEach(ZoneOrientation.allCases) { orientation in
                        Text(orientation.menuLabel).tag(orientation)
                    }
                }
                Toggle("Show note separator lines", isOn: $state.showsGuides)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Note length")
                        Spacer()
                        Text(String(format: "%.2f s", state.noteLength))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $state.noteLength, in: PianoEngine.noteLengthRange, step: 0.25) {
                        Text("Note length")
                    } minimumValueLabel: {
                        Text("Short")
                    } maximumValueLabel: {
                        Text("Long")
                    }
                    .labelsHidden()
                    Text("How long each note sustains and then fades away.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle("Launch at login", isOn: $state.launchesAtLogin)
            } header: {
                Text("Playing")
            } footer: {
                Text("While on, the whole built-in screen is divided into note zones playing the chosen scale upwards from its root, low notes first. Several fingers play a chord, and sliding across a boundary plays the next note. Content under the overlay is not clickable until you turn Music Touch off.")
            }

            Section {
                Picker("Key", selection: $state.keyRoot) {
                    ForEach(KeyRoot.allCases) { root in
                        Text(root.name(in: state.scaleMode)).tag(root)
                    }
                }
                Picker("Mode", selection: $state.scaleMode) {
                    ForEach(ScaleMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Zones", selection: $state.zoneCount) {
                    ForEach(Array(Scale.degreeRange), id: \.self) { count in
                        Text(Scale.degreesLabel(count)).tag(count)
                    }
                }
                LabeledContent("Notes", value: state.scale.names.joined(separator: "  "))
                    .monospacedDigit()
            } header: {
                Text("Key")
            } footer: {
                Text("The screen is split evenly into the chosen number of zones, playing the \(state.scale.title) scale from the root upwards; one octave runs root to root, more zones keep climbing. Minor is the natural minor. Keys from G up start below middle C so every key sits in the same range.")
            }

            Section {
                if state.canControlLidLogo {
                    Toggle("Pulse the Apple logo on the lid", isOn: $state.pulsesLogo)

                    LabeledContent("Helper") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(helperColor)
                                .frame(width: 8, height: 8)
                            Text(helperStatus)
                        }
                    }

                    HStack {
                        if state.logoHelperInstalled {
                            Button("Uninstall Helper…") { state.uninstallLogoHelper() }
                        } else {
                            Button("Install Helper…") { state.installLogoHelper() }
                        }
                        Button("Refresh") { state.refreshHelperStatus() }
                    }

                    if let message = state.logoHelperMessage {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                } else {
                    Text("Pulsing the lid logo needs a small helper that the App Store version of Music Touch isn't allowed to install. The free download from beardfm.app includes it.")
                    Link("Get the beardfm.app version", destination: URL(string: "https://beardfm.app/music-touch/")!)
                }
            } header: {
                Text("Apple Logo")
            } footer: {
                if state.canControlLidLogo {
                    Text("macOS only lets the lid logo be switched off or on, through a system preference that needs an administrator password. The helper is a tiny launch daemon that flips that preference on request. With pulsing on, the logo rests dark while Music Touch is on, lights the instant a note is struck and goes dark again as the note starts to fade, so a longer Note length keeps it lit longer. macOS sets the logo's brightness itself, so it switches rather than fades. It is left lit when Music Touch is turned off or quits.")
                } else {
                    Text("On a MacBook Pro with PROLED XDR Display, the direct-download version can light the illuminated Apple logo on each note.")
                }
            }

            if AppUpdater.isAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { state.updater.automaticallyChecksForUpdates },
                        set: { state.updater.automaticallyChecksForUpdates = $0 }
                    ))
                    Button("Check for Updates…") { state.updater.checkForUpdates() }
                        .disabled(!state.updater.canCheckForUpdates)
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Updates come from beardfm.app and are verified before they install.")
                }
            }

            Section {
                LabeledContent("Touchscreen", value: state.hasTouchscreen ? "Detected" : "Not detected (clicks and drags still play)")
                LabeledContent("Piano", value: state.pianoLoaded ? "System grand piano loaded" : "Not loaded")
                LabeledContent("Audio engine", value: state.isEnabled ? (state.audioRunning ? "Running" : "Not running") : "Idle until Music Touch is on")
                LabeledContent("Audio output", value: state.audioOutputName)
                LabeledContent("Last input", value: state.lastInputDescription)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last touch")
                    Text(state.lastTouchDiagnostic)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Notes play through the Mac's current default output, and follow it when it changes. Last input shows whether the most recent note came from a finger on the screen or from a click, with the note it played.")
            }
        }
        .formStyle(.grouped)
        // The window (SettingsWindowController) fixes the width and lets the height vary; the
        // grouped form scrolls when the window is shorter than its content.
        .frame(width: SettingsWindowController.width)
        .onAppear {
            state.refreshHelperStatus()
            NSApp.activate()
        }
    }

    private var helperStatus: String {
        if !state.logoHelperInstalled { return "Not installed" }
        return state.logoHelperRunning ? "Installed and running" : "Installed, not running"
    }

    private var helperColor: Color {
        if !state.logoHelperInstalled { return .secondary }
        return state.logoHelperRunning ? .green : .orange
    }
}

/// Shows Settings in a window the app owns: fixed width, any height from `minHeight` up, with
/// the resizable style set at creation. The SwiftUI `Settings` scene would not let its window
/// resize on macOS 27 and widened it once the content's height became flexible.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    static let width: CGFloat = 520
    static let minHeight: CGFloat = 420
    static let defaultHeight: CGFloat = 820
    private static let autosaveName = "MusicTouchSettings"

    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            window = makeWindow(state: state)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow(state: AppState) -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(state: state))
        // The window, not SwiftUI, decides the size: SwiftUI would otherwise resize it back to the
        // content's ideal size after every change.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Music Touch Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Self.width, height: Self.minHeight)
        window.contentMaxSize = NSSize(width: Self.width, height: 10_000)
        if !window.setFrameUsingName(Self.autosaveName) {
            window.setContentSize(NSSize(width: Self.width, height: Self.defaultHeight))
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        return window
    }
}
