#!/usr/bin/env bash
# Build a release yafm.app and package it into a distributable .dmg.
#
# Usage: Scripts/make-dmg.sh
#
# Produces .build/release/yafm-<version>.dmg containing yafm.app + an
# /Applications drop link (the standard drag-to-install layout).
#
# Signing & notarization are OPT-IN via env vars; without them you still get a
# working (ad-hoc-signed) DMG for local/testing use — Gatekeeper will warn on
# another Mac until it's signed + notarized. Per VISION the shipped artifact is
# a *notarized* DMG, so set these before cutting a public release:
#
#   CODESIGN_IDENTITY  "Developer ID Application: Name (TEAMID)"   # Developer ID cert
#   AC_NOTARY_PROFILE  notarytool keychain profile name           # `xcrun notarytool store-credentials`
#
# Example (notarized):
#   CODESIGN_IDENTITY="Developer ID Application: A Kurach (XXXXXXXXXX)" \
#   AC_NOTARY_PROFILE="yafm-notary" Scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/App/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
APP="$ROOT/.build/release/yafm.app"
DMG="$ROOT/.build/release/yafm-$VERSION.dmg"
STAGE="$ROOT/.build/release/dmg-stage"

echo "▸ Building release binary…"
swift build -c release

echo "▸ Wrapping into yafm.app…"
"$ROOT/Scripts/make-app.sh" release >/dev/null

# Real signing if a Developer ID identity is provided; else keep the ad-hoc
# signature make-app.sh already applied.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
	echo "▸ Code-signing with Developer ID (hardened runtime)…"
	codesign --force --deep --options runtime --timestamp \
		--sign "$CODESIGN_IDENTITY" "$APP"
fi

echo "▸ Staging DMG contents…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating ${DMG}…"
hdiutil create -volname "yafm $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Notarize + staple when a notarytool profile is configured.
if [[ -n "${AC_NOTARY_PROFILE:-}" ]]; then
	echo "▸ Submitting to Apple notary service (this can take a few minutes)…"
	xcrun notarytool submit "$DMG" --keychain-profile "$AC_NOTARY_PROFILE" --wait
	echo "▸ Stapling ticket…"
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"
else
	echo "⚠︎ AC_NOTARY_PROFILE not set — DMG is NOT notarized (fine for local testing,"
	echo "  but Gatekeeper will block it on other Macs). See header for setup."
fi

echo "✓ $DMG"
