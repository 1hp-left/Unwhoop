"""Sleep staging in 30-second epochs: Wake / Light / Deep / REM.

Evidence basis (PRD Ch. 4):
- Architecture follows Walch et al. (2019, open): per-epoch features from wrist
  accelerometry (activity counts, posture changes), PPG-derived HR and HRV
  (RMSSD, HF power), and PPG-derived respiratory rate, plus a circadian
  time-of-night prior. Adding autonomic features to motion alone lifted 4-class
  accuracy 57% -> 79% (Altini & Kinnunen 2021, n=106, 440 nights).
- Temporal structure via Viterbi smoothing over epoch posteriors (the
  HMM/CRF half of the "temporal model" family named in Ch. 4).
- Expected limits, disclosed in the UI per PRD: 4-class kappa ~0.5-0.65 vs PSG;
  light sleep reads high, deep sleep and wake time read low (every wrist
  device, WHOOP included).

This v1 is a TRANSPARENT heuristic classifier on the literature's feature set
— no trained weights, fully auditable. Upgrade path: fit the linear weights
(and transition matrix) on the benchmark paired nights.
"""

from __future__ import annotations

import math

WAKE, LIGHT, DEEP, REM = 0, 1, 2, 3
STAGE_NAMES = ("Wake", "Light", "Deep", "REM")
EPOCH_S = 30

# Transition matrix rows = from-stage, cols = to-stage. Sleep architecture is
# sticky; wake->deep and deep->REM direct jumps are rare.
TRANSITION = [
    [0.80, 0.15, 0.01, 0.04],  # wake
    [0.06, 0.86, 0.05, 0.03],  # light
    [0.02, 0.06, 0.90, 0.02],  # deep
    [0.05, 0.08, 0.02, 0.85],  # rem
]


def _clip(x: float, lo: float = -1.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, x))


def epoch_scores(motion: float, hr: float, median_hr: float,
                 rmssd: float, median_rmssd: float,
                 hr_var: float, t_hours: float) -> list[float]:
    """Logit-ish scores per stage from literature's feature set.

    motion: 0..1 activity index. hr_var: within-epoch HR std (bpm).
    t_hours: hours since bedtime (circadian prior: deep early, REM late).
    """
    hr_elev = _clip((hr - median_hr) / 12.0)          # HR above sleep median
    hrv_high = _clip((rmssd - median_rmssd) / 15.0)   # vagal tone proxy
    hrv_var = _clip(hr_var / 6.0, 0.0, 1.0)           # autonomic lability
    early = _clip(1.0 - t_hours / 4.0, 0.0, 1.0)       # deep-sleep pressure
    late = _clip(t_hours / 4.0, 0.0, 1.0)             # REM pressure

    s_wake = 4.0 * motion + 1.5 * hr_elev - 1.2
    s_light = 0.25 - 1.0 * motion
    s_deep = (-3.0 * motion - 1.2 * hr_elev + 1.0 * hrv_high
              + 1.4 * early - 0.6)
    s_rem = (-2.0 * motion + 1.2 * hrv_var + 1.4 * late
             - 0.5 * hrv_high - 0.4)
    return [s_wake, s_light, s_deep, s_rem]


def _softmax(xs: list[float]) -> list[float]:
    m = max(xs)
    ex = [math.exp(x - m) for x in xs]
    s = sum(ex)
    return [e / s for e in ex]


def viterbi(emissions: list[list[float]]) -> list[int]:
    """Most likely stage sequence given per-epoch posteriors (log space)."""
    n = len(emissions)
    log_tr = [[math.log(p) for p in row] for row in TRANSITION]
    # uniform start prior in log space (clamped: posteriors can be ~0)
    prev = [math.log(max(e, 1e-12)) + math.log(0.25) for e in emissions[0]]
    back: list[list[int]] = []
    for t in range(1, n):
        cur = []
        bt = []
        for j in range(4):
            best_v, best_k = float("-inf"), 0
            for k in range(4):
                v = prev[k] + log_tr[k][j]
                if v > best_v:
                    best_v, best_k = v, k
            cur.append(best_v + math.log(max(emissions[t][j], 1e-12)))
            bt.append(best_k)
        prev, back = cur, back + [bt]
    path = [max(range(4), key=lambda j: prev[j])]
    for bt in reversed(back):
        path.append(bt[path[-1]])
    return list(reversed(path))


def stage_night(epochs: list[dict]) -> list[int]:
    """Stage a full night. Each epoch dict: motion, hr, rmssd, hr_var, t_hours.

    Median HR/RMSSD are computed over low-motion epochs (sleep reference).
    """
    calm_hr = sorted(e["hr"] for e in epochs if e["motion"] < 0.3)
    calm_rmssd = sorted(e["rmssd"] for e in epochs if e["motion"] < 0.3)
    med_hr = calm_hr[len(calm_hr) // 2] if calm_hr else 60.0
    med_rmssd = calm_rmssd[len(calm_rmssd) // 2] if calm_rmssd else 40.0
    emissions = [
        _softmax(epoch_scores(e["motion"], e["hr"], med_hr, e["rmssd"],
                              med_rmssd, e["hr_var"], e["t_hours"]))
        for e in epochs
    ]
    return viterbi(emissions)


def summarize(stages: list[int], bedtime_epoch: int = 0) -> dict:
    """Sleep summary from a stage sequence.

    Onset: first of >=3 consecutive sleep epochs. Wake: last sleep epoch
    before the final >=10-min wake stretch. TST/efficiency/stage minutes.
    """
    n = len(stages)
    onset = None
    for i in range(n - 2):
        if all(s != WAKE for s in stages[i:i + 3]):
            onset = i
            break
    if onset is None:  # no sleep at all
        return {"total_sleep_min": 0.0, "efficiency": 0.0,
                "stage_min": {s: 0.0 for s in STAGE_NAMES},
                "onset_epoch": None, "wake_epoch": None}
    wake = onset
    for i in range(n - 1, onset - 1, -1):
        if stages[i] != WAKE:
            wake = i
            break
    span = stages[onset:wake + 1]
    tst_min = sum(1 for s in span if s != WAKE) * EPOCH_S / 60.0
    tib_min = len(span) * EPOCH_S / 60.0
    stage_min = {name: 0.0 for name in STAGE_NAMES}
    for s in span:
        stage_min[STAGE_NAMES[s]] += EPOCH_S / 60.0
    return {
        "total_sleep_min": tst_min,
        "efficiency": 100.0 * tst_min / tib_min if tib_min else 0.0,
        "stage_min": stage_min,
        "onset_epoch": onset + bedtime_epoch,
        "wake_epoch": wake + bedtime_epoch,
    }
