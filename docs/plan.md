# Dictation Mac — plano de produto e engenharia

## Produto

Ditar em português ou inglês no aplicativo em uso, sem abrir um editor separado. Pressionar um atalho inicia a captura; soltar encerra e insere texto pontuado. Público inicial: profissionais que escrevem em vários apps e usuários de terminal. Nome provisório; GitHub público é decisão tomada, licença e marca de distribuição não são.

## Decisão atual: nuvem primeiro, offline opcional

A primeira versão prioriza um serviço pago de transcrição, com chave de API do usuário. A decisão sucede os testes offline da issue #1: houve transcrição local, mas a rota ainda não comprovou qualidade e latência interativas no host disponível. Os gates offline passam a valer para promover uma rota offline, não para iniciar o app. Provedor inicial candidato: API oficial de transcrição da OpenAI; escolher o modelo após conferir catálogo vigente e ciclo de vida. A assinatura do ChatGPT/Codex não equivale a uma credencial de API de áudio. Codex/Claude instalados continuam candidatos à revisão textual opcional, não dependências do MVP.

PRs de implementação em rascunho: [#8](https://github.com/mruniverse/dictation-mac/pull/8) acrescenta a barra de menus, captura manual e transcrição cloud com opt-in; [#10](https://github.com/mruniverse/dictation-mac/pull/10), empilhado sobre #8, integra push-to-talk opcional. O primeiro corte não insere texto automaticamente em outros apps: mostra resultado na prévia/menu e só copia por ação explícita. O atalho é desativado a cada lançamento e só pode ser ativado depois de autorizar o microfone pela captura manual.

- Captura manual: Iniciar/Parar/Cancelar, acesso ao microfone sob ação, até 30 s; em captura manual, Parar ou limite podem enviar apenas com chave e consentimento.
- Push-to-talk: combinação Carbon Ctrl+Shift+D/G/J/K, opt-in; primeiro par press/release arma. Soltar a combinação antes de 25 s encerra e pode iniciar transcrição; prazo, cancelamento, suspensão, Secure Input no release ou perda de sessão descartam sem enviar. A captura manual não pode ser tomada pelo atalho, e o botão Parar não submete uma sessão PTT.
- Cloud: `gpt-transcribe`, chave própria no Keychain, autorização explícita separada e confirmação do primeiro envio. Remover chave revoga também se o Keychain falhar. Os testes usam apenas transporte falso; não houve chamada paga.
- Evidência automatizada local: suite Swift, janela AppKit real para o prazo e bundle assinado x86_64 passam nas branches de trabalho. CI do PR #8 passa; o CI do PR #10 e o smoke físico de teclas/microfone ainda são gates antes de declarar esse corte pronto. Apple Silicon e inserção em destino real também seguem não verificados.

Próximos gates: smoke manual da permissão/liberação do microfone, atalho com outro app em foco e diversas ordens de soltura dos modificadores, Secure Input e suspensão. Manter preview/copy como padrão; a inserção global só começa depois de resolver e testar foco, Terminal/TUI/REPL e modo de entrada seguro.

## Fases e critérios de saída

| Fase | Entrega | Aceite / evidência |
|---|---|---|
| 0 — viabilidade | Swift/AppKit, testes macOS, prova com áudio de arquivo e transcrição no dispositivo | Build no Mac atual; teste em pt-BR com engine real e sem credenciais ou rede como fallback; registrar compatibilidade Intel/Apple Silicon separadamente |
| 1 — ditado | Menu bar, onboarding de permissões, captura de microfone, push-to-talk, pontuação e entrega no destino | Demonstração real em TextEdit, Terminal e editor/navegador; casos de pergunta, afirmação, exclamação, acentos e troca de foco; zero execução automática |
| 2 — escolha de modelos | Seletores separados para transcrição e revisão de texto; modelos locais e BYOK | Exibir idioma, capacidade e destino dos dados; chave no Keychain; teste de credencial iniciado pelo usuário; falha sem redirecionamento silencioso |
| 3 — CLI instalada | Avaliar Codex e Claude Code como revisores opcionais de texto | Viabilidade técnica e termos/documentação oficiais validados por fornecedor; opt-in; escopo isolado, sem ferramentas ou execução de comandos; não ler tokens da sessão, não fazer login pelo usuário; se o isolamento não puder ser garantido, não disponibilizar |
| 4 — serviço gerenciado | Conta e API própria com catálogo, quotas e cobrança | Limites e isolamento por conta, consentimento, orçamento, política de retenção, exclusão e operação do serviço aprovados antes do lançamento |
| 5 — distribuição | Beta instalável, depois release assinada e notarizada | Teste em máquina limpa, verificação de arquitetura, atualização e rollback; README/demonstração em inglês para portfólio; preço a validar |

Codex/Claude instalados são clientes locais, não modelos offline: podem enviar texto ao fornecedor. Não presumir que assinatura de chat cobre API ou transcrição, nem habilitar chamadas pagas em desenvolvimento sem autorização. Apple Speech on-device é hipótese para a primeira prova; se não suportar pt-BR nesta máquina, avaliar Whisper multilíngue compatível com Intel, com revisão de licença e medição de tamanho/tempo. Não habilitar reconhecimento remoto automaticamente. Streaming, reuniões, histórico na nuvem e mobile ficam fora do primeiro entregável.

## Fluxo e fronteiras da fase 1

- Atalho atual: Carbon global com lista curta Ctrl+Shift+D/G/J/K, default D, opt-in e desativado ao iniciar. O primeiro par press/release só arma; manter latch, dono por ID e prazo monotônico de 25 s iniciado no press. Só release válido antes do prazo submete; watchdog, suspensão ou Secure Input no release descarta. Sem toggle, modifier-only Command direito ou event tap genérico.
- Captura manual: `idle → awaitingPermission → recording`; Parar ou 30 s pode submeter após consentimento. Push-to-talk usa o mesmo controller com origem e deadline explícitos: release da sessão dona submete, `Parar` manual não age sobre ela; limite/deadline cancelam sem enviar, inclusive se a permissão chegar tarde. Repetição não inicia outra captura. Eventos antigos e callbacks assíncronos não podem tomar posse de outra sessão.
- `processing → preview/copy → idle`: mostrar resultado no menu, copiar apenas por ação explícita. Não inserir texto automaticamente ainda. Qualquer incremento futuro de inserção revalida app e campo focado; Terminal, TUI e REPL ficam em prévia/cópia por padrão porque digitação sem Return também pode executar ações. Nada de pressionar Return ou executar shell.
- Microfone, reconhecimento e Accessibility: pedir em contexto, explicar por que e tratar negativa/revogação sem travar. Não mudar preferências do sistema e não desligar Dictation nativo. Áudio e texto sem persistência por padrão; temporários em disco apenas quando necessários, isolados e apagados ao encerrar; logs sem conteúdo, segredos ou nomes de janelas. Nenhum provedor extra habilitado por fallback.
- Pontuação automática no motor quando suportada; preservar intenção, nomes, números e comandos. Revisão por LLM é opcional, pode errar e nunca substitui a transcrição original em caso de falha. Saída de provedor é dado, não instrução. Mudanças semânticas entram na matriz de avaliação, não são “melhoria” presumida.

## Critério reproduzível da fase 0

- Prova local com motor real, separada do CI (build e testes determinísticos). Se o Speech exigir autorização, usar bundle com `NSSpeechRecognitionUsageDescription` e concessão manual; nunca automatizar permissões. Registrar downloads de preparação separadamente da inferência, que deve rodar sem fallback remoto. Não alterar ajustes de ditado para mascarar indisponibilidade.
- Em pt-BR, testar afirmação, pergunta e exclamação. Para o smoke sintético, exigir texto esperado, incluindo acentos e pontuação, após remover apenas espaços nas extremidades. Rodar três vezes por frase e registrar ambiente, modelo, execução fria/quente e tempos; o smoke de uma rodada já registrado em [#1](https://github.com/mruniverse/dictation-mac/issues/1) é exploratório. Áudio sintético não entra no Git, nas issues ou na demo. Antes de fechar a fase, validar roteiro equivalente com fala humana voluntária e registrar erros por categoria sem publicar áudio pessoal.
- Avaliar integridade, licença, tamanho e desempenho frio/quente do modelo antes de empacotar. Resultados x86_64 valem apenas para a máquina medida; Apple Silicon não testado não é compatibilidade demonstrada. Validar em hardware Apple para distribuição e demo pública.
- Antes da fase 1: definir seleção de idioma e testar termos técnicos misturados; verificar Input Monitoring, Secure Input, suspensão, mudança de microfone, conflitos de atalho e duração mínima/máxima. Terminais, REPLs e TUIs ficam em prévia/cópia por padrão: um alvo cujo modo de entrada não é verificável não recebe teclas sintéticas nem colagem automática.

## Primeira execução e gates

Fase 0, arquivos permitidos: documentação, configuração de build/CI, `Probes/` e testes associados. Primeiro medir reconhecimento on-device de uma frase sintética pt-BR, separando capacidade reportada de reconhecimento confirmado. Sem capturar áudio pessoal, alterar permissões por automação ou fazer chamadas pagas. A fase 1 depende de revisão técnica e de produto deste plano e das provas de captura/foco; nenhum resultado de fixture equivale a ditado global. Checklist de teste manual: permitir/negar permissões, gravar/soltar/cancelar, trocar foco durante o processamento, campo de senha, Terminal sem execução, sessão sobreposta, português/inglês e queda do motor. Registrar latências de soltar até inserir por rota e máquina antes de publicar metas. Portfólio: PRs pequenos, ADRs para escolhas de privacidade, resultados comparáveis, vídeo real de uso e instruções reproduzíveis em inglês. GitHub Issues acompanha fases e evidências; sem segredos ou áudios privados no GitHub. Repo público não constitui licença de redistribuição.
