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
                Text("While on, the whole built-in screen plays the C major scale from middle C (C4) to the D above the octave (D5), low notes first. Several fingers play a chord, and sliding across a boundary plays the next note. Content under the overlay is not clickable until you turn Music Touch off.")
            }

            Section {
                if state.canControlLidLogo {
                    Toggle("Pulse the Apple logo on the lid", isOn: $state.pulsesLogo)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Blink length")
                            Spacer()
                            Text(String(format: "%.2f s", state.logoBlinkSeconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $state.logoBlinkSeconds, in: LidLogoController.blinkRange, step: 0.05) {
                            Text("Blink length")
                        } minimumValueLabel: {
                            Text("Quick")
                        } maximumValueLabel: {
                            Text("Slow")
                        }
                        .labelsHidden()
                        Text("How long the logo stays dark after each note before it comes back. The logo itself fades, so very short values may not be visible.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!state.pulsesLogo)

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
                    Text("macOS only lets the lid logo be switched off or on, through a system preference that needs an administrator password. The helper is a tiny launch daemon that flips that preference on request. With pulsing on, the logo blinks dark for a moment on each note and comes straight back. It is left lit when Music Touch is turned off or quits.")
                } else {
                    Text("On a MacBook Pro with PROLED XDR Display, the direct-download version can blink the illuminated Apple logo on each note.")
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
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
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
