# TQsignal V2 — Android Flutter source (development build)

This is a **buildable source package**, not a finished APK. It includes a GitHub Actions Android build workflow. Flutter SDK is not installed in the current execution environment, so no successful APK compilation is claimed.

## Implemented
- QQQ EMA20/60/200 baseline BUY and EMA60/5-day drawdown SELL from November main.dart
- QQQ 20-session annualized volatility >= 28%
- TQQQ +5% gain arms protection, peak-close -3% SELL
- 3 full trading-session cooldown after protection and QQQ positive-close reentry while baseline remains in BUY state
- Original baseline SELL priority over protection; no automatic orders
- Home, daily history, account cash management, FX, settings carried over from earlier Flutter source
- Yahoo Finance daily QQQ/TQQQ data requested for 10y to warm up EMA200; the feed may restrict availability

## CRITICAL VALIDATION LIMIT
The old app screenshot BUY/SELL history is **not reproduced exactly** by the supplied November main.dart baseline. Therefore the previously reported V2 +29.81% (2026 continuous) and +41.42% (2026 independent) **are not validated results for this code**. Those numbers came from screenshot-based baseline backtests. Do not advertise them as returns for this APK. Verify signal-day dates against original screenshots before live reliance.

## Build
1. Create a GitHub repository and upload this ZIP contents to its root.
2. Actions -> APK 빌드 -> Run workflow.
3. Download the generated APK artifact.

No auto trading, no guaranteed returns.
