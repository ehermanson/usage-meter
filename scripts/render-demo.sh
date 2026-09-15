#!/bin/bash
# Renders docs/demo-light.png and docs/demo-dark.png from the site's mockup, so
# the README picture is always the same dropdown the site shows.
#
# Lifts the `.mockup-wrap` block out of site/index.html into a bare capture page
# (same stylesheet, animations off, 40px of page background around it) and
# screenshots that with headless Chrome at 2x. The page height is measured in
# a first pass — Chrome only captures the viewport — then captured in a second.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Chrome not found at: $CHROME (set CHROME=…)" >&2; exit 1; }

# The capture page must live beside style.css and the logos for its relative
# paths to resolve; it's a build artifact and is removed on exit.
PAGE="site/.demo-capture.html"
trap 'rm -f "$PAGE"' EXIT

python3 - "$PAGE" <<'EOF'
import re, sys
src = open("site/index.html", encoding="utf-8").read()
start = src.index('<div class="mockup-wrap">')
# Walk the tags to find the div that closes the wrapper.
depth, i = 0, start
for m in re.finditer(r"<div\b|</div>", src[start:]):
    depth += 1 if m.group().startswith("<div") else -1
    if depth == 0:
        i = start + m.end()
        break
mockup = src[start:i]
open(sys.argv[1], "w", encoding="utf-8").write(f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<link rel="stylesheet" href="style.css">
<style>
  *, *::before, *::after {{ animation: none !important; transition: none !important; }}
  html, body {{ margin: 0; background: var(--bg); }}
  body {{ width: 820px; padding: 40px 0; overflow: hidden; }}
  /* The gap to the hero copy isn't part of the picture. */
  .mockup-wrap {{ margin-top: 0; }}
</style>
</head>
<body>
{mockup}
<script>document.title = String(Math.ceil(document.body.getBoundingClientRect().height));</script>
</body>
</html>
""")
EOF

URL="file://$PWD/$PAGE"
for theme in light dark; do
    flags=(--headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2)
    [ "$theme" = dark ] && flags+=(--force-dark-mode)
    height=$("$CHROME" "${flags[@]}" --window-size=820,600 --dump-dom "$URL" 2>/dev/null \
        | sed -n 's/.*<title>\([0-9]*\)<\/title>.*/\1/p')
    [ -n "$height" ] || { echo "couldn't measure the $theme page" >&2; exit 1; }
    "$CHROME" "${flags[@]}" --window-size="820,$height" \
        --screenshot="docs/demo-$theme.png" "$URL" 2>/dev/null
    echo "docs/demo-$theme.png  (820×$height @2x)"
done
