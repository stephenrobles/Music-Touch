import AppKit
import Darwin

/// Drives the illuminated Apple logo on the lid of a MacBook Pro with PROLED XDR Display.
///
/// Apple exposes a single control: the `LEBacklightMode` preference in the root
/// `com.apple.CoreBrightness` domain (0 = off, absent = normal). Writing it needs root,
/// so the app installs a tiny launch daemon once (with an administrator password) that
/// listens on a named pipe and flips that preference. The app then writes "on" or "off"
/// into the pipe. The logo stays lit and blinks dark for a moment on each note.
@MainActor
final class LidLogoController {
    nonisolated static let label = "fm.beard.MusicTouch.LogoHelper"
    nonisolated static let fifoPath = "/Users/Shared/MusicTouch/logo-control"
    nonisolated static let helperDirectory = "/Library/Application Support/MusicTouch"
    nonisolated static let scriptPath = helperDirectory + "/logo-helper.sh"
    nonisolated static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    /// How long the logo stays dark after a note is struck before it comes back.
    var blinkSeconds: TimeInterval = 0.3

    private enum Lamp: String { case on, off }

    /// What we last asked the helper to do. The logo is normally lit, so start there.
    private var lamp: Lamp = .on
    private var pulsing = false
    private var relightWorkItem: DispatchWorkItem?
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

    /// Turns per-note blinking on or off. Either way the logo rests lit.
    func setPulsing(_ enabled: Bool) {
        pulsing = enabled
        relightWorkItem?.cancel()
        relightWorkItem = nil
        send(.on)
    }

    /// Blinks the logo dark now and relights it after `blinkSeconds`. Notes that arrive while
    /// it is dark push the relight back, so a fast run reads as one longer blink.
    func noteStruck() {
        guard pulsing else { return }
        send(.off)
        relightWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pulsing else { return }
            self.send(.on)
        }
        relightWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + blinkSeconds, execute: item)
    }

    /// Always call before quitting so the logo is never left dark.
    func restore() {
        pulsing = false
        relightWorkItem?.cancel()
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

    /// Writes one line to the pipe, retrying briefly if the daemon is between reads.
    nonisolated private static func write(_ line: String) {
        for attempt in 0..<8 {
            let fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                defer { close(fd) }
                var ok = false
                line.withCString { cString in
                    ok = Darwin.write(fd, cString, strlen(cString)) >= 0
                }
                if ok { return }
            }
            if attempt < 7 { usleep(15_000) }
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
