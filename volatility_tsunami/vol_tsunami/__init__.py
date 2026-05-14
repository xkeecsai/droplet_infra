"""Volatility Tsunami — Andrew Thrasher (2017) signal replication."""

from .data import load_vix_history, load_vvix_history, load_universe
from .signals import (
    compute_features,
    compressed_dispersion_signal,
    elevated_vvix_filter,
    combined_signal,
    detect_spikes,
    SignalConfig,
)
from .backtest import evaluate_signal, BacktestResult

__all__ = [
    "load_vix_history",
    "load_vvix_history",
    "load_universe",
    "compute_features",
    "compressed_dispersion_signal",
    "elevated_vvix_filter",
    "combined_signal",
    "detect_spikes",
    "SignalConfig",
    "evaluate_signal",
    "BacktestResult",
]
