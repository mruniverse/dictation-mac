# Inserção de ditado: piloto TextEdit

Issue #12, fase 1. O objetivo segue sendo entregar o ditado no campo em uso; este piloto só insere em uma área de texto editável do TextEdit, por push-to-talk e com opt-in desativado ao abrir o app. Outros apps, incluindo Terminal, TUI e REPL, continuam em prévia/cópia até haver um mecanismo verificável que não execute comandos. Não simular teclas nem usar o clipboard para inserção.

## Prova de viabilidade

Em um processo do TextEdit lançado em segundo plano com um documento descartável e dados sintéticos, um processo local já autorizado em Acessibilidade encontrou a área de texto do documento, verificou que `AXSelectedText` era gravável, colocou o cursor no fim e acrescentou uma frase com acento e emoji. A leitura do documento sintético confirmou a inserção exata; o conteúdo foi restaurado e a instância de teste encerrou. Isso valida o mecanismo naquele TextEdit/macOS, não a permissão do bundle nem o fluxo do produto. O cabeçalho público de Acessibilidade marca o atributo como não gravável; a disponibilidade precisa ser consultada no elemento, não generalizada para outros apps.

## Contrato de destino e sessão

- Vincular o alvo ao identificador exato de uma sessão de push-to-talk aceita. Não usar o resultado de captura manual ou de uma sessão anterior. Sem acesso de Acessibilidade, com Secure Input, foco desconhecido, campo protegido, seleção não vazia ou destino fora da allowlist, manter prévia/cópia.
- Identificar processo, janela, elemento editável e posição de cursor. Revalidar os quatro imediatamente antes da única escrita direcionada a esse elemento. Perda de foco observada, confirmação do primeiro envio, suspensão ou desativação invalidam o alvo; voltar ao mesmo app não restabelece um alvo invalidado.
- Preservar a transcrição original na prévia. Para a escrita, substituir separadores de linha e tabulação por espaço, remover controles e bidi explícito, preservar texto Unicode comum e recusar resultado vazio ou longo demais.
- Consumir o destino antes de qualquer tentativa; confirmar pelo cursor e, quando disponível, pelo intervalo inserido. Sem confirmação, informar resultado indeterminado, nunca tentar novamente. Nenhum texto, nome de janela ou credencial nos logs.

A validação e a escrita são mensagens distintas do macOS; não há garantia de atomicidade. Se o usuário selecionar texto depois da última validação, o macOS ainda pode substituir essa seleção. A confirmação indica o resultado observado, não que nenhuma seleção concorrente foi substituída. Não usar o mecanismo fora do TextEdit nem apresentar uma escrita incerta como sucesso.

## Gates

1. Política por sessão e sanitização em `Sources/DictationCore/TextInsertion.swift`, com testes em `Tests/DictationCoreTests/TextInsertionTests.swift`: sem tentativa extra, sem uso por outra sessão e sem escrever após perda de foco, cancelamento ou texto inválido.
2. Adaptador de Acessibilidade e integração com captura/atalho: testes com dublês para destino mudado, seleção, Secure Input, permissão revogada e primeira confirmação. Provar que a cópia explícita continua disponível e que nada é enviado ao Terminal. Manter a função atrás do opt-in.
3. Smoke do bundle assinado: TextEdit com texto simples e rico, desfazer, outro app em foco, troca de janela/cursor, campo protegido e Terminal sem alteração. Registrar limites, não publicar áudio ou texto pessoal.

O rascunho ainda não observa mudanças reversíveis de janela, campo ou cursor dentro do TextEdit: por enquanto uma volta ao mesmo alvo passa na revalidação final. Antes de sair de rascunho, invalidar o alvo ao observar mudanças internas e fazer o smoke do bundle. A ligação real do primeiro envio é coberta por `FirstSendWiringTests`, que chama o mesmo wrapper usado por `AppDelegate.cloud`; retirar a invalidação faz esse teste falhar.
