#!/usr/bin/env bash
# Builds NotchSnes in Release and packages dist/NotchSnes.dmg.
# Usage: scripts/make-dmg.sh [--skip-build]
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=.derivedData/dmg
APP="$DERIVED/Build/Products/Release/NotchSnes.app"
STAGE=.derivedData/dmg-stage
OUT=dist/NotchSnes.dmg

# Versão do bundle: VERSION=1.2 (ou tag v1.2 do git) sobrescreve o 1.0 fixo do
# projeto; sem isso o checador de update nunca acharia a versão instalada nova.
VERSION="${VERSION:-$(git describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"

if [[ "${1:-}" != "--skip-build" ]]; then
  xcodebuild -project NotchSnes.xcodeproj -scheme NotchSnes -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" CODE_SIGNING_ALLOWED=YES \
    ${VERSION:+MARKETING_VERSION="$VERSION"} CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build | tail -3
fi

rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname NotchSnes -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
