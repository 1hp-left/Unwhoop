# Unwhoop

A native iOS app for WHOOP 5.0 that connects directly over Bluetooth, stores
sensor data locally, and calculates sleep, recovery, and strain estimates on
your phone. No WHOOP account or membership is required by the app.

No cloud service, account, or health-data uploads. Unwhoop uses its own scoring
algorithms; its estimates have not been validated as equivalent to WHOOP's
proprietary scores or as clinical measurements.

## Current release

**1.1.0 (build 6)** includes the connected scoring pipeline, automatic sync,
R-R quality gates, history diagnostics, a WHOOP-inspired dark dashboard, and
an original U/pulse app icon.

The [verified build](https://github.com/1hp-left/Unwhoop/actions/runs/38491488317)
compiled the device app and passed **26 iOS tests and 8 metadata tests** at
commit `a873295`. Pairing and live sensor transfers have been verified on the
user's WHOOP 5.0. Physical overnight backfill and unattended background sync
still need device verification. See [BUILD_NOTES.md](BUILD_NOTES.md) for details.

## Install and get started

1. Download the `Unwhoop-unsigned-ipa` artifact from the verified build above
   and unzip it to get the IPA.
2. Install with **Sideloadly** using your Apple ID. To update, install over the
   existing app with the same signing identity and bundle ID to preserve data.
3. Accept the disclaimer, put the band in pairing mode with its blue light
   flashing, then pair in Unwhoop and accept the iOS Bluetooth pairing prompt.
4. In **Data**, set your maximum heart rate and physiology for strain, and
   choose your sleep goal. Strain stays unavailable until its inputs exist.
5. Wear the band, keep Bluetooth enabled, and leave your phone charging
   overnight. Open Unwhoop after waking; it syncs automatically.

Requirements: **iOS 17 or later** and a **WHOOP 5.0**. Free Apple ID signing
requires periodic renewal through your sideloading tool.

## Automatic sync and diagnostics

Backfill is requested after every successful connection, including restored
Bluetooth connections. The working bond, hello, and notification sequence is
preserved. Sensor batches persist to SwiftData before analytics runs; repeated
transfers merge without duplicating samples. Raw archives and frame journals
allow interrupted processing to resume. Minute sensor pages retain fourteen
days; daily summaries remain stored separately.

Battery-powered transfers are bounded. Full offloads use charging power, and
low phone or band battery backs off retries. Charging-only background processing
requests complement CoreBluetooth restoration. **iOS decides background launch
timing**, so an overnight offload is not guaranteed at a particular time.

Version 1.1.1 preserves a healthy Bluetooth connection after a transfer instead
of routinely disconnecting. Record/time budgets finish the current history bank
and wait for its acknowledgement before pausing. Restored connections have a
timeout. Foreground retries run every five minutes, or after one minute for a
charging budget continuation; low-power backoff remains four hours. Data shows
the last data-received time, the transfer stop reason, and the next foreground
attempt. Background launch timing remains controlled by iOS.

**Data → Sync diagnostics** reports whether actual older timestamps arrived,
history command/marker information, R-R packet timing, and notification state.
An empty transfer shows **waiting for data** and does not advance Last sync.
If a transfer contains only live-window data, it cannot reconstruct overnight
sleep. If no older timestamps arrive, the strap may have no stored history,
or backfill may still have a device/protocol issue.

## Scoring

| Metric | Calculation and requirements |
| --- | --- |
| Sleep | Heuristic 30-second stages from HR, motion, and usable HRV. Final scores need at least three observed overnight hours, sufficient coverage, and observed wakefulness before and after sleep. |
| Sleep score | Sufficiency and efficiency initially; timing consistency and restfulness join after three prior usable nights. Sleep need incorporates your sleep goal, available prior-day strain, and recent sleep debt. |
| HRV | RMSSD from cleaned R-R in covered five-minute quiet sleep windows, stored as lnRMSSD. Requires at least 120 clean intervals, 80% beat-duration coverage, and no packet gap longer than ten seconds. |
| Resting HR | Observed quiet overnight heart rate. |
| Respiratory rate | Estimated from respiratory modulation of cleaned R-R during quiet sleep; weak or incomplete signals can produce no reading. |
| Recovery | HRV, resting HR, and sleep performance relative to **seven prior usable baseline nights**. It is unavailable on the first night. |
| Strain | Observed HR training load using Banister TRIMP, mapped to 0–21. Requires maximum HR, the male/female coefficient setting, observed resting HR, and at least 80% daily HR coverage. |
| Skin temperature | Overnight mean; deviation becomes available after at least three prior usable temperature nights. |

`RRAnalysis.cleanRR` runs before HRV calculations. More than **15% R-R artifacts**
in the night's data withholds HRV-based sleep and recovery scores. Sparse,
stopped, duplicated, or incomplete signals leave affected scores unavailable
with an explanation. Sleep staging and respiratory estimates still require
validation against real overnight recordings.

## The three tabs

- **Home** — Sleep, Recovery, and Strain dials; automatic-sync status; overnight
  health metrics; sleep and activity summaries.
- **Trends** — 7D/30D/90D charts for stored HRV, resting HR, sleep, and strain.
- **Data** — band status, sync diagnostics, raw-sync and CSV/JSON exports,
  scoring settings, and baseline reset.

## Build and test

Local builds require macOS, Xcode 16 or later, and XcodeGen:

```sh
brew install xcodegen
xcodegen generate
open Unwhoop.xcodeproj
```

Select the Unwhoop scheme and a simulator to run tests, or configure signing
and select your iPhone for a device build. The vendored protocol package is
included in the repository.

GitHub Actions can build an unsigned IPA without local Xcode. In **Actions**,
select **Build unsigned .ipa (free, no Apple Developer account)**, choose
**Run workflow**, and select the desired branch. Pushes to `main` also trigger
it. The workflow builds for device, runs simulator tests, exports screenshots,
checks permission/background/icon metadata, and uploads the IPA.

The local packaging checks can also run with Python:

```sh
python3 scripts/test_validate_app_plist.py
```

## Project layout

```text
Unwhoop/
  App/        app entry, disclaimer, pairing, pipeline orchestration
  Models/     SwiftData settings, sensor minute pages, daily summaries
  BLE/        CoreBluetooth sync, restoration, background tasks, journals
  Analytics/  R-R cleaning, sleep, HRV, respiration, recovery, strain
  UI/         native SwiftUI Home / Trends / Data
  Export/     CSV, JSON, and raw sensor archive exports
  Import/     developer-only WHOOP export benchmark import
  HealthKit/  optional writer, disabled by default
  Resources/  permission/background metadata, privacy manifest, app icon
UnwhoopTests/ pairing, sync, scoring, and dashboard regression tests
Vendor/Noop/  vendored WhoopProtocol Swift package and attribution
scripts/      packaging metadata validation and icon generation
```

## License and attribution

- Unwhoop's own code: [MIT](LICENSE).
- Vendored Noop code: [PolyForm Noncommercial 1.0.0](Vendor/Noop/LICENSE).
  Personal/noncommercial use only; commercial use is not granted. The vendored
  code keeps its own license and [attribution](Vendor/Noop/ATTRIBUTION.md).

Unwhoop is an independent project and is not affiliated with or endorsed by
WHOOP. The name identifies the hardware it interoperates with.
