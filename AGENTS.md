# AGENTS.md

Cloud Recipes é um plugin de IA distribuído como **skills** (não é uma aplicação): provisiona infraestrutura na Locaweb Cloud e instala aplicações prontas (Hermes Agent, Coolify, Jitsi...) via conversa interativa (`/start-cloud`).

Este repo está em **estágio pré-scaffold (M0)** — ainda não há `skills/`, `scripts/`, `tests/` nem `.claude-plugin/`. Antes de qualquer trabalho, leia:

- `MEMORY.md` — handoff da sessão anterior: decisões fechadas, roadmap M0–M6, estrutura-alvo, padrões a replicar
- `docs/PRD.md` — especificação completa (arquitetura, fluxo, segurança, critérios de aceite)

## Fatos que um agente provavelmente erraria

- **Padrões não estão neste repo.** As skills, preflight e testes do Cofounder (modelo a copiar) ficam em `/home/fagner.lopes@king.local/workspaces/workspace-locaweb/repositories/cofounder`. Verificar a versão atual lá antes de copiar qualquer padrão.
- **Convenções obrigatórias:** saída ao usuário sempre em PT-BR; comentários de código em inglês; toda mensagem do agente começa com `[Cloud Recipes]`.
- **Decisões fechadas (não re-abrir sem motivo forte):** instalação via `npx skills` (`--agent universal`); receitas fixas no plugin; coleta de dados 1 pergunta por vez; deploy por **Docker direto na VM via SSH** (sem Kamal, sem GitHub Actions de deploy); segurança herdada integralmente do Cofounder (secrets nunca na conversa, guard de arquivos sensíveis, SSH Ed25519, nomes validados com `[a-z0-9_]`).
- **Versionamento:** a versão vive em `.claude-plugin/plugin.json` (fonte da verdade) e é propagada via `scripts/stamp-version.sh` — ambos ainda a criar em M0.
- **Remote:** `git@github.com:fagnerlopes/cloud-recipes.git` (não `locaweb/cloud-recipes`).

## Comandos

Não há scripts nem testes neste repo ainda. Quando existirem, sigam o padrão do Cofounder (`bash tests/scripts/test-scripts.sh`, etc.). Presumir o contrário é arriscado neste estágio.