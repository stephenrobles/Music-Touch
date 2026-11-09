import AppKit
import CoreImage
import OSLog
import QuartzCore

/// Where a strike came from, shown in Settings › Status so touch delivery can be checked.
enum StrikeSource: String {
    case touch = "Touch"
    case click = "Click"
}

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlayView(_ view: OverlayView, didStrikeZone zone: Int, at point: CGPoint, from source: StrikeSource)
}

/// Receives finger touches for the overlay view.
///
/// On macOS 27, finger touches reach an app only through gesture recognizers: AppKit does not
/// deliver them through the responder chain's `touchesBegan(with:)` or through event monitors
/// (Apple TN3212). This recognizer exists only to receive touches and hand them to the view. It
/// reports `began` / `changed` / `ended` so AppKit keeps delivering, and never acts on its own.
final class DirectTouchRecognizer: NSGestureRecognizer {
    var handler: ((Set<NSTouch>, NSTouch.Phase, NSEvent) -> Void)?

    /// Last known location in window coordinates, for `location(in:)`.
    private var lastWindowLocation: NSPoint = .zero

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = .direct
        delaysPrimaryMouseButtonEvents = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Every touch in the event, located in the recognizer's view.
    private func touches(in event: NSEvent) -> Set<NSTouch> {
        guard let view else { return event.allTouches() }
        return event.touches(matching: .any, in: view)
    }

    override func touchesBegan(with event: NSEvent) {
        let touches = touches(in: event)
        let phases = touches.map { String($0.phase.rawValue) }.joined(separator: ",")
        log.info("recognizer touchesBegan: \(touches.count) touches (all: \(event.allTouches().count)), phases [\(phases, privacy: .public)], state \(self.state.rawValue), window \(self.view?.window != nil)")
        remember(touches)
        // Phase filtering is a hint, not a gate: a direct touch that arrives here is beginning.
        let beginning = touches.filter { $0.phase == .began }
        handler?(beginning.isEmpty ? touches : beginning, .began, event)
        state = state == .possible ? .began : .changed
    }

    override func mouseDown(with event: NSEvent) {
        log.info("recognizer saw mouseDown subtype \(event.subtype.rawValue), state \(self.state.rawValue)")
        super.mouseDown(with: event)
    }

    override func touchesMoved(with event: NSEvent) {
        let touches = touches(in: event)
        remember(touches)
        handler?(touches.filter { $0.phase == .moved }, .moved, event)
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(with event: NSEvent) {
        let touches = touches(in: event)
        handler?(touches.filter { $0.phase == .ended }, .ended, event)
        let stillTouching = touches.contains { NSTouch.Phase.touching.contains($0.phase) }
        if state == .began || state == .changed {
            state = stillTouching ? .changed : .ended
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        let touches = touches(in: event)
        handler?(touches.filter { $0.phase == .cancelled }, .cancelled, event)
        if state == .began || state == .changed { state = .cancelled }
    }

    override func location(in view: NSView?) -> NSPoint {
        guard let view else { return lastWindowLocation }
        return view.convert(lastWindowLocation, from: nil)
    }

    private func remember(_ touches: Set<NSTouch>) {
        let live = touches.filter { NSTouch.Phase.touching.contains($0.phase) }
        guard !live.isEmpty else { return }
        let sum = live.reduce(CGPoint.zero) { acc, touch in
            let p = touch.location(in: nil)
            return CGPoint(x: acc.x + p.x, y: acc.y + p.y)
        }
        lastWindowLocation = CGPoint(x: sum.x / CGFloat(live.count), y: sum.y / CGFloat(live.count))
    }
}

/// Transparent full-screen view that turns finger touches (or clicks) into notes and glows.
final class OverlayView: NSView {
    weak var delegate: OverlayViewDelegate?

    /// One line describing the most recent finger-down, for Settings › Status and the log.
    var onTouchDiagnostic: ((String) -> Void)?

    var orientation: ZoneOrientation = .vertical {
        didSet { rebuildGuides() }
    }

    var showsGuides = false {
        didSet { rebuildGuides() }
    }

    /// Names the guide labels and diagnostics use for the zones.
    var scale: Scale = .default {
        didSet { if scale != oldValue { rebuildGuides() } }
    }

    private let guidesLayer = CALayer()
    private let glowLayer = CALayer()
    private let touchRecognizer = DirectTouchRecognizer(target: nil, action: nil)

    /// Last zone struck by each live finger, so dragging across a boundary plays the next note.
    private var touchZones: [NSObject: Int] = [:]
    private var mouseZone: Int?

    /// Where fingers have recently been. macOS also synthesizes a click for a tap in apps that
    /// are not marked touch-native; a click that lands where a finger just was is that echo and
    /// is ignored, so a tap plays once. Real trackpad clicks nowhere near a finger still play.
    private var recentTouches: [(point: CGPoint, time: CFTimeInterval)] = []
    private let echoWindow: CFTimeInterval = 0.6
    private let echoDistance: CGFloat = 48
    private var mouseIsEcho = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layerContentsRedrawPolicy = .never
        allowedTouchTypes = [.direct]
        wantsRestingTouches = false
        layer?.addSublayer(guidesLayer)
        layer?.addSublayer(glowLayer)

        touchRecognizer.handler = { [unowned self] touches, phase, event in
            self.handleTouches(touches, phase: phase, event: event)
        }
        touchRecognizer.delegate = self
        addGestureRecognizer(touchRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        guidesLayer.frame = bounds
        glowLayer.frame = bounds
        rebuildGuides()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildGuides()
    }

    // MARK: Direct touches (via the gesture recognizer)

    private func handleTouches(_ touches: Set<NSTouch>, phase: NSTouch.Phase, event: NSEvent) {
        let now = CACurrentMediaTime()
        switch phase {
        case .began:
            for touch in touches {
                let (point, space) = location(of: touch, event: event)
                let zone = zone(at: point)
                touchZones[key(for: touch)] = zone
                recentTouches.append((point, now))
                report(touch, event: event, resolved: point, space: space, zone: zone)
                strike(zone: zone, at: point, from: .touch)
            }
        case .moved:
            for touch in touches {
                let (point, _) = location(of: touch, event: event)
                let zone = zone(at: point)
                let key = key(for: touch)
                recentTouches.append((point, now))
                if touchZones[key] != zone {
                    touchZones[key] = zone
                    strike(zone: zone, at: point, from: .touch)
                }
            }
        default:
            for touch in touches {
                recentTouches.append((location(of: touch, event: event).0, now))
                touchZones.removeValue(forKey: key(for: touch))
            }
        }
        recentTouches.removeAll { now - $0.time > echoWindow }
    }

    /// Where a finger is, in this view's coordinates, and which coordinate space supplied it.
    ///
    /// `NSTouch.normalizedPosition` and `deviceSize` are trackpad properties: on macOS 27 reading
    /// them on a direct (touchscreen) touch raises an internal assertion that unwinds the whole
    /// event, so they are never read for direct touches. The touch's own `location(in:)` is the
    /// first choice; when that lands outside the overlay the event's `locationInWindow` and the
    /// current screen pointer position are tried in turn, since the touchscreen reports some of
    /// these in a space the overlay panel does not share.
    private func location(of touch: NSTouch, event: NSEvent) -> (CGPoint, String) {
        var candidates: [(String, CGPoint)] = []
        if touch.type == .direct {
            candidates.append(("touch", touch.location(in: self)))
            candidates.append(("event", convert(event.locationInWindow, from: nil)))
            if let window {
                let screenPoint = NSEvent.mouseLocation
                let windowPoint = window.convertPoint(fromScreen: screenPoint)
                candidates.append(("pointer", convert(windowPoint, from: nil)))
            }
        } else {
            let n = touch.normalizedPosition
            if n.x.isFinite, n.y.isFinite, (0...1).contains(n.x), (0...1).contains(n.y), !(n.x == 0 && n.y == 0) {
                candidates.append(("normalized", CGPoint(x: n.x * bounds.width, y: n.y * bounds.height)))
            }
            candidates.append(("touch", touch.location(in: self)))
        }
        if let hit = candidates.first(where: { bounds.contains($0.1) }) {
            return (hit.1, hit.0)
        }
        let fallback = candidates[0]
        return (fallback.1, fallback.0 + " (out of bounds)")
    }

    private func report(_ touch: NSTouch, event: NSEvent, resolved point: CGPoint, space: String, zone: Int) {
        guard let onTouchDiagnostic else { return }
        func f(_ v: CGFloat) -> String { String(format: "%.0f", v) }
        func f(_ p: CGPoint) -> String { "(\(f(p.x)), \(f(p.y)))" }
        let inView = touch.location(in: self)
        let inWindow = touch.location(in: nil)
        let eventInView = convert(event.locationInWindow, from: nil)
        let pointer = NSEvent.mouseLocation
        let windowFrame = window?.frame ?? .zero
        let line = "zone \(scale.names[zone]) at \(f(point)) via \(space) · "
            + "touch view \(f(inView)) window \(f(inWindow)) · "
            + "event view \(f(eventInView)) window \(f(event.locationInWindow)) · "
            + "pointer screen \(f(pointer)) · type \(touch.type == .direct ? "direct" : "indirect") · "
            + "bounds \(f(bounds.width))×\(f(bounds.height)) · "
            + "panel \(f(windowFrame.width))×\(f(windowFrame.height)) at \(f(windowFrame.origin))"
        onTouchDiagnostic(line)
    }

    // MARK: Mouse (trackpad testing, and the click macOS synthesizes for a tap)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let now = CACurrentMediaTime()
        recentTouches.removeAll { now - $0.time > echoWindow }
        mouseIsEcho = recentTouches.contains { hypot($0.point.x - point.x, $0.point.y - point.y) < echoDistance }
        let pointer = NSEvent.mouseLocation
        log.info("mouseDown subtype \(event.subtype.rawValue) at (\(Int(point.x)), \(Int(point.y))) in bounds \(Int(self.bounds.width))×\(Int(self.bounds.height)), pointer screen (\(Int(pointer.x)), \(Int(pointer.y))), echo \(self.mouseIsEcho)")
        guard !mouseIsEcho else { return }
        let zone = zone(at: point)
        mouseZone = zone
        strike(zone: zone, at: point, from: .click)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !mouseIsEcho else { return }
        let point = convert(event.locationInWindow, from: nil)
        let zone = zone(at: point)
        if mouseZone != zone {
            log.info("mouseDragged to zone \(zone) at (\(Int(point.x)), \(Int(point.y))), previous \(self.mouseZone.map(String.init) ?? "none", privacy: .public)")
            mouseZone = zone
            strike(zone: zone, at: point, from: .click)
        }
    }

    override func mouseUp(with event: NSEvent) {
        log.info("mouseUp subtype \(event.subtype.rawValue)")
        mouseZone = nil
        mouseIsEcho = false
    }

    // MARK: Striking

    private func zone(at point: CGPoint) -> Int {
        NoteZone.zone(at: point, in: bounds.size, orientation: orientation, count: scale.degrees)
    }

    private func key(for touch: NSTouch) -> NSObject {
        (touch.identity as? NSObject) ?? NSNumber(value: ObjectIdentifier(touch.identity).hashValue)
    }

    private func strike(zone: Int, at point: CGPoint, from source: StrikeSource) {
        showGlow(at: point, color: NoteZone.color(for: zone, of: scale.degrees))
        delegate?.overlayView(self, didStrikeZone: zone, at: point, from: source)
    }

    // MARK: Glow

    /// A bright, thick ring in the note's colour that emanates slowly from the touch point and fades as it grows.
    private func showGlow(at point: CGPoint, color: NSColor) {
        let startRadius: CGFloat = 6
        let endRadius: CGFloat = 80
        let lineWidth: CGFloat = 16
        let duration: CFTimeInterval = 1.3

        let bright = color.blended(withFraction: 0.22, of: .white) ?? color

        // Coloured body of the ring with a wide glow.
        let ring = CAShapeLayer()
        ring.frame = bounds
        ring.fillColor = nil
        ring.strokeColor = bright.cgColor
        ring.lineWidth = lineWidth
        ring.shadowColor = color.cgColor
        ring.shadowOpacity = 1
        ring.shadowRadius = 16
        ring.shadowOffset = .zero

        // Soft white highlight diffused along the middle of the ring.
        let highlight = CAShapeLayer()
        highlight.frame = bounds
        highlight.fillColor = nil
        highlight.strokeColor = NSColor.white.withAlphaComponent(0.75).cgColor
        highlight.lineWidth = lineWidth * 0.45
        highlight.shadowColor = NSColor.white.cgColor
        highlight.shadowOpacity = 0.6
        highlight.shadowRadius = 6
        highlight.shadowOffset = .zero
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 5]) {
            highlight.filters = [blur]
        }

        let startPath = Self.circlePath(center: point, radius: startRadius)
        let endPath = Self.circlePath(center: point, radius: endRadius)
        ring.path = endPath
        highlight.path = endPath
        glowLayer.addSublayer(ring)
        glowLayer.addSublayer(highlight)

        func emanate() -> CAAnimationGroup {
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = startPath
            grow.toValue = endPath

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1.0, 1.0, 0.0]
            fade.keyTimes = [0, 0.45, 1]

            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            group.fillMode = .forwards
            return group
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            ring.removeFromSuperlayer()
            highlight.removeFromSuperlayer()
        }
        ring.add(emanate(), forKey: "emanate")
        highlight.add(emanate(), forKey: "emanate")
        ring.opacity = 0
        highlight.opacity = 0
        CATransaction.commit()
    }

    private static func circlePath(center: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    // MARK: Guides

    private func rebuildGuides() {
        guidesLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard showsGuides, bounds.width > 0, bounds.height > 0 else { return }

        let backingScale = window?.backingScaleFactor ?? 2
        let lines = CAShapeLayer()
        lines.frame = guidesLayer.bounds
        lines.contentsScale = backingScale
        lines.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        lines.lineWidth = 1
        lines.shadowColor = NSColor.white.cgColor
        lines.shadowOpacity = 0.5
        lines.shadowRadius = 2
        lines.shadowOffset = .zero

        let path = CGMutablePath()
        let count = scale.degrees
        for i in 1..<count {
            let fraction = CGFloat(i) / CGFloat(count)
            switch orientation {
            case .vertical:
                let y = (bounds.height * fraction).rounded() + 0.5
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: bounds.width, y: y))
            case .horizontal:
                let x = (bounds.width * fraction).rounded() + 0.5
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: bounds.height))
            }
        }
        lines.path = path
        guidesLayer.addSublayer(lines)

        for i in 0..<count {
            let label = CATextLayer()
            label.contentsScale = backingScale
            label.string = scale.names[i]
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.fontSize = 13
            label.alignmentMode = .center
            label.foregroundColor = NoteZone.color(for: i, of: count).withAlphaComponent(0.8).cgColor
            let size = CGSize(width: 36, height: 18)
            switch orientation {
            case .vertical:
                let zoneHeight = bounds.height / CGFloat(count)
                label.frame = CGRect(x: 10, y: zoneHeight * CGFloat(i) + 8, width: size.width, height: size.height)
                label.alignmentMode = .left
            case .horizontal:
                let zoneWidth = bounds.width / CGFloat(count)
                label.frame = CGRect(x: zoneWidth * CGFloat(i) + (zoneWidth - size.width) / 2, y: 10, width: size.width, height: size.height)
            }
            guidesLayer.addSublayer(label)
        }
    }
}

// MARK: - Gesture recognizer delegate

extension OverlayView: NSGestureRecognizerDelegate {
    /// Keeps the recognizer out of every event that is not a finger on the screen. A trackpad
    /// click is a mouse event with the touch subtype, and letting the recognizer take part in it
    /// opened a touch sequence on this view that never closed (the trackpad's finger-lift is an
    /// indirect touch this view does not accept), after which AppKit treated the view as still
    /// exclusive and dropped later screen touches. Mouse events still reach `mouseDown` and
    /// friends directly.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let isDirectTouch = event.type == .directTouch
        if !isDirectTouch {
            log.info("recognizer declining event type \(event.type.rawValue) subtype \(event.subtype.rawValue)")
        }
        return isDirectTouch
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        let isDirect = touch.type == .direct
        log.info("recognizer shouldReceive touch \(isDirect ? "direct" : "indirect", privacy: .public) phase \(touch.phase.rawValue): \(isDirect)")
        return isDirect
    }
}
