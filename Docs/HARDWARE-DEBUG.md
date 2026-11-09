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

## Findings (2026-11-09, on the MacBook Pro)

Worked through with the Debug build of this checkout; every item below was confirmed in the log
and by Stephen tapping the screen.

1. **1.0.2's "no rings anywhere" was an exception, not routing.** Direct touches do reach
   `DirectTouchRecognizer` (`recognizer touchesBegan` logged for every finger). But reading
   `NSTouch.normalizedPosition` on a direct touch raises `NSInternalInconsistencyException`
   (assertion in `NSTouch.m:82`, visible as an AppKit `FAULT` in `log show`). AppKit swallows
   it, so the handler never reached the zone, ring or strike code. Hypothesis 3 was right about
   the property, wrong about the symptom: it does not return garbage, it throws. `deviceSize` is
   the same class of trackpad-only property. Neither is read for `.direct` touches any more.
2. **`touch.location(in: view)` is correct on this hardware.** With the exception gone, all 18
   test taps (9 per orientation) resolved to the right zone from the touch's own location; the
   event's `locationInWindow` matched it exactly, and `NSEvent.mouseLocation` did not move with
   the finger (no synthesized click arrived while the recognizer handled the touch). The mapping
   keeps the window and pointer spaces as fallbacks for displays that report differently, and the
   "Last touch" line names the space that was used.
3. **"Only the highest note plays" and "rings but no sound" were the audio graph.** The nine
   samplers were connected straight to the `AVAudioUnitEQ`, which has one input bus, so each
   connection replaced the previous one and only zone 8's sampler stayed wired. The engine was
   running the whole time (no `play ignored` lines). An `AVAudioMixerNode` now sums the samplers
   before the EQ. Hypothesis 4 (`setDeviceID`) was not the cause; the device pin stays.
4. **Lid logo pulse was inverted from what Stephen wants.** The logo now rests dark while Music
   Touch is on with pulsing enabled, lights on each note, and is left lit when Music Touch is
   turned off or quits.
5. **The logo does not fade; the "lag" was dropped pipe writes.** The app gave up writing to the
   helper's pipe after ~120 ms, but the helper is often busy in `defaults` for longer than that,
   so an "off" could be lost and the logo stayed lit until the next note. Writes now wait up to a
   second. With that fixed the logo switches instantly and abruptly. `corebrightnessd`'s log
   (`subsystem CONTAINS "CBLE"`, category `bklb-backlight`) shows why: the logo is a PWM
   backlight whose nits follow the display brightness and ambient light, and `LEBacklightMode`
   is the only preference the mode store reads (`mode 0; from defaults` = off, `mode 2; from
   NVRAM` = normal). Mode 0 is applied as "Setting PWM to: OFF (duty cycle 0)" with the ramp
   completing at once, so off never fades. The module does own ramps, but only for its own
   transitions: a sleep/wake factor fade (0.14–0.28 s), a rate limiter that occasionally eases
   a large rise (the fade-in Stephen sometimes sees after "on"), and ambient-light restriction
   ramps. The other keys it reads (`LEPWMFollowFallRateTable`, `LEPWMRestrictionFallDuration`,
   `LEPWMLuxToMaxNitsRestrictionMapping`, …) are undocumented brightness-policy tables loaded
   at daemon start, so a fade could only be faked by rewriting system brightness policy per
   note. Not worth it. The pulse follows the note's envelope instead: lit through the note's
   hold (40% of the Note length), off as the note starts to fade. The Blink length slider from
   1.0.2 is gone, since it tuned a fade that does not exist.
6. **A trackpad click on the overlay stopped screen touches.** WindowServer kept dispatching
   touchscreen contacts, but after one trackpad click on the overlay none reached the
   recognizer, and AppKit's Gestures framework later logged a touch sequence stuck in one phase
   for 40 s followed by "Marking view as no longer exclusive". The click (a mouse event with the
   touch subtype) entered the recognizer's gesture environment and the sequence never closed,
   since the trackpad's finger-lift is an indirect touch the overlay does not accept, so the
   view stayed exclusive and direct touches were dropped. The recognizer's delegate now declines
   every event that is not a direct-touch event; mouse events still reach `mouseDown`. Verified
   with tap, click, tap: the later taps play.

Not reproduced here: 1.0.1's top-zone-only ring. The window/level/key-window ideas in hypothesis
1 were not needed; the non-activating `NSPanel` at level 23 receives direct touches as is.

## Hand-off to the Mac Studio (2026-11-09)

Everything above is fixed and committed, with Settings › Key (root, major/minor, 8–12 zones) and
a resizable Settings window added on top. Version is bumped to 1.1.0 (build 4) in both targets,
`release-notes/1.1.0.html` and the App Store "What's New" are written, and `Tools/appstore.mjs`
now takes its version from the project and has a `withdraw` command that cancels the pending
review submission. This MacBook Pro has no Developer ID certificate, Sparkle key, notarytool
profile, App Store Connect key, beardfm.app checkout, `gh` or `node`, so the release itself runs
on the Mac Studio:

```bash
git pull
Tools/release.sh --notarize --upload
(cd ~/Movies/Apps/beardfm.app && git add -A && git commit -m "Music Touch 1.1.0" && git push)
gh release create v1.1.0 "dist/Music Touch 1.1.0.dmg" --title "Music Touch 1.1.0" --notes-file release-notes/1.1.0.html
node Tools/appstore.mjs withdraw     # pulls 1.0.2 out of review (Developer Rejected)
Tools/archive-appstore.sh            # archives and uploads build 4
node Tools/appstore.mjs metadata     # What's New for 1.1.0, renames the editable version
node Tools/appstore.mjs attach       # once build 4 shows as processed (status)
node Tools/appstore.mjs submit
```

## Rules

- Do not run `Tools/archive-appstore.sh`, `xcodebuild archive`, `-exportArchive` or any upload to
  App Store Connect or TestFlight; Stephen asks for that explicitly each time.
- Shipping a fix to the direct download is `Tools/release.sh --notarize --upload` (it needs the
  Developer ID certificate and the Sparkle key, account `musictouch`, which live on the Mac
  Studio), then commit and push `~/Movies/Apps/beardfm.app`, then push this repo and
  `gh release create vX.Y.Z dist/Music-Touch-X.Y.Z.dmg`. If this Mac lacks those, hand the
  diagnosis back to the Mac Studio session instead. Bump `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` in both targets and add `release-notes/<version>.html` first.
