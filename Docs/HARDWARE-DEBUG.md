# Debugging Music Touch on the touchscreen MacBook Pro

Written 2026-11-09 for a Claude Code session running **on the MacBook Pro with Touchscreen PROLED
XDR Display**, where the bugs below reproduce. The app was developed on a Mac Studio without a
touchscreen, where clicks and drags work and the audio engine runs, so none of this could be
reproduced there. Build, run and watch the log here while Stephen taps the screen.

## What Stephen sees

| Version | Touching the screen | Clicking with the mouse |
| --- | --- | --- |
| 1.0 | Nothing (no ring, no sound). | Plays. |
| 1.0.1 | Only the **top** zone (highest note) rings and plays. Same in horizontal mode: only the rightmost zone. Lower zones do nothing at all. | Plays. |
| 1.0.2 | Nothing: no rings anywhere. | Rings appear, but **no sound**. |

The lid-logo blink also lags: the logo takes a while to go dark and come back. The app's own path
(FIFO → root daemon → `defaults write`) is fast; the system's own fade is probably what lags.
1.0.2 added a Blink length slider so the dark interval can be tuned to the fade.

## What changed between versions

- 1.0 → 1.0.1: direct touches handled by `DirectTouchRecognizer` (an `NSGestureRecognizer`
  subclass with `allowedTouchTypes = .direct`) in `Music Touch/OverlayView.swift`, because
  macOS 27 delivers finger touches only through gesture recognizers (Apple TN3212). Zone from
  `touch.location(in: view)`. `PianoEngine` now pins the output node to the system default
  output device with `auAudioUnit.setDeviceID` and rebinds on default-device changes. Sparkle
  added to the direct-download target only.
- 1.0.1 → 1.0.2: zone from `touch.normalizedPosition` scaled to the overlay bounds (fallback
  `location(in:)`), "Last touch" raw-coordinate line in Settings › Status, Blink length slider.
- After 1.0.2 (uncommitted → this commit): info/error logging at the recognizer entry, in
  `mouseDown`, and around audio engine start / play, so the log shows which path runs.

## How to observe

Build and run the Developer ID flavour (Sparkle, unsandboxed) from this checkout. Quit the
installed copy first (menu bar → Quit Music Touch), since two copies fight over the overlay.

```bash
xcodebuild -project "Music Touch.xcodeproj" -scheme "Music Touch" -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/dev build CODE_SIGN_IDENTITY="-" 2>&1 | grep -E "error:|BUILD"
open "build/dev/Build/Products/Debug/Music Touch.app"
```

Watch the log (note `/usr/bin/log`: in zsh, `log` is a builtin):

```bash
/usr/bin/log stream --predicate 'subsystem == "fm.beard.MusicTouch"' --level debug --style compact
```

Then turn Music Touch on (⌃⌥⌘M) and have Stephen tap each zone, then click with the mouse. Expect:

- `recognizer touchesBegan: N touches …` for each finger-down. **If this never appears, direct
  touches are not reaching the recognizer at all**, and the top-zone behaviour in 1.0.1 was
  something else (see hypotheses).
- `touch zone … view (x, y) · window (x, y) · normalized (u, v) · bounds W×H · panel …` for each
  finger-down. Compare the three coordinate spaces against the bounds. The same line is shown in
  Settings › Status under "Last touch".
- `mouseDown subtype S at (x, y) in bounds W×H, echo E` for clicks, and for the click macOS
  synthesizes from a tap in apps it does not consider touch-native. `echo true` means the click
  was dropped as a duplicate of a finger.
- `strike zone … via Touch|Click`, then sound. If `play ignored: engine running false …` appears,
  the audio engine is not running: look for `audio engine failed to start` or `could not select
  the default output device`.

Settings › Status (menu bar → Settings…) also shows Touchscreen detected, Audio engine, Audio
output and Last input without the log.

## Hypotheses, most likely first

1. **Touches never reach the recognizer.** The overlay is a borderless, non-activating `NSPanel`
   at window level 23 (just under the menu bar) that can never become key
   (`OverlayPanel.canBecomeKey` is false). Direct-touch routing may require a key window, a
   normal window level, or a regular `NSWindow`. Try, one at a time: let the panel become key
   and `makeKeyAndOrderFront`; drop the level to `.floating` or `.normal`; use `NSWindow` instead
   of `NSPanel`; add `NSIsTouchNative = YES` to `Config/Info.plist` (declares the app handles
   touches itself, which also turns off the synthesized click).
2. **1.0.1's top-zone-only behaviour came from synthesized clicks**, not touches, with a
   `locationInWindow` outside the overlay bounds that clamped to the highest zone. The new
   `mouseDown` log line shows the subtype and coordinates. If the taps show up as `mouseDown`
   with out-of-range coordinates, map them from `NSEvent.mouseLocation` (screen coordinates)
   converted into the window instead of `locationInWindow`.
3. **Normalized position is not populated for direct touches** (always 0,0 or garbage), which
   would explain 1.0.2 showing no rings if the points land off-screen; the "Last touch" line
   settles it. Fall back to whichever space matches the bounds.
4. **Audio engine not running on this machine** since 1.0.1 pinned the output device. Check the
   start/fail log lines. If `setDeviceID` is the problem, stop calling it (remove
   `bindToDefaultOutputDevice()` from `PianoEngine.start()` and the device-change handler, keep
   the engine restart) and let AVAudioEngine follow the default output on its own.

## Rules

- Do not run `Tools/archive-appstore.sh`, `xcodebuild archive`, `-exportArchive` or any upload to
  App Store Connect or TestFlight; Stephen asks for that explicitly each time.
- Shipping a fix to the direct download is `Tools/release.sh --notarize --upload` (it needs the
  Developer ID certificate and the Sparkle key, account `musictouch`, which live on the Mac
  Studio), then commit and push `~/Movies/Apps/beardfm.app`, then push this repo and
  `gh release create vX.Y.Z dist/Music-Touch-X.Y.Z.dmg`. If this Mac lacks those, hand the
  diagnosis back to the Mac Studio session instead. Bump `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` in both targets and add `release-notes/<version>.html` first.
