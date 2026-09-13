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

## Como rodar

```bash
./Scripts/create-signing-identity.sh   # uma vez só
./Scripts/bundle.sh
open dist/Cicero.app
```

Na primeira execução o Cicero baixa o modelo Whisper (~1,5 GB) e pede permissão
de microfone e de Acessibilidade.

## Testes

```bash
./Scripts/test.sh
```
