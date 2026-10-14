# Build and scoring verification

Version 1.1.1 (7), October 13, 2026. GitHub Actions uses Xcode on macOS to
compile the device app, run simulator XCTest, export dashboard screenshots,
validate the packaged permission/background/icon metadata, and produce an
unsigned IPA for Sideloadly. The local Windows environment cannot run Xcode.

## Implemented

- Batches persist to SwiftData before sleep and daily analytics. Repeated
  backfill is idempotent; raw archives and CRC-checked journals recover
  interrupted processing. Minute sensor pages retain fourteen days.
- All HRV inputs pass `RRAnalysis.cleanRR`. Five-minute overnight windows need
  at least 120 clean intervals, 80% beat-duration coverage, no packet gap over
  ten seconds, and plausible total beat duration. More than 15% artifacts in
  the night's R-R data withholds HRV-based sleep and recovery scores.
- Sleep uses observed HR and motion in thirty-second epochs. At least three
  observed hours, 80% coverage, no ten-minute holes, observed wakefulness
  before onset, and ten minutes of wakefulness afterward are required to
  finalize scores. Sleep stages remain heuristic estimates.
- Sleep scoring initially uses sufficiency and efficiency; consistency and
  restfulness join after three prior usable nights. Recovery requires seven
  prior usable baseline nights. Respiratory rate is estimated from cleaned
  R-R in quiet sleep windows and may remain unavailable for weak signals.
- Strain requires an explicit maximum HR and male/female TRIMP coefficient
  choice in Data, observed resting HR, and 80% daily HR coverage. Missing
  data cannot be treated as zero activity.
- Backfill starts on each connect/restoration after the existing bond and
  notification handshake. Battery transfers are capped; full offloads use
  charging power. Low phone/band battery backs off automatic work. Charging
  BGProcessingTask requests have no guaranteed launch time.
- History diagnostics distinguish actual older timestamps from live-window
  packets. R-R diagnostics record source subscription state and last packet
  timing. Empty transfers stay waiting for data without changing Last sync.
- Normal transfer completion retains the healthy bonded connection. Budget
  pauses wait for the current history bank and its ACK write confirmation.
  Restored enabled subscriptions are recognized after hello; pending restored
  connections have a forty-second timeout. Foreground retries use five minutes,
  or one minute for charging budget continuations, with low-power backoff kept.
  Data shows stop reasons, last data-received time, and the next foreground
  attempt. The verified build passed 32 iOS and 8 metadata tests.

## Evidence and remaining device checks

The user verified working pairing and real HR/motion/temperature/R-R frames
on their WHOOP 5.0. Their three supplied transfers contained only live-window
data; one had sparse R-R and around 20% artifacts. Such data must not produce
a nightly score.

Simulator tests cover synthetic overnight sleep/strain/respiration, recovery
baseline gating, artifact rejection, sparse/stopped/duplicated R-R, still-open
sleep, repeated ingest, empty transfer behavior, prior pairing regression,
history opcode encoding, history timestamp classification, independent GATT
reassembly, and battery policy. Synthetic tests establish code behavior, not
measurement accuracy against a physical strap or WHOOP.

Physical overnight backfill and unattended iOS background launches still need
verification. Wear the strap, leave Bluetooth enabled and the phone charging,
then open the app after waking. Data should report older history timestamps.
If only live-window data arrives, overnight scores cannot be reconstructed.
No returned history alone cannot distinguish an empty strap buffer from a
device/protocol issue; use the command/marker/timestamp diagnostics.

Sleep/recovery/respiration remain custom estimates. No validated claim of
clinical accuracy or equivalence to WHOOP's proprietary algorithm is made.
WHOOP export imports and HealthKit behavior require separate device testing;
RMSSD must never be written under HealthKit's SDNN measurement type.
