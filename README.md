# Islet

A tiny, free and open-source notch island and system monitor for Mac developers.

- **Notch island**: live CPU and temperature beside the notch. Hover to open it: album art and play/pause/skip for Apple Music and Spotify, plus ring gauges for CPU, memory, temperature, disk and network. Alerts and other apps' notifications pop out of the notch. On Macs without a notch it appears at the top center of the screen.
- **Menu bar stats**: CPU, memory, temperature (°C), network speed and free disk as compact items in a row, like Battery and Wi-Fi. Switch each one on or off, and ⌘-drag to reorder.
- **Developer cleanup**: finds build output you can safely delete (`build`, `.dart_tool`, `node_modules`, `Pods`, `.gradle`, `.cxx`, `.next`, `__pycache__`, `.apk`, `.aab`, `.ipa`) plus tool caches (DerivedData, Gradle, npm, CocoaPods, SwiftPM), and moves them to the Trash.
- Open at login.

Native Swift and SwiftUI, no dependencies. The universal app is under 1 MB.

## Requirements

macOS 14 Sonoma or later. Temperature in °C needs Apple Silicon; Intel Macs show the thermal state instead.

## Build and run

```bash
swift run                 # quick dev run
./scripts/bundle.sh       # build/Islet.app: universal, hardened runtime, ad-hoc signed
open build/Islet.app
swift test                # core logic tests
```

## Permissions

| Feature | Permission | When it's asked |
|---|---|---|
| Music controls and album art | Automation for Music/Spotify | The first time Islet talks to the player |
| Other apps' notifications | Accessibility | When you turn the setting on (off by default) |

Ad-hoc builds get a new signature each time you rebuild, so macOS may ask for Accessibility again. A Developer ID signed build keeps it.

## How cleanup stays safe

A folder only counts as build output when its parent is a real project. For example, `build` is only removed when it sits next to `pubspec.yaml`, `build.gradle`, `package.json` and similar files, so a source folder that happens to be named `build` is never touched. Islet never looks inside `.git` and never follows symlinks. Tool caches are listed but not preselected, because deleting them means your next build downloads everything again. Everything goes to the Trash, so you can undo it.

## Distribution

Islet is distributed directly (signed and notarized), not through the Mac App Store. Reading CPU temperatures uses IOKit functions that aren't in Apple's public headers, and mirroring notifications needs Accessibility, which App Store apps can't use. To make a release:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/bundle.sh
ditto -c -k --keepParent build/Islet.app build/Islet.zip
xcrun notarytool submit build/Islet.zip --keychain-profile <profile> --wait
xcrun stapler staple build/Islet.app
```

## Known limits

- Now playing covers Apple Music and Spotify. Browsers (YouTube and others) need Apple's private MediaRemote framework, which macOS 15.4 and later lock to Apple's own apps.
- The notifications mirror reads banners through Accessibility, so a macOS update that changes the banner layout can break it until Islet is updated.
- On notched Macs, macOS hides menu bar items that don't fit next to the notch. Turn off metrics you don't need, or ⌘-drag them.

## Project layout

```
Sources/IsletCore   stats, temperature, network and cleanup scanner (no UI, unit tested)
Sources/Islet       app: menu bar items, notch island, dashboard, models
Resources           Info.plist and entitlements
scripts/bundle.sh   builds Islet.app
```

## License

MIT
