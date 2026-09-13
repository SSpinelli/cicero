# Cicero

> *Verba volant, scripta manent*

Ditado por voz para macOS, inteiramente local. Segure `⌃⌥Espaço`, fale, solte —
o texto transcrito e polido aparece no app em que você está.

Nenhum áudio sai da máquina. A transcrição roda no Whisper via CoreML e o
polimento usa o modelo on-device da Apple.

## Requisitos

- macOS 26 ou superior, Apple Silicon
- Apple Intelligence ativado (sem ele o Cicero cola o texto cru)
- Swift 6.3 (Command Line Tools bastam; o Xcode não é necessário)

### As Command Line Tools precisam estar no caminho padrão

O `Package.swift` aponta para o Swift Testing de dentro das Command Line Tools,
num caminho fixo:

```
/Library/Developer/CommandLineTools/Library/Developer/Frameworks
```

O motivo está comentado no próprio manifesto: rodar testes aqui não usa
`swift test` (sem o Xcode não existe o binário `xctest`), então cada suíte é um
executável com `@main`, e executáveis não enxergam o framework `Testing` sem
esses flags.

Consequência: numa máquina que tem o Xcode mas **não** tem as Command Line
Tools instaladas separadamente, esse diretório não existe e tanto `swift build`
no nível do pacote quanto `./Scripts/test.sh` falham em algum alvo de teste —
com esta mensagem, que não menciona caminho nenhum e por isso engana:

```
error: no such module 'Testing'
```

(Se o módulo for achado mas o framework não, a mesma causa aparece como
`ld: framework 'Testing' not found`.)

Se isso acontecer, instale as Command Line Tools (`xcode-select --install`) —
tê-las embutidas no Xcode não basta, porque o caminho acima é o das CLT
avulsas. Construir só o app (`./Scripts/bundle.sh`, que passa
`--product CiceroApp`) não passa pelos alvos de teste e portanto não depende
disso.

## Como rodar

```bash
./Scripts/create-signing-identity.sh   # uma vez só
./Scripts/bundle.sh
open dist/Cicero.app
```

Na primeira execução o Cicero baixa o modelo Whisper (~1,5 GB) e pede permissão
de microfone e de Acessibilidade.

## Distribuição

`Scripts/bundle.sh` monta `dist/Cicero.app` e copia para
`Contents/Resources/` os resource bundles que o SwiftPM emite para as
dependências (`swift-transformers_Hub.bundle`, `swift-crypto_Crypto.bundle`).
Antes eles não eram copiados: o `.app` saía com `Resources/` vazio.

Resta uma limitação conhecida, medida neste worktree, para quem for levar o
`.app` para outra máquina:

- O acessor de `Bundle.module` que o SwiftPM gera para uma dependência procura
  o bundle em `Bundle.main.bundleURL/<nome>.bundle` — ou seja, na **raiz** do
  `.app`, ao lado de `Contents` — e, se não achar, cai num caminho absoluto
  fixo para o `.build` da máquina onde foi compilado.
- O `codesign` recusa qualquer conteúdo na raiz de um `.app` ("unsealed
  contents present in the bundle root"): como diretório, como symlink, com
  `--ignore-resources` e mesmo copiando depois de assinar (aí a assinatura
  passa a não verificar e o `spctl` rejeita o app).

Ou seja, as duas coisas não coexistem, e a escolha aqui é manter o `.app`
assinável — é a assinatura estável que faz a permissão de Acessibilidade
sobreviver a rebuilds, e sem ela o Cicero não tem nem atalho global nem
colagem. O efeito colateral é que, numa máquina sem o `.build` deste projeto,
`Hub.fallbackTokenizerConfig` (usado só quando a busca remota do tokenizer não
traz `tokenizer_class`) pode terminar em `fatalError`. Distribuir de verdade
para outras máquinas exige resolver isso antes — construindo o app pelo Xcode,
que gera um acessor que olha para `Contents/Resources`, ou embutindo os
recursos num alvo próprio.

## Testes

```bash
./Scripts/test.sh
```
