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

/// The twelve roots a scale can start on, as semitones above C.
enum KeyRoot: Int, CaseIterable, Identifiable {
    case c = 0, cSharp, d, eFlat, e, f, fSharp, g, aFlat, a, bFlat, b

    var id: Int { rawValue }

    private static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    private static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

    /// Whether this key is written with flats in the given mode (B♭ major, C minor…) or sharps.
    /// Decided from the key signature: a minor key shares its relative major's. F♯ major and
    /// E♭ minor are the conventional spellings of the six-accidental key.
    func usesFlats(in mode: ScaleMode) -> Bool {
        let majorRoot = (rawValue + (mode == .minor ? 3 : 0)) % 12
        switch majorRoot {
        case 1, 3, 5, 8, 10: return true
        case 6: return mode == .minor
        default: return false
        }
    }

    /// Spelled name of a pitch class in this key, such as "B♭" in F major or "A♯" in B major.
    func spell(pitchClass: Int, in mode: ScaleMode) -> String {
        (usesFlats(in: mode) ? Self.flatNames : Self.sharpNames)[((pitchClass % 12) + 12) % 12]
    }

    /// The key's name as written in the given mode, such as "D♭" or "C♯".
    func name(in mode: ScaleMode) -> String { spell(pitchClass: rawValue, in: mode) }

    /// MIDI note of the scale's first zone. Roots from G up start below middle C so every key
    /// sits in the same comfortable range (G3 to G5) instead of climbing with the root.
    var midiNote: UInt8 { UInt8(rawValue >= 7 ? 48 + rawValue : 60 + rawValue) }
}

/// Major or natural minor.
enum ScaleMode: String, CaseIterable, Identifiable {
    case major
    case minor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .major: "Major"
        case .minor: "Minor"
        }
    }

    /// Semitone steps of the seven scale degrees above the root.
    var intervals: [Int] {
        switch self {
        case .major: [0, 2, 4, 5, 7, 9, 11]
        case .minor: [0, 2, 3, 5, 7, 8, 10]
        }
    }
}

/// The notes the zones play: a key's scale from the root upwards, one zone per scale degree.
struct Scale: Equatable {
    var root: KeyRoot
    var mode: ScaleMode
    /// How many zones share the screen: 8 is one octave (root to root), up to 12 (to the twelfth).
    var degrees: Int = Scale.defaultDegrees {
        didSet { degrees = min(max(degrees, Self.degreeRange.lowerBound), Self.degreeRange.upperBound) }
    }

    static let defaultDegrees = 9
    static let degreeRange = 8...12
    static let `default` = Scale(root: .c, mode: .major)

    /// MIDI note numbers, zone 0 first.
    var midiNotes: [UInt8] {
        let steps = mode.intervals
        return (0..<degrees).map { zone in
            let octave = zone / steps.count
            return root.midiNote + UInt8(steps[zone % steps.count] + 12 * octave)
        }
    }

    /// Spelled note names with octave numbers, zone 0 first, such as "F♯4".
    var names: [String] {
        midiNotes.map { note in
            let n = Int(note)
            return root.spell(pitchClass: n % 12, in: mode) + String(n / 12 - 1)
        }
    }

    /// "D major", "F♯ minor".
    var title: String { "\(root.name(in: mode)) \(mode.rawValue)" }

    /// "One octave", "9 notes"…, for the Settings picker.
    static func degreesLabel(_ count: Int) -> String {
        count == 8 ? "One octave (8 notes)" : "\(count) notes"
    }
}

/// The note zones across the screen. How many there are, and which notes they play, is a `Scale`.
enum NoteZone {
    /// Colour stops from the bottom of the scale (warm) to the top (cool); zones take evenly
    /// spaced points along this sweep, so any zone count gets the same warm-to-cool run.
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

    /// The colour of zone `zone` out of `count`: a point along the sweep, blended between the
    /// two nearest stops.
    static func color(for zone: Int, of count: Int) -> NSColor {
        guard count > 1 else { return colors[0] }
        let position = CGFloat(max(0, min(count - 1, zone))) / CGFloat(count - 1) * CGFloat(colors.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, colors.count - 1)
        let fraction = position - CGFloat(lower)
        guard fraction > 0.001, lower != upper else { return colors[lower] }
        return colors[lower].blended(withFraction: fraction, of: colors[upper]) ?? colors[lower]
    }

    /// Maps a point (AppKit coordinates, origin bottom-left) to a zone index out of `count`.
    static func zone(at point: CGPoint, in size: CGSize, orientation: ZoneOrientation, count: Int) -> Int {
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
