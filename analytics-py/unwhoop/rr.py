"""R-R interval cleaning and HRV time-domain metrics.

Evidence basis (PRD Ch. 2):
- Task Force (ESC/NASPE 1996): RMSSD and friends defined on *normal* (artifact-free)
  beats; ectopic/missed beats must be removed BEFORE any HRV math.
- Malik / Kubios-style filtering: reject beats deviating strongly from the local
  rhythm (Kamath 20%-of-local-median rule used here) and physiologically
  impossible intervals.
- LnRMSSD (natural log of RMSSD) is the most evidence-backed recovery metric;
  the log transform normalizes RMSSD's skewed distribution.

Quality gate: a night whose artifact fraction exceeds ARTIFACT_GATE is labeled
"low confidence" — the app must show the badge, never a fake-clean score.
"""

from __future__ import annotations

import math
import statistics

# Physiologically plausible R-R bounds for a resting/sleeping athlete (ms).
RR_MIN_MS = 300.0
RR_MAX_MS = 2000.0

# Kamath rule: a beat is ectopic if it differs from the local median by more
# than this fraction.
ECTOPIC_FRACTION = 0.20
LOCAL_WINDOW = 5  # beats on each side for the local median

# Above this artifact fraction, the night is flagged low-confidence.
ARTIFACT_GATE = 0.15


def _local_median(rr: list[float], i: int) -> float:
    lo = max(0, i - LOCAL_WINDOW)
    hi = min(len(rr), i + LOCAL_WINDOW + 1)
    window = [rr[j] for j in range(lo, hi) if j != i]
    return statistics.median(window) if window else rr[i]


def clean_rr(rr_ms: list[float]) -> dict:
    """Artifact-correct an R-R series (Malik/Kubios-style, Kamath 20% rule).

    Returns dict with:
      cleaned: list[float] — ectopic/out-of-range beats replaced by the local
               median (so downstream math sees a continuous normal-beat series)
      artifact_fraction: fraction of beats flagged
      n_removed: count flagged
      low_confidence: True when artifact_fraction > ARTIFACT_GATE
    """
    rr = [float(x) for x in rr_ms]
    n = len(rr)
    if n == 0:
        return {"cleaned": [], "artifact_fraction": 1.0,
                "n_removed": 0, "low_confidence": True}

    bad = [False] * n
    for i, v in enumerate(rr):
        if not (RR_MIN_MS <= v <= RR_MAX_MS):
            bad[i] = True
            continue
        med = _local_median(rr, i)
        if med > 0 and abs(v - med) / med > ECTOPIC_FRACTION:
            bad[i] = True

    cleaned = list(rr)
    for i in range(n):
        if bad[i]:
            cleaned[i] = _local_median(rr, i)

    n_removed = sum(bad)
    frac = n_removed / n
    return {
        "cleaned": cleaned,
        "artifact_fraction": frac,
        "n_removed": n_removed,
        "low_confidence": frac > ARTIFACT_GATE,
    }


def rmssd(rr_ms: list[float]) -> float:
    """Root mean square of successive differences (ms). Input: cleaned series."""
    if len(rr_ms) < 2:
        return 0.0
    diffs = [b - a for a, b in zip(rr_ms, rr_ms[1:])]
    return math.sqrt(sum(d * d for d in diffs) / len(diffs))


def ln_rmssd(rr_ms: list[float]) -> float:
    """Natural log of RMSSD — the primary recovery HRV metric."""
    r = rmssd(rr_ms)
    return math.log(r) if r > 0 else float("-inf")


def deepest_sleep_window(
    epoch_hr: list[float],
    epoch_motion: list[float],
    motion_thresh: float = 0.15,
    window_epochs: int = 10,
) -> int | None:
    """Find the most autonomically stable 5-min window during sleep.

    epoch_hr: mean HR per 30-s epoch; epoch_motion: motion index per epoch (0..1).
    Returns the START epoch index of the window_epochs-long window with the
    lowest mean HR among windows whose mean motion is below motion_thresh.
    None if no window qualifies (restless night -> no LnRMSSD reading).
    """
    n = len(epoch_hr)
    if n < window_epochs:
        return None
    best, best_hr = None, float("inf")
    for s in range(n - window_epochs + 1):
        m = sum(epoch_motion[s:s + window_epochs]) / window_epochs
        if m > motion_thresh:
            continue
        h = sum(epoch_hr[s:s + window_epochs]) / window_epochs
        if h < best_hr:
            best, best_hr = s, h
    return best
