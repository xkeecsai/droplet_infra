# volatility_tsunami

Replication of Andrew Thrasher's **Forecasting a Volatility Tsunami** (2017 CMT Charles H. Dow Award).

> A 20-day standard deviation of VIX closes that compresses into the bottom percentile of its own history has historically preceded large upward spikes in VIX. Adding a VVIX confirmation filter sharpens the timing.

## Signal definitions

| Concept | Default |
|---|---|
| `std_window` — rolling std of VIX closes | 20 trading days |
| `percentile` — dispersion enters this expanding-quantile zone | 15th percentile |
| `cooldown` — gap between successive fires | 10 trading days |
| `spike_pct` — close → intraday-high move that defines a spike | 30% |
| `spike_window` — forward window for the spike label | 5 trading days |
| `vvix_percentile` — VVIX confirmation threshold | 50th percentile (expanding) |

The primary signal fires when the 20-day std drops into its bottom 15th percentile **for the first time in at least 10 trading days**. The combined signal additionally requires VVIX to sit at or above its own 50th-percentile expanding rank.

The "did a spike happen?" label looks forward five trading days from the signal date and asks whether VIX's *intraday high* exceeded the signal day's close by 30% — matching the paper's definition.

## Repository layout

```
volatility_tsunami/
├── app.py                    # Dash dashboard entrypoint (port 8054)
├── Dockerfile                # gunicorn / dash image
├── requirements.txt
├── vol_tsunami/
│   ├── data.py               # yfinance VIX/VVIX loaders
│   ├── signals.py            # SignalConfig + compute_features + signal rules
│   ├── backtest.py           # evaluate_signal() → hit rate, lift, fwd moves
│   └── plotting.py           # plotly chart builders
└── scripts/
    └── backtest_cli.py       # run the backtest from the command line
```

## Run locally

```bash
pip install -r requirements.txt

# CLI backtest
python scripts/backtest_cli.py --start 2007-01-01 --csv signals.csv

# Dashboard
PORT=8054 python app.py
# → http://localhost:8054
```

## Run on the droplet

The droplet_infra repo wires this dashboard at `https://vol-tsunami.<tailnet>.ts.net`.

```bash
ssh kx-macro 'cd /opt/kx/droplet_infra && make deploy-vol-tsunami'
```

## Caveats

- The "spike hit rate" is a diagnostic, not a P&L. The paper makes no claim of a specific tradeable expression — common follow-ons are buying VIX calls, long VXX, or long /VX futures.
- Hit rates are sensitive to the percentile threshold; the dashboard exposes sliders so you can stress-test it.
- VVIX only goes back to March 2007, so any combined-signal backtest is bounded by that.

## Sources

- Thrasher, A. (2017). *Forecasting a Volatility Tsunami*. CMT Association — Charles H. Dow Award.
- yfinance ticker symbols: `^VIX`, `^VVIX`.
