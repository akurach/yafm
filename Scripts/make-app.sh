#!/usr/bin/env bash
# Wrap the SwiftPM-built `yafm` executable into a proper macOS .app bundle.
#
# A bare SPM executable has no Info.plist / CFBundleIdentifier, so SwiftUI
# launches it as a faceless background process — no window, no Dock icon, and
# the noisy "missing main bundle identifier" / linkd.autoShortcut warnings.
# A real .app bundle fixes all of that.
#
# Usage: Scripts/make-app.sh [debug|release]   (default: debug)
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/yafm"
APP="$ROOT/.build/$CONFIG/yafm.app"

if [[ ! -x "$BIN" ]]; then
	echo "Binary not found: $BIN — run 'swift build${CONFIG:+ -c }${CONFIG/debug/}' first." >&2
	exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/yafm"
cp "$ROOT/App/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/App/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Localizations (v0.7 i18n): copy every <lang>.lproj so SwiftUI's LocalizedString
# lookup resolves against the chosen language. Bundle.main is the app bundle here.
for lproj in "$ROOT"/App/Resources/*.lproj; do
	[[ -d "$lproj" ]] && cp -R "$lproj" "$APP/Contents/Resources/"
done

# Ad-hoc codesign so the bundle launches without Gatekeeper friction locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run: open \"$APP\""
