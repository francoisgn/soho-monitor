#!/usr/bin/env bash
# Builds SohoMonitor in release mode and assembles a menu-bar .app bundle (no Dock icon),
# signed ad hoc (or with $CODESIGN_IDENTITY). Output: build/SohoMonitor.app.
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
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier com.francoisgn.soho-monitor "$app" >/dev/null 2>&1 ||
  ko "codesign failed"
ok "$app ($version)"

if $install; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/SohoMonitor.app"
  cp -R "$app" "$HOME/Applications/"
  ok "installed in ~/Applications/SohoMonitor.app"
  warn "an ad hoc signature changes at every build: Full Disk Access must be granted again"
fi
