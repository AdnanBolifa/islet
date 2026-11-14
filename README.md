# Islet

A tiny, free and open-source menu bar companion for Mac developers.

- **Notch island**: hover the notch to see what's playing and live system stats. Alerts (memory almost full, Mac running hot, cleanup done) pop out of the notch. On Macs without a notch it appears at the top center of the screen.
- **System monitor**: CPU, memory (with swap), free disk and thermal state, refreshed every 2 seconds.
- **Developer cleanup**: finds build output you can safely delete (`build`, `.dart_tool`, `node_modules`, `Pods`, `.gradle`, `.cxx`, `.next`, `__pycache__`, `DerivedData`, `.apk`, `.aab`, `.ipa`) and moves it to the Trash.

Native Swift and SwiftUI, no dependencies. The universal app is under 1 MB.

## Requirements

macOS 14 Sonoma or later.

## Build and run

```bash
swift run                 # quick dev run (no sandbox)
./scripts/bundle.sh       # build/Islet.app: universal, sandboxed, ad-hoc signed
open build/Islet.app
swift test                # core logic tests
```

## How cleanup stays safe

A folder only counts as build output when its parent is a real project. For example, `build` is only removed when it sits next to `pubspec.yaml`, `build.gradle`, `package.json` and similar files, so a source folder that happens to be named `build` is never touched. Islet never looks inside `.git` and never follows symlinks. Everything goes to the Trash, so you can undo it.

## Limits (App Store rules)

Islet only uses public APIs so it can ship on the Mac App Store:

- **Temperature**: macOS has no public API for sensor temperatures, so Islet shows the system's thermal state (Normal, Warm, Hot, Critical) instead.
- **Now playing**: works with Apple Music and Spotify through their public track-change broadcasts. Playback controls and other apps' notifications need private APIs, so they aren't included.
- **Cleanup**: the sandbox only allows folders you choose. Islet remembers them between launches.

## Project layout

```
Sources/IsletCore   system stats and cleanup scanner (no UI, unit tested)
Sources/Islet       app: menu bar dashboard, notch island, models
Resources           Info.plist and sandbox entitlements
scripts/bundle.sh   builds Islet.app
```

## License

MIT
