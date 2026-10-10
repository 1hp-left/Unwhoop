"""Sleep score: 0-100 nightly composite from four 0-1 components.

1:1 port of Unwhoop/Analytics/SleepScore.swift (pure functions only).
Components mirror what WHOOP's docs say Sleep Performance is built from:
sufficiency (sleep vs need), efficiency (asleep / in bed), consistency
(timing vs recent norm), restfulness (vitals vs baseline = low stress).
"""


def normalize_weights(w):
    vals = [max(0.0, x) for x in w]
    s = sum(vals)
    if s <= 0:
        return [0.35, 0.25, 0.20, 0.20]
    return [v / s for v in vals]


DEFAULT_WEIGHTS = [0.35, 0.25, 0.20, 0.20]


def sleep_score(components, weights=None):
    """components: (sufficiency, efficiency, consistency, restfulness)."""
    w = normalize_weights(weights if weights is not None else DEFAULT_WEIGHTS)
    raw = sum(wi * ci for wi, ci in zip(w, components))
    return min(max(raw, 0.0), 1.0) * 100.0


def sufficiency(total_sleep_min, need_min):
    if need_min <= 0 or total_sleep_min <= 0:
        return 0.0
    return min(total_sleep_min / need_min, 1.0)


def efficiency(total_sleep_min, time_in_bed_min):
    if time_in_bed_min <= 0 or total_sleep_min < 0:
        return 0.0
    return min(total_sleep_min / time_in_bed_min, 1.0)


def consistency(dev_hours):
    """dev_hours: |tonight's midpoint - median midpoint|, hours."""
    return max(0.0, 1.0 - dev_hours / 3.0)


def restfulness(rhr_bpm, rhr_baseline_bpm, hrv_ms, hrv_baseline_ms):
    if rhr_baseline_bpm > 0:
        rhr_part = min(max(1.0 - max(0.0, rhr_bpm - rhr_baseline_bpm) / 12.0, 0.0), 1.0)
    else:
        rhr_part = 0.5
    if hrv_baseline_ms > 0 and hrv_ms > 0:
        hrv_part = min(hrv_ms / hrv_baseline_ms, 1.2) / 1.2
    else:
        hrv_part = 0.5
    return 0.5 * rhr_part + 0.5 * hrv_part


def sleep_need_minutes(baseline_median_min, day_strain, sleep_debt_min):
    base = min(max(baseline_median_min, 360.0), 600.0)
    strain_bump = max(0.0, day_strain - 12.0) * 3.0
    debt_bump = min(max(sleep_debt_min, 0.0), 120.0) * 0.25
    return base + strain_bump + debt_bump


def sleep_debt_minutes(nights):
    """nights: iterable of (need_min, actual_min); trailing 7 summed."""
    recent = list(nights)[-7:]
    return max(0.0, sum(max(0.0, n - a) for n, a in recent))
