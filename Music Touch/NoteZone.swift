import AppKit

/// Which way the nine note zones run across the screen.
enum ZoneOrientation: String, CaseIterable, Identifiable {
    case vertical
    case horizontal

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .vertical: "Vertical (low notes at bottom)"
        case .horizontal: "Horizontal (low notes at left)"
        }
    }
}

/// The C major scale from middle C up to the D above the octave, one zone each.
enum NoteZone {
    static let count = 9

    /// MIDI note numbers, zone 0 first (C4 … D5).
    static let midiNotes: [UInt8] = [60, 62, 64, 65, 67, 69, 71, 72, 74]

    static let names = ["C4", "D4", "E4", "F4", "G4", "A4", "B4", "C5", "D5"]

    /// One colour per note, warm at the bottom of the scale and cool at the top.
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.25, alpha: 1), // C4  sunny yellow
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.20, alpha: 1), // D4  orange
        NSColor(srgbRed: 1.00, green: 0.36, blue: 0.36, alpha: 1), // E4  coral red
        NSColor(srgbRed: 0.38, green: 0.86, blue: 0.42, alpha: 1), // F4  green
        NSColor(srgbRed: 0.20, green: 0.80, blue: 0.78, alpha: 1), // G4  teal
        NSColor(srgbRed: 0.33, green: 0.62, blue: 1.00, alpha: 1), // A4  sky blue
        NSColor(srgbRed: 0.45, green: 0.42, blue: 0.98, alpha: 1), // B4  indigo
        NSColor(srgbRed: 0.72, green: 0.42, blue: 0.98, alpha: 1), // C5  violet
        NSColor(srgbRed: 0.98, green: 0.45, blue: 0.80, alpha: 1), // D5  pink
    ]

    static func color(for zone: Int) -> NSColor {
        colors[max(0, min(count - 1, zone))]
    }

    static func midiNote(for zone: Int) -> UInt8 {
        midiNotes[max(0, min(count - 1, zone))]
    }

    /// Maps a point (AppKit coordinates, origin bottom-left) to a zone index.
    static func zone(at point: CGPoint, in size: CGSize, orientation: ZoneOrientation) -> Int {
        let fraction: CGFloat
        switch orientation {
        case .vertical:
            fraction = size.height > 0 ? point.y / size.height : 0
        case .horizontal:
            fraction = size.width > 0 ? point.x / size.width : 0
        }
        let index = Int((fraction * CGFloat(count)).rounded(.down))
        return max(0, min(count - 1, index))
    }
}
