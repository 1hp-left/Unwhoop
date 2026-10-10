"""Recovery score (0-100%) from overnight HRV + resting HR + sleep.

Evidence basis (PRD Ch. 2/3):
- LnRMSSD from the deepest-sleep window is the primary input (most
  autonomically stable window; standardized resting conditions).
- Each metric is expressed as a z-score against the user's own 7-day rolling
  baseline. Smallest worthwhile change = +/-0.5 SD.
- LF/HF ratio is NOT used (evidence is against it).
- Bands: 67-100% green (Recovered), 34-66% yellow (Pay attention),
  0-33% red (Rest).
- Confounder flags (alcohol / illness signatures) move the DISPLAY, not the
  baseline — flagged nights are excluded from baseline updates.
- First 7 days: "building baseline", no score until the baseline exists.

Fusion weights below are v1 starting points, documented as tunable: the
benchmark mode exists precisely to fit these against paired WHOOP data.
"""

from __future__ import annotations

import math
import statistics

BASELINE_DAYS = 7
SWC_SD = 0.5  # smallest worthwhile change, in SD units

# v1 fusion weights (tunable via benchmark fitting).
W_HRV = 0.60
W_RHR = 0.25
W_SLEEP = 0.15

BAND_GREEN = 67.0
BAND_YELLOW = 34.0


def rolling_baseline(history: list[float], days: int = BASELINE_DAYS) -> dict:
    """7-day rolling mean/SD. Returns status when history is too short."""
    vals = [v for v in history[-days:] if v is not None and math.isfinite(v)]
    if len(vals) < days:
        return {"ready": False, "nights_to_go": days - len(vals)}
    mean = statistics.fmean(vals)
    sd = statistics.pstdev(vals) if len(vals) > 1 else 0.0
    return {"ready": True, "mean": mean, "sd": sd, "n": len(vals)}


def zscore(value: float, baseline: dict) -> float | None:
    if not baseline.get("ready"):
        return None
    if baseline["sd"] <= 0:
        # Zero-variance history: no measurable deviation in a z framework.
        return 0.0
    return (value - baseline["mean"]) / baseline["sd"]


def fuse_recovery(z_hrv: float, z_rhr: float, z_sleep: float) -> float:
    """Fuse z-scores into 0-100%. RHR elevation is bad -> subtracted.

    score = 50 + 22 * (0.6*z_hrv - 0.25*z_rhr + 0.15*z_sleep), clipped.
    The 22-point-per-SD slope puts a typical night's combined z (SD ~0.67)
    at roughly +/-15 points around 50 — a sensible spread across the bands.
    """
    combined = W_HRV * z_hrv - W_RHR * z_rhr + W_SLEEP * z_sleep
    return max(0.0, min(100.0, 50.0 + 22.0 * combined))


def band(score: float) -> str:
    if score >= BAND_GREEN:
        return "green"    # Recovered
    if score >= BAND_YELLOW:
        return "yellow"   # Pay attention
    return "red"          # Rest


def confounder_flags(z_hrv: float, z_rhr: float,
                     rhr_delta_bpm: float) -> list[str]:
    """Display-only flags. Flagged nights must NOT enter the baseline."""
    flags: list[str] = []
    # Alcohol signature: HRV suppressed + RHR elevated the same night.
    if z_hrv < -1.0 and z_rhr > 1.0:
        flags.append("alcohol_signature")
    # Illness signature: RHR +2-5 bpm with HRV suppression.
    if rhr_delta_bpm >= 2.0 and z_hrv < -0.75:
        flags.append("possible_illness")
    return flags


def score_night(ln_rmssd: float, rhr: float, sleep_perf: float,
                hr_history: list[float], rhr_history: list[float],
                perf_history: list[float]) -> dict:
    """Full nightly pipeline. Histories EXCLUDE the current night.

    sleep_perf: sleep performance vs need, 0-100 (from the sleep module).
    Returns score + band + z-scores + flags, or building-baseline status.
    """
    b_hrv = rolling_baseline(hr_history)
    b_rhr = rolling_baseline(rhr_history)
    b_perf = rolling_baseline(perf_history)
    if not (b_hrv["ready"] and b_rhr["ready"] and b_perf["ready"]):
        need = max(b_hrv.get("nights_to_go", 0), b_rhr.get("nights_to_go", 0),
                   b_perf.get("nights_to_go", 0))
        return {"ready": False, "nights_to_go": need,
                "status": "building_baseline"}
    z_h = zscore(ln_rmssd, b_hrv)
    z_r = zscore(rhr, b_rhr)
    z_s = zscore(sleep_perf, b_perf)
    score = fuse_recovery(z_h, z_r, z_s)
    flags = confounder_flags(z_h, z_r, rhr - b_rhr["mean"])
    return {
        "ready": True,
        "score": score,
        "band": band(score),
        "z_hrv": z_h,
        "z_rhr": z_r,
        "z_sleep": z_s,
        "flags": flags,
        "exclude_from_baseline": bool(flags),
    }
