# CloudWeaver — Convenções de Desenvolvimento

CloudWeaver é distribuído como um conjunto de **skills** (sob `skills/`, cada uma nomeada `cloud-weaver-<x>`), instalado em projetos dos usuários via `npx skills` — não é uma aplicação. Ao alterar o conteúdo de skills, apresentar as mudanças primeiro. Ao fazer commit, bumpar a versão em `.claude-plugin/plugin.json` (mantido exclusivamente como fonte da verdade para o update gate e para a descoberta via `npx skills`).

Enquanto estivermos na geração 0.x.y: incrementar o minor (x+1) para mudanças significativas; incrementar o patch (y+1) para pequenas correções.

Após bumpar a versão em `plugin.json`, rodar `scripts/stamp-version.sh` para propagar a marcação `CLOUD_WEAVER_VERSION` no `skills/cloud-weaver-pre-flight-check/SKILL.md`.

## Projetos relacionados

CloudWeaver existe dentro de um ecossistema de ferramentas Locaweb. Ao trabalhar em qualquer skill, considere como ela se relaciona com estes projetos:

- **Cofounder** — `~/workspaces/workspace-locaweb/repositories/cofounder/`
  Plugin de skills para desenvolvimento de aplicações, criação de infraestrutura e deploy no Locaweb Cloud (Apache CloudStack). Tem estrutura análoga ao CloudWeaver (`cofounder-<x>` skills, mesmo mecanismo de distribuição via `npx skills`). É o projeto de referência para padrões de skills e arquitetura geral.

- **locaweb-cloud-provision** — `~/workspaces/workspace-locaweb/repositories/locaweb-cloud-provision/`
  Ferramenta especialista em provisionamento de VMs no Locaweb Cloud (Apache CloudStack). Exposta como GitHub Actions reusable workflow (`locaweb/locaweb-cloud-provision/.github/workflows/provision.yml@v1`). O CloudWeaver v2 consome este workflow nos templates de `deploy.yml` gerados por `cloud-weaver-repo-setup`. Consultar sua documentação antes de alterar qualquer lógica de provisionamento.

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
