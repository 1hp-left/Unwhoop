# BUILD_NOTES — what is verified and what is not

Scaffold written 2026-10-09. Read this before trusting anything.

## Explicitly NOT verified

- **The Swift was never compiled.** This machine is Linux; there is no Xcode
  here. `project.yml`, every `.swift` file, the plist, and the privacy
  manifest are hand-written and uncompiled. Expect syntax/API issues on first
  Xcode build — budget a cleanup pass.
- **BLE is a skeleton.** `NoopBandSyncAdapter` compiles against CoreBluetooth
  but every band operation is a `TODO(fork)` trap until `Vendor/Noop/` is
  vendored per `FORK_PLAN.md`. No scan, connect, or sync works yet.
- **The simulator cannot do Bluetooth.** Milestone 1's gate — overnight
  offload completing on a physical iPhone with no user interaction — must pass
  on device before any score is trusted. No algorithm work should start until
  raw R-R/motion land on the phone reliably.
- **Analytics are implemented but the Swift is uncompiled.** `Unwhoop/Analytics/`
  now contains real implementations ported 1:1 from the tested Python
  reference (`analytics-py/unwhoop/` — 27/27 tests green, every computation
  hand-verified). The port is faithful by construction, but Swift has never
  been compiled here — expect a syntax/API cleanup pass in Xcode. The DSP
  path in `RespiratoryEstimator` (spline → bandpass → peak-detect, pure
  Swift) must additionally be validated on-device against the Python
  reference before trusting breathing-rate readings.
- **No live data has ever flowed through this.** All UI states beyond the
  empty/baseline-countdown states are unexercised.

## Data import: user uploads, nothing leaves the phone

- **WHOOP export import is in-app and on-device** (`Unwhoop/Import/WhoopExportImport.swift`,
  DEBUG-only like all benchmark tooling). Flow: user requests the WHOOP member
  data export, unzips `my_whoop_data_*.zip` in the Files app, then picks
  `physiological_cycles.csv` (+ optionally `sleeps.csv`) from a document
  picker in Data > Benchmark entry (dev). The parser is header-name-driven
  and tolerant (BOM/quotes/CRLF, localized filenames, `skin_temp_f` vs
  `skin_temp_celsius`-style variants); rows pair to `BenchmarkEntry` by local
  calendar day with upsert semantics (fills blanks, never overwrites).
- **Privacy posture, explicit:** the app makes zero network requests, so there
  is no code path by which health data could reach the developer, the
  assistant, or anyone else. The user never hands health data to anyone —
  they upload it into their own app, on their own phone. If algorithm tuning
  help is ever wanted, only the on-device agreement numbers (bias, limits of
  agreement) need to be shared — never raw data.
- Column schema verified against Noop's `WhoopExportImporter` (same files).
  Like the rest of the Swift, uncompiled here — validate the import against a
  real export on-device.

## PRD ambiguities resolved (and how)

1. **Analytics signatures** (`score(night:baselines:)`, `strain(for:day:)`,
   `estimate(from:)`): parameter types were unspecified, so the scaffold
   defines them — `NightSummary`/`Baselines`, `StrainDayInput`,
   `RespirationInput`. Output types (`RecoveryResult`, `DayStrain`,
   `[SleepEpoch]`) likewise.
2. **Stale threshold**: PRD §5.1 says banner if last sync > 12h — used 12h.
3. **Recovery bands**: 67–100 / 34–66 / 0–33 from PRD §5.3, centralized in
   `RecoveryBand`.
4. **DaySummary "per-minute TRIMP aggregates ref"**: stored inline as
   `[Double] minuteTRIMP` (~11 KB/day, inside the storage budget).
5. **HealthKit HRV**: HealthKit defines an SDNN type but no RMSSD type.
   The writer exposes an SDNN-only path and does NOT write LnRMSSD under an
   SDNN label — no mislabeled data.
6. **Biological sex for the TRIMP constant**: PRD §5.5 gives male/female
   formulas but no source; the v1 settings surface is fixed (units, HealthKit
   toggle, reset baseline, about), so `StrainDayInput` carries `sex` and the
   source is an open question (below).
7. **Sleep need**: PRD shows "need: 8h 05m" but never says where need comes
   from; `NightSummary.sleepNeedMinutes` is pipeline-owned, formula TBD by
   the analytics workstream.
8. **Benchmark strip**: rendered in DEBUG only when paired rows actually
   exist — no empty pleading, per PRD §5.6.
9. **"Recovery ready" notification**: PRD §5.1 wants a local notification when
   nightly computation finishes; not scaffolded — needs BackgroundTasks
   wiring in milestone 1 alongside the sync engine.
10. **Delta arrows**: the authoritative baselines live in the pipeline; the
    Today view's arrows use a cheap display-only rolling mean with that
    documented, so the UI is real without duplicating scoring logic.

## Open questions (for Anay / the analytics workstream)

- Where does `BiologicalSex` for strain come from? (Settings surface is
  fixed by the PRD; HealthKit is read-nothing by design.)
- Sleep-need formula for `sleepNeedMinutes`.
- Final app name (Unwhoop is a working title).
- The WHOOP data export (`my_whoop_data_*.zip`) — request NOW while
  subscribed; it is use-it-or-lose-it when the membership lapses.
