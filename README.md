# SnapBar

macOS menubar app showing net worth + per-account breakdown across brokerages, via the SnapTrade API.

## Run

```sh
./make-app.sh && open dist/SnapBar.app
```

Builds and launches the app bundle — required for macOS notifications (new dividends/trades/deposits, broken connections). Grant the notification permission on first launch; verify via ⋯ → Test Notification.

`swift run -c release` still works for quick iteration, but notifications are unavailable without the bundle.

First launch writes a template config to `~/.config/snapbar/config.json` and the menubar item shows setup state.

## Setup (bring your own key)

1. Get a personal SnapTrade key at [dashboard.snaptrade.com](https://dashboard.snaptrade.com) — SnapBar is a pure local client; your keys and data never touch anything but your Mac and the SnapTrade API.
2. Click the menubar item: the setup wizard asks for `clientId` + `consumerKey`, validates them live, and stores secrets in the **macOS Keychain**. A SnapTrade user is auto-registered (or paste an existing `userId`/`userSecret` under the optional disclosure).
3. **Connect Account** opens the SnapTrade connection portal in the browser; link brokerages there.

Non-secret settings live at `~/.config/snapbar/config.json` (chmod 600). Pre-existing configs with inline keys keep working; use ⋯ → **Move Keys to Keychain** to migrate:

- `baseCurrency` — net worth display currency (default `USD`)
- `refreshMinutes` — auto-refresh cadence (default 15)
- `fxRates` — manual `{currency: baseCurrency-per-unit}` fallbacks, e.g. `{"CAD": 0.73}`. Live rates come from frankfurter.dev when reachable.

## Notes

- Balances come from SnapTrade's cached reads (no forced broker refreshes), so data moves at broker sync cadence — roughly daily. Rows show per-account last-sync and flag anything staler than 36h.
- Request signing is the canonical-JSON HMAC-SHA256 scheme, verified byte-for-byte against the reference Python implementation.
