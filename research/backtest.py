"""Daily-bar momentum-burst backtest adapted from stockbee-momentum-burst-screener.

Stockbee's stock trigger (+4% day on rising volume, range expansion, close near
the high, stop at trigger-day low, 3-5 day hold) is translated to CFDs:
the move is measured in ATR units instead of percent, tick volume is ignored.

Signal on the close of bar t, entry at the open of bar t+1. The MQL5 EA in
mql5/Experts/MomentumBurstEA.mq5 implements the same rules.
"""

from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# Round-trip spread + commission + slippage in price units, and annual
# financing rate charged per overnight hold (assumed charged on both sides).
COSTS = {
    "US100": {"round_trip": 2.0, "swap_rate": 0.06},
    "EURUSD": {"round_trip": 0.00020, "swap_rate": 0.02},
    "GBPUSD": {"round_trip": 0.00025, "swap_rate": 0.02},
    "USDJPY": {"round_trip": 0.025, "swap_rate": 0.02},
    "XAUUSD": {"round_trip": 0.40, "swap_rate": 0.05},
    "USOIL": {"round_trip": 0.05, "swap_rate": 0.06},
}


@dataclass(frozen=True)
class Params:
    atr_len: int = 20
    trigger_atr: float = 1.0  # close-to-close move >= trigger_atr * ATR
    close_loc_min: float = 0.7  # close in top 30% of the bar (bottom 30% for shorts)
    max_stop_atr: float = 2.0  # skip if stop is further than this many ATRs
    hold_days: int = 5  # time exit at close of the hold_days-th bar
    tp_r: float | None = None  # optional take profit in R multiples
    allow_short: bool = True
    skip_after_3_runup: bool = True  # Stockbee failure filter


def load(symbol: str, start: str = "2009-01-01") -> pd.DataFrame:
    df = pd.read_csv(DATA_DIR / f"{symbol}.csv", index_col=0, parse_dates=True)
    return clean(df).loc[start:]


def clean(df: pd.DataFrame) -> pd.DataFrame:
    """Repair Yahoo bar inconsistencies and drop bars that are clearly bad data."""
    df = df.copy()
    df["High"] = df[["Open", "High", "Low", "Close"]].max(axis=1)
    df["Low"] = df[["Open", "High", "Low", "Close"]].min(axis=1)
    rng = df["High"] - df["Low"]
    prev_atr = rng.rolling(20).mean().shift(1)
    bad = (rng <= 0) | (df["Low"] <= 0) | (rng > 10 * prev_atr)
    return df[~bad]


def signals(df: pd.DataFrame, p: Params) -> pd.Series:
    """+1 long, -1 short, 0 none, evaluated on the close of each bar."""
    o, h, l, c = df["Open"], df["High"], df["Low"], df["Close"]
    rng = h - l
    atr = rng.rolling(p.atr_len).mean().shift(1)  # ATR of prior bars only
    move = c - c.shift(1)
    expansion = rng > rng.shift(1).rolling(3).max()
    loc = (c - l) / rng

    up = c > c.shift(1)
    runup3 = up.shift(1) & up.shift(2) & up.shift(3)
    down = c < c.shift(1)
    rundown3 = down.shift(1) & down.shift(2) & down.shift(3)

    long_ = (move >= p.trigger_atr * atr) & expansion & (loc >= p.close_loc_min)
    short = (-move >= p.trigger_atr * atr) & expansion & (loc <= 1 - p.close_loc_min)
    if p.skip_after_3_runup:
        long_ &= ~runup3.fillna(False).astype(bool)
        short &= ~rundown3.fillna(False).astype(bool)
    if not p.allow_short:
        short[:] = False
    sig = pd.Series(0, index=df.index)
    sig[long_.fillna(False)] = 1
    sig[short.fillna(False)] = -1
    return sig


def trades(df: pd.DataFrame, p: Params, symbol: str) -> pd.DataFrame:
    """Simulate one-position-at-a-time trades. Returns one row per trade with R multiple."""
    cost = COSTS[symbol]
    sig = signals(df, p).to_numpy()
    o, h, l, c = (df[k].to_numpy() for k in ("Open", "High", "Low", "Close"))
    rng = h - l
    atr = pd.Series(rng).rolling(p.atr_len).mean().shift(1).to_numpy()
    dates = df.index
    out = []
    i = 0
    n = len(df)
    while i < n - 1:
        side = sig[i]
        if side == 0:
            i += 1
            continue
        entry = o[i + 1]
        stop = l[i] if side == 1 else h[i]
        risk = (entry - stop) * side
        if not (risk > 0) or risk > p.max_stop_atr * atr[i]:
            i += 1
            continue
        target = entry + side * p.tp_r * risk if p.tp_r else None
        exit_px, exit_j, reason = None, None, None
        last = min(i + p.hold_days, n - 1)
        for j in range(i + 1, last + 1):
            # gap through stop/target at the open fills at the open
            if j > i + 1 and (o[j] - stop) * side <= 0:
                exit_px, exit_j, reason = o[j], j, "stop"
                break
            adverse = l[j] if side == 1 else h[j]
            favorable = h[j] if side == 1 else l[j]
            if (adverse - stop) * side <= 0:  # stop checked before target: conservative
                exit_px, exit_j, reason = stop, j, "stop"
                break
            if target is not None:
                if j > i + 1 and (o[j] - target) * side >= 0:
                    exit_px, exit_j, reason = o[j], j, "target"
                    break
                if (favorable - target) * side >= 0:
                    exit_px, exit_j, reason = target, j, "target"
                    break
        if exit_px is None:
            exit_px, exit_j, reason = c[last], last, "time"
        nights = exit_j - (i + 1)
        friction = cost["round_trip"] + entry * cost["swap_rate"] / 252 * nights
        pnl = (exit_px - entry) * side - friction
        out.append(
            {
                "symbol": symbol,
                "side": side,
                "signal_date": dates[i],
                "entry_date": dates[i + 1],
                "exit_date": dates[exit_j],
                "entry": entry,
                "stop": stop,
                "exit": exit_px,
                "reason": reason,
                "risk": risk,
                "r": pnl / risk,
                # worst open excursion in R over the trade's life (for daily-loss checks)
                "mae_r": min(0.0, min(((l if side == 1 else h)[i + 1 : exit_j + 1] - entry) * side) / risk),
            }
        )
        i = exit_j  # next signal may form on the exit bar
    return pd.DataFrame(out)


def summarize(t: pd.DataFrame) -> dict:
    if t.empty:
        return {"trades": 0}
    wins = t.loc[t.r > 0, "r"].sum()
    losses = -t.loc[t.r <= 0, "r"].sum()
    eq = t.sort_values("exit_date").r.cumsum()
    dd = (eq.cummax() - eq).max()
    years = max((t.exit_date.max() - t.entry_date.min()).days / 365.25, 1e-9)
    return {
        "trades": len(t),
        "per_year": round(len(t) / years, 1),
        "win_rate": round((t.r > 0).mean(), 3),
        "avg_r": round(t.r.mean(), 3),
        "profit_factor": round(wins / losses, 2) if losses else np.inf,
        "total_r": round(t.r.sum(), 1),
        "max_dd_r": round(dd, 1),
    }


def daily_equity(t: pd.DataFrame, risk_pct: float, start: pd.Timestamp | None = None) -> pd.DataFrame:
    """Daily closed-balance and worst-case intraday equity, fixed-fractional sizing on balance.

    Open trades are charged their full adverse excursion (MAE) on every day they are open,
    which over-states intraday drawdown and keeps the FTMO daily-loss check conservative.
    """
    if start is not None:
        t = t[t.entry_date >= start]
    if t.empty:
        return pd.DataFrame(columns=["balance", "worst"])
    days = pd.bdate_range(t.entry_date.min(), t.exit_date.max())
    balance = 1.0
    rows = []
    open_trades: list[tuple] = []  # (exit_date, r, mae_r, risk_amount)
    pending = t.sort_values("entry_date").itertuples()
    nxt = next(pending, None)
    for d in days:
        while nxt is not None and nxt.entry_date <= d:
            open_trades.append((nxt.exit_date, nxt.r, nxt.mae_r, balance * risk_pct))
            nxt = next(pending, None)
        day_start = balance
        worst = day_start + sum(mae * amt for _, _, mae, amt in open_trades)
        still = []
        for ex, r, mae, amt in open_trades:
            if ex <= d:
                balance += r * amt
            else:
                still.append((ex, r, mae, amt))
        open_trades = still
        rows.append((d, day_start, balance, min(worst, balance)))
    return pd.DataFrame(rows, columns=["date", "day_start", "balance", "worst"]).set_index("date")


def ftmo_attempts(
    t: pd.DataFrame,
    risk_pct: float,
    target: float = 0.10,
    daily_limit: float = 0.05,
    total_limit: float = 0.10,
    max_days: int | None = None,
) -> pd.DataFrame:
    """Start a fresh challenge at the first trading day of every month and record the outcome."""
    starts = t.entry_date.dt.to_period("M").drop_duplicates().dt.start_time
    out = []
    for s in starts:
        eq = daily_equity(t, risk_pct, start=s)
        if eq.empty:
            continue
        result, days = "open", len(eq)
        for k, (d, row) in enumerate(eq.iterrows(), 1):
            if row.worst <= row.day_start - daily_limit or row.worst <= 1 - total_limit:
                result, days = "fail", k
                break
            if row.balance >= 1 + target:
                result, days = "pass", k
                break
            if max_days and k >= max_days:
                result, days = "timeout", k
                break
        out.append({"start": s, "result": result, "days": days})
    return pd.DataFrame(out)
