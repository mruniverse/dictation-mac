# Candidato para transcrição em nuvem

Primeira integração a validar: `gpt-transcribe` em `POST https://api.openai.com/v1/audio/transcriptions`, via API key própria do usuário. [Guia oficial de transcrição de arquivos](https://developers.openai.com/api/docs/guides/speech-to-text). Não usar os modelos de transcrição em desligamento como default novo; [cronograma oficial](https://developers.openai.com/api/docs/deprecations).

A primeira versão envia um clipe por ação explícita, preferencialmente depois de soltar o atalho; não faz streaming. A requisição usa multipart com `model` e `file`; a resposta fornece `text` e pode informar os idiomas detectados. O adaptador tem prazo, cancelamento, erro de autenticação e limite do provedor; nunca faz fallback, reenvio ou troca de modelo silenciosos. Chave via Keychain, sem logs; apresentar destino e custo separado do plano ChatGPT. As amostras pessoais anteriores são apenas para o teste local. Teste real inicial com fixture aprovada e credencial de desenvolvimento; contratos, parser e falhas podem ser testados com transporte injetável sem custo.

Status: contrato documentado; nenhuma requisição paga executada e nenhum resultado de qualidade ou latência em nuvem medido.
