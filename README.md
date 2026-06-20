# Usage Meter

A tiny macOS menu-bar app that shows how much of your **Claude**, **Codex**, and
**Gemini** usage windows you've burned, at a glance.

Click the menu-bar gauge to see:

```
Claude
  5h    4%   resets in 4h 41m
  7d   31%   resets in 3d 12h

Codex
  5h    0%   resets in 4h 59m
  Weekly 0%  resets in 6d 23h
```

The menu-bar title itself shows the **highest 5-hour utilization** across all
providers, so you can spot trouble without clicking. Bars stay a calm neutral
while there's headroom and only take on color as a window approaches its limit:
**yellow ≥ 75%**, **red ≥ 90%** used.

Two display options live in the dropdown: **Compact (5hr only)** trims the
menu-bar title to just the 5-hour window, and **Show % remaining** flips every
window (and the bar) from usage consumed to headroom left.

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
./build.sh                                # compiles + assembles build/UsageMeter.app
open build/UsageMeter.app                 # launch
cp -R build/UsageMeter.app /Applications/ # optional: install
```

Requires the Swift toolchain (Xcode CLT), Node.js, and macOS 14+. `build.sh`
runs `npm ci` for the helper automatically the first time.

The resulting `.app` is **self-contained**: the Claude Node helper and its
`node_modules` are copied into `Contents/Resources/helpers`, so the bundle keeps
working when moved or installed to `/Applications`. (It still needs Node.js, the
`codex` CLI, and the relevant sign-ins present on the machine to read usage — see
the graceful "needs setup" hints below.) For development, `swift run` falls back
to the checked-out `helpers/`; override with the `USAGE_METER_HELPER` env var.

### When a provider isn't set up

If Node.js, the Codex CLI, or a provider sign-in is missing, that provider's row
shows a calm, actionable hint (e.g. "Sign in to Claude Code to track usage" with
a **Set up ↗** link) instead of an error — and recovers on its own once you
install or sign in.

### Signing & notarization (for distributing to other Macs)

`build.sh` ad-hoc signs by default (fine for local use). To produce a
notarizable, Developer ID-signed build with the hardened runtime:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
# then notarize + staple + zip (see the script header for one-time setup):
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="usage-meter-notary" ./scripts/notarize.sh
```

The app is **not** sandboxed (it spawns the `node`/`codex` CLIs and reads
Gemini's Keychain item), so it ships as a direct download rather than via the
Mac App Store.

### Debug the data path without the UI

```sh
.build/release/UsageMeter --selftest
```

Prints every provider's windows to the terminal.

## Launch at login

System Settings → General → Login Items → **+** → add `UsageMeter.app`.

## Notes / caveats

- Claude auth/token refresh is handled by the Claude Agent SDK — no keychain
  prompt, no "token expired" handling needed.
- `helpers/node_modules` is large (the SDK vendors the Claude Code CLI). It's
  git-ignored in the checkout but **copied into the `.app`** at build time so the
  bundle is self-contained (`cp -Rc` uses APFS clonefile, so it's cheap on disk).
- The app ad-hoc codesigns by default; set `CODESIGN_IDENTITY` for a Developer ID
  + notarizable build (see Build & run).

## Development

Swift sources are formatted and lint-checked with the `swift format` tool
bundled with the Swift 6 toolchain, configured by [`.swift-format`](.swift-format).

```sh
swift format lint --strict --configuration .swift-format -r Sources Tests  # check
swift format --in-place --configuration .swift-format -r Sources Tests     # fix
```

Unit tests (Swift Testing) cover the provider rate-limit parsers and the
display/formatting logic — the pure parts that don't touch the network:

```sh
swift test
```

CI (`.github/workflows/ci.yml`) runs the lint, a release build, and the test
suite on every push and pull request, and syntax-checks the Node helper.

## License

[MIT](LICENSE) © Eric Hermanson
