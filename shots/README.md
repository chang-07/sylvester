# Designed screenshots

`scenes.html` composes the raw popover captures (`raw/`) into the staged
marketing shots used on the site (`docs/assets/shot-*.png`).

Regenerate after replacing a raw capture:

```sh
npx playwright screenshot ... # or: render each .scene div at deviceScaleFactor 2
```

(Any Playwright/browser screenshot of each `.scene` element at 2x yields the
1680×2240 assets. Raw captures come from the real app running against a local
mock API — see the git history for the demo dataset.)
