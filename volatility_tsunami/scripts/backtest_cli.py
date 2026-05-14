"""Run the Thrasher volatility-tsunami backtest from the command line.

Usage:
    python scripts/backtest_cli.py [--start 2007-01-01] [--no-vvix] [--csv out.csv]

Prints summary stats and (optionally) writes the per-signal diagnostic frame.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Allow running directly from the repo root without installing
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from vol_tsunami import SignalConfig, evaluate_signal, load_universe  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser(description="Volatility Tsunami backtest")
    p.add_argument("--start", default="2007-01-01")
    p.add_argument("--std-window", type=int, default=20)
    p.add_argument("--percentile", type=float, default=0.15)
    p.add_argument("--cooldown", type=int, default=10)
    p.add_argument("--spike-pct", type=float, default=0.30)
    p.add_argument("--spike-window", type=int, default=5)
    p.add_argument(
        "--no-vvix",
        action="store_true",
        help="Evaluate the compressed-VIX signal standalone (no VVIX confirm filter)",
    )
    p.add_argument("--csv", type=Path, help="Write per-signal diagnostic frame to this CSV")
    args = p.parse_args()

    cfg = SignalConfig(
        std_window=args.std_window,
        percentile=args.percentile,
        cooldown=args.cooldown,
        spike_pct=args.spike_pct,
        spike_window=args.spike_window,
    )

    print(f"Loading VIX/VVIX from yfinance (start={args.start})...", file=sys.stderr)
    universe = load_universe(start=args.start)
    print(f"  rows: {len(universe)}  range: {universe.index.min().date()} → {universe.index.max().date()}", file=sys.stderr)

    result = evaluate_signal(universe, cfg, use_vvix_filter=not args.no_vvix)
    print(json.dumps(result.summary, indent=2, default=str))

    if args.csv:
        result.signals_df.to_csv(args.csv)
        print(f"Wrote {len(result.signals_df)} signal rows to {args.csv}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
