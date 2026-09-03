#!/usr/bin/env bash
# Builds NotchSnes in Release and packages dist/NotchSnes.dmg.
# Usage: scripts/make-dmg.sh [--skip-build]
#
# Assinatura: por padrão ad-hoc (CI). Com CODE_SIGN_IDENTITY="Developer ID
# Application" assina com timestamp, e se NOTARY_PROFILE estiver definido
# (perfil salvo via `xcrun notarytool store-credentials`) envia o DMG para
# notarização, grampeia o ticket e atualiza docs/appcast.xml (Sparkle).
#
# Release completa:
#   VERSION=2.0 CODE_SIGN_IDENTITY="Developer ID Application" \
#     DEVELOPMENT_TEAM=LK4R5SQ8MK NOTARY_PROFILE=NotchSnes scripts/make-dmg.sh
#   gh release upload v2.0 dist/NotchSnes.dmg --clobber
#   git commit docs/appcast.xml && git push   # o workflow Pages publica o feed
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=.derivedData/dmg
APP="$DERIVED/Build/Products/Release/NotchSnes.app"
STAGE=.derivedData/dmg-stage
OUT=dist/NotchSnes.dmg
IDENTITY="${CODE_SIGN_IDENTITY:--}"

# Versão do bundle: VERSION=1.2 (ou tag v1.2 do git) sobrescreve o 1.0 fixo do
# projeto; sem isso o checador de update nunca acharia a versão instalada nova.
VERSION="${VERSION:-$(git describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"

SIGN_FLAGS=()
if [[ "$IDENTITY" != "-" ]]; then
  # Sem CODE_SIGN_INJECT_BASE_ENTITLEMENTS o Xcode adiciona get-task-allow,
  # que a notarização rejeita.
  SIGN_FLAGS=(CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp
              CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
              ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"})
fi

if [[ "${1:-}" != "--skip-build" ]]; then
  xcodebuild -project NotchSnes.xcodeproj -scheme NotchSnes -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGNING_ALLOWED=YES ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} \
    ${VERSION:+MARKETING_VERSION="$VERSION"} CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build | tail -3
fi

if [[ "$IDENTITY" != "-" ]]; then
  # O xcodebuild só assina o Sparkle.framework em si; os XPC/helpers dentro dele
  # continuam ad-hoc, e num app sandboxed o Installer.xpc precisa do mesmo Team
  # ID do app (e a notarização rejeita ad-hoc). Reassina de dentro para fora.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for item in "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/XPCServices/Downloader.xpc" \
              "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" \
              "$APP/Contents/Frameworks/Sparkle.framework" "$APP"; do
    codesign --force --sign "$IDENTITY" --timestamp --options runtime \
      --preserve-metadata=entitlements "$item"
  done
fi

rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname NotchSnes -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null

if [[ "$IDENTITY" != "-" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$OUT"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
    spctl -a -t open --context context:primary-signature -v "$OUT"
    scripts/update-appcast.sh "$OUT"
  fi
fi

echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
