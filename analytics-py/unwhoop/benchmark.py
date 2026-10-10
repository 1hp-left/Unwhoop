"""Benchmark agreement statistics (dev tooling, compiler-gated out of prod).

Evidence basis (PRD Ch. 8):
- NEVER validate with correlation alone. Report:
  - Bland-Altman: bias (mean difference) + 95% limits of agreement
  - ICC (absolute agreement) — Shrout-Fleiss ICC(A,1): two-way random effects,
    single measures, absolute agreement
  - MAE
- Categorical outputs (sleep stages, recovery color bands): confusion matrix +
  Cohen's kappa (Landis & Koch bands: 0.21-0.40 fair, 0.41-0.60 moderate,
  0.61-0.80 substantial) + PABAK (prevalence-and-bias-adjusted kappa, as in
  the Oura Gen3 validation), because kappa is distorted by class imbalance.
- Design notes (Menghini et al. 2021): paired nights, report artifact-rejection
  rates with coverage, stratify by sleep quality.
"""

from __future__ import annotations

import math
import statistics


def bland_altman(a: list[float], b: list[float]) -> dict:
    """Bias and 95% limits of agreement for paired measurements."""
    if len(a) != len(b) or len(a) < 2:
        raise ValueError("need >=2 paired measurements")
    d = [x - y for x, y in zip(a, b)]
    bias = statistics.fmean(d)
    sd = statistics.pstdev(d) if len(d) == 2 else statistics.stdev(d)
    return {
        "bias": bias,
        "sd": sd,
        "loa_lower": bias - 1.96 * sd,
        "loa_upper": bias + 1.96 * sd,
        "n": len(d),
    }


def mae(a: list[float], b: list[float]) -> float:
    return statistics.fmean(abs(x - y) for x, y in zip(a, b))


def icc_a1(ratings: list[list[float]]) -> float:
    """ICC(A,1) absolute agreement, two raters, n targets.

    ratings[i] = [rater1_score, rater2_score] for target i.
    ANOVA decomposition: MSR (rows/targets), MSC (columns/raters), MSE.
    ICC(A,1) = (MSR - MSE) / (MSR + (k-1)*MSE + (k/n)*(MSC - MSE)).
    """
    n = len(ratings)
    k = 2
    if n < 2 or any(len(r) != k for r in ratings):
        raise ValueError("need >=2 targets x 2 raters")
    flat = [v for row in ratings for v in row]
    grand = statistics.fmean(flat)
    row_means = [statistics.fmean(row) for row in ratings]
    col_means = [statistics.fmean([ratings[i][j] for i in range(n)])
                 for j in range(k)]
    ssr = k * sum((m - grand) ** 2 for m in row_means)
    ssc = n * sum((m - grand) ** 2 for m in col_means)
    sst = sum((v - grand) ** 2 for v in flat)
    sse = sst - ssr - ssc
    df_r, df_c, df_e = n - 1, k - 1, (n - 1) * (k - 1)
    msr, msc, mse = ssr / df_r, ssc / df_c, sse / df_e if df_e else 0.0
    denom = msr + (k - 1) * mse + (k / n) * (msc - mse)
    if denom == 0:
        return 1.0 if mse == 0 else 0.0
    return (msr - mse) / denom


def cohen_kappa(confusion: list[list[int]]) -> float:
    """Cohen's kappa from a square confusion matrix (rows=true, cols=pred)."""
    n = sum(sum(row) for row in confusion)
    if n == 0:
        return 0.0
    po = sum(confusion[i][i] for i in range(len(confusion))) / n
    pe = 0.0
    for i in range(len(confusion)):
        row_sum = sum(confusion[i])
        col_sum = sum(confusion[r][i] for r in range(len(confusion)))
        pe += row_sum * col_sum / (n * n)
    return (po - pe) / (1 - pe) if pe < 1 else 0.0


def pabak(confusion: list[list[int]]) -> float:
    """Prevalence-and-bias-adjusted kappa: 2*po - 1."""
    n = sum(sum(row) for row in confusion)
    if n == 0:
        return 0.0
    po = sum(confusion[i][i] for i in range(len(confusion))) / n
    return 2 * po - 1


def kappa_band(k: float) -> str:
    """Landis & Koch (1977) bands."""
    if k < 0:
        return "poor"
    if k <= 0.20:
        return "slight"
    if k <= 0.40:
        return "fair"
    if k <= 0.60:
        return "moderate"
    if k <= 0.80:
        return "substantial"
    return "almost_perfect"
