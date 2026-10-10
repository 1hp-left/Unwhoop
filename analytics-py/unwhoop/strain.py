"""Strain (0-21, live) via per-minute Banister TRIMP.

Evidence basis (PRD Ch. 5):
- Per-minute Banister TRIMP from heart-rate reserve:
    x = (HR - HRrest) / (HRmax - HRrest)
    Y = 0.64 * e^(1.92*x) (male) / 0.86 * e^(1.67*x) (female)
    TRIMP_min = x * Y
  Edwards zone-summation is NOT used (fails to discriminate intensities
  where Banister succeeds).
- Accumulated load maps through a saturating exponential onto 0-21
  (Borg-anchored, "exponentially harder at the top"):
    strain = 21 * (1 - e^(-load / 100))
  The /100 constant is the v1 starting point — fit it against paired WHOOP
  strain data in benchmark mode.
"""

from __future__ import annotations

import math

STRAIN_MAX = 21.0
LOAD_CONSTANT = 100.0  # v1; fit against benchmark data


def _weight(x: float, sex: str) -> float:
    s = sex.lower()
    if s.startswith("f"):
        return 0.86 * math.exp(1.67 * x)
    return 0.64 * math.exp(1.92 * x)  # male default


def trimp_minute(hr: float, hr_rest: float, hr_max: float,
                 sex: str = "male") -> float:
    """Banister TRIMP for one minute at the given heart rate."""
    if hr_max <= hr_rest:
        return 0.0
    x = (hr - hr_rest) / (hr_max - hr_rest)
    if x <= 0:
        return 0.0
    return x * _weight(x, sex)


def day_load(per_minute_hr: list[float], hr_rest: float, hr_max: float,
             sex: str = "male") -> float:
    """Accumulated TRIMP load across the day."""
    return sum(trimp_minute(h, hr_rest, hr_max, sex) for h in per_minute_hr)


def load_to_strain(load: float) -> float:
    """Saturating exponential map onto the 0-21 scale."""
    return STRAIN_MAX * (1.0 - math.exp(-load / LOAD_CONSTANT))


def day_strain(per_minute_hr: list[float], hr_rest: float, hr_max: float,
               sex: str = "male") -> dict:
    load = day_load(per_minute_hr, hr_rest, hr_max, sex)
    return {"load": load, "strain": load_to_strain(load)}
