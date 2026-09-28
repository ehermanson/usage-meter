#!/bin/bash
# Renders the README pictures from the site's mockup, so they're always the
# same dropdown the site shows: docs/demo-{light,dark}.png on the Limits tab,
# and docs/demo-cost-{light,dark}.png on the Cost tab with its chart hovered.
#
# Lifts the `.mockup-wrap` block out of site/index.html into a bare capture page
# (same stylesheet, no page scripts, animations off, 40px of page background
# around it) and screenshots that with headless Chrome at 2x. Each variant is
# the same block with the panel's attributes edited: `data-tab` picks the tab,
# and `data-demo-hover` shows the chart's hover state parked in the markup. The
# page height is measured in a first pass — Chrome only captures the viewport —
# then captured in a second.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Chrome not found at: $CHROME (set CHROME=…)" >&2; exit 1; }

# The capture pages must live beside style.css and the logos for their relative
# paths to resolve; they're build artifacts and are removed on exit.
PAGES=(site/.demo-capture-limits.html site/.demo-capture-cost.html)
trap 'rm -f "${PAGES[@]}"' EXIT

python3 - "${PAGES[@]}" <<'EOF'
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

# The site opens on Limits; the Cost variant switches tabs and shows the
# hovered chart the way the page's script would.
panel = '<div class="panel" data-tab="limits"'
assert panel in mockup, "the mockup's panel tag changed; update render-demo.sh"
variants = {
    "limits": mockup,
    "cost": mockup.replace(panel, '<div class="panel" data-tab="cost" data-demo-hover', 1),
}

for path, name in zip(sys.argv[1:], ("limits", "cost")):
    open(path, "w", encoding="utf-8").write(f"""<!doctype html>
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
{variants[name]}
<script>document.title = String(Math.ceil(document.body.getBoundingClientRect().height));</script>
</body>
</html>
""")
EOF

for variant in limits cost; do
    page="site/.demo-capture-$variant.html"
    URL="file://$PWD/$page"
    # Limits keeps the README's original file names.
    prefix=docs/demo
    [ "$variant" = limits ] || prefix="docs/demo-$variant"
    for theme in light dark; do
        flags=(--headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2)
        # Pin both schemes: left alone, headless Chrome follows the Mac's own
        # appearance, and a light render taken in dark mode comes out dark.
        if [ "$theme" = dark ]; then
            flags+=(--force-dark-mode)
        else
            flags+=(--blink-settings=preferredColorScheme=1)
        fi
        height=$("$CHROME" "${flags[@]}" --window-size=820,600 --dump-dom "$URL" 2>/dev/null \
            | sed -n 's/.*<title>\([0-9]*\)<\/title>.*/\1/p')
        [ -n "$height" ] || { echo "couldn't measure the $variant $theme page" >&2; exit 1; }
        "$CHROME" "${flags[@]}" --window-size="820,$height" \
            --screenshot="$prefix-$theme.png" "$URL" 2>/dev/null
        echo "$prefix-$theme.png  (820×$height @2x)"
    done
done
