"""Backtest scaffolding for the Thrasher volatility-tsunami signal.

The backtest is **diagnostic**, not a return series — the paper's claim is about
the *hit rate* of compressed-VIX days predicting future spikes, plus the size of
those spikes when they materialise. We surface those statistics rather than a
P&L curve, since the paper does not propose a specific tradeable expression.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import numpy as np
import pandas as pd

from .signals import (
    SignalConfig,
    combined_signal,
    compute_features,
    detect_spikes,
    forward_max_move,
)


@dataclass
class BacktestResult:
    """Per-signal evaluation result."""

    config: SignalConfig
    signals_df: pd.DataFrame  # one row per fire date, with diagnostics
    summary: dict  # hit rate, mean forward move, etc.

    def hit_rate(self) -> float:
        return float(self.summary.get("hit_rate", float("nan")))

    def n(self) -> int:
        return int(self.summary.get("n_signals", 0))


def _summarise(signal_dates: pd.DatetimeIndex, fwd_move: pd.Series, hits: pd.Series) -> dict:
    n = len(signal_dates)
    if n == 0:
        return {
            "n_signals": 0,
            "hit_rate": float("nan"),
            "mean_fwd_move": float("nan"),
            "median_fwd_move": float("nan"),
            "p75_fwd_move": float("nan"),
            "p90_fwd_move": float("nan"),
        }
    moves = fwd_move.reindex(signal_dates).dropna()
    return {
        "n_signals": int(n),
        "hit_rate": float(hits.reindex(signal_dates).fillna(False).mean()),
        "mean_fwd_move": float(moves.mean()) if len(moves) else float("nan"),
        "median_fwd_move": float(moves.median()) if len(moves) else float("nan"),
        "p75_fwd_move": float(moves.quantile(0.75)) if len(moves) else float("nan"),
        "p90_fwd_move": float(moves.quantile(0.90)) if len(moves) else float("nan"),
    }


def evaluate_signal(
    universe: pd.DataFrame,
    cfg: SignalConfig = SignalConfig(),
    use_vvix_filter: bool = True,
    horizon: Optional[int] = None,
) -> BacktestResult:
    """Run the diagnostic backtest.

    Parameters
    ----------
    universe : DataFrame
        From ``data.load_universe()``. Must have vix_close, vix_high, vvix_close.
    cfg : SignalConfig
    use_vvix_filter : bool
        If True, the combined signal is used. If False, the compressed-VIX
        signal is evaluated standalone (paper compares both).
    horizon : int, optional
        Forward window for the "did a spike happen?" label. Defaults to
        ``cfg.spike_window``.
    """
    horizon = horizon or cfg.spike_window

    features = compute_features(universe, cfg)
    signals = combined_signal(features, cfg)
    spike = detect_spikes(universe, cfg)
    fwd = forward_max_move(universe, horizon)

    fire = signals["combined_signal"] if use_vvix_filter else signals["compressed_signal"]
    fire_dates = fire[fire].index

    diag = pd.DataFrame(
        {
            "vix_close": universe["vix_close"].reindex(fire_dates),
            "vix_std20": features["vix_std20"].reindex(fire_dates),
            "vvix_close": universe["vvix_close"].reindex(fire_dates),
            "fwd_max_move": fwd.reindex(fire_dates),
            "spike_hit": spike.reindex(fire_dates).fillna(False),
        }
    )

    summary = _summarise(fire_dates, fwd, spike)
    summary["base_rate"] = float(spike.mean())  # unconditional prob of a spike
    summary["lift"] = (
        summary["hit_rate"] / summary["base_rate"] if summary["base_rate"] > 0 else float("nan")
    )
    summary["mode"] = "compressed+vvix" if use_vvix_filter else "compressed_only"

    return BacktestResult(config=cfg, signals_df=diag, summary=summary)
