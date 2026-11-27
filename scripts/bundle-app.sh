#!/usr/bin/env bash
# Builds SohoMonitor in release mode and assembles a menu-bar .app bundle (no Dock icon),
# signed with $CODESIGN_IDENTITY, else the first "Apple Development" identity of the keychain, else ad hoc.
# A certificate signature keeps the designated requirement stable across builds, so privacy grants
# (Full Disk Access) survive a rebuild; an ad hoc one is tied to the binary's hash. Output: build/SohoMonitor.app.
# Usage: scripts/bundle-app.sh [--install]   --install also copies it to ~/Applications.
# macOS only (swift, codesign, plutil).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else G='' Y='' R='' N=''; fi
ok() { printf '%sok%s    %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s  %s\n' "$Y" "$N" "$*"; }
ko() { printf '%sko%s    %s\n' "$R" "$N" "$*" >&2; exit 1; }

install=false
case "${1:-}" in "") ;; --install) install=true ;; *) ko "usage: $0 [--install]" ;; esac

version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/SohoMonitorCore/SohoMonitorCore.swift)"
[ -n "$version" ] || ko "version not found in SohoMonitorCore.swift"

swift build -c release --product SohoMonitor >/dev/null || ko "swift build failed"
bin="$(swift build -c release --show-bin-path)/SohoMonitor"
app="build/SohoMonitor.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/SohoMonitor"

# Claude card helper (docs/adr/0001-claude-usage-source.md): the script and its pinned Agent SDK, installed from the
# lockfile without the SDK's own copy of Claude Code (optional package, ~370 MB: the installed `claude` is used).
# Before codesign: signing must stay the last step that modifies the bundle.
command -v npm >/dev/null || ko "npm not found: install Node.js 18.14 or later (needed by the Claude card helper)"
helper="$app/Contents/Resources/claude-usage"
mkdir -p "$helper"
cp Helpers/claude-usage/package.json Helpers/claude-usage/package-lock.json Helpers/claude-usage/usage.mjs "$helper/"
(cd "$helper" && npm ci --omit=optional --omit=peer --omit=dev --ignore-scripts --no-audit --no-fund \
  --loglevel=error >/dev/null) || ko "npm ci failed for the Claude helper"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.francoisgn.soho-monitor</string>
  <key>CFBundleName</key><string>soho-monitor</string>
  <key>CFBundleDisplayName</key><string>soho-monitor</string>
  <key>CFBundleExecutable</key><string>SohoMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null || ko "invalid Info.plist"
# Identity by SHA-1 hash: its name carries the developer's e-mail, which must not reach logs.
identity="${CODESIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  # No early exit in awk (SIGPIPE under pipefail); a failing keychain falls back to ad hoc.
  identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / && !h { h = $2 } END { print h }')" ||
    identity=""
fi
[ "$identity" != "-" ] || identity=""  # CODESIGN_IDENTITY=- asks for ad hoc explicitly
codesign --force --sign "${identity:--}" --identifier com.francoisgn.soho-monitor "$app" >/dev/null 2>&1 ||
  ko "codesign failed"
if [ -n "$identity" ]; then signature="certificate"; else signature="ad hoc"; fi
ok "$app ($version, $signature signature)"

if $install; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/SohoMonitor.app"
  cp -R "$app" "$HOME/Applications/"
  ok "installed in ~/Applications/SohoMonitor.app"
  if [ -z "$identity" ]; then
    warn "ad hoc signature: it changes at every build, Full Disk Access must be granted again"
  fi
fi
