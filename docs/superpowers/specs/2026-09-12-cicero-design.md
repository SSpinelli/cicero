# Cicero — Design

**Data:** 2026-09-12
**Status:** Aprovado, pronto para virar plano de implementação

## 1. Visão

Cicero é um app de menu bar para macOS que transforma fala em texto escrito, no app em que você já está trabalhando. Você segura um atalho global, fala, solta — e o texto transcrito e polido aparece onde o cursor estava.

É um clone do [Wispr Flow](https://wisprflow.ai) com uma diferença deliberada: **tudo roda na máquina local**. Nenhum áudio sai do computador, não há chave de API, não há custo por uso e funciona offline.

O nome homenageia Marco Túlio Cícero, o maior orador de Roma — a profissão dele era converter pensamento em palavra falada com precisão.

## 2. Restrições da máquina alvo

O design é calibrado para o hardware do usuário, verificado em 2026-09-12:

| Item | Valor | Consequência no design |
|---|---|---|
| Chip | Apple M4 (arm64) | Neural Engine disponível; Whisper via CoreML roda com baixa latência |
| RAM | 16 GB | Whisper e o polidor precisam coexistir; evitar LLM próprio de vários GB |
| macOS | 26.6.2 (Tahoe) | `FoundationModels.framework` disponível |
| Apple Intelligence | Ativado (`opted_in_buddy = 1`), assets generativos presentes | LLM on-device utilizável sem nenhum download |
| Swift | 6.3.3 | Concorrência estrita; Swift Testing nativo |
| Xcode | **Não instalado** (só Command Line Tools) | Build inteiramente via SwiftPM; o `.app` é montado e assinado por script |
| Disco livre | ~32 GB | Baixar só o modelo Whisper (~1,5 GB); não baixar LLM |

A ausência do Xcode e o disco limitado são os dois fatores que mais moldam as decisões abaixo.

## 3. Escopo do MVP

**Dentro:**

- App de menu bar (sem ícone no Dock)
- Atalho global push-to-talk: segurar, falar, soltar
- Captura de áudio do microfone
- Transcrição local via Whisper, com português e inglês misturados
- Polimento do texto por LLM on-device (remover vícios de linguagem, pontuar, formatar)
- Inserção automática do texto no app em foco
- HUD flutuante mostrando o estado da ditada
- Fluxo de permissões (microfone e Acessibilidade)

**Fora (marcos posteriores):**

- Modo hands-free (toque duplo para ligar/desligar)
- Vocabulário personalizado e aprendizado de termos
- Histórico de ditadas além da última
- Janela de preferências completa
- Execução da identidade visual (ícone desenhado, HUD refinado) — a *direção* está definida na Seção 8; a execução é um marco próprio
- Distribuição, notarização, atualizações automáticas

## 4. Arquitetura

**Princípio:** todo o miolo é lógica pura e testável. Tudo que toca o mundo real — microfone, teclado, clipboard, modelos — fica atrás de um protocolo. O fluxo completo é testável com fakes, sem microfone e sem modelo carregado.

### 4.1 Módulos

```
cicero/
├── Package.swift
├── Sources/
│   ├── CiceroKit/        lógica pura, zero efeito colateral
│   ├── CiceroAudio/      AVAudioEngine → PCM 16 kHz mono
│   ├── CiceroWhisper/    WhisperKitTranscriber (CoreML / Neural Engine)
│   ├── CiceroPolish/     FoundationModelsPolisher + PassthroughPolisher
│   ├── CiceroInput/      HotkeyMonitor (CGEventTap) + ClipboardTextInserter
│   └── CiceroApp/        executável: menu bar, HUD, permissões, composição
├── Tests/CiceroKitTests/
├── Resources/            Info.plist, ícone
└── Scripts/bundle.sh     monta e assina o Cicero.app
```

`CiceroKit` não importa nenhum outro módulo — a dependência aponta sempre para dentro. `CiceroApp` é o único lugar que conhece todas as implementações concretas e as monta.

Trocar WhisperKit por MLX no futuro significa escrever um módulo novo e mudar uma linha em `CiceroApp`.

### 4.2 Conteúdo de `CiceroKit`

- `DictationEngine` — a máquina de estados e orquestrador
- `Transcriber` — protocolo: `func transcribe(_ audio: AudioBuffer) async throws -> String`
- `TextPolisher` — protocolo: `func polish(_ text: String, context: DictationContext) async throws -> String`
- `TextInserter` — protocolo: `func insert(_ text: String) async throws`
- `AudioRecorder` — protocolo: `func start() async throws` / `func stop() async throws -> AudioBuffer`
- Modelos: `DictationState`, `DictationContext`, `AudioBuffer`, `CiceroError`

`DictationContext` carrega o nome e o bundle id do app em foco no momento da ditada, para o polidor ajustar o tom — escrever mais formal num cliente de e-mail que numa janela de chat, como o Wispr faz.

### 4.3 Máquina de estados

```
       segura atalho              solta atalho
idle ──────────────► recording ──────────────► transcribing
 ▲                       │                          │
 │                       │ Esc (cancela)            ▼
 │                       ▼                      polishing
 └───────────────────────┴──────◄── inserting ◄─────┘
```

Qualquer erro em qualquer estado leva de volta a `idle` com notificação ao usuário. O HUD nunca fica travado.

### 4.4 Fluxo de uma ditada

1. `HotkeyMonitor` detecta a tecla pressionada → `DictationEngine.start()`
2. Engine captura o app em foco (monta o `DictationContext`), liga o `AudioRecorder`, HUD aparece
3. Tecla solta → `AudioRecorder.stop()` devolve o buffer PCM
4. `Transcriber.transcribe(audio)` → texto cru
5. `TextPolisher.polish(texto, contexto)` → texto limpo
6. `TextInserter.insert(texto)` → cola no app em foco
7. Volta a `idle`, HUD some

### 4.5 Concorrência

Swift 6 com concorrência estrita ativada. `DictationEngine` é `@MainActor @Observable` — a UI observa o estado diretamente, sem camada de binding. O trabalho pesado (Whisper, LLM) roda em tasks assíncronas fora da main actor; as implementações de `Transcriber` e `TextPolisher` são `Sendable` e gerenciam seus próprios actors.

## 5. Decisões técnicas

### 5.1 Atalho push-to-talk

**Padrão: `⌃⌥Space`.** Configurável.

O Wispr usa `fn` por padrão, mas `fn` colide com o comportamento nativo do macOS (seletor de emoji / ditado do sistema) e exigiria que o usuário alterasse os Ajustes do Sistema. `⌃⌥Space` não tem conflito e funciona imediatamente. `fn` continua sendo uma opção configurável para quem quiser paridade com o Wispr.

A implementação usa `CGEventTap` em `.keyDown`/`.keyUp` e `.flagsChanged`, o que já requer permissão de Acessibilidade — a mesma que precisamos para inserir texto. Sem permissão adicional.

### 5.2 Inserção de texto

**Técnica: troca de clipboard + ⌘V sintético.**

1. Salvar o conteúdo atual do `NSPasteboard.general`
2. Escrever o texto transcrito
3. Postar um `CGEvent` de ⌘V direcionado ao app em foco
4. Restaurar o clipboard anterior após um atraso curto

A alternativa — inserção direta via Acessibilidade (`kAXSelectedTextAttribute`) — é mais limpa e não toca no clipboard, mas não é suportada por muitos apps (Electron, VS Code, Slack). Confiabilidade universal vence elegância. O protocolo `TextInserter` mantém a porta aberta para adicionar a via AX depois como preferência do usuário.

O atraso da restauração precisa ser calibrado: restaurar cedo demais quebra a colagem; tarde demais deixa o clipboard errado por mais tempo que o necessário.

Não há como detectar programaticamente que o app de destino leu o pasteboard — o `changeCount` do macOS incrementa em escrita, nunca em leitura. O atraso é, portanto, necessariamente um valor calibrado. O `changeCount` ainda assim é usado, para outra finalidade: se **outro** processo escreveu no clipboard durante a janela de espera, o `changeCount` terá mudado e a restauração é abortada, para não destruir o que esse processo colocou lá.

### 5.3 Transcrição

**WhisperKit** (`github.com/argmaxinc/WhisperKit`), pacote SwiftPM nativo que roda Whisper via CoreML na Neural Engine.

**Modelo: `large-v3-turbo`**, ~1,5 GB, baixado no primeiro uso. É o menor modelo que lida bem com português e inglês misturados — os modelos menores e mais rápidos (`distil-large-v3`, `*.en`) são English-only e não servem.

O idioma é deixado em detecção automática, para acomodar o code-switching PT/EN do usuário.

O download do modelo acontece na primeira execução. Enquanto isso, o app permanece aberto e utilizável, e o menu bar mostra o estado de carregamento; o atalho de ditado fica inerte até o modelo estar pronto. Uma barra de progresso detalhada fica para um marco posterior.

### 5.4 Polimento

**Apple `FoundationModels`** — o LLM on-device que já está instalado e ativado nesta máquina. Custo zero, download zero, offline, privado.

Implementação: `SystemLanguageModel.default` com uma `LanguageModelSession` cujas instruções descrevem a tarefa — limpar vícios de linguagem, pontuar, preservar o sentido, **nunca** responder ao conteúdo nem adicionar informação. O `DictationContext` entra nas instruções para ajuste de tom.

Duas restrições reais do framework, tratadas no design:

- **Disponibilidade.** `SystemLanguageModel.default.availability` pode retornar indisponível (Apple Intelligence desligado, modelo ainda baixando, dispositivo inelegível). O app checa na inicialização e a cada ditada, e cai para `PassthroughPolisher` quando indisponível — o texto cru é colado normalmente. O polimento é um realce, nunca um ponto único de falha.
- **Janela de contexto limitada** (na ordem de alguns milhares de tokens). Ditadas longas podem estourá-la. O polidor divide transcrições longas em blocos por fronteira de frase, poli cada bloco e reconcatena.

### 5.5 Permissões

- **Microfone** — `NSMicrophoneUsageDescription` no Info.plist + `AVCaptureDevice.requestAccess(for: .audio)`
- **Acessibilidade** — `AXIsProcessTrustedWithOptions` com prompt; necessária tanto para o `CGEventTap` quanto para o ⌘V sintético

**Armadilha crítica de desenvolvimento:** apps assinados ad-hoc perdem a permissão de Acessibilidade a cada rebuild, porque a assinatura muda a cada compilação. Isso tornaria o desenvolvimento insuportável.

**Solução:** criar uma vez um certificado self-signed de assinatura de código no Keychain do usuário e assinar sempre com ele. A identidade permanece estável entre builds e o macOS preserva a permissão concedida. O `Scripts/bundle.sh` usa essa identidade, e a criação do certificado é um passo documentado de setup único.

## 6. Tratamento de erros

Regra de ouro: **nunca perder o que o usuário falou.**

| Falha | Comportamento |
|---|---|
| Apple Intelligence indisponível | Cai para `PassthroughPolisher`; cola o texto cru |
| Polimento falha ou expira | Cola o texto cru |
| Campo de senha em foco (secure input ativo) | Recusa colar; mostra o texto no HUD para cópia manual |
| Permissão de microfone negada | Menu bar sinaliza; abre os Ajustes do Sistema |
| Permissão de Acessibilidade negada | Menu bar sinaliza; abre os Ajustes do Sistema |
| Modelo Whisper ainda não baixado | HUD informa; ditada não inicia |
| Transcrição falha | Notifica; volta a `idle` |
| Áudio vazio ou silêncio | No-op; nada é colado |
| Colagem falha | Texto permanece acessível no menu bar |

Rede de segurança geral: a **última transcrição fica sempre acessível pelo menu bar**. Uma colagem que falhou nunca apaga as palavras do usuário.

## 7. Testes

**Swift Testing** (nativo do Swift 6), em TDD — testes antes da implementação.

`CiceroKitTests` exercita o `DictationEngine` inteiro com `FakeRecorder`, `FakeTranscriber`, `FakePolisher` e `FakeInserter`:

- Transições de estado do caminho feliz
- Cancelamento durante a gravação
- Fallback quando o polidor falha (deve colar o texto cru)
- Cada caminho de erro da Seção 6
- Áudio vazio não dispara colagem
- O `DictationContext` chega ao polidor com o app em foco correto

Os adaptadores concretos (`CGEventTap`, clipboard, WhisperKit, FoundationModels) são verificados manualmente. Não existe teste unitário honesto para eles; tentar mockar as APIs do sistema testaria o mock, não o código.

## 8. Branding

**Conceito:** a eloquência de Roma, com a contenção de um app macOS moderno. A regra é restrição — o tema romano vive na identidade visual e nos detalhes, nunca no caminho do uso. O app fala português e inglês normalmente; não há menus em latim.

**Mote:** *Verba volant, scripta manent* — provérbio latino: "as palavras faladas voam, as escritas permanecem". Aparece na janela Sobre e na tela de boas-vindas.

**Paleta:**

| Nome | Hex | Uso |
|---|---|---|
| Mármore | `#F4F1EA` | fundos, superfície do HUD |
| Púrpura de Tiro | `#6B2D4F` | cor primária (a cor da faixa dos senadores) |
| Louro | `#6B7A4F` | estado de sucesso |
| Bronze | `#C9A227` | acentos |
| Basalto | `#1C1A19` | texto, modo escuro |

**Ícone:** um "C" formado por uma coroa de louros — a abertura natural da coroa já é o formato da letra. Precisa funcionar em duas escalas: colorido no Dock e como glifo monocromático (template image) nos 16 px da menu bar, adaptando-se sozinho a tema claro e escuro.

**HUD:** pílula flutuante discreta na base da tela. Superfície mármore, forma de onda em púrpura reagindo à voz durante a gravação; ao soltar a tecla a onda se acalma e os louros se fecham durante transcrição e polimento. Feedback de estado sem texto.

**Menu bar:** o mesmo glifo de louros com variação sutil — repouso em contorno, gravando preenchido e pulsando, processando girando devagar.

A execução visual é um marco próprio, posterior ao esqueleto funcional. O que está definido aqui é a direção.

## 9. Build e empacotamento

Sem Xcode. O build é SwiftPM puro e o `.app` é montado por script.

`Scripts/bundle.sh`:

1. `swift build -c release --arch arm64`
2. Monta a árvore `Cicero.app/Contents/{MacOS,Resources}`
3. Copia o executável, o `Info.plist` e os recursos
4. Assina com a identidade self-signed estável (Seção 5.5)

O `Info.plist` define `LSUIElement = true` (app de menu bar, sem ícone no Dock) e `NSMicrophoneUsageDescription`.

## 10. Decisões registradas

Escolhas feitas durante o brainstorming, com a razão, para não serem relitigadas sem motivo novo:

| Decisão | Alternativa descartada | Razão |
|---|---|---|
| Transcrição local | API na nuvem | Privacidade, custo zero, offline; o M4 dá conta |
| `FoundationModels` para polir | MLX com modelo próprio | Zero download e zero RAM extra; já está instalado e ativo. Disco livre é limitado |
| SwiftPM + bundle por script | Instalar Xcode | Nada para baixar; tooling inteiramente por CLI |
| `⌃⌥Space` | `fn` (padrão do Wispr) | `fn` colide com o macOS e exigiria mudar Ajustes do Sistema |
| Clipboard + ⌘V | Inserção via Acessibilidade | Funciona em todo app, inclusive Electron |
| `large-v3-turbo` | Modelos menores | Os menores são English-only; o uso é PT/EN misturado |
| Polidor plugável | Polimento embutido no engine | Permite fallback para texto cru e troca de motor sem refatorar |
