# Usage Bar

A tiny macOS menu-bar app that shows how much of your **Claude** and **Codex**
usage windows you've burned, at a glance.

Click the menu-bar gauge to see:

```
Claude
  5h    4%   resets in 4h 41m
  7d   31%   resets in 3d 12h

Codex
  5h    0%   resets in 4h 59m
  Weekly 0%  resets in 6d 23h
```

The menu-bar title itself shows the **highest 5-hour utilization** across both
providers, so you can spot trouble without clicking. Bars are green < 60%,
orange < 85%, red above.

## Where the numbers come from

- **Claude** — the **same path Relay uses**: the Claude Agent SDK's experimental
  `get_usage` control request, driven by a small Node helper
  (`helpers/claude-usage.mjs`) that calls
  `startup()` → `query()` → `usage_EXPERIMENTAL_…()`. This reuses Claude Code's
  own credentials (including silent OAuth token refresh), so there's no keychain
  parsing or token-expiry handling. Reads `rate_limits.five_hour` /
  `seven_day` `utilization` + `resets_at`, plus `subscription_type` (plan).
- **Codex** — spawns `codex app-server --listen stdio://` and makes a JSON-RPC
  `account/rateLimits/read` call, reading `primary` (5h) and `secondary`
  (weekly) `usedPercent`. Same approach Relay uses.

### Rate-limit awareness

Claude's usage endpoint is *itself* rate-limited. So the app:
- probes Claude at most once every **5 minutes** (the 5h window moves slowly);
- on a transient throttle, keeps showing the **last good value** with an amber
  "throttled" note instead of blanking;
- refreshes the cheap, local Codex data every 60s and on each menu open.

The manual refresh button (↻) forces an immediate Claude probe.

## Build & run

```sh
cd helpers && npm install && cd ..   # one-time: installs the Claude Agent SDK
./build.sh                           # compiles + assembles build/UsageBar.app
open build/UsageBar.app              # launch
cp -R build/UsageBar.app /Applications/   # optional: install
```

Requires the Swift toolchain (Xcode CLT), Node.js, and macOS 14+.

`build.sh` bakes the absolute path of `helpers/claude-usage.mjs` into the app's
Info.plist (`ClaudeHelperPath`), so the app keeps working after you move the
`.app` — as long as the `helpers/` directory (with its `node_modules`) stays
put. Override with the `USAGE_BAR_HELPER` env var if you relocate it.

### Debug the data path without the UI

```sh
.build/release/UsageBar --selftest
```

Prints both providers' windows to the terminal.

## Launch at login

System Settings → General → Login Items → **+** → add `UsageBar.app`.

## Notes / caveats

- Claude auth/token refresh is handled by the Claude Agent SDK — no keychain
  prompt, no "token expired" handling needed.
- `helpers/node_modules` is ~245 MB (the SDK vendors the Claude Code CLI), so
  it's git-ignored and not bundled into the `.app`; the app shells out to it in
  place.
- The app is ad-hoc codesigned (no Apple Developer account needed).
