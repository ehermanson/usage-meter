# Usage Meter

[![CI](https://github.com/ehermanson/usage-meter/actions/workflows/ci.yml/badge.svg)](https://github.com/ehermanson/usage-meter/actions/workflows/ci.yml)
[![Release](https://github.com/ehermanson/usage-meter/actions/workflows/release.yml/badge.svg)](https://github.com/ehermanson/usage-meter/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/ehermanson/usage-meter)](https://github.com/ehermanson/usage-meter/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/ehermanson/usage-meter/total)](https://github.com/ehermanson/usage-meter/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
[![License: MIT](https://img.shields.io/github/license/ehermanson/usage-meter)](LICENSE)

A tiny macOS menu-bar app showing how much of your **Claude**, **Codex**, and
**Gemini** usage you've burned, at a glance.

```
Claude
  5h    4%   resets in 4h 41m
  7d   31%   resets in 3d 12h

Codex
  5h    0%   resets in 4h 59m
  Weekly 0%  resets in 6d 23h
```

The menu-bar title shows the highest 5-hour usage across all providers. Bars turn
**yellow at 75%** and **red at 90%**. Two toggles in the dropdown: **Compact**
(5-hour window only) and **Show % remaining**.

## Install

1. Download **`UsageMeter.dmg`** from the [latest release](https://github.com/ehermanson/usage-meter/releases/latest).
2. Open it, drag **Usage Meter** into **Applications**, and launch it from there.

It reads usage from tools you already have — [Node.js](https://nodejs.org)
(Claude), the [Codex CLI](https://github.com/openai/codex), and a Gemini sign-in
(Antigravity or the Gemini CLI). Any provider that isn't set up shows a
**Set up ↗** hint until you install or sign in.

## Develop

```sh
swift test                 # run the unit tests
./build.sh                 # build build/UsageMeter.app (self-contained)
open build/UsageMeter.app
```

Swift sources are formatted with `swift format` (config in
[`.swift-format`](.swift-format)). `.build/release/UsageMeter --selftest` prints
each provider's windows without the UI.

## Release

Push a tag — [the release workflow](.github/workflows/release.yml) builds, signs,
notarizes, staples, and publishes the `.dmg` and `.zip`:

```sh
git tag v1.2.0 && git push origin v1.2.0
```

The one-time signing secrets are documented at the top of that workflow file.

## License

[MIT](LICENSE) © Eric Hermanson
