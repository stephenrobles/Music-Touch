#if APPSTORE
import Observation

/// The App Store delivers updates, so this build has no updater; the stub keeps call sites uniform.
@Observable
final class AppUpdater {
    static let isAvailable = false
    let canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    func checkForUpdates() {}
}
#else
import AppKit
import Combine
import Observation
import Sparkle

/// Sparkle updates for the direct download, from the feed in Config/Info.plist (SUFeedURL).
/// Updates must be signed with the EdDSA key in the release Mac's keychain (account "musictouch");
/// see Tools/release.sh.
@Observable
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    static let isAvailable = true

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var cancellable: AnyCancellable?

    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// A menu bar app has no Dock icon or main window, so let Sparkle use its gentle
    /// reminders for scheduled checks instead of popping a window over whatever the user is doing.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Bring the update window forward, since this app is never frontmost on its own.
        if handleShowingUpdate { NSApp.activate() }
    }
}
#endif
