"""Plotly chart builders shared between the Dash app and any notebooks."""

from __future__ import annotations

import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots


PALETTE = {
    "vix": "#e6e6e6",
    "vix_std": "#ffb86b",
    "threshold": "#ff5d5d",
    "vvix": "#7cc8ff",
    "vvix_thresh": "#5d8eff",
    "signal": "#ffd93d",
    "spike": "#ff5d5d",
    "background": "#0e1117",
    "grid": "#222633",
    "text": "#e6e6e6",
}


def _style(fig: go.Figure, title: str) -> go.Figure:
    fig.update_layout(
        title=title,
        template="plotly_dark",
        paper_bgcolor=PALETTE["background"],
        plot_bgcolor=PALETTE["background"],
        font=dict(color=PALETTE["text"]),
        margin=dict(l=40, r=20, t=60, b=40),
        hovermode="x unified",
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
    )
    fig.update_xaxes(gridcolor=PALETTE["grid"], zerolinecolor=PALETTE["grid"])
    fig.update_yaxes(gridcolor=PALETTE["grid"], zerolinecolor=PALETTE["grid"])
    return fig


def signal_chart(
    universe: pd.DataFrame,
    features: pd.DataFrame,
    signals: pd.DataFrame,
    spike: pd.Series,
) -> go.Figure:
    """Three-panel chart: VIX with signal/spike markers; 20d std vs threshold; VVIX vs threshold."""
    fig = make_subplots(
        rows=3,
        cols=1,
        shared_xaxes=True,
        vertical_spacing=0.04,
        row_heights=[0.5, 0.25, 0.25],
        subplot_titles=("VIX (close, intraday high)", "VIX 20d std vs p15", "VVIX vs p50"),
    )

    fig.add_trace(
        go.Scatter(
            x=universe.index,
            y=universe["vix_close"],
            mode="lines",
            name="VIX close",
            line=dict(color=PALETTE["vix"], width=1),
        ),
        row=1,
        col=1,
    )

    combined = signals["combined_signal"]
    fire_dates = combined[combined].index
    if len(fire_dates):
        fig.add_trace(
            go.Scatter(
                x=fire_dates,
                y=universe["vix_close"].reindex(fire_dates),
                mode="markers",
                name="Signal",
                marker=dict(color=PALETTE["signal"], size=8, symbol="triangle-up"),
            ),
            row=1,
            col=1,
        )

    spike_dates = spike[spike].index
    if len(spike_dates):
        fig.add_trace(
            go.Scatter(
                x=spike_dates,
                y=universe["vix_close"].reindex(spike_dates),
                mode="markers",
                name="Spike (forward 30%/5d)",
                marker=dict(color=PALETTE["spike"], size=4, symbol="x"),
                opacity=0.5,
            ),
            row=1,
            col=1,
        )

    fig.add_trace(
        go.Scatter(
            x=features.index,
            y=features["vix_std20"],
            name="VIX 20d std",
            line=dict(color=PALETTE["vix_std"], width=1),
        ),
        row=2,
        col=1,
    )
    fig.add_trace(
        go.Scatter(
            x=features.index,
            y=features["vix_std20_pct_thresh"],
            name="p15 threshold",
            line=dict(color=PALETTE["threshold"], width=1, dash="dash"),
        ),
        row=2,
        col=1,
    )

    fig.add_trace(
        go.Scatter(
            x=universe.index,
            y=universe["vvix_close"],
            name="VVIX close",
            line=dict(color=PALETTE["vvix"], width=1),
        ),
        row=3,
        col=1,
    )
    fig.add_trace(
        go.Scatter(
            x=features.index,
            y=features["vvix_pct_thresh"],
            name="p50 threshold",
            line=dict(color=PALETTE["vvix_thresh"], width=1, dash="dash"),
        ),
        row=3,
        col=1,
    )

    return _style(fig, "Volatility Tsunami — Thrasher (2017)")


def fwd_move_distribution(signal_diag: pd.DataFrame) -> go.Figure:
    """Distribution of forward max moves on signal days."""
    fig = go.Figure()
    if not signal_diag.empty:
        fig.add_trace(
            go.Histogram(
                x=signal_diag["fwd_max_move"] * 100,
                nbinsx=30,
                marker=dict(color=PALETTE["signal"]),
                name="fwd max VIX move (%)",
            )
        )
    return _style(fig, "Forward max VIX move on signal days (%)")
