import pandas as pd
import pytest

import backtest as bt

P = bt.Params(atr_len=3, trigger_atr=1.0, close_loc_min=0.7, max_stop_atr=5.0, hold_days=3, skip_after_3_runup=False)
ZERO_COST = {"round_trip": 0.0, "swap_rate": 0.0}


def frame(bars):
    idx = pd.bdate_range("2024-01-01", periods=len(bars))
    return pd.DataFrame(bars, columns=["Open", "High", "Low", "Close"], index=idx)


def quiet(n, px=100.0):
    # alternating closes so no 3-bar run-ups form
    return [(px, px + 1, px - 1, px + (0.2 if k % 2 else -0.2)) for k in range(n)]


@pytest.fixture(autouse=True)
def no_costs(monkeypatch):
    monkeypatch.setitem(bt.COSTS, "TEST", ZERO_COST)


def test_long_signal_on_range_expansion_close_near_high():
    bars = quiet(5) + [(100, 104, 99.5, 103.8)]
    sig = bt.signals(frame(bars), P)
    assert sig.iloc[-1] == 1
    assert (sig.iloc[:-1] == 0).all()


def test_no_signal_when_close_not_near_high():
    bars = quiet(5) + [(100, 106, 99.5, 102.5)]
    assert bt.signals(frame(bars), P).iloc[-1] == 0


def test_short_signal_mirrors_long():
    bars = quiet(5) + [(100, 100.5, 96, 96.2)]
    assert bt.signals(frame(bars), P).iloc[-1] == -1


def test_stop_at_trigger_low_is_hit():
    bars = quiet(5) + [(100, 104, 99.5, 103.8), (104, 104.5, 99.0, 100)]
    t = bt.trades(frame(bars), P, "TEST")
    assert len(t) == 1
    row = t.iloc[0]
    assert row.entry == 104 and row.stop == 99.5 and row.reason == "stop"
    assert row.r == pytest.approx(-1.0)


def test_gap_through_stop_fills_at_open():
    bars = quiet(5) + [(100, 104, 99.5, 103.8), (104, 104.5, 103, 103.5), (97, 98, 96, 97)]
    row = bt.trades(frame(bars), P, "TEST").iloc[0]
    assert row.reason == "stop" and row.exit == 97
    assert row.r == pytest.approx((97 - 104) / 4.5)


def test_time_exit_after_hold_days():
    bars = quiet(5) + [(100, 104, 99.5, 103.8)] + [(104, 105, 103, 104.5)] * 3
    row = bt.trades(frame(bars), P, "TEST").iloc[0]
    assert row.reason == "time"
    assert row.exit_date == frame(bars).index[5 + 3]
    assert row.r == pytest.approx(0.5 / 4.5)


def test_costs_reduce_r(monkeypatch):
    monkeypatch.setitem(bt.COSTS, "TEST", {"round_trip": 0.45, "swap_rate": 0.0})
    bars = quiet(5) + [(100, 104, 99.5, 103.8)] + [(104, 105, 103, 104.5)] * 3
    row = bt.trades(frame(bars), P, "TEST").iloc[0]
    assert row.r == pytest.approx((0.5 - 0.45) / 4.5)


def test_ftmo_daily_loss_breach_fails_attempt():
    t = pd.DataFrame(
        {
            "entry_date": pd.to_datetime(["2024-01-02"]),
            "exit_date": pd.to_datetime(["2024-01-03"]),
            "r": [-1.0],
            "mae_r": [-1.0],
        }
    )
    res = bt.ftmo_attempts(t, risk_pct=0.06)
    assert res.iloc[0].result == "fail"
