# Music Touch

A free Mac menu bar utility that turns the touchscreen on the MacBook Pro with PROLED XDR Display
into a piano. Turn it on and the whole screen becomes nine note zones playing the C major scale from
middle C (C4) up to the D above the octave (D5). Touch anywhere to play, use several fingers for a
chord, or slide across the zones for a glissando. Every touch sends out a glowing ring in that note's
colour.

- **Menu bar only.** No Dock icon. Toggle it from the menu or anywhere with ⌃⌥⌘M.
- **Nine zones, one scale.** C4 D4 E4 F4 G4 A4 B4 C5 D5, bottom to top, or left to right in
  horizontal mode. Optional separator lines with note names.
- **A soft piano.** The system's General MIDI grand piano, mellowed with a low-pass filter and a
  long hall reverb. Each zone has its own sampler so notes fade independently; the note length is
  adjustable in Settings.
- **Lid logo pulse.** On a MacBook Pro with the illuminated Apple logo, the logo can go dark while
  Music Touch is on and light up with each note (direct-download version only, see below).
- **Blocks the screen while on.** The overlay sits above every window and the Dock, just under the
  menu bar, so a touch never lands in the app underneath. Turn Music Touch off to get back to work.
- Works with a mouse or trackpad too, so it runs on any Mac with macOS 26 or later.

Nothing is collected or sent anywhere. There is no account, no analytics and no network access.

## Install

- **Free download** (recommended): [beardfm.app/music-touch](https://beardfm.app/music-touch/).
  Signed and notarized. This version can install the lid-logo helper.
- **Mac App Store**: the same app, sandboxed, without the lid-logo helper (the sandbox doesn't allow
  installing a launch daemon).

## How the lid logo pulse works

macOS exposes exactly one control for the lid logo: the `LEBacklightMode` preference in the root
`com.apple.CoreBrightness` domain, documented in
[Apple's support article](https://support.apple.com/en-us/149248). Writing it needs root, so
Settings › Apple Logo › Install Helper… installs a tiny launch daemon (with your administrator
password, once). It listens on a named pipe at `/Users/Shared/MusicTouch/logo-control` for the words
`on` and `off` and flips that preference. The app keeps the logo dark while it is on and lights it
for each note, and always restores it when Music Touch is turned off or quits. Uninstall Helper…
removes everything and restores the logo.

## Building

Open `Music Touch.xcodeproj` in Xcode 27 or later and run. The project has no dependencies.

- `Tools/release.sh [--notarize] [--upload]` builds a Release app signed with Developer ID, packages
  a DMG, and optionally notarizes it and copies it into the beardfm.app site checkout.
- `Tools/archive-appstore.sh` archives the sandboxed App Store build and uploads it to App Store
  Connect. `Tools/appstore.mjs` fills in the listing from `AppStore/metadata.md`, uploads the
  screenshots in `AppStore/screenshots`, attaches the build and submits for review.
- `swift Tools/make-icon.swift` regenerates the app icon from code.

## Project layout

| File | What it does |
| --- | --- |
| `MusicTouchApp.swift` | App entry, menu bar menu, Settings scene |
| `AppState.swift` | Settings persistence and the on/off state; wires overlay, audio, logo and hotkey together |
| `OverlayController.swift` | The full-screen, non-activating panel over the touchscreen |
| `OverlayView.swift` | Direct-touch and mouse handling, glissando tracking, rings and separator lines |
| `NoteZone.swift` | Zone geometry, MIDI notes, note names and colours |
| `PianoEngine.swift` | AVAudioEngine graph: nine samplers, low-pass, reverb, per-zone fades |
| `LidLogoController.swift` | Lid logo state machine and the privileged helper installer |
| `GlobalHotKey.swift` | Carbon hot key for ⌃⌥⌘M |
| `SettingsView.swift` | The Settings window |

## License

MIT. See [LICENSE](LICENSE).
