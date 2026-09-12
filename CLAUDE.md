# CloudWeaver — Convenções de Desenvolvimento

## Objetivo primário

Disponibilizar uma forma prática e rápida de provisionar uma VM com Hermes Agent e acesso por terminal web no Workshop do TDC São Paulo.

## Objetivo secundário

Evoluir o plugin para provisionar outras receitas de aplicações como Coolify, Portainer, Jitsi Meet, OpenClaw, N8N, etc.

CloudWeaver é distribuído como um conjunto de **skills** (sob `skills/`, cada uma nomeada `cloud-weaver-<x>`), instalado em projetos dos usuários via `npx skills` — não é uma aplicação. Ao alterar o conteúdo de skills, apresentar as mudanças primeiro. Ao fazer commit, bumpar a versão em `.claude-plugin/plugin.json` (mantido exclusivamente como fonte da verdade para o update gate e para a descoberta via `npx skills`).

Enquanto estivermos na geração 0.x.y: incrementar o minor (x+1) para mudanças significativas; incrementar o patch (y+1) para pequenas correções.

Após bumpar a versão em `plugin.json`, rodar `scripts/stamp-version.sh` para propagar a marcação `CLOUD_WEAVER_VERSION` no `skills/cloud-weaver-pre-flight-check/SKILL.md`.

## Projetos relacionados

CloudWeaver existe dentro de um ecossistema de ferramentas Locaweb. Ao trabalhar em qualquer skill, considere como ela se relaciona com estes projetos:

- **Cofounder** — `~/workspaces/workspace-locaweb/repositories/cofounder/`
  Plugin de skills para desenvolvimento de aplicações, criação de infraestrutura e deploy no Locaweb Cloud (Apache CloudStack). Tem estrutura análoga ao CloudWeaver (`cofounder-<x>` skills, mesmo mecanismo de distribuição via `npx skills`). É o projeto de referência para padrões de skills e arquitetura geral.

- **locaweb-cloud-provision** — `~/workspaces/workspace-locaweb/repositories/locaweb-cloud-provision/`
  Ferramenta especialista em provisionamento de VMs no Locaweb Cloud (Apache CloudStack). Exposta como GitHub Actions reusable workflow (`locaweb/locaweb-cloud-provision/.github/workflows/provision.yml@v1`). O CloudWeaver v2 consome este workflow nos templates de `deploy.yml` gerados por `cloud-weaver-repo-setup`. Consultar sua documentação antes de alterar qualquer lógica de provisionamento.

- **cloud-weaver-web** — `~/projects/cloud-weaver-web/`
  Landing page do CloudWeaver e **porta de entrada real dos participantes**. Ver `docs/PRD.md`, `docs/ADR.md` e `docs/TASKS.md`.

## Como os participantes instalam

Este é o caminho que o participante do workshop percorre. Qualquer mudança nas skills precisa funcionar por aqui.

1. O participante cria uma pasta de projeto e entra nela — `install.sh` **aborta se `$PWD` for `$HOME`**. A instalação é sempre por projeto, nunca global.
2. Roda `curl -fsSL <domínio>/install.sh | bash`.
3. O script (em `cloud-weaver-web/backend/internal/server/install.sh`, servido via `//go:embed` em `/install.sh` — ADR-0005) executa:
   `npx -y skills add fagnerlopes/cloud-weaver --agent universal claude-code codex opencode hermes-agent --skill '*' -y`
   Se já existir `skills-lock.json`, roda `npx -y skills update`.
4. Escreve um bloco delimitado por `<!-- cloud-weaver:begin/end -->` no `AGENTS.md` e no `CLAUDE.md` da pasta do participante. O bloco do `AGENTS.md` manda o agente invocar `cloud-weaver-playbook` como primeira ação da sessão.
5. O participante abre o agente naquela pasta e pede a instalação (ou digita `/start-cloud`).

**Consequências ao alterar skills:**

- O participante roda em **projeto próprio, com config de agente própria** — nada do `.claude/` deste repo alcança ele. Nunca assumir permissões, allowlists ou variáveis que só existem aqui.
- **Permissões vêm do instalador, não da skill.** O `cloud-weaver-repo-setup` roda `gh secret set`, que em auto mode é barrado pelo classificador (Secret-Store Writes) e trava o provisionamento. O Cofounder resolve isso fixando `.claude/settings.json` no projeto do participante durante a instalação (`cofounder-computer-setup/scripts/install.sh:372-397`, com `permissions.allow: ["Bash", "Read", "WebFetch"]`). O `install.sh` do CloudWeaver **ainda não faz isso** — é o que precisa ser espelhado.
- Mudanças no nome do plugin, na lista de agentes, no fluxo de bootstrap ou nas permissões fixadas exigem atualizar `install.sh` no `cloud-weaver-web` e refazer o build/deploy da landing.

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
