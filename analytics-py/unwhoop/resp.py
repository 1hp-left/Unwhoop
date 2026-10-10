"""Respiratory rate from R-R intervals via respiratory sinus arrhythmia (RSA).

Evidence basis (PRD Ch. 6, Appendix A.1):
- WHOOP 5.0 exposes no raw respiration stream over BLE; breathing rate is
  derived from RSA (HR rises on inhale, falls on exhale) — the same approach as
  Noop's SleepStager.respRateFromRR and Fitbit's production algorithm
  (Fitbit: MAE 0.75 breaths/min vs flow sensors).
- Recipe: still-window gate (>=2 min continuous stillness) -> interpolate R-R
  to a uniform 4 Hz tachogram (cubic spline) -> bandpass 0.1-0.5 Hz (6-30 brpm,
  the HF band = the RSA signal) -> peak-detect, 60 / mean inter-peak interval.
- Nightly value: MEDIAN of per-minute deep-sleep estimates (rejects minutes
  where RSA momentarily collapses, common in REM).
- Reject when HF power is negligible vs total HRV power (weak RSA: low-HRV
  individuals, stress, illness). A confident "no reading" beats a fabrication.
- Expected accuracy: MAE ~0.75-2.5 brpm at rest/sleep. Good enough as a
  recovery input and baseline-deviation flag; not a clinical measurement.
"""

from __future__ import annotations

import numpy as np
from scipy import signal
from scipy.interpolate import CubicSpline

TARGET_FS = 4.0          # Hz for the uniform tachogram
BAND_LO = 0.1            # Hz -> 6 brpm
BAND_HI = 0.5            # Hz -> 30 brpm
MIN_STILL_SECONDS = 120  # gate: need >= 2 min of continuous stillness
HF_LO, HF_HI = 0.15, 0.40  # HF band for the RSA-strength check
MIN_HF_RATIO = 0.05        # reject when HF power < 5% of total HRV power


def _to_tachogram(rr_ms: np.ndarray, rr_times_s: np.ndarray,
                  fs: float = TARGET_FS) -> tuple[np.ndarray, np.ndarray]:
    """Interpolate uneven R-R series to a uniform tachogram (cubic spline)."""
    t0, t1 = rr_times_s[0], rr_times_s[-1]
    t_uniform = np.arange(t0, t1, 1.0 / fs)
    cs = CubicSpline(rr_times_s, rr_ms)
    return t_uniform, cs(t_uniform)


def _bandpass(x: np.ndarray, fs: float,
              lo: float = BAND_LO, hi: float = BAND_HI) -> np.ndarray:
    sos = signal.butter(4, [lo, hi], btype="band", fs=fs, output="sos")
    return signal.sosfiltfilt(sos, x)


def _hf_ratio(tach: np.ndarray, fs: float = TARGET_FS) -> float:
    """Fraction of HRV power in the HF band (RSA-strength gate)."""
    f, pxx = signal.welch(tach - np.mean(tach), fs=fs, nperseg=min(256, len(tach)))
    total = np.trapz(pxx, f)
    if total <= 0:
        return 0.0
    mask = (f >= HF_LO) & (f <= HF_HI)
    return float(np.trapz(pxx[mask], f[mask]) / total)


def estimate_from_tachogram(tach_ms: np.ndarray,
                            fs: float = TARGET_FS) -> float | None:
    """Breaths/min from a uniform 4 Hz tachogram. None when RSA is too weak."""
    if len(tach_ms) < int(fs * 60):
        return None
    if _hf_ratio(tach_ms, fs) < MIN_HF_RATIO:
        return None
    filt = _bandpass(tach_ms, fs)
    # Breathing is 6-30 brpm -> peaks at least ~1.5 s apart at 4 Hz.
    peaks, _ = signal.find_peaks(filt, distance=int(fs * 1.5),
                                 prominence=np.std(filt) * 0.3)
    if len(peaks) < 3:
        return None
    ipi = np.diff(peaks) / fs  # inter-peak intervals, seconds
    mean_ipi = float(np.mean(ipi))
    if mean_ipi <= 0:
        return None
    brpm = 60.0 / mean_ipi
    return brpm if BAND_LO * 60 <= brpm <= BAND_HI * 60 else None


def estimate_from_rr(rr_ms: list[float], rr_times_s: list[float]) -> float | None:
    """Breaths/min from raw R-R intervals + beat times. None if unavailable."""
    rr = np.asarray(rr_ms, dtype=float)
    tt = np.asarray(rr_times_s, dtype=float)
    if len(rr) < 30 or tt[-1] - tt[0] < MIN_STILL_SECONDS:
        return None  # stillness gate: need >= 2 min of data
    _, tach = _to_tachogram(rr, tt)
    return estimate_from_tachogram(tach)


def nightly_respiratory_rate(per_minute_estimates: list[float | None]) -> float | None:
    """Median of per-minute deep-sleep estimates. None if no valid minutes."""
    vals = [v for v in per_minute_estimates if v is not None]
    if not vals:
        return None
    return float(np.median(vals))
