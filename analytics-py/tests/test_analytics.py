"""Tests for the Unwhoop analytics core. Plain asserts, run with:
    python3 tests/test_analytics.py
All expected values below were hand-computed independently of the
implementation (see comments). Tolerance 1e-2 unless noted.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import numpy as np

from unwhoop import rr, resp, recovery, sleep, sleep_score, strain, benchmark


def approx(a, b, tol=1e-2):
    assert abs(a - b) <= tol, f"{a} != {b} (tol {tol})"


# ---------- rr.py ----------

def test_rmssd_known_series():
    # diffs: 10, -20, 15 -> squares 100, 400, 225 -> mean 241.667 -> sqrt
    approx(rr.rmssd([800, 810, 790, 805]), 15.5456)
    approx(rr.ln_rmssd([800, 810, 790, 805]), math.log(15.5456))


def test_clean_rr_flags_ectopic():
    # 400 and 1200 deviate >20% from local median 800 -> flagged & replaced.
    # 2 bad in 20 beats = 10% -> under the low-confidence gate.
    series = [800] * 20
    series[5], series[14] = 400, 1200
    out = rr.clean_rr(series)
    assert out["n_removed"] == 2
    approx(out["artifact_fraction"], 0.10)
    assert not out["low_confidence"]
    assert all(300 <= v <= 2000 for v in out["cleaned"])


def test_clean_rr_low_confidence_gate():
    out = rr.clean_rr([800, 400, 1200, 400, 1200, 800])  # 4/6 bad
    assert out["low_confidence"]


def test_clean_rr_rejects_impossible():
    out = rr.clean_rr([800, 50, 800, 5000, 800])
    assert out["n_removed"] == 2


def test_deepest_sleep_window():
    hr = [70.0] * 30
    for i in range(10, 20):  # calmest stretch at epochs 10-19
        hr[i] = 52.0
    motion = [0.05] * 30
    assert rr.deepest_sleep_window(hr, motion, window_epochs=10) == 10


def test_deepest_sleep_window_restless():
    assert rr.deepest_sleep_window([70.0] * 30, [0.9] * 30) is None


# ---------- resp.py ----------

def test_resp_rate_synthetic_rsa():
    # Pure 0.25 Hz RSA -> 15 breaths/min
    t = np.arange(0, 300, 0.25)
    tach = 800 + 60 * np.sin(2 * np.pi * 0.25 * t)
    v = resp.estimate_from_tachogram(tach)
    assert v is not None
    approx(v, 15.0, tol=0.75)


def test_resp_rate_end_to_end():
    # Beat-sampled RSA at 12 brpm (0.2 Hz), 4 minutes of still data
    t = 0.0
    rr_vals, rr_times = [], []
    while t < 240:
        interval = (820 + 55 * math.sin(2 * math.pi * 0.2 * t)) / 1000.0
        t += interval
        rr_vals.append(interval * 1000.0)
        rr_times.append(t)
    v = resp.estimate_from_rr(rr_vals, rr_times)
    assert v is not None, "expected a reading from clean synthetic RSA"
    approx(v, 12.0, tol=1.5)


def test_resp_rejects_weak_rsa():
    # RSA buried under strong low-frequency drift + noise: HF power is
    # negligible RELATIVE to total HRV power (stress/illness pattern) ->
    # confident "no reading", never a fabricated number.
    rng = np.random.default_rng(7)
    t = np.arange(0, 300, 0.25)
    tach = (800 + 5 * np.sin(2 * np.pi * 0.25 * t)
            + 80 * np.sin(2 * np.pi * 0.05 * t) + rng.normal(0, 10, len(t)))
    assert resp.estimate_from_tachogram(tach) is None


def test_nightly_median_rejects_outliers():
    vals = [14.5, 15.0, 45.0, 14.8, None, 15.2]  # 45 = collapsed-RSA minute
    approx(resp.nightly_respiratory_rate(vals), 14.9, tol=0.2)


# ---------- recovery.py ----------

def test_baseline_building():
    out = recovery.score_night(4.0, 55, 80, [4.0] * 3, [55] * 3, [80] * 3)
    assert out["ready"] is False
    assert out["nights_to_go"] == 4
    assert out["status"] == "building_baseline"


def test_fusion_neutral_is_50_yellow():
    approx(recovery.fuse_recovery(0, 0, 0), 50.0)
    assert recovery.band(50.0) == "yellow"


def test_fusion_extremes():
    # z_hrv=+2, z_rhr=-2 (low RHR = good), z_sleep=+1
    # combined = 1.2 + 0.5 + 0.15 = 1.85 -> 50 + 40.7 = 90.7
    s = recovery.fuse_recovery(2.0, -2.0, 1.0)
    approx(s, 90.7, tol=0.1)
    assert recovery.band(s) == "green"
    s2 = recovery.fuse_recovery(-2.0, 2.0, -1.0)
    assert recovery.band(s2) == "red"
    assert 0.0 <= s2 <= 100.0


def test_full_night_pipeline():
    hist_h = [3.9, 4.0, 4.1, 3.8, 4.0, 4.2, 3.9]
    hist_r = [54, 55, 56, 54, 55, 53, 55]
    hist_p = [80, 82, 78, 85, 80, 83, 81]
    out = recovery.score_night(4.3, 52, 90, hist_h, hist_r, hist_p)
    assert out["ready"] is True
    assert out["z_hrv"] > 0 and out["z_rhr"] < 0  # better than baseline
    assert out["band"] == "green"
    assert out["flags"] == []


def test_confounder_flags():
    assert "alcohol_signature" in recovery.confounder_flags(-1.5, 1.5, 1.0)
    assert "possible_illness" in recovery.confounder_flags(-1.0, 0.5, 3.0)
    assert recovery.confounder_flags(0.2, -0.1, 0.5) == []
    # flagged nights must be excluded from baseline updates: tonight's HRV
    # is crushed and RHR spiked vs a varying baseline -> alcohol signature
    hist_h = [3.9, 4.0, 4.1, 3.9, 4.0, 4.1, 3.9]
    hist_r = [54, 55, 56, 54, 55, 56, 54]
    out = recovery.score_night(3.2, 63, 80, hist_h, hist_r, [80] * 7)
    assert "alcohol_signature" in out["flags"]
    assert out["exclude_from_baseline"] is True


# ---------- sleep.py ----------

def _mk_epoch(stage, t_hours):
    if stage == "wake":
        return dict(motion=0.85, hr=75.0, rmssd=25.0, hr_var=10.0,
                    t_hours=t_hours)
    if stage == "light":
        return dict(motion=0.05, hr=58.0, rmssd=40.0, hr_var=3.0,
                    t_hours=t_hours)
    if stage == "deep":
        return dict(motion=0.02, hr=52.0, rmssd=70.0, hr_var=2.0,
                    t_hours=t_hours)
    return dict(motion=0.03, hr=62.0, rmssd=35.0, hr_var=8.0,
                t_hours=t_hours)  # rem


def test_stage_synthetic_night():
    epochs = []
    plan = (["wake"] * 20 + ["light"] * 40 + ["deep"] * 30
            + ["rem"] * 30 + ["wake"] * 10)
    for i, st in enumerate(plan):
        epochs.append(_mk_epoch(st, i * 30 / 3600))
    stages = sleep.stage_night(epochs)
    s = sleep.summarize(stages)
    # 100 sleep epochs = 50 min of sleep; allow Viterbi edge wobble
    assert 45.0 <= s["total_sleep_min"] <= 55.0, s["total_sleep_min"]
    assert s["onset_epoch"] is not None and s["onset_epoch"] <= 22
    deep_rem = s["stage_min"]["Deep"] + s["stage_min"]["REM"]
    assert deep_rem >= 20.0, s["stage_min"]
    assert s["efficiency"] > 80.0


def test_summarize_no_sleep():
    s = sleep.summarize([sleep.WAKE] * 60)
    assert s["total_sleep_min"] == 0.0
    assert s["onset_epoch"] is None


def test_viterbi_prefers_continuity():
    # Ambiguous middles should not flicker wake/deep/wake/deep
    emissions = [[0.34, 0.33, 0.33, 0.0]] * 12
    path = sleep.viterbi(emissions)
    assert len(set(path)) == 1  # single most-likely run, no flicker


# ---------- strain.py ----------

def test_trimp_hand_computed():
    # male, rest 50, max 190, 60 min at 150 bpm:
    # x = 100/140 = 0.71429; Y = 0.64*e^1.37143 = 2.52213; TRIMP = 1.80159/min
    approx(strain.trimp_minute(150, 50, 190, "male"), 1.8016, tol=1e-3)
    out = strain.day_strain([150.0] * 60, 50, 190, "male")
    approx(out["load"], 108.10, tol=0.3)
    # 21*(1 - e^-1.08095) = 13.87
    approx(out["strain"], 13.87, tol=0.1)


def test_strain_rest_is_zero():
    out = strain.day_strain([52.0] * 600, 52, 190, "male")
    approx(out["strain"], 0.0, tol=1e-6)


def test_strain_saturates_at_21():
    out = strain.day_strain([185.0] * 300, 50, 190, "male")
    assert 0 < out["strain"] <= 21.0
    # monotonic: more load -> more strain, never exceeding 21
    assert strain.load_to_strain(1e9) == 21.0


def test_strain_female_weighting_differs():
    m = strain.trimp_minute(150, 50, 190, "male")
    f = strain.trimp_minute(150, 50, 190, "female")
    assert m != f and m > 0 and f > 0


# ---------- benchmark.py ----------

def test_bland_altman_known():
    # d = [-0.1, -0.2, 0.1]; bias = -0.0667; sd (ddof=1) = 0.1528
    r = benchmark.bland_altman([1, 2, 3], [1.1, 2.2, 2.9])
    approx(r["bias"], -0.0667, tol=1e-3)
    approx(r["sd"], 0.1528, tol=1e-3)
    approx(r["loa_lower"], -0.0667 - 1.96 * 0.1528, tol=1e-3)
    approx(r["loa_upper"], -0.0667 + 1.96 * 0.1528, tol=1e-3)


def test_mae():
    approx(benchmark.mae([1, 2, 3], [1.1, 2.2, 2.9]), 0.1333, tol=1e-3)


def test_icc_identical_raters_is_one():
    approx(benchmark.icc_a1([[1, 1], [2, 2], [3, 3], [4, 4]]), 1.0)


def test_icc_penalizes_systematic_bias():
    # rater2 = rater1 + 1: hand-derived ICC(A,1) = 2/3
    approx(benchmark.icc_a1([[1, 2], [2, 3], [3, 4]]), 2 / 3, tol=1e-6)


def test_kappa_known():
    # po = 0.85, pe = 0.51 -> k = 0.6939
    approx(benchmark.cohen_kappa([[50, 10], [5, 35]]), 0.6939, tol=1e-3)
    approx(benchmark.pabak([[50, 10], [5, 35]]), 0.70, tol=1e-3)
    assert benchmark.kappa_band(0.55) == "moderate"
    assert benchmark.kappa_band(0.65) == "substantial"


# ---------- sleep_score.py ----------

def test_sleep_score_perfect_night():
    # all components 1.0, default weights -> 100
    approx(sleep_score.sleep_score((1.0, 1.0, 1.0, 1.0)), 100.0)


def test_sleep_score_half_components():
    # all components 0.5 -> 50 regardless of weights (weights sum to 1)
    approx(sleep_score.sleep_score((0.5, 0.5, 0.5, 0.5)), 50.0)
    approx(sleep_score.sleep_score((0.5, 0.5, 0.5, 0.5),
                                   weights=[0.1, 0.2, 0.3, 0.4]), 50.0)


def test_sleep_score_weights():
    # only sufficiency matters here: 0.8 * 100
    approx(sleep_score.sleep_score((0.8, 0.2, 0.2, 0.2),
                                   weights=[1, 0, 0, 0]), 80.0)


def test_normalize_weights():
    # (2,1,1,0) -> (0.5,0.25,0.25,0); negatives clipped; all-zero -> default
    w = sleep_score.normalize_weights([2, 1, 1, 0])
    approx(w[0], 0.5); approx(w[1], 0.25); approx(w[2], 0.25); approx(w[3], 0.0)
    w = sleep_score.normalize_weights([-1, 2, 0, 0])
    approx(w[0], 0.0); approx(w[1], 1.0)
    assert sleep_score.normalize_weights([0, 0, 0, 0]) == [0.35, 0.25, 0.20, 0.20]


def test_sufficiency():
    # 480/480 -> 1.0; 240/480 -> 0.5; oversleep caps at 1.0 (no extra credit)
    approx(sleep_score.sufficiency(480, 480), 1.0)
    approx(sleep_score.sufficiency(240, 480), 0.5)
    approx(sleep_score.sufficiency(600, 480), 1.0)
    approx(sleep_score.sufficiency(480, 0), 0.0)


def test_efficiency():
    # 420/480 -> 0.875; over 1.0 clamps
    approx(sleep_score.efficiency(420, 480), 0.875)
    approx(sleep_score.efficiency(500, 480), 1.0)
    approx(sleep_score.efficiency(420, 0), 0.0)


def test_consistency():
    # 0h dev -> 1; 1.5h -> 0.5; >=3h -> 0
    approx(sleep_score.consistency(0.0), 1.0)
    approx(sleep_score.consistency(1.5), 0.5)
    approx(sleep_score.consistency(3.0), 0.0)
    approx(sleep_score.consistency(5.0), 0.0)


def test_restfulness():
    # rhr 60 vs 55 -> 1-5/12 = 0.5833; hrv 50 vs 50 -> 0.8333; mean = 0.7083
    approx(sleep_score.restfulness(60, 55, 50, 50), 0.7083)
    # rhr at/below baseline and hrv above baseline -> 1.0
    approx(sleep_score.restfulness(52, 55, 60, 50), 1.0)
    # no baselines -> neutral 0.5
    approx(sleep_score.restfulness(60, 0, 50, 0), 0.5)


def test_sleep_need_minutes():
    # base only; strain bump +3/min over 12; debt repays 25% capped at 120 min
    approx(sleep_score.sleep_need_minutes(480, 12, 0), 480.0)
    approx(sleep_score.sleep_need_minutes(480, 18, 0), 498.0)
    approx(sleep_score.sleep_need_minutes(480, 12, 60), 495.0)
    approx(sleep_score.sleep_need_minutes(300, 12, 0), 360.0)   # clamped floor
    approx(sleep_score.sleep_need_minutes(700, 12, 0), 600.0)   # clamped ceiling
    approx(sleep_score.sleep_need_minutes(480, 12, 400), 510.0)  # debt capped


def test_sleep_debt_minutes():
    # shortfalls 80 + 0 + 180 = 260; trailing-7 window; floored at 0
    approx(sleep_score.sleep_debt_minutes([(480, 400), (480, 480), (480, 300)]),
           260.0)
    approx(sleep_score.sleep_debt_minutes([(480, 500)]), 0.0)


def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL {fn.__name__}: {e}")
    print(f"\n{len(fns) - failed}/{len(fns)} passed")
    return failed


if __name__ == "__main__":
    sys.exit(1 if run_all() else 0)
