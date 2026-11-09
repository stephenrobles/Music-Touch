import AppKit

/// Borderless, non-activating panel that covers the touchscreen while the utility is on.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController: OverlayViewDelegate {
    var onStrike: ((Int, CGPoint, StrikeSource) -> Void)?
    var onTouchDiagnostic: ((String) -> Void)? {
        get { view.onTouchDiagnostic }
        set { view.onTouchDiagnostic = newValue }
    }

    var orientation: ZoneOrientation {
        get { view.orientation }
        set { view.orientation = newValue }
    }

    var showsGuides: Bool {
        get { view.showsGuides }
        set { view.showsGuides = newValue }
    }

    private(set) var isShowing = false
    private var panel: OverlayPanel?
    private let view = OverlayView(frame: .zero)

    init() {
        view.delegate = self
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionIfShowing()
            }
        }
    }

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        reposition(panel)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(view)
        isShowing = true
    }

    func hide() {
        panel?.orderOut(nil)
        isShowing = false
    }

    /// The built-in touchscreen when there is one, otherwise the built-in display, otherwise the main screen.
    static func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let touch = screens.first(where: { $0.touchCapabilities.contains(.multiTouch) }) {
            return touch
        }
        if let builtIn = screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }) {
            return builtIn
        }
        return NSScreen.main ?? screens.first
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Above every app window and the Dock, just below the menu bar so the menu bar stays reachable.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
        return panel
    }

    private func reposition(_ panel: OverlayPanel) {
        guard let screen = Self.targetScreen() else { return }
        panel.setFrame(screen.frame, display: true)
    }

    private func repositionIfShowing() {
        guard isShowing, let panel else { return }
        reposition(panel)
    }

    func overlayView(_ view: OverlayView, didStrikeZone zone: Int, at point: CGPoint, from source: StrikeSource) {
        onStrike?(zone, point, source)
    }
}
