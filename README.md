# FTMO Momentum Burst – Risiko-EA für MetaTrader 5

Ein MQL5 Expert Advisor, der die Verlustregeln einer FTMO-2-Step-Challenge
durchsetzt, plus der Python-Research, der zeigt, warum das eingebaute
Beispielsignal **kein** profitables System ist.

> **Kurzfassung:** Die Schutzlogik (Positionsgröße, Tages- und Gesamtverlust-
> Sperre) ist das, was dieser EA liefert. Das mitgelieferte Momentum-Burst-
> Signal hat im Backtest nach Kosten verloren. Ersetze `GetSignal()` durch
> deine eigenen, getesteten Regeln, bevor du echtes Geld oder eine bezahlte
> Challenge riskierst.

## Research-Ergebnis

Die Regeln stammen aus dem Skill `stockbee-momentum-burst-screener`
([claude-trading-skills](https://github.com/tradermonty/claude-trading-skills))
und wurden für CFDs übertragen:

- **Trigger:** Close-to-Close-Bewegung ≥ 1 ATR, Range größer als die drei vorherigen Bars, Close im oberen 30 % des Bars (Short spiegelbildlich).
- **Filter:** Kein Trade nach drei Schlusskursen in Folge in Signalrichtung.
- **Einstieg:** Open des nächsten Tages.
- **Stop:** Tief (bzw. Hoch) des Signaltags, maximal 2 ATR entfernt.
- **Exit:** Nach 5 Tagen, sofern der Stop nicht vorher erreicht wurde.

Getestet auf Tagesdaten von Yahoo Finance (Stellvertreter für die FTMO-CFDs:
`NQ=F`→US100, `GC=F`→XAUUSD, `CL=F`→USOIL, Spot-FX). Kosten: Spread,
Kommission und Slippage pro Trade plus Finanzierungskosten pro Nacht
(`research/backtest.py`, `COSTS`).

| Zeitraum | Trades | Trefferquote | Ø R/Trade | Profit-Faktor |
|---|---:|---:|---:|---:|
| In-Sample 2009–2019 | 578 | 37 % | −0,16 | 0,71 |
| Out-of-Sample 2020–2026 | 298 | 44 % | −0,04 | 0,92 |
| In-Sample **ohne** Kosten | 578 | – | −0,09 | 0,83 |

**Simulierte FTMO-Phase-1** (Ziel +10 %, 5 % Tages-, 10 % Gesamtverlust, ein
neuer Versuch an jedem Monatsanfang, Tagesverlust konservativ mit dem
schlechtesten Kurs jedes offenen Trades gerechnet):

| Risiko pro Trade | Bestanden | Gescheitert | Noch offen |
|---|---:|---:|---:|
| 0,5 % | 15 | 166 | 31 |
| 1,0 % | 26 | 172 | 14 |

Variiert wurden außerdem: Trigger 0,5–2 ATR, Haltedauer 1–20 Tage, Trendfilter
(SMA 50/100/200), Nur-Long, Stop-Abstand und Take-Profit. Keine Variante war über
mehrere Instrumente stabil positiv. Zwei Lehrbuch-Alternativen ohne Optimierung
(Donchian 50/20-Trendfolge, RSI(2)-Dip-Kauf über SMA200) lagen ebenfalls bei
einem Profit-Faktor um 1.

Grenzen: Die Tagesdaten von Yahoo sind nur eine Näherung für FTMOs Kursfeed,
Intraday-Strategien wurden nicht getestet, und Lot-Rundung ist nicht
modelliert. Die endgültige Prüfung gehört in den MT5 Strategy Tester mit
FTMO-Daten.

Reproduzieren:

```bash
uv sync
uv run python research/fetch_data.py     # lädt data/*.csv
uv run python research/run_research.py   # Tabellen oben
uv run --group dev pytest -q             # Tests der Backtest-Logik
```

## Der EA

Datei: `mql5/Experts/MomentumBurstEA.mq5`

**Was er durchsetzt**

- **Positionsgröße nach Risiko:** `InpRiskPercent` % des Kontostands bis zum Stop, berechnet mit `OrderCalcProfit` (funktioniert für FX, Gold und Indizes). Liegt die Mindest-Lotgröße über dem Risikobudget, wird der Trade übersprungen, nie aufgerundet.
- **Tagesverlust-Sperre:** Die Untergrenze liegt beim Tagesstart-Wert (Maximum aus Balance und Equity beim ersten Tick des Servertags) minus `InpDailyLossLimitPct` % des Startkapitals. Wird sie erreicht, schließt der EA alle eigenen Positionen und pausiert bis zum nächsten Tag.
- **Gesamtverlust-Sperre:** Die Untergrenze liegt bei Startkapital × (1 − `InpMaxLossLimitPct` %). Wird sie erreicht, schließt der EA alles und stoppt dauerhaft.
- **Prüfung vor jedem Trade:** Selbst wenn **alle** offenen Stops und der neue Stop getroffen werden, muss das Equity über beiden Untergrenzen bleiben. Sonst wird kein Trade eröffnet.
- **Jede Position hat einen Stop-Loss.** Positionen ohne Stop blockieren neue Trades.
- **Wochenende:** Freitags ab `InpFridayCloseHour` (Serverzeit) wird alles geschlossen.
- **Echtgeld-Sperre:** Auf Echtgeld-Konten verweigert der EA den Start, solange `InpAllowRealAccount=false` ist.

Die Grenzen gelten für alle Instanzen auf demselben Konto mit derselben
Magic Number. Den Zustand speichert der EA in Terminal-Globalvariablen
(`MB_<Login>_<Magic>_*`), damit er Neustarts übersteht.

**Wichtige Eingaben**

| Eingabe | Standard | Hinweis |
|---|---|---|
| `InpRiskPercent` | 0,5 | Maximal 2 erlaubt |
| `InpInitialBalance` | 0 | **Auf die Challenge-Kontogröße setzen**, z. B. 10000. Bei 0 nimmt der EA den Kontostand beim ersten Start. |
| `InpDailyLossLimitPct` | 4,0 | Puffer unter FTMOs 5 % |
| `InpMaxLossLimitPct` | 8,0 | Puffer unter FTMOs 10 % |
| `InpMaxOpenPositions` | 3 | Über alle Symbole |
| `InpCloseBeforeWeekend` | true | Siehe Annahmen unten |
| `InpNewsFilter` | true | Keine Einstiege ±30 min um High-Impact-Termine der Symbolwährungen (Basis- und Gegenwährung) |
| `InpNewsFlatBeforeMin` | 0 | > 0: Positionen des Symbols so viele Minuten vor einem Termin schließen. Für FTMO mindestens 5, damit das Schließen nicht selbst ins 2-Minuten-Fenster fällt. |
| `InpPauseUntil` | 0 | Manueller Stopp für neue Einstiege bis zu dieser Serverzeit, z. B. vor Wahlen oder bei Eskalationen aus dem Briefing |

Der News-Filter nutzt den eingebauten MT5-Wirtschaftskalender. **Im Strategy
Tester liefert der Kalender keine Daten**, dort ist der Filter also wirkungslos.
Prüfe ihn auf dem Demokonto im Journal (`high-impact event nearby`).

**Annahmen, die du prüfen musst**

Die FTMO-Regeln stammen aus Drittquellen, weil ftmo.com bei der Entwicklung
nicht erreichbar war. Prüfe auf ftmo.com bzw. in deinem Account:

1. **Zeitpunkt des Tagesresets:** FTMO setzt um Mitternacht CE(S)T zurück, der EA am Mitternachtswechsel der **Serverzeit**. Weichen beide ab, verschiebt sich der Tagesstart. Der Puffer von 1 % fängt das in der Regel ab.
2. **News:** Auf FTMO-Konten mit Normal-Regeln ist der Handel rund um wichtige News eingeschränkt. Der News-Filter (siehe unten) blockiert Einstiege um High-Impact-Termine und kann vorher flat gehen. Er kennt aber nur **geplante** Termine aus dem MT5-Kalender. Unerwartete politische Ereignisse (Tweets, Angriffe, überraschende Sanktionen) erkennt er nicht; dafür gibt es `InpPauseUntil` und das tägliche Briefing.
3. **Wochenende:** Ob Positionen übers Wochenende gehalten werden dürfen, hängt vom Kontotyp ab (Normal oder Swing). Der Standard ist konservativ: schließen. Der Backtest hat übers Wochenende gehalten.
4. **FTMO-Konten sind simuliert:** Auch ein Funded Account kann sich als Demo melden, dann greift die Echtgeld-Sperre nicht. Ob du „funded“ handelst, entscheidest du selbst.

## Telegram-Benachrichtigungen

Der EA meldet per Telegram:
- jeden Einstieg mit Symbol, Richtung, Lots, Preis und Stop
- jede Schließung mit Grund (Stop-Loss, EA, manuell), P/L und Equity
- das Auslösen der Tages- bzw. Gesamtverlust-Sperre

Einrichten:
1. MT5: *Extras → Optionen → Expert Advisors → „WebRequest für folgende URLs erlauben“* aktivieren und `https://api.telegram.org` eintragen.
2. Beim Anhängen des EA `InpTelegramToken` (von @BotFather) und `InpTelegramChatId` setzen. Leer = aus.

Der Token steht dann in den EA-Einstellungen auf dem VPS. Gib den VPS-Zugang nicht weiter.
Im Strategy Tester ist Telegram automatisch aus. Fehler stehen im Journal (`Telegram failed`).

## Deployment auf dem Windows-VPS

1. **MT5 installieren:** Lade das MetaTrader-5-Terminal aus deinem FTMO-Kundenbereich herunter, installiere es auf dem VPS und melde dich mit den Zugangsdaten deines **Demo-/Free-Trial-Kontos** an.
2. **EA kopieren:** Im Terminal *Datei → Datenordner öffnen*, dann `MomentumBurstEA.mq5` nach `MQL5\Experts\` kopieren.
3. **Kompilieren:** MetaEditor öffnen (F4), die Datei öffnen und kompilieren (F7). Erwartet sind 0 Fehler. *Der Code wurde ohne MQL5-Compiler geschrieben. Melde Compiler-Fehler, und ich korrigiere sie.*
4. **Strategy Tester:** Vor dem Einsatz im Strategy Tester (Strg+R) laufen lassen.
   - Einstellungen: Modus *Every tick based on real ticks*, Zeitraum mindestens 2020–heute, Symbole US100.cash, XAUUSD, EURUSD.
   - Prüfen, dass Lotgrößen dem eingestellten Risiko entsprechen, dass keine Position ohne Stop-Loss existiert und dass die Tagesverlust-Sperre auslöst. Zum Testen der Sperre `InpDailyLossLimitPct` z. B. auf 0,5 setzen.
   - Optional automatisiert mit dem Skill `mt5-robot-tester`.
5. **Live auf Demo:**
   - Für jedes Symbol einen Chart öffnen und den EA anhängen, auf allen mit **derselben** Magic Number.
   - `InpInitialBalance` auf die Kontogröße setzen.
   - *Algo Trading* in der Symbolleiste aktivieren.
6. **Dauerbetrieb:**
   - Windows-Updates mit automatischem Neustart abschalten oder in ein Wartungsfenster legen.
   - MT5 in den Autostart legen (Verknüpfung in `shell:startup`).
   - Im Journal-Tab prüfen, ob `MomentumBurstEA on …: initial balance …` erscheint.
7. **Erst nach mehreren Wochen** stabilem Demo-Betrieb **mit einem eigenen, belegten Signal** über eine bezahlte Challenge nachdenken.

## Eigenes Signal einbauen

Ersetze den Inhalt von `GetSignal(double &stop)`:

- **Rückgabe:** `+1` für Long, `-1` für Short, `0` für kein Signal.
- **`stop`:** Muss auf den Stop-Kurs gesetzt werden.
- **Aufruf:** Die Funktion läuft einmal pro neuem Bar von `InpSignalTF`.

Positionsgröße, Sperren und Zeit-Exit bleiben unverändert. Teste ein neues
Signal zuerst in `research/` (gleiche Logik in Python), dann im Strategy
Tester.

## Lizenz und Haftung

Nur zu Lern- und Testzwecken. Keine Anlageberatung. Handel mit CFDs kann zum
Verlust des eingesetzten Kapitals führen.
