import SwiftUI

@main
struct MusicTouchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.isEnabled ? "pianokeys.inverse" : "pianokeys")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(state: state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
}

struct MenuContent: View {
    @Bindable var state: AppState

    var body: some View {
        Toggle("Music Touch On", isOn: $state.isEnabled)
        Text("Toggle anywhere with \(GlobalHotKey.toggleDescription)")

        Divider()

        Picker("Orientation", selection: $state.orientation) {
            ForEach(ZoneOrientation.allCases) { orientation in
                Text(orientation.menuLabel).tag(orientation)
            }
        }
        Toggle("Show Note Lines", isOn: $state.showsGuides)
        if state.canControlLidLogo {
            Toggle("Pulse Apple Logo", isOn: $state.pulsesLogo)
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        if AppUpdater.isAvailable {
            Button("Check for Updates…") { state.updater.checkForUpdates() }
                .disabled(!state.updater.canCheckForUpdates)
        }

        Divider()

        Button("Quit Music Touch") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
