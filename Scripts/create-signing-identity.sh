#!/usr/bin/env bash
# Creates a stable self-signed code signing identity named "Cicero Dev".
# Run once. Without it, every rebuild changes the app's signature and macOS
# revokes the Accessibility permission you just granted.
set -euo pipefail

IDENTITY="Cicero Dev"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Identidade \"$IDENTITY\" já existe."
    exit 0
fi

cat <<'EOF'
A criação da identidade é interativa e precisa ser feita no Acesso às Chaves:

  1. Abra o app "Acesso às Chaves"
  2. Menu: Acesso às Chaves > Assistente de Certificado > Criar um certificado…
  3. Nome:            Cicero Dev
     Tipo de identidade: Raiz autoassinada
     Tipo de certificado: Assinatura de código
  4. Marque "Permitir que eu sobreponha os padrões" e avance aceitando tudo
  5. Conclua e rode este script de novo para confirmar

EOF
exit 1
