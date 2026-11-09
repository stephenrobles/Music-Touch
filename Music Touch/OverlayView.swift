import AppKit
import CoreImage
import QuartzCore

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlayView(_ view: OverlayView, didStrikeZone zone: Int, at point: CGPoint)
}

/// Transparent full-screen view that turns finger touches (or clicks) into notes and glows.
final class OverlayView: NSView {
    weak var delegate: OverlayViewDelegate?

    var orientation: ZoneOrientation = .vertical {
        didSet { rebuildGuides() }
    }

    var showsGuides = false {
        didSet { rebuildGuides() }
    }

    private let guidesLayer = CALayer()
    private let glowLayer = CALayer()

    /// Last zone struck by each live finger, so dragging across a boundary plays the next note.
    private var touchZones: [NSObject: Int] = [:]
    private var mouseZone: Int?

    /// Finger touches arrive both as direct-touch events and as synthesized mouse events;
    /// strikes close together in time and space are treated as one.
    private var recentStrikes: [(point: CGPoint, time: CFTimeInterval)] = []
    private let duplicateWindow: CFTimeInterval = 0.15
    private let duplicateDistance: CGFloat = 40

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layerContentsRedrawPolicy = .never
        allowedTouchTypes = [.direct]
        wantsRestingTouches = false
        layer?.addSublayer(guidesLayer)
        layer?.addSublayer(glowLayer)
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

    // MARK: Direct touches

    override func touchesBegan(with event: NSEvent) {
        for touch in event.touches(matching: .began, in: self) where touch.type == .direct {
            let point = touch.location(in: self)
            let zone = zone(at: point)
            touchZones[key(for: touch)] = zone
            strike(zone: zone, at: point)
        }
    }

    override func touchesMoved(with event: NSEvent) {
        for touch in event.touches(matching: .moved, in: self) where touch.type == .direct {
            let point = touch.location(in: self)
            let zone = zone(at: point)
            let key = key(for: touch)
            if touchZones[key] != zone {
                touchZones[key] = zone
                strike(zone: zone, at: point)
            }
        }
    }

    override func touchesEnded(with event: NSEvent) {
        for touch in event.touches(matching: .ended, in: self) {
            touchZones.removeValue(forKey: key(for: touch))
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        for touch in event.touches(matching: .cancelled, in: self) {
            touchZones.removeValue(forKey: key(for: touch))
        }
    }

    // MARK: Mouse (trackpad testing, and the compatibility events a finger also produces)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let zone = zone(at: point)
        mouseZone = zone
        strike(zone: zone, at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let zone = zone(at: point)
        if mouseZone != zone {
            mouseZone = zone
            strike(zone: zone, at: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        mouseZone = nil
    }

    // MARK: Striking

    private func zone(at point: CGPoint) -> Int {
        NoteZone.zone(at: point, in: bounds.size, orientation: orientation)
    }

    private func key(for touch: NSTouch) -> NSObject {
        (touch.identity as? NSObject) ?? NSNumber(value: ObjectIdentifier(touch.identity).hashValue)
    }

    private func strike(zone: Int, at point: CGPoint) {
        let now = CACurrentMediaTime()
        recentStrikes.removeAll { now - $0.time > duplicateWindow }
        if recentStrikes.contains(where: { hypot($0.point.x - point.x, $0.point.y - point.y) < duplicateDistance }) {
            return
        }
        recentStrikes.append((point, now))

        showGlow(at: point, color: NoteZone.color(for: zone))
        delegate?.overlayView(self, didStrikeZone: zone, at: point)
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

        let scale = window?.backingScaleFactor ?? 2
        let lines = CAShapeLayer()
        lines.frame = guidesLayer.bounds
        lines.contentsScale = scale
        lines.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        lines.lineWidth = 1
        lines.shadowColor = NSColor.white.cgColor
        lines.shadowOpacity = 0.5
        lines.shadowRadius = 2
        lines.shadowOffset = .zero

        let path = CGMutablePath()
        for i in 1..<NoteZone.count {
            let fraction = CGFloat(i) / CGFloat(NoteZone.count)
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

        for i in 0..<NoteZone.count {
            let label = CATextLayer()
            label.contentsScale = scale
            label.string = NoteZone.names[i]
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.fontSize = 13
            label.alignmentMode = .center
            label.foregroundColor = NoteZone.color(for: i).withAlphaComponent(0.8).cgColor
            let size = CGSize(width: 36, height: 18)
            switch orientation {
            case .vertical:
                let zoneHeight = bounds.height / CGFloat(NoteZone.count)
                label.frame = CGRect(x: 10, y: zoneHeight * CGFloat(i) + 8, width: size.width, height: size.height)
                label.alignmentMode = .left
            case .horizontal:
                let zoneWidth = bounds.width / CGFloat(NoteZone.count)
                label.frame = CGRect(x: zoneWidth * CGFloat(i) + (zoneWidth - size.width) / 2, y: 10, width: size.width, height: size.height)
            }
            guidesLayer.addSublayer(label)
        }
    }
}
