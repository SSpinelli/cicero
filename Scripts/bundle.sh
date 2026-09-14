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
BIN_PATH="$(swift build -c release --package-path "$ROOT" --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/CiceroApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Os resource bundles que o SwiftPM emite para as dependências
# (swift-transformers_Hub, swift-crypto_Crypto). Antes disso o .app saía sem
# nenhum deles e só funcionava nesta máquina, por acidente: o acessor gerado
# do `Bundle.module` tenta `Bundle.main.bundleURL/<nome>.bundle` e, se não
# achar, cai num caminho absoluto fixo para o `.build` DESTE worktree.
#
# ATENÇÃO — limitação conhecida, medida, não suposta: para um .app,
# `Bundle.main.bundleURL` é o próprio .app, ou seja, o acessor procura na
# RAIZ do bundle, ao lado de `Contents`. E o `codesign` recusa qualquer coisa
# na raiz de um .app ("unsealed contents present in the bundle root") — como
# diretório, como symlink, com --ignore-resources, e mesmo copiando depois de
# assinar (aí a verificação passa a falhar e o `spctl` rejeita o app). Não dá
# para ter as duas coisas: ou o .app é assinável (e as permissões de
# Acessibilidade sobrevivem a rebuilds), ou o `Bundle.module` do SwiftPM
# resolve. Escolhemos a assinatura.
#
# O que isto resolve, então: o .app passa a carregar os próprios recursos em
# `Contents/Resources`, que é onde todo build de Xcode os coloca e onde
# qualquer busca por `Bundle.main.resourceURL` acha. O que NÃO resolve: o
# acessor gerado pelo SwiftPM continua caindo no `.build` desta máquina, e
# `Hub.fallbackTokenizerConfig` ainda pode dar `fatalError` numa máquina sem
# ele. Ver README, seção "Distribuição".
copied=0
for bundle in "$BIN_PATH"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
    echo "    + Contents/Resources/$(basename "$bundle")"
    copied=$((copied + 1))
done
if [ "$copied" -eq 0 ]; then
    echo "    ERRO: nenhum resource bundle encontrado em $BIN_PATH." >&2
    echo "    O app sairia sem recurso nenhum, dependendo inteiramente do .build local." >&2
    exit 1
fi

echo "==> Assinando"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "    assinado com \"$IDENTITY\" (permissões sobrevivem a rebuilds)"
else
    codesign --force --deep --sign - "$APP"
    echo "    AVISO: assinado ad-hoc. Rode Scripts/create-signing-identity.sh,"
    echo "    senão você terá que reconceder a permissão de Acessibilidade a cada build."
fi

# O guard de instância única do app faz a cópia NOVA sair quando já há uma
# rodando — o comportamento certo em uso normal, e exatamente o errado depois de
# um build: você roda `open dist/Cicero.app`, o binário recém-assinado encerra em
# silêncio, e o que responde ao atalho continua sendo o build velho. Não há
# janela nem ícone no Dock para denunciar isso, e o app que sobrevive é o que
# tem o código antigo. Isso já contaminou três sessões de diagnóstico neste
# projeto, com comportamento de build obsoleto atribuído a código novo.
#
# Encerrar aqui, depois de o build ter dado certo, garante a invariante: ao
# terminar o bundle.sh, nenhuma instância obsoleta está no ar. Um build que
# falha aborta antes desta linha e deixa o app em execução intocado.
#
# O executável se chama CiceroApp, não Cicero — `pkill -x Cicero` não casa com
# nada e silenciosamente não faz coisa alguma.
if pkill -x CiceroApp 2>/dev/null; then
    echo "==> Encerrada a instância anterior (o build novo sairia sozinho se ela continuasse no ar)"
fi

echo "==> Pronto: $APP"
