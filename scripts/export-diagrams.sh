#!/usr/bin/env bash
# Exports the README diagrams (docs/diagrams/*.excalidraw, edited on excalidraw.com › Open, then saved back) to SVG
# with Excalidraw's own exportToSvg, Excalifont embedded, so they render on GitHub as drawn (white background: legible
# in light and dark themes). The tooling (pinned @excalidraw/excalidraw, React, esbuild, puppeteer-core) is installed
# in a cache folder outside the repository: it is not an app dependency. Needs Node.js 18+ and Google Chrome.
# Usage: scripts/export-diagrams.sh [--png <dir>] [scene.excalidraw...]
#   no scene: every docs/diagrams/*.excalidraw; --png also renders each SVG to <dir>/<name>.png (2x) to look at it.
# Environment: CHROME (default: the macOS Google Chrome app), EXPORT_TOOLING_DIR (default:
#   ~/.cache/soho-monitor/excalidraw-export), DEBUG_EXPORT=1 prints the page's console.
# After editing a scene, run this script and commit the .excalidraw and its .svg together (nothing checks they match).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then G=$'\e[32m' R=$'\e[31m' N=$'\e[0m'; else G='' R='' N=''; fi
ok() { printf '%sok%s    %s\n' "$G" "$N" "$*"; }
ko() { printf '%sko%s    %s\n' "$R" "$N" "$*" >&2; exit 1; }

png=()
scenes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --png)
      [ $# -ge 2 ] || ko "usage: $0 [--png <dir>] [scene.excalidraw...]"
      mkdir -p "$2" || ko "cannot create $2"
      png=(--png "$(cd "$2" && pwd)")
      shift 2
      ;;
    -*) ko "usage: $0 [--png <dir>] [scene.excalidraw...]" ;;
    *)
      [ -f "$1" ] || ko "scene not found: $1"
      scenes+=("$(cd "$(dirname "$1")" && pwd)/$(basename "$1")")
      shift
      ;;
  esac
done
if [ ${#scenes[@]} -eq 0 ]; then
  for scene in "$ROOT"/docs/diagrams/*.excalidraw; do scenes+=("$scene"); done
fi

chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$chrome" ] || ko "Chrome not found at $chrome (set CHROME)"
command -v npm >/dev/null || ko "npm not found: install Node.js 18 or later"

tooling="${EXPORT_TOOLING_DIR:-$HOME/.cache/soho-monitor/excalidraw-export}"
mkdir -p "$tooling"
# Exact versions of the direct dependencies, each published weeks before it was adopted (their own dependencies are
# not locked: the export of an unchanged scene was byte-identical across clean installs; compare after a bump).
cat >"$tooling/package.json" <<'JSON'
{
  "name": "soho-monitor-excalidraw-export",
  "private": true,
  "type": "module",
  "dependencies": {
    "@excalidraw/excalidraw": "0.18.1",
    "esbuild": "0.28.2",
    "puppeteer-core": "25.16.0",
    "react": "18.3.1",
    "react-dom": "18.3.1"
  }
}
JSON
printf '%s\n' \
  'import { exportToSvg, restore } from "@excalidraw/excalidraw";' \
  'window.ExcalidrawLib = { exportToSvg, restore };' >"$tooling/entry.mjs"
cp "$ROOT/scripts/export-diagrams.mjs" "$tooling/export-diagrams.mjs"

# --ignore-scripts: esbuild's binary comes from its optional platform package, no install script is needed.
(cd "$tooling" && npm install --ignore-scripts --no-audit --no-fund --loglevel=error >/dev/null) || ko "npm install failed in $tooling"
(cd "$tooling" && npx --no-install esbuild entry.mjs --bundle --format=iife --minify \
  --define:process.env.NODE_ENV='"production"' --define:process.env.IS_PREACT='"false"' \
  --outfile=bundle.js --log-level=error) || ko "esbuild failed"
ok "tooling ready in $tooling"

(cd "$tooling" && node export-diagrams.mjs --bundle bundle.js \
  --assets node_modules/@excalidraw/excalidraw/dist/prod --chrome "$chrome" ${png[@]+"${png[@]}"} "${scenes[@]}")
