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

- **Claude** — `GET https://api.anthropic.com/api/oauth/usage`, authenticated
  with the OAuth token Claude Code stores in the macOS keychain
  (`Claude Code-credentials`). Reads `five_hour` / `seven_day` `utilization`.
- **Codex** — spawns `codex app-server --listen stdio://` and makes a JSON-RPC
  `account/rateLimits/read` call, reading `primary` (5h) and `secondary`
  (weekly) `usedPercent`. Same approach the Relay app uses.

Data refreshes every 60s and again each time you open the menu.

## Build & run

```sh
./build.sh                      # compiles + assembles build/UsageBar.app
open build/UsageBar.app         # launch
cp -R build/UsageBar.app /Applications/   # optional: install
```

Requires the Swift toolchain (Xcode CLT) and macOS 13+.

### Debug the data path without the UI

```sh
.build/release/UsageBar --selftest
```

Prints both providers' windows to the terminal.

## Launch at login

System Settings → General → Login Items → **+** → add `UsageBar.app`.

## Notes / caveats

- The first keychain read may prompt for access — click **Always Allow**.
- If Claude shows "Token expired", just open Claude Code once to refresh it;
  this app intentionally does not perform OAuth token refresh itself.
- The app is ad-hoc codesigned (no Apple Developer account needed).
