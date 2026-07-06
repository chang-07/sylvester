# SnapBar

macOS menubar app showing net worth + per-account breakdown across brokerages, via the SnapTrade API.

## Run

```sh
./make-app.sh && open dist/SnapBar.app
```

Builds and launches the app bundle — required for macOS notifications (new dividends/trades/deposits, broken connections). Grant the notification permission on first launch; verify via ⋯ → Test Notification.

`swift run -c release` still works for quick iteration, but notifications are unavailable without the bundle.

First launch writes a template config to `~/.config/snapbar/config.json` and the menubar item shows setup state.

## Setup

1. Put your SnapTrade partner `clientId` + `consumerKey` in the config.
2. Either paste an existing `userId`/`userSecret`, or hit **Register User** in the dropdown (set `userId` in config first to pick the id, otherwise one is generated).
3. **Connect Account** opens the SnapTrade connection portal in the browser; link brokerages there, then **Refresh**.

Config lives at `~/.config/snapbar/config.json` (chmod 600):

- `baseCurrency` — net worth display currency (default `USD`)
- `refreshMinutes` — auto-refresh cadence (default 15)
- `fxRates` — manual `{currency: baseCurrency-per-unit}` fallbacks, e.g. `{"CAD": 0.73}`. Live rates come from frankfurter.dev when reachable.

## Notes

- Balances come from SnapTrade's cached reads (no forced broker refreshes), so data moves at broker sync cadence — roughly daily. Rows show per-account last-sync and flag anything staler than 36h.
- Request signing is the canonical-JSON HMAC-SHA256 scheme, verified byte-for-byte against the reference Python implementation.
