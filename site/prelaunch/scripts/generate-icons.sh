#!/usr/bin/env bash
# Regenerate the pre-launch site's PNG icon set from the source SVGs.
#
# Sources:
#   scripts/icons/logo.svg        - transparent background, used for favicons / PWA icons / OG logo
#   scripts/icons/logo-padded.svg - opaque brand-color background with 80% safe zone,
#                                   used for Apple touch icon, Android maskable, Twitter profile
#
# Re-run after any change to either source SVG (which should mirror src/components/Logo.tsx).
# Requires: rsvg-convert (install via `brew install librsvg`).

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert not found. Install with: brew install librsvg" >&2
  exit 1
fi

OUT="$(cd ../public && pwd)"
mkdir -p "$OUT/icons" "$OUT/og"

# Transparent-background icons (rasterized from logo.svg)
rsvg-convert -w 32  -h 32  icons/logo.svg -o "$OUT/favicon-32.png"
rsvg-convert -w 192 -h 192 icons/logo.svg -o "$OUT/icons/icon-192.png"
rsvg-convert -w 512 -h 512 icons/logo.svg -o "$OUT/icons/icon-512.png"
rsvg-convert -w 600 -h 600 icons/logo.svg -o "$OUT/og/logo.png"

# Opaque brand-background icons (rasterized from logo-padded.svg)
rsvg-convert -w 180 -h 180 icons/logo-padded.svg -o "$OUT/apple-touch-icon.png"
rsvg-convert -w 512 -h 512 icons/logo-padded.svg -o "$OUT/icons/icon-512-maskable.png"

# Twitter / X profile picture (opaque, brand background)
rsvg-convert -w 400 -h 400 icons/logo-padded.svg -o "$OUT/og/twitter-profile.png"

# Open Graph / Twitter card image (1200x630).
# Uses og-card.svg if it exists (artwork composite); otherwise falls back to og-default.svg (flat brand background).
if [ -f icons/og-card.svg ] && [ -f icons/og-bg.png ]; then
  rsvg-convert -w 1200 -h 630 icons/og-card.svg -o "$OUT/og/og-default.png"
else
  rsvg-convert -w 1200 -h 630 icons/og-default.svg -o "$OUT/og/og-default.png"
fi

# Twitter / X profile banner (1500x500). Generated when banner-bg.png exists.
if [ -f icons/banner-twitter.svg ] && [ -f icons/banner-bg.png ]; then
  rsvg-convert -w 1500 -h 500 icons/banner-twitter.svg -o "$OUT/og/banner-twitter.png"
fi

echo "Generated icon set in $OUT:"
echo "  favicon-32.png          (32x32)"
echo "  apple-touch-icon.png    (180x180, opaque brand bg)"
echo "  icons/icon-192.png      (192x192)"
echo "  icons/icon-512.png      (512x512)"
echo "  icons/icon-512-maskable.png  (512x512, opaque brand bg, 80% safe zone)"
echo "  og/logo.png             (600x600, JSON-LD organization logo)"
echo "  og/twitter-profile.png  (400x400, opaque brand bg, Twitter avatar)"
echo "  og/og-default.png       (1200x630, OG / Twitter card image)"
[ -f "$OUT/og/banner-twitter.png" ] && echo "  og/banner-twitter.png   (1500x500, Twitter / X profile banner)"
