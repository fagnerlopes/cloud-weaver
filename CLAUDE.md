# CloudWeaver — Convenções de Desenvolvimento

CloudWeaver é distribuído como um conjunto de **skills** (sob `skills/`, cada uma nomeada `cloud-weaver-<x>`), instalado em projetos dos usuários via `npx skills` — não é uma aplicação. Ao alterar o conteúdo de skills, apresentar as mudanças primeiro. Ao fazer commit, bumpar a versão em `.claude-plugin/plugin.json` (mantido exclusivamente como fonte da verdade para o update gate e para a descoberta via `npx skills`).

Enquanto estivermos na geração 0.x.y: incrementar o minor (x+1) para mudanças significativas; incrementar o patch (y+1) para pequenas correções.

Após bumpar a versão em `plugin.json`, rodar `scripts/stamp-version.sh` para propagar a marcação `CLOUD_WEAVER_VERSION` no `skills/cloud-weaver-pre-flight-check/SKILL.md`.

## Convenções de código e saída

- Toda saída ao usuário em **português brasileiro (PT-BR)**.
- Toda mensagem do agente começa com a tag **`[CloudWeaver]`**.
- Comentários de código em **inglês**.
- Nomes de VM/receita validados contra regex `[a-z0-9_]` (evita injeção de flags).

## Segurança

- **Nunca aceitar ou exibir valores de secrets na conversa.**
- Secrets gerados com `python -c "import secrets; print(secrets.token_urlsafe(32))"`.
- Chaves SSH apenas Ed25519 (`ssh-keygen -t ed25519`), `chmod 600`.
- Qualquer endpoint sensível de teste só existe quando `DEV_MODE` está ativo.