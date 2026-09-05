#!/usr/bin/env bash
# Assemble ONE deployable static site that integrates both faces of the project:
#   /        → the promo landing page (website/)
#   /app/    → the Flutter web "memory" app (build/web/, base-href /app/)
# The landing's "打开 Web 回忆版 / Open the web app" button links to /app/.
#
# Output: ./dist  — deploy this directory to any static host (Vercel / Cloudflare
# Pages / Nginx / NAS web server). Used by the `site` job in .github/workflows/build.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 版本号由调用方给（CI 里来自 CHANGELOG.md，见 scripts/version.sh）。本机直接跑
# 时两个都留空，flutter 就吃 pubspec 里的 version —— 所以本机验证不需要额外参数。
VERSION_ARGS=()
if [ -n "${BUILD_NAME:-}" ]; then
  VERSION_ARGS+=(--build-name "$BUILD_NAME")
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  VERSION_ARGS+=(--build-number "$BUILD_NUMBER")
fi

echo "==> flutter build web (base-href /app/)${BUILD_NAME:+ · v$BUILD_NAME}"
# `${arr[@]+"${arr[@]}"}` 而不是 `"${arr[@]}"`：后者在空数组 + `set -u` 下会被
# 老版本 bash 当成未绑定变量而报错。
flutter build web --release --base-href /app/ ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}

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
