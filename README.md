# KnockSense

Knock on your Mac to make it do things. Knock twice to play or pause music, three times to open
Mission Control, or knock on the lid to lock the screen. Every action is up to you.

KnockSense is a small menu-bar app (look for the ✋ icon) for macOS 13 Ventura or later.

## Download

Get **KnockSense.zip** from the repository's [Releases](../../releases/latest) page. Unzip it and
drag `KnockSense.app` into Applications.

macOS blocks apps that aren't from the App Store or a registered developer the first time you open
them. To get past that once:

* Right-click `KnockSense.app` → **Open** → **Open**, or
* if there's no Open button: **System Settings ▸ Privacy & Security**, scroll down, click
  **Open Anyway**.

Or remove the download flag in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/KnockSense.app
```

## Updating

Click the menu-bar icon → **Check for Updates**. If a newer build exists, KnockSense downloads it,
checks it against the published SHA-256 checksum, replaces itself and restarts. It also checks
quietly every few hours and shows **Install Update** in the menu when one is ready (turn this off in
Settings ▸ General ▸ Updates).

For this to work, KnockSense must be in a folder it can write to, such as Applications. It can't
update an app opened straight from Downloads. Because builds are signed locally ("ad-hoc"), macOS
may ask for microphone access again after an update, and you may need to switch KnockSense off and on
under Accessibility.

## Build and install from source

You need Apple's Swift tools. If you don't have Xcode, install the free Command Line Tools:

```bash
xcode-select --install
```

Then, in this folder:

```bash
./build.sh --install
```

That compiles the app, copies `KnockSense.app` into `/Applications` and starts it.
(`./build.sh --run` builds into `./build` and starts it without installing.)

On first launch macOS asks for **microphone** access. Click Allow.

## Using it

1. **Knock twice** on the palm rest next to the trackpad. The menu-bar icon flashes on each knock
   and your music plays or pauses.
2. Open **Settings…** from the menu-bar icon:
   - **Actions:** add, edit, test or turn off rules. A rule is *knock N times (anywhere / on an
     area) → do something*. Available actions:
     - Built-ins: play/pause, next/previous track, volume up/down, mute, lock screen, sleep display,
       screenshot (to the clipboard, a dragged area to the clipboard, or saved to the Desktop),
       Mission Control, test notification
     - Open any app, website or file
     - Run a shell command, an AppleScript or a Shortcut from the Shortcuts app
   - **Areas:** teach KnockSense the spots you knock on (left palm rest, right palm rest, lid…) so
     each spot can do something different. Add an area, click **Train**, then knock 6 times on that
     spot. Turn on **Test mode** to check which area it detects. The **self-test accuracy** score
     shows how well your spots can be told apart.
   - **General:** sensitivity, the time allowed between knocks, sounds, permissions and launch at
     login.

### Permissions

| Permission | Why | When |
|---|---|---|
| Microphone | Hearing the knocks | Always required |
| Accessibility | Media keys (play/pause, next/previous) and Lock screen | Only if you use those actions |
| Automation ("System Events") | Lock screen and AppleScript actions | macOS asks the first time |
| Screen Recording | Screenshot action | macOS asks the first time |

Accessibility is granted in **System Settings ▸ Privacy & Security ▸ Accessibility**. The General
tab has a shortcut button. Because the app is signed locally ("ad-hoc"), macOS may ask for
permissions again after you rebuild it.

## Stopping false triggers (doors, claps, footsteps)

* **Teach my knock** (Settings ▸ General, or the tip in the menu): knock 8 times. KnockSense then only
  reacts to sounds that match your knock's tone, and ignores sounds that are much quieter than your
  knocks. A door across the room is both different-sounding and far quieter at the mic than a knuckle
  on the case.
* **Patterns must sound alike:** a door's latch click followed by the slam produces two sharp sounds
  close together, which looks like a double knock. But the two sounds are very different, while your
  two knocks sound the same, so patterns like that are ignored. This needs no setup.
* **That wasn't me:** if something still sets it off, click **That wasn't me** in the menu (shown
  for a minute after an action runs) and sounds like that are ignored from then on.

## Motion-sensor mode (beta)

On Apple Silicon MacBooks (M2 or newer) KnockSense can feel knocks through the built-in motion
sensor instead of listening. Doors, voices and music can't trigger it, and the microphone stays off.

Settings ▸ General ▸ **Sense knocks with: Motion sensor**, then **Install Helper…** and enter your
admin password once. Apple has no public API for this sensor, so a small helper
(`/Library/PrivilegedHelperTools/com.knocksense.imu`, run by launchd as root) reads it and streams the
readings to KnockSense over `/var/run/knocksense-imu.sock`. The sensor is only switched on while
KnockSense is connected. **Remove Helper…** uninstalls it. The interface is undocumented and could
change in a future macOS update; if it stops working, switch back to the microphone.

Areas work in this mode too: knocks on different spots push the Mac in different directions.

## How it works

The Apple Silicon MacBook motion sensor has no public API. Reading it needs root and undocumented
hardware interfaces. KnockSense uses the **built-in microphones** instead. A knock travels through
the aluminium case straight to the mics and makes a short, sharp sound that is easy to tell apart
from speech or music. This works on every Mac model without admin rights.

```
mic audio ─▶ KnockDetector ─▶ FeatureExtractor ─▶ ZoneClassifier ─▶ PatternGrouper ─▶ RuleMatcher ─▶ ActionRunner
             (onset + fast    (spectral shape,     (k-nearest        (1, 2, 3, 4       (area rule
              decay check)     inter-mic cues)      neighbours)       knocks)           beats "anywhere")
```

* **Detection:** the audio is analysed in frames of about 5 ms, in the full band and in four
  frequency bands at once. A frame is a knock onset when, in some band, it is much louder than
  that band's background (the median of the last 0.3 s) *and* several times louder than anything in
  the previous 20 ms. Then, 20 to 50 ms later, the sound must have died away, or fallen back to what
  was playing just before the knock. Knocks fade within about 15 ms; words, notes and fans don't.
* **Knocking during a movie or music:** the soundtrack comes out of the speakers and into the mic.
  Soundtracks are mostly low and mid frequencies, while a knock is a sharp broadband click. So the
  knock still stands out in the bands the soundtrack leaves quieter, and the "back to what was
  playing" check accepts knocks on top of ongoing sound. In tests with simulated film audio, all
  knocks are caught at normal volume, nearly all at loud volume, and dialogue and music cause no
  false triggers.
* **Areas:** each knock is turned into a fingerprint: 16 frequency bands, brightness, decay speed,
  and the level and timing differences between the built-in microphones. It is then matched
  against your training knocks.
* **Patterns:** knocks less than the "max time between knocks" apart are grouped. If no rule uses
  more knocks than you've already made, the action fires right away with no waiting.
* **False alarms:** knocks within 0.35 s of a key press or trackpad click are ignored. This uses
  `CGEventSource` idle time and needs no permission. The app's own feedback sound is also ignored.

**Privacy:** audio is processed in memory, in real time, on your Mac. Nothing is recorded, saved or
sent anywhere. macOS shows the orange microphone dot while KnockSense is listening. Pause it from
the menu at any time.

## Tips

* Knock with a knuckle, firmly. If knocks are missed, raise **Sensitivity**. If random noises
  trigger actions, lower it.
* Double and triple knocks are much more reliable than single knocks.
* Area detection works best when the spots are far apart and on different parts of the case
  (palm rest vs. lid vs. bottom). Train with the Mac where you normally use it.
* Area training is tied to the current microphone. If you switch to an external mic, retrain.
* KnockSense always listens through the Mac's built-in microphone, even when AirPods or a headset
  are connected (their mics can't hear knocks on the Mac). You can turn this off in General.
* During a very loud movie, knock a bit firmer, or raise the sensitivity one notch.

## Project layout

```
Package.swift
Sources/KnockCore/        platform-independent signal processing + data model (unit-tested)
  KnockDetector.swift       streaming knock detector
  Features.swift            fingerprint extraction, FFT
  Patterns.swift            area classifier, pattern grouping, rule matching
  Models.swift              rules, actions, areas, config (Codable)
Sources/KnockSense/       the macOS app (SwiftUI menu-bar app)
  KnockSenseApp.swift       entry point, menu bar, settings window
  AppState.swift            wires everything together, persistence
  AudioPipeline.swift       AVAudioEngine microphone capture
  ActionRunner.swift        runs actions, permissions helpers
  Views/                    menu, actions, areas and general settings UI
Tests/KnockCoreTests/     tests with synthetic knock / speech audio
Resources/                Info.plist, app icon (AppIcon.svg is the editable source; AppIcon.png is rendered from it)
build.sh                  builds KnockSense.app
```

Run the tests with `swift test`. Settings are stored in
`~/Library/Application Support/KnockSense/config.json`.

To rename the app or use your own bundle ID, edit `Resources/Info.plist` (`CFBundleIdentifier`,
`CFBundleName`).
