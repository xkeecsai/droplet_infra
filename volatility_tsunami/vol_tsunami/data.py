"""Data loaders. yfinance for ^VIX (1990-) and ^VVIX (2007-)."""

from __future__ import annotations

import logging
from functools import lru_cache
from typing import Optional

import pandas as pd
import yfinance as yf

log = logging.getLogger(__name__)


def _download(ticker: str, start: Optional[str] = None) -> pd.DataFrame:
    df = yf.download(
        ticker,
        start=start,
        progress=False,
        auto_adjust=False,
        threads=False,
    )
    if df is None or df.empty:
        raise RuntimeError(f"yfinance returned no data for {ticker}")
    # yfinance may return a MultiIndex column frame even for a single ticker
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    df.index = pd.DatetimeIndex(df.index).tz_localize(None).normalize()
    df = df.rename(columns=str.lower)
    keep = [c for c in ("open", "high", "low", "close", "adj close", "volume") if c in df.columns]
    return df[keep].astype("float64")


@lru_cache(maxsize=4)
def load_vix_history(start: str = "1990-01-01") -> pd.DataFrame:
    """Returns OHLC for ^VIX. ``high`` is required for the intraday-high spike rule."""
    return _download("^VIX", start=start)


@lru_cache(maxsize=4)
def load_vvix_history(start: str = "2007-01-01") -> pd.DataFrame:
    """Returns OHLC for ^VVIX. Note: VVIX history begins March 2007."""
    return _download("^VVIX", start=start)


def load_universe(start: str = "2007-01-01") -> pd.DataFrame:
    """Returns a single frame with vix_close, vix_high, vvix_close aligned to VIX trading days."""
    vix = load_vix_history(start=start)
    vvix = load_vvix_history(start=start)
    df = pd.DataFrame(
        {
            "vix_close": vix["close"],
            "vix_high": vix["high"],
            "vvix_close": vvix["close"],
        }
    )
    df = df.dropna(subset=["vix_close", "vix_high"]).sort_index()
    return df
