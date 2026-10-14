# Unwhoop

Native iOS app for the user's WHOOP 5.0, installed with Sideloadly.
Bluetooth and local SwiftData storage; no account or cloud.

Sensor batches persist as minute pages before analytics runs. Home, Trends,
and Data display calculated sleep, HRV, resting HR, respiratory rate,
recovery, and strain when their data requirements are met. These are custom
estimates, not WHOOP's proprietary scores. Missing or unreliable inputs must
leave scores unavailable and show the reason.

Backfill starts after every successful BLE handshake or restoration.
Automatic foreground retries use battery backoff. Charging-only background
processing requests complement CoreBluetooth restoration; iOS controls timing.
Data exposes history/R-R diagnostics and raw export. Empty transfers show
waiting for data and never advance Last sync.

Preserve the working bond/hello/subscription order, disclaimer acceptance,
paired device settings, and installed data across updates. Keep the native
WHOOP-inspired dark dashboard and the original U/pulse app icon.
