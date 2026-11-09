import AppKit
import Darwin

/// Drives the illuminated Apple logo on the lid of a MacBook Pro with PROLED XDR Display.
///
/// Apple exposes a single control: the `LEBacklightMode` preference in the root
/// `com.apple.CoreBrightness` domain (0 = off, absent = normal). Writing it needs root,
/// so the app installs a tiny launch daemon once (with an administrator password) that
/// listens on a named pipe and flips that preference. The app then writes "on" or "off"
/// into the pipe. While Music Touch is on and pulsing, the logo rests dark, lights the instant a
/// note is struck and goes dark again as the note starts to fade; it is left lit (macOS's normal
/// state) when Music Touch is off or quits. The logo cannot be dimmed: macOS sets its brightness
/// from the display and ambient light and exposes only the switch, so it cuts rather than fades.
@MainActor
final class LidLogoController {
    nonisolated static let label = "fm.beard.MusicTouch.LogoHelper"
    nonisolated static let fifoPath = "/Users/Shared/MusicTouch/logo-control"
    nonisolated static let helperDirectory = "/Library/Application Support/MusicTouch"
    nonisolated static let scriptPath = helperDirectory + "/logo-helper.sh"
    nonisolated static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    private enum Lamp: String { case on, off }

    /// What we last asked the helper to do. The logo is normally lit, so start there.
    private var lamp: Lamp = .on
    private var pulsing = false
    private var darkenWorkItem: DispatchWorkItem?
    private let pipeQueue = DispatchQueue(label: "fm.beard.MusicTouch.logo-pipe", qos: .userInteractive)

    var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.plistPath)
    }

    /// True when the daemon is alive and waiting on the pipe.
    var isHelperRunning: Bool {
        let fd = open(Self.fifoPath, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    // MARK: Pulsing

    /// Turns per-note pulsing on or off. While pulsing the logo rests dark, ready to light on a
    /// note; otherwise it is lit as macOS normally has it.
    func setPulsing(_ enabled: Bool) {
        pulsing = enabled
        darkenWorkItem?.cancel()
        darkenWorkItem = nil
        send(enabled ? .off : .on)
    }

    /// Lights the logo now and darkens it again after `seconds`, the time the note rings at full
    /// level before it starts to fade. Notes that arrive while it is lit push the darkening back,
    /// so a fast run reads as one longer pulse.
    func noteStruck(litFor seconds: TimeInterval) {
        guard pulsing else { return }
        send(.on)
        darkenWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pulsing else { return }
            self.send(.off)
        }
        darkenWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Always call before quitting so the logo is never left dark.
    func restore() {
        pulsing = false
        darkenWorkItem?.cancel()
        lamp = .off // force the write even if we believe it is already on
        send(.on)
    }

    private func send(_ state: Lamp) {
        guard state != lamp else { return }
        lamp = state
        let line = state.rawValue + "\n"
        pipeQueue.async {
            Self.write(line)
        }
    }

    /// Writes one line to the pipe, waiting for the daemon if it is between reads.
    ///
    /// The daemon reopens the pipe for every line and runs `defaults` in between, which can take
    /// a few hundred milliseconds, during which there is no reader and a non-blocking open fails.
    /// Giving up early drops the line, which for an "off" leaves the logo lit until the next
    /// note; so keep trying for up to a second. Calls arrive on a serial queue, so order holds.
    nonisolated private static func write(_ line: String) {
        for attempt in 0..<50 {
            let fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                defer { close(fd) }
                var ok = false
                line.withCString { cString in
                    ok = Darwin.write(fd, cString, strlen(cString)) >= 0
                }
                if ok { return }
            }
            if attempt < 49 { usleep(20_000) }
        }
    }

    // MARK: Helper installation

    enum HelperError: LocalizedError {
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message): message
            }
        }
    }

    func installHelper() throws {
        let staging = try stageInstallFiles()
        try runAsAdministrator("/bin/sh '\(staging.path)/install.sh'")
        lamp = .on
    }

    func uninstallHelper() throws {
        let staging = try stageInstallFiles()
        try runAsAdministrator("/bin/sh '\(staging.path)/uninstall.sh'")
        lamp = .on
    }

    private func stageInstallFiles() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MusicTouchHelper", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try Self.helperScript.write(to: dir.appendingPathComponent("logo-helper.sh"), atomically: true, encoding: .utf8)
        try Self.launchdPlist.write(to: dir.appendingPathComponent("\(Self.label).plist"), atomically: true, encoding: .utf8)
        try Self.installScript(from: dir).write(to: dir.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try Self.uninstallScript.write(to: dir.appendingPathComponent("uninstall.sh"), atomically: true, encoding: .utf8)
        return dir
    }

    private func runAsAdministrator(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw HelperError.scriptFailed("Could not build the installer script.")
        }
        script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "The installer did not finish."
            throw HelperError.scriptFailed(message)
        }
    }

    // MARK: Helper sources

    private static let helperScript = """
    #!/bin/sh
    # Music Touch lid-logo helper. Runs as root under launchd and waits for "on" / "off"
    # lines on a named pipe, applying Apple's documented CoreBrightness preference.
    FIFO="\(fifoPath)"
    if [ ! -p "$FIFO" ]; then
        mkdir -p "$(dirname "$FIFO")"
        rm -f "$FIFO"
        mkfifo "$FIFO"
        chmod 666 "$FIFO"
    fi
    while :; do
        if read -r cmd < "$FIFO"; then
            case "$cmd" in
                off) /usr/bin/defaults write com.apple.CoreBrightness LEBacklightMode -int 0 ;;
                on)  /usr/bin/defaults delete com.apple.CoreBrightness LEBacklightMode 2>/dev/null ;;
            esac
        else
            sleep 0.2
        fi
    done

    """

    private static let launchdPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(label)</string>
        <key>ProgramArguments</key>
        <array>
            <string>/bin/sh</string>
            <string>\(scriptPath)</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>ProcessType</key>
        <string>Interactive</string>
    </dict>
    </plist>

    """

    private static func installScript(from staging: URL) -> String {
        """
        #!/bin/sh
        set -e
        SRC='\(staging.path)'
        mkdir -p '\(helperDirectory)' '/Users/Shared/MusicTouch'
        cp "$SRC/logo-helper.sh" '\(scriptPath)'
        chown root:wheel '\(scriptPath)'
        chmod 755 '\(scriptPath)'
        if [ ! -p '\(fifoPath)' ]; then
            rm -f '\(fifoPath)'
            mkfifo '\(fifoPath)'
        fi
        chmod 666 '\(fifoPath)'
        cp "$SRC/\(label).plist" '\(plistPath)'
        chown root:wheel '\(plistPath)'
        chmod 644 '\(plistPath)'
        launchctl bootout system/\(label) 2>/dev/null || true
        launchctl bootstrap system '\(plistPath)'

        """
    }

    private static let uninstallScript = """
    #!/bin/sh
    launchctl bootout system/\(label) 2>/dev/null || true
    rm -f '\(plistPath)' '\(scriptPath)' '\(fifoPath)'
    rmdir '\(helperDirectory)' 2>/dev/null || true
    rmdir '/Users/Shared/MusicTouch' 2>/dev/null || true
    /usr/bin/defaults delete com.apple.CoreBrightness LEBacklightMode 2>/dev/null || true
    exit 0

    """
}
