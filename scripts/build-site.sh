#!/usr/bin/env bash
# Assemble ONE deployable static site that integrates both faces of the project:
#   /        → the promo landing page (website/)
#   /app/    → the Flutter web "memory" app (build/web/, base-href /app/)
# The landing's "打开 Web 回忆版 / Open the web app" button links to /app/.
#
# Output: ./dist  — deploy this directory to any static host (Vercel / Cloudflare
# Pages / Nginx / NAS web server). Used by .github/workflows/deploy-web.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> flutter build web (base-href /app/)"
flutter build web --release --base-href /app/

echo "==> assembling ./dist"
rm -rf dist
mkdir -p dist/app
cp -r website/. dist/           # promo landing → site root
rm -f dist/README.md            # don't ship the site's dev README
cp -r build/web/. dist/app/     # Flutter app → /app

echo "==> done. ./dist ready (landing at /, app at /app/)."
echo "    Serve ./dist and open the ROOT path:  cd dist && python3 -m http.server 48082"
echo "    NOTE: build/web is now base-href=/app/ — do NOT serve build/web at '/'"
echo "    (its assets would 404 under /app/). Serve ./dist instead."
