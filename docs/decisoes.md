# Decisões do Cicero

Por que o código é assim. Registro das escolhas que não são óbvias lendo os arquivos — várias delas contrariam o que parece natural, e algumas contrariam o próprio spec.

Mantido porque o motivo de uma decisão dura mais que a memória de quem a tomou.

---

## Testes não rodam com `swift test`

**Nunca use `swift test` neste projeto.** Sem o Xcode instalado não existe o binário `xctest` para carregar o bundle que o SwiftPM constrói, então o comando compila, imprime `Build complete!`, sai com código 0 e **executa zero testes**. Um `swift test` verde aqui não prova nada.

Os alvos de teste são `executableTarget` com um `Runner.swift` que chama o entry point do Swift Testing, acionados por `./Scripts/test.sh`.

Isso foi descoberto quando uma tarefa reportou suíte verde tendo executado nada. O custo da solução: `unsafeFlags` com caminhos absolutos das Command Line Tools em `Package.swift`, e uma API com underscore. Se uma atualização de toolchain mover esses caminhos, o build de testes quebra até alguém atualizar duas constantes.

## O idioma da transcrição é fixado, não detectado

O spec pedia detecção automática, para suportar ditado misturando português e inglês. **Medição mostrou que essa escolha não é viável** nos clipes de 2 a 4 segundos que ditado por atalho produz.

No mesmo áudio de dois segundos:

| `language` | Resultado | Repetições |
|---|---|---|
| `nil` (auto) | `The rat ruined the King of Rome's clothes.` | 5 de 5 |
| `"pt"` | `O rato roeu a roupa do rei de Roma.` | 3 de 3 |

A detecção lê uma única janela e erra em clipes curtos. O Whisper então condiciona o decodificador no token errado e **gera texto naquele idioma** — o usuário vê uma tradução, ou português com palavras que nunca disse. Palavras em inglês dentro de uma frase em português continuam transcrevendo bem com o idioma fixado; um token de idioma errado, não.

## A compilação da Neural Engine acontece no `prepare()`

Sem `prewarm: true`, a primeira transcrição de cada execução passava cerca de dois minutos dentro do `ANECompiler` enquanto o menu dizia "Transcrevendo…". Medido: 162,9s com o cache limpo, 10,9s com ele intacto — o cache persiste entre execuções e é invalidado quando o binário muda.

O `prepare()` já está fora do caminho do ditado e já mostra "Carregando modelo…". É onde esse custo pertence.

## O motor identifica ditados por geração, não por estado

`state` e o handle da task **não sobrevivem a um `await`**: depois de qualquer suspensão, podem pertencer a um ditado mais recente. Re-checar `state` após um `await` está checando o estado de outro ditado.

Cada operação captura um contador de geração antes da primeira suspensão e revalida a posse após **cada** suspensão seguinte. `isCancelling` é privado e deliberadamente **não** é um caso de `DictationState` — esse enum é público e percorrido exaustivamente por outros módulos, e seus casos são fixados pelo spec.

Esta classe de defeito — condição verificada antes de um `await`, usada depois — apareceu **nove vezes** no projeto. Duas correções dela introduziram outra da mesma classe. Se você for mexer em concorrência aqui, assuma que é mais sutil do que parece.

## O cancelamento não solta o motor antes de terminar

Soltar `state = .idle` no início de um cancelamento é o que permite a um novo ditado entrar por baixo de um cancelamento em andamento. O motor permanece não-iniciável até o gravador ter sido de fato cancelado.

## A área de transferência é restaurada condicionalmente

Não há como detectar que o app de destino leu o pasteboard — `changeCount` incrementa em escrita, nunca em leitura. A espera antes de restaurar é necessariamente um atraso calibrado, não uma confirmação.

O `changeCount` serve a outro propósito: se **outro processo** escreveu no clipboard durante a espera, o conteúdo dele é mais novo, e restaurar destruiria. Nesse caso a restauração é abortada.

Inserções concorrentes são serializadas por um mutex FIFO. Sem isso, dois ditados sobrepostos gravavam o texto ditado por cima do clipboard real do usuário, de forma irrecuperável — um actor sozinho **não** resolve, porque actors são reentrantes em pontos de suspensão.

## O atalho solta com `.flagsChanged`, e o key-up casa só pelo keyCode

Soltar ⌃⌥ antes do Espaço — acidente de ordem de varredura do hardware, não intenção — deixava o app gravando para sempre, com o microfone ligado e o atalho morto pelo resto da sessão.

O key-**down** exige casamento estrito de modificadores, senão o atalho dispararia em teclas alheias. O key-**up** casa só pelo keyCode enquanto a tecla estiver marcada como pressionada, e `.flagsChanged` também encerra o ditado quando os modificadores deixam de satisfazer o atalho.

## O polidor preserva palavras condicionalmente

Instruir o modelo a apagar "aí" e "sabe" incondicionalmente perde sentido: são hesitação comum em português brasileiro, mas também verbo e advérbio. A instrução é condicionada à **função** da palavra, com exemplos contrastantes e um desempate explícito de preservar em caso de dúvida.

Medido: remoção de vícios, "sabe" como verbo e "aí" como advérbio, 20 de 20 execuções cada, sem tensão entre as propriedades.

O polidor também é instruído a **nunca responder** ao conteúdo. Sem isso, ditar "qual é a capital da França" devolvia "Paris" em vez da pergunta escrita.

## O HUD é `NSPanel`, não `NSWindow`

`.nonactivatingPanel` é um style mask exclusivo de painéis e **inerte** num `NSWindow`. Com `NSWindow`, mostrar o HUD roubaria o foco do app onde o usuário está ditando — quebrando a interação central do produto.

## O app recusa uma segunda cópia

Duas instâncias produzem dois glifos idênticos na barra, dois event taps disputando o mesmo atalho, e dois modelos de ~1,5 GB em memória. Isso custou uma sessão inteira de depuração: uma build velha e uma nova rodaram lado a lado, a velha respondeu ao atalho, e o comportamento dela foi atribuído à nova.

## O ícone é a letra, não a coroa

O briefing de marca pedia um "C" formado por uma coroa de louros. **Isso não sobrevive a 18 pontos** — folhas se fundem em caroços sobre o traço ou desaparecem, confirmado por várias tentativas renderizadas. A letra carrega a identidade sozinha; a coroa fica para um vetor desenhado à mão.

O símbolo original, `laurel.leading`, renderiza com 9 pontos de largura e era invisível na prática. Foi escolhido no plano sem ninguém tê-lo renderizado.

## A assinatura é preferida à portabilidade do bundle

Copiar os bundles de recurso do SwiftPM para a **raiz** do `.app`, que é onde o accessor gerado procura, é inconstruível: o `codesign` rejeita qualquer entrada na raiz. A assinatura carrega a concessão de Acessibilidade — sem ela não há atalho nem colagem, ou seja, não há app.

Os bundles vão para `Contents/Resources` e o `Bundle.module` ainda resolve por um caminho absoluto do `.build` local. **O `.app` não é portátil para outra máquina.** Distribuição está fora do escopo do spec.

---

## Lacunas conhecidas

- A fiação do event tap e a camada AppKit não têm teste automatizado. São cobertas por uma lista de verificação manual — e foi exatamente ali que os três bugs que tornaram o app inutilizável se esconderam.
- Texto de erro de frameworks em inglês aparece embutido em mensagens em português, em caminhos de falha raros.
- `TextChunker` fragmenta "..." e "?!" em sentenças de um caractere, acima do limiar de 1500 caracteres.
- Um `cancel()` que nunca retorne trava o motor permanentemente. O gravador real limita isso por timeout.
