"""Reproduce the numbers in README.md: per-symbol results and simulated FTMO attempts."""

import pandas as pd

import backtest as bt

IS, OOS = ("2009-01-01", "2019-12-31"), ("2020-01-01", "2026-12-31")


def main() -> None:
    p = bt.Params()
    all_trades = pd.concat([bt.trades(bt.load(s), p, s) for s in bt.COSTS])

    print("Momentum burst, default parameters, after costs")
    for name, (a, b) in {"In-sample 2009-2019": IS, "Out-of-sample 2020-2026": OOS}.items():
        t = all_trades[(all_trades.entry_date >= a) & (all_trades.entry_date <= b)]
        print(f"\n{name}: {bt.summarize(t)}")
        for sym, g in t.groupby("symbol"):
            print(f"  {sym:7s} {bt.summarize(g)}")

    print("\nSimulated FTMO phase 1 (+10% target, 5% daily, 10% max), new start every month")
    for risk in (0.005, 0.01):
        res = bt.ftmo_attempts(all_trades, risk_pct=risk)
        counts = res.result.value_counts().to_dict()
        passed = res[res.result == "pass"].days
        print(f"  risk {risk:.1%}/trade: {counts}, median business days to pass: {passed.median() if len(passed) else '-'}")


if __name__ == "__main__":
    main()
