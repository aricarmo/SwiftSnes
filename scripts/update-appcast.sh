#!/usr/bin/env bash
# Adiciona o DMG recém-gerado ao feed do Sparkle em docs/appcast.xml.
# Usage: scripts/update-appcast.sh [dist/NotchSnes.dmg]
#
# O DMG é assinado com a chave EdDSA do Keychain (gerada com generate_keys;
# a pública está em snes/Info.plist) e a URL da enclosure aponta para o asset
# da release v<versão> no GitHub. Depois é só commitar docs/appcast.xml: o
# workflow Pages publica o feed.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-dist/NotchSnes.dmg}"
REPO=aricarmo/SwiftSnes
FEED=docs/appcast.xml
TOOLS=.derivedData/sparkle-tools
WORK=.derivedData/appcast

# Ferramentas da mesma versão do Sparkle resolvida pelo SPM.
SPARKLE_VERSION=$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' \
  NotchSnes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved | head -1)
if [[ ! -x "$TOOLS/bin/generate_appcast" ]]; then
  echo "baixando Sparkle $SPARKLE_VERSION (generate_appcast)…"
  mkdir -p "$TOOLS"
  curl -sSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$TOOLS"
fi

# Versão lida do app dentro do DMG, para montar a URL da release.
MOUNT=$(hdiutil attach -nobrowse -readonly "$DMG" | grep -o '/Volumes/.*' | tail -1)
VERSION=$(plutil -extract CFBundleShortVersionString raw "$MOUNT/NotchSnes.app/Contents/Info.plist")
hdiutil detach "$MOUNT" -quiet

# generate_appcast trabalha numa pasta: o feed atual + o novo arquivo, com o
# mesmo nome do asset publicado na release (NotchSnes.dmg).
rm -rf "$WORK" && mkdir -p "$WORK"
[[ -f "$FEED" ]] && cp "$FEED" "$WORK/appcast.xml"
cp "$DMG" "$WORK/NotchSnes.dmg"

"$TOOLS/bin/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://aricarmo.github.io/SwiftSnes/" \
  --full-release-notes-url "https://github.com/$REPO/releases/tag/v$VERSION" \
  --maximum-deltas 0 \
  "$WORK"

cp "$WORK/appcast.xml" "$FEED"
echo "wrote $FEED (v$VERSION)"
