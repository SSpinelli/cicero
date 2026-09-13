#!/usr/bin/env bash
# Creates a stable self-signed code signing identity named "Cicero Dev".
# Run once. Without it, every rebuild changes the app's signature and macOS
# revokes the Accessibility permission you just granted.
set -euo pipefail

IDENTITY="Cicero Dev"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Identidade \"$IDENTITY\" pronta para uso."
    exit 0
fi

# The certificate may exist while still being unusable. A self-signed root is
# not trusted for code signing until you say so explicitly, and until then
# `find-identity -v` reports nothing at all — which looks identical to having
# created no certificate. Tell the two cases apart so the instructions match
# the situation.
if security find-identity | grep -q "$IDENTITY"; then
    cat <<'EOF'
O certificado "Cicero Dev" já existe e a chave privada está pareada, mas o
macOS ainda não confia nele para assinar código (CSSMERR_TP_NOT_TRUSTED).
Falta só marcar a confiança:

  1. Abra o app "Acesso às Chaves":
     open "/System/Library/CoreServices/Applications/Keychain Access.app"
  2. Chaveiro "login", aba "Meus Certificados"
  3. Duplo clique em "Cicero Dev"
  4. Expanda a seção "Confiar"
  5. Em "Assinatura de Código", escolha "Sempre Confiar"
  6. Feche a janela — o macOS vai pedir a senha do seu Mac
  7. Rode este script de novo para confirmar

EOF
    exit 1
fi

cat <<'EOF'
A criação da identidade é interativa e precisa ser feita no Acesso às Chaves.

No macOS 26 o app não fica mais na pasta Utilitários. Abra assim:

  open "/System/Library/CoreServices/Applications/Keychain Access.app"

Depois:

  1. Menu "Acesso às Chaves" (na barra do topo da tela, ao lado da maçã)
     > Assistente de Certificado > Criar um certificado…
     Ou abra o assistente direto:
     open "/System/Library/CoreServices/Certificate Assistant.app"
  2. Nome:                Cicero Dev
     Tipo de identidade:  Raiz autoassinada
     Tipo de certificado: Assinatura de código
  3. Marque "Permitir que eu sobreponha os padrões" e avance aceitando tudo
  4. Conclua

Criar o certificado NÃO basta: uma raiz autoassinada não é confiável para
assinar código até você marcar isso à mão. Rode este script de novo depois de
criar e ele te guia pelo passo da confiança.

EOF
exit 1
