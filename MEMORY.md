# MEMORY — CloudWeaver

Estado do projeto salvo para a próxima sessão. Leia este arquivo antes de qualquer trabalho.

## Contexto do Projeto

**CloudWeaver** é um plugin de IA que instala aplicações prontas (Hermes Agent, Coolify, Jitsi Meet, etc.) na Locaweb Cloud por meio de conversa interativa. Ele é inspirado no **Cofounder** da Locaweb (repositório: `/home/fagner.lopes@king.local/workspaces/workspace-locaweb/repositories/cofounder`), mas com escopo diferente:

| | Cofounder | CloudWeaver |
|---|---|---|
| Escopo | Cria apps Go+React do zero | Instala apps prontos |
| Instalação | Por projeto | **Global** |
| Entry point | Sessão do agente | `/start-cloud` |
| Deploy | Kamal + GitHub Actions | **Docker direto na VM** |
| Receitas | N/A | **Fixas no plugin** |

## Decisões Já Tomadas (não re-abrir sem motivo forte)

1. **Mecanismo de instalação:** `npx skills` (mesmo padrão do Cofounder), com `--agent universal`.
2. **Modelo de receitas:** fixas no plugin (sem registry dinâmico na v1).
3. **Interatividade:** máxima — uma pergunta por vez, validada antes de avançar, com indicador de progresso.
4. **Modelo de deploy:** Docker direto na VM via SSH (SEM Kamal, SEM GitHub Actions para deploy).
5. **Compatibilidade multi-agente:** Claude Code, Codex, OpenCode, Cursor, agy/Antigravity.
6. **Segurança:** herdar integralmente os padrões do Cofounder (secrets nunca na conversa, guard de arquivos sensíveis, SSH Ed25519, regex `[a-z0-9_]`, DEV_MODE).

## Artefatos Criados

- `docs/PRD.md` — PRD completo (v0.1.0 draft) com arquitetura, fluxo, segurança, roadmap e critérios de aceite.
- `README.md` — placeholder (# cloud-weaver), precisa ser preenchido.

## Roadmap (próximos passos)

| Fase | Status | Conteúdo |
|---|---|---|
| M0 — Scaffold | **PRÓXIMO** | Estrutura do repo, `.claude-plugin/plugin.json`, `CLAUDE.md`, `scripts/stamp-version.sh`, estrutura `skills/` e `tests/` |
| M1 — Playbook + Pre-flight | Pendente | Persona, fluxo `/start-cloud`, validação de ambiente e versão |
| M2 — VM Setup | Pendente | Provisionamento Locaweb Cloud idempotente |
| M3 — Hermes Agent | Pendente | Primeira receita completa + testes |
| M4 — Monitor | Pendente | Health check, timeout, retry, rollback |
| M5 — Coolify + Jitsi | Pendente | Receitas adicionais |
| M6 — Testes E2E | Pendente | Suite multi-harness |

## Estrutura-Alvo do Repositório

```
cloud-weaver/
├── .claude-plugin/plugin.json          # name, description, version (fonte da verdade)
├── CLAUDE.md                           # Convenções de dev do repo
├── README.md                           # Preencher
├── docs/PRD.md                         # OK
├── scripts/stamp-version.sh            # Propaga versão → pre-flight marker
├── skills/
│   ├── cloud-weaver-playbook/         # Persona + fluxo + /start-cloud
│   ├── cloud-weaver-computer-setup/   # Verifica ferramentas (gh, ssh, jq)
│   ├── cloud-weaver-pre-flight-check/ # Validação pré-sessão + versão
│   ├── cloud-weaver-vm-setup/         # VM + rede + firewall via Locaweb Cloud
│   ├── cloud-weaver-monitor/          # Health check + polling + rollback
│   ├── cloud-weaver-hermes/           # Receita Hermes Agent
│   ├── cloud-weaver-coolify/          # Receita Coolify
│   ├── cloud-weaver-jitsi/            # Receita Jitsi Meet
│   └── cloud-weaver-ssh-key-rotation/ # Rotação de chaves SSH
└── tests/
    ├── lib/assert.sh                   # Asserts compartilhados (copiar padrão do Cofounder)
    ├── scripts/test-scripts.sh         # Testes offline (preflight + scripts de receita)
    └── agent/                          # test-agent.sh, run-agent.sh, judge.sh
```

## Padrões do Cofounder a Replicar (referência)

Ao implementar, consultar sempre:

- **Playbook:** `cofounder-playbook/SKILL.md` — persona, sessão start, skill reference, regras (tag obrigatória `[Cofounder]` → aqui `[CloudWeaver]`, detectar idioma, docs em PT-BR).
- **Pre-flight:** `cofounder-pre-flight-check/SKILL.md` + `scripts/preflight.sh` — guard de arquivos sensíveis (`.env`, `.npmrc`, `.netrc`, `.pem`, `.key`, `credentials*.json`, `secrets.yaml`, chaves), git sync, check de ferramentas, `NEEDS_*` flags, marker de versão via HTML comment.
- **Security:** secrets gerados com `python -c "import secrets; print(secrets.token_urlsafe(32))"`; secrets do usuário via editor com placeholders `REPLACE_WITH_`; nunca na conversa.
- **VM setup:** aplicar o mesmo fluxo de provisionamento da `locaweb-cloud-provision` (env_name, zone ZP01/ZP02, web_plan, disk 20GB em `/data/`), hero URLs via `nip.io`.
- **Testes:** pirâmide determinista primeiro (asserts de filesystem/exit codes), depois LLM-as-judge; `lib/assert.sh` com `expect`/`refute`/`file_contains`/`count_eq`/`summary`.

## Receitas Planejadas (v1)

| Receita | App | Dependências | Config interativa |
|---|---|---|---|
| Hermes Agent | WAHA + PostgreSQL | 1 VM + Postgres | Porta API, domínio/URL, volume de dados |
| Coolify | PaaS self-hosted | 1 VM + PostgreSQL | Domínio painel, porta, email admin |
| Jitsi Meet | Videoconferência | 1 VM (all-in-one) | Domínio, porta, senha SRTP |

## Fluxo-Alvo do Usuário

```
Instalar plugin globalmente (npx skills add)
  → chamar /start-cloud em qualquer sessão
  → LLM lista receitas
  → selecionar receita(s)
  → LLM coleta infos (1 pergunta por vez)
  → provisiona VM + rede + firewall (Locaweb Cloud API)
  → SSH + docker compose up
  → monitora health check até 200
  → reporta URL + credenciais + próximos passos
```

## Próxima Sessão: Começar por M0

1. Inicializar estrutura do repo (pasta `skills/`, `tests/`, `scripts/`, `.claude-plugin/`).
2. Criar `.claude-plugin/plugin.json` com `name: "cloud-weaver"` e versão inicial `0.1.0`.
3. Criar `CLAUDE.md` (convenções: bump de versão no plugin.json, rodar stamp-version.sh, commit de settings).
4. Criar `scripts/stamp-version.sh` (copiar padrão do Cofounder, ajustando nomes).
5. Preencher `README.md`.
6. Depois: M1 (playbook + pre-flight).

## Notas

- Toda saída ao usuário em **PT-BR**; comentários de código em inglês.
- Toda mensagem do agente começa com a tag **`[CloudWeaver]`**.
- Perguntar antes de novas decisões de escopo; não assumir mudanças de M0-M6.
- Fonte de referência do Cofounder pode evoluir — verificar versão atual antes de copiar padrões.