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
                    Text("macOS only lets the lid logo be switched off or on, through a system preference that needs an administrator password. The helper is a tiny launch daemon that flips that preference on request. With pulsing on, the logo stays dark while Music Touch is on and lights up for each note. It is restored when Music Touch is turned off or quits.")
                } else {
                    Text("On a MacBook Pro with PROLED XDR Display, the direct-download version can dim the illuminated Apple logo while Music Touch is on and light it for each note.")
                }
            }

            Section("Status") {
                LabeledContent("Touchscreen", value: state.hasTouchscreen ? "Detected" : "Not detected (clicks and drags still play)")
                LabeledContent("Piano", value: state.pianoLoaded ? "System grand piano loaded" : "Not loaded")
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
