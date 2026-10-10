# Unwhoop (working title)

An iOS app that keeps a WHOOP 5.0 band useful without a WHOOP membership.
It talks to the band directly over Bluetooth, pulls the raw sensor data, and
computes recovery, sleep, and strain scores on-device using published,
peer-reviewed methods.

**No cloud. No account. No subscription. No network calls at all.**

## The three tabs

- **Today** — the morning glance: recovery score (0–100%, green/yellow/red),
  overnight vitals vs your baseline, sleep summary, live strain (0–21).
- **Trends** — 7D/30D/90D charts: HRV with baseline band, resting HR, sleep,
  strain.
- **Data** — band connection, sync, CSV/JSON export, settings.

## Building

Requirements: macOS with Xcode 16+, XcodeGen.

```sh
brew install xcodegen
xcodegen generate        # produces Unwhoop.xcodeproj from project.yml
open Unwhoop.xcodeproj
```

Or push to `main` — the `ios-build-unsigned` workflow builds an unsigned
`.ipa` on GitHub's free macOS runners; install it with SideStore/AltStore
using a free Apple ID.

## Project layout

```
Unwhoop/
  App/        entry, first-run (disclaimer + pairing), app state
  Models/     SwiftData models (NightSummary, DaySummary, SyncState, AppSettings…)
  BLE/        narrow BandSyncProtocol + NoopBandSyncAdapter skeleton
  Analytics/  documented API stubs (real implementations land separately)
  UI/         Today / Trends / Data — real SwiftUI, dark-first
  Export/     CSV / JSON / raw-streaming exporters, storage meter
  HealthKit/  optional write-only HealthKit writer (off by default)
  Resources/  Info.plist, PrivacyInfo.xcprivacy (no data collected)
Vendor/Noop/  FORK_PLAN.md — how the Noop BLE fork gets vendored (not yet done)
```

## License

- Unwhoop's own code: MIT.
- `Vendor/Noop/` (when vendored): **PolyForm Noncommercial 1.0.0** — personal /
  noncommercial use only, commercial use not granted. That directory keeps its
  own license and attribution; it is never relicensed as MIT.

## Status

Scaffold. See [BUILD_NOTES.md](BUILD_NOTES.md) for what is and isn't verified —
notably, nothing here has been compiled yet and BLE needs a physical iPhone.
