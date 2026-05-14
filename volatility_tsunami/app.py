"""Volatility Tsunami dashboard — Dash app.

Replicates Andrew Thrasher's 2017 CMT/Dow-Award paper "Forecasting a Volatility
Tsunami". The signal: VIX 20-day standard deviation drops into the bottom
``percentile`` (default 15%) of its expanding history for the first time in
``cooldown`` (default 10) trading days, optionally confirmed by elevated VVIX.
The label: a 30% rise from close to intraday-high inside the next 5 trading days.

Run locally:
    PORT=8054 python app.py
Or inside Docker — see the project Dockerfile.
"""

from __future__ import annotations

import logging
import os
from datetime import date

import dash
from dash import Input, Output, dcc, html

from vol_tsunami import (
    SignalConfig,
    combined_signal,
    compute_features,
    detect_spikes,
    evaluate_signal,
    load_universe,
)
from vol_tsunami.plotting import PALETTE, fwd_move_distribution, signal_chart

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
log = logging.getLogger("vol_tsunami.app")

PORT = int(os.environ.get("PORT", 8054))
DEFAULT_START = os.environ.get("VOL_TSUNAMI_START", "2007-01-01")

app = dash.Dash(__name__, title="Volatility Tsunami")
server = app.server  # for gunicorn

_PARAM_STYLE = {
    "display": "flex",
    "flexDirection": "column",
    "gap": "4px",
    "minWidth": "140px",
}
_INPUT_STYLE = {
    "backgroundColor": "#1c1f2b",
    "color": PALETTE["text"],
    "border": f"1px solid {PALETTE['grid']}",
    "padding": "4px 8px",
    "borderRadius": "4px",
}


def _stat_card(label: str, value: str) -> html.Div:
    return html.Div(
        [
            html.Div(label, style={"fontSize": "12px", "color": "#8d93a3"}),
            html.Div(value, style={"fontSize": "22px", "fontWeight": 600}),
        ],
        style={
            "backgroundColor": "#1c1f2b",
            "padding": "12px 16px",
            "borderRadius": "8px",
            "minWidth": "150px",
        },
    )


app.layout = html.Div(
    [
        html.Div(
            [
                html.H2("Volatility Tsunami", style={"margin": 0}),
                html.Div(
                    "Thrasher (2017) — compressed VIX dispersion as a leading indicator of vol spikes",
                    style={"color": "#8d93a3", "fontSize": "13px"},
                ),
            ],
            style={"marginBottom": "16px"},
        ),
        html.Div(
            [
                html.Div(
                    [
                        html.Label("VIX std window"),
                        dcc.Input(
                            id="std-window",
                            type="number",
                            value=20,
                            min=5,
                            max=120,
                            style=_INPUT_STYLE,
                        ),
                    ],
                    style=_PARAM_STYLE,
                ),
                html.Div(
                    [
                        html.Label("Dispersion percentile"),
                        dcc.Input(
                            id="percentile",
                            type="number",
                            value=15,
                            min=1,
                            max=50,
                            step=1,
                            style=_INPUT_STYLE,
                        ),
                    ],
                    style=_PARAM_STYLE,
                ),
                html.Div(
                    [
                        html.Label("Cooldown (days)"),
                        dcc.Input(
                            id="cooldown",
                            type="number",
                            value=10,
                            min=1,
                            max=60,
                            step=1,
                            style=_INPUT_STYLE,
                        ),
                    ],
                    style=_PARAM_STYLE,
                ),
                html.Div(
                    [
                        html.Label("Spike %"),
                        dcc.Input(
                            id="spike-pct",
                            type="number",
                            value=30,
                            min=5,
                            max=100,
                            step=1,
                            style=_INPUT_STYLE,
                        ),
                    ],
                    style=_PARAM_STYLE,
                ),
                html.Div(
                    [
                        html.Label("Spike window (days)"),
                        dcc.Input(
                            id="spike-window",
                            type="number",
                            value=5,
                            min=1,
                            max=20,
                            step=1,
                            style=_INPUT_STYLE,
                        ),
                    ],
                    style=_PARAM_STYLE,
                ),
                html.Div(
                    [
                        html.Label("VVIX confirm?"),
                        dcc.RadioItems(
                            id="vvix-filter",
                            options=[
                                {"label": "On", "value": "on"},
                                {"label": "Off", "value": "off"},
                            ],
                            value="on",
                            inline=True,
                        ),
                    ],
                    style=_PARAM_STYLE,
                ),
                html.Div(
                    [
                        html.Label("Start"),
                        dcc.DatePickerSingle(
                            id="start-date",
                            date=DEFAULT_START,
                            min_date_allowed=date(1990, 1, 1),
                            max_date_allowed=date.today(),
                        ),
                    ],
                    style=_PARAM_STYLE,
                ),
            ],
            style={
                "display": "flex",
                "flexWrap": "wrap",
                "gap": "16px",
                "marginBottom": "20px",
            },
        ),
        html.Div(id="stat-row", style={"display": "flex", "gap": "12px", "flexWrap": "wrap"}),
        dcc.Loading(
            dcc.Graph(id="signal-chart", style={"height": "70vh"}),
            color=PALETTE["signal"],
        ),
        dcc.Loading(
            dcc.Graph(id="fwd-hist", style={"height": "40vh"}),
            color=PALETTE["signal"],
        ),
        html.Div(
            "Data: yfinance ^VIX (1990-) and ^VVIX (2007-). Source: Thrasher, A. — "
            "Forecasting a Volatility Tsunami (2017 CMT Dow Award).",
            style={"color": "#8d93a3", "fontSize": "12px", "marginTop": "12px"},
        ),
    ],
    style={
        "fontFamily": "Inter, system-ui, sans-serif",
        "backgroundColor": PALETTE["background"],
        "color": PALETTE["text"],
        "padding": "20px",
        "minHeight": "100vh",
    },
)


@app.callback(
    Output("signal-chart", "figure"),
    Output("fwd-hist", "figure"),
    Output("stat-row", "children"),
    Input("std-window", "value"),
    Input("percentile", "value"),
    Input("cooldown", "value"),
    Input("spike-pct", "value"),
    Input("spike-window", "value"),
    Input("vvix-filter", "value"),
    Input("start-date", "date"),
)
def refresh(std_window, percentile, cooldown, spike_pct, spike_window, vvix_filter, start_date):
    cfg = SignalConfig(
        std_window=int(std_window or 20),
        percentile=float(percentile or 15) / 100,
        cooldown=int(cooldown or 10),
        spike_pct=float(spike_pct or 30) / 100,
        spike_window=int(spike_window or 5),
    )
    use_vvix = vvix_filter == "on"

    universe = load_universe(start=start_date or DEFAULT_START)
    features = compute_features(universe, cfg)
    signals = combined_signal(features, cfg)
    spike = detect_spikes(universe, cfg)

    # If VVIX filter is off, show the compressed-only signal column on the chart
    if not use_vvix:
        signals = signals.copy()
        signals["combined_signal"] = signals["compressed_signal"]

    fig_main = signal_chart(universe, features, signals, spike)

    result = evaluate_signal(universe, cfg, use_vvix_filter=use_vvix)
    fig_hist = fwd_move_distribution(result.signals_df)

    summary = result.summary
    cards = [
        _stat_card("Signals", f"{summary['n_signals']}"),
        _stat_card("Hit rate", f"{summary['hit_rate'] * 100:.1f}%"),
        _stat_card("Base rate", f"{summary['base_rate'] * 100:.1f}%"),
        _stat_card(
            "Lift", f"{summary['lift']:.2f}×" if summary["lift"] == summary["lift"] else "—"
        ),
        _stat_card("Mean fwd move", f"{summary['mean_fwd_move'] * 100:.1f}%"),
        _stat_card("Median fwd move", f"{summary['median_fwd_move'] * 100:.1f}%"),
    ]
    return fig_main, fig_hist, cards


if __name__ == "__main__":
    log.info("starting Volatility Tsunami dashboard on :%s", PORT)
    app.run(host="0.0.0.0", port=PORT, debug=False)
