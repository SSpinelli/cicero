#!/usr/bin/env bash
# Builds Cicero and assembles a signed .app bundle at dist/Cicero.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Cicero.app"
IDENTITY="Cicero Dev"

echo "==> Compilando"
# Só o produto CiceroApp: o pacote também tem executáveis de teste que usam
# "@testable import" e só compilam com testabilidade habilitada (o padrão do
# SwiftPM em debug, não em release). Construir o pacote inteiro em release
# falharia por causa deles, sem relação nenhuma com o bundle ou a assinatura.
swift build -c release --package-path "$ROOT" --product CiceroApp
BINARY="$(swift build -c release --package-path "$ROOT" --show-bin-path)/CiceroApp"

echo "==> Montando o bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/CiceroApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> Assinando"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "    assinado com \"$IDENTITY\" (permissões sobrevivem a rebuilds)"
else
    codesign --force --deep --sign - "$APP"
    echo "    AVISO: assinado ad-hoc. Rode Scripts/create-signing-identity.sh,"
    echo "    senão você terá que reconceder a permissão de Acessibilidade a cada build."
fi

echo "==> Pronto: $APP"
