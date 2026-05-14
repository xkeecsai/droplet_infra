"""Thrasher (2017) — Forecasting a Volatility Tsunami.

Definitions used here (matching the paper):

* **Spike**: VIX rises at least ``spike_pct`` (30%) from a daily close to an
  intraday high inside the next ``spike_window`` (5) trading days.
* **Compressed dispersion**: the 20-day rolling standard deviation of VIX closes
  drops to or below the ``percentile`` (15th) of its own *expanding* history,
  and this is the first such reading in at least ``cooldown`` (10) trading days.
* **VVIX overlay**: an optional confirmation filter requiring VVIX to be at or
  above its own 50th-percentile expanding rank. The paper found combining the
  two improved timeliness.
"""

from __future__ import annotations

from dataclasses import dataclass

import pandas as pd


@dataclass(frozen=True)
class SignalConfig:
    std_window: int = 20
    percentile: float = 0.15  # bottom 15% of dispersion history
    cooldown: int = 10  # bars since previous signal must be >= cooldown
    spike_pct: float = 0.30  # 30% close -> intraday-high move
    spike_window: int = 5  # within next N trading days
    vvix_percentile: float = 0.50  # for the VVIX confirmation filter
    use_expanding_percentile: bool = True
    min_history: int = 252  # bars of warmup before signals are eligible


def _expanding_quantile(s: pd.Series, q: float, min_periods: int) -> pd.Series:
    """Rolling/expanding quantile of ``s`` evaluated at each point in time.

    Uses pandas expanding().quantile which is O(n log n) and avoids look-ahead.
    """
    return s.expanding(min_periods=min_periods).quantile(q)


def compute_features(df: pd.DataFrame, cfg: SignalConfig = SignalConfig()) -> pd.DataFrame:
    """Returns the feature frame used by all downstream rules.

    Required input columns: ``vix_close``, ``vix_high``, ``vvix_close``.
    """
    out = df.copy()
    out["vix_std20"] = out["vix_close"].rolling(cfg.std_window).std(ddof=0)

    if cfg.use_expanding_percentile:
        out["vix_std20_pct_thresh"] = _expanding_quantile(
            out["vix_std20"], cfg.percentile, min_periods=cfg.min_history
        )
        out["vvix_pct_thresh"] = _expanding_quantile(
            out["vvix_close"], cfg.vvix_percentile, min_periods=cfg.min_history
        )
    else:
        thresh_std = out["vix_std20"].quantile(cfg.percentile)
        thresh_vvix = out["vvix_close"].quantile(cfg.vvix_percentile)
        out["vix_std20_pct_thresh"] = thresh_std
        out["vvix_pct_thresh"] = thresh_vvix

    return out


def compressed_dispersion_signal(
    features: pd.DataFrame, cfg: SignalConfig = SignalConfig()
) -> pd.Series:
    """Bool series. True on bars where VIX dispersion enters its low-percentile
    zone for the first time in ``cfg.cooldown`` trading days."""
    below = features["vix_std20"] <= features["vix_std20_pct_thresh"]
    below = below.fillna(False)

    # First touch in `cooldown` window: today below, but no True in prior cooldown bars
    # rolling().sum() on a bool gives count of True in the window
    prior_count = (
        below.shift(1)
        .rolling(cfg.cooldown, min_periods=1)
        .sum()
        .fillna(0)
    )
    first_touch = below & (prior_count == 0)
    first_touch.name = "compressed_signal"
    return first_touch


def elevated_vvix_filter(features: pd.DataFrame) -> pd.Series:
    """Bool series. True when VVIX close is at/above its expanding p50 threshold."""
    f = (features["vvix_close"] >= features["vvix_pct_thresh"]).fillna(False)
    f.name = "vvix_filter"
    return f


def combined_signal(
    features: pd.DataFrame, cfg: SignalConfig = SignalConfig()
) -> pd.DataFrame:
    """Returns a frame with three signal columns:
    ``compressed_signal``, ``vvix_filter``, ``combined_signal``.
    """
    s1 = compressed_dispersion_signal(features, cfg)
    s2 = elevated_vvix_filter(features)
    combined = (s1 & s2).rename("combined_signal")
    return pd.concat([s1, s2, combined], axis=1)


def detect_spikes(
    df: pd.DataFrame, cfg: SignalConfig = SignalConfig()
) -> pd.Series:
    """Bool series. ``True`` on day *t* if the *forward* ``spike_window`` bars
    contain an intraday VIX high that is at least ``(1 + spike_pct)`` × today's
    close. This is the labelling target — it look-ahead biases by design (used
    only for backtest evaluation, not for live signalling)."""
    close = df["vix_close"]
    high = df["vix_high"]

    # forward-looking max of high over next N bars *excluding* today
    fwd_high = (
        high.shift(-1)
        .rolling(cfg.spike_window, min_periods=1)
        .max()
    )
    # rolling(min_periods=1).max() with shift(-1) lookahead leaves NaN at the tail
    spike = (fwd_high / close - 1.0 >= cfg.spike_pct).fillna(False)
    spike.name = "spike_within_window"
    return spike


def forward_max_move(df: pd.DataFrame, window: int) -> pd.Series:
    """Helper for diagnostics: max forward gain in VIX intraday-high over ``window``
    bars, expressed as a percentage of today's close."""
    close = df["vix_close"]
    high = df["vix_high"]
    fwd_high = high.shift(-1).rolling(window, min_periods=1).max()
    return (fwd_high / close - 1.0).rename("fwd_max_move")
