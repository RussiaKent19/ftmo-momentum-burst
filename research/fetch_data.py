"""Download daily OHLC bars from Yahoo Finance into data/<SYMBOL>.csv.

Yahoo tickers are proxies for the FTMO CFDs (futures for US100/gold/oil,
spot rates for FX). Prices differ slightly from FTMO's feed; validate the
final EA in the MT5 Strategy Tester on FTMO data.
"""

from pathlib import Path

import yfinance as yf

# FTMO symbol -> Yahoo ticker
SYMBOLS = {
    "US100": "NQ=F",
    "EURUSD": "EURUSD=X",
    "GBPUSD": "GBPUSD=X",
    "USDJPY": "USDJPY=X",
    "XAUUSD": "GC=F",
    "USOIL": "CL=F",
}

DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def main() -> None:
    DATA_DIR.mkdir(exist_ok=True)
    for name, ticker in SYMBOLS.items():
        df = yf.download(ticker, period="max", interval="1d", progress=False, auto_adjust=False)
        df.columns = [c[0] if isinstance(c, tuple) else c for c in df.columns]
        df = df[["Open", "High", "Low", "Close"]].dropna()
        df.index.name = "Date"
        df.to_csv(DATA_DIR / f"{name}.csv")
        print(f"{name:7s} {ticker:9s} {len(df):6d} bars  {df.index[0].date()} .. {df.index[-1].date()}")


if __name__ == "__main__":
    main()
