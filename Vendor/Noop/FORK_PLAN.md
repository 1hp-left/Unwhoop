# Vendoring Noop's BLE layer — FORK PLAN

Unwhoop does NOT reimplement the WHOOP 5.0 Bluetooth protocol. The
reverse-engineering is the moat; we fork it (PRD §5.1, §7). This document is
the exact procedure. Noop's repo was used as read-only reference at
`vendor/noop-ref` (never copied from); the steps below create the real fork.

## 0. License facts (verified 2026-10-08)

- Noop is **PolyForm Noncommercial License 1.0.0** — NOT MIT.
- Forking for personal / noncommercial use is allowed. **Commercial use is not granted.**
- Keep Noop's attribution: `ATTRIBUTION.md` and the license text, including the
  **Required Notice: Copyright 2026 NoopApp** line.
- **Never relicense Noop's code as MIT.** The Unwhoop host repo is MIT; the
  vendored `Vendor/Noop/` directory keeps PolyForm Noncommercial 1.0.0 and its
  own license file. The license boundary is this directory — Noop code must not
  be copied into MIT-licensed directories.

## 1. Fork on GitHub

1. Open https://github.com/ryanbr/noop and click **Fork**.
2. Fork into your own account (e.g. `1hp-left/noop`). Keep it public or
   private — your choice; the fork is a pin, not a product.

## 2. Pin the commit

The reference clone was taken at:

```
e58017508d9731c51d0631fe0eb4bb1d7ea0c582  (2026-10-09)
```

Pin EXACTLY this commit (do not track `main` — upstream moves and the 5.0
protocol code is the part that must not drift silently):

```sh
git clone --no-checkout https://github.com/1hp-left/noop.git /tmp/noop-fork
cd /tmp/noop-fork
git checkout e58017508d9731c51d0631fe0eb4bb1d7ea0c582
```

Record the pinned commit here when done: `PINNED: e58017508d9731c51d0631fe0eb4bb1d7ea0c582`

## 2b. What actually landed (2026-10-10)

The full `Packages/WhoopProtocol/` Swift package was vendored verbatim into
`Vendor/Noop/Packages/WhoopProtocol/` (Sources, Tests, resources, Package.swift
unchanged) and linked as a local Swift package in `project.yml`. It is pure
Swift + Foundation with zero external dependencies, and it is the actual
protocol moat: CRC16-Modbus framing, CLIENT_HELLO, historical ("puffin")
streams, and the Whoop 5.0 decoders (R-R, raw IMU, raw optical, PPG HR).

Noop's `Strand/BLE/` app layer (`BLEManager.swift` et al.) was deliberately
NOT vendored: it is a 7,600-line `ObservableObject` entangled with Noop's
`WhoopStore`, `StrandAnalytics`, and app UI. The CoreBluetooth orchestration
(scan/connect/GATT/notify) is instead implemented fresh in
`Unwhoop/BLE/NoopBandSyncAdapter.swift`, written directly against
WhoopProtocol's public API. Narrower surface, same protocol facts.

Trim note: upstream's `Tests/` and the three executable targets
(`whoop-decode`, `whoop-optical-experiment`, `whoop-re`) were dropped from the
vendored copy — Unwhoop's CI never runs them — and `Package.swift` was trimmed
to the library target accordingly (the trim is documented in the file itself).
Everything else is verbatim at the pinned commit.

## 3. Vendor the needed files

Copy into `Vendor/Noop/` (this directory), preserving relative paths:

```
Vendor/Noop/
  LICENSE              <- Noop's PolyForm Noncommercial 1.0.0 text (from fork root LICENSE)
  ATTRIBUTION.md       <- from fork root (keep the "Required Notice: Copyright 2026 NoopApp" line)
  FORK_PLAN.md         <- this file
  Packages/WhoopProtocol/          <- whole Swift package (framing, 5.0 decode)
  Strand/BLE/BLEManager.swift
  Strand/BLE/SourceCoordinator.swift
  Strand/BLE/BackfillPolicy.swift
  Strand/BLE/FrameRouter.swift
  Strand/BLE/Commands.swift
```

Then resolve transitive imports: the files above may import other
`Strand/BLE/` or `Packages/` files. Add ONLY what the compiler demands,
one file at a time, keeping the vendored surface minimal. (Noop also
supports 4.0/Oura/Xiaomi — none of that comes over.)

## 4. Wire the adapter

`Unwhoop/BLE/NoopBandSyncAdapter.swift` has `TODO(fork)` markers at every
seam, each naming the exact Noop file it wraps:

| Adapter method | Wraps |
|---|---|
| `startScan` / `stopScan` | `Strand/BLE/BLEManager.swift` (Whoop-5 service UUID family `fd4b0001-…`) |
| `connect(to:)` | `BLEManager.swift` + CLIENT_HELLO via `Packages/WhoopProtocol` (`DeviceFamily` Whoop-5 path) |
| `requestSync` | `BackfillPolicy.swift` → `HistoricalStreams.swift` ("puffin" packets) → decode via `Whoop5RR.swift` (R-R), `Whoop5RawImu.swift` (motion), `Whoop5RawOptical.swift`/`PpgHr.swift` (HR) → `RawSampleBatch` |
| state restoration | `centralManager(_:willRestoreState:)` is already implemented in the adapter; hand restored peripherals to `SourceCoordinator` |

Replace each `forkGate(_:)` call with the real wiring. Nothing in
`Unwhoop/Analytics/` or `Unwhoop/UI/` changes — that's the point of the
narrow `BandSyncProtocol`.

## 5. License hygiene checklist

- [ ] `Vendor/Noop/LICENSE` = PolyForm Noncommercial 1.0.0 text, verbatim
- [ ] `Vendor/Noop/ATTRIBUTION.md` present, "Required Notice: Copyright 2026 NoopApp" intact
- [ ] No Noop file copied outside `Vendor/Noop/`
- [ ] Pinned commit recorded in §2 above
- [ ] Host repo LICENSE (MIT) does not claim the vendored directory
