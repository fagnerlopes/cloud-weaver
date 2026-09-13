# CloudWeaver

Um plugin de IA que transforma agentes de código em engenheiros de infraestrutura. Instala aplicações prontas na Locaweb Cloud por conversa interativa.

## Receitas

| Receita | Descrição | Status |
|---------|-----------|--------|
| Hermes Agent (Docker + terminal web) | Agente Telegram + LLM | ✅ disponível |
| Hermes Agent (host direto) | Agente Telegram + LLM instalado no host (sem Docker) | ✅ disponível |
| WAHA | Agente WhatsApp (WAHA) + PostgreSQL | ✅ disponível |
| Coolify | PaaS self-hosted | 🔜 em breve |
| Jitsi Meet | Servidor de videoconferência | 🔜 em breve |

## Instalação

O CloudWeaver se instala **dentro da pasta de um projeto**, não globalmente.

```bash
mkdir meu-hermes && cd meu-hermes
curl -fsSL https://cloudweaver.fagnerlopes.dev/install.sh | bash
```

O instalador copia as skills para esta pasta (`.agents/skills`, `.claude/skills`,
`.hermes/skills`, …) e grava um bloco em `AGENTS.md` e `CLAUDE.md` instruindo o
agente a carregar a skill `cloud-weaver-playbook` na primeira ação da sessão.

Depois é só abrir o agente **nessa mesma pasta** e pedir em português:

> Crie uma instância do Hermes Agent no Locaweb Cloud

O comando `/start-cloud` também funciona, para quem prefere o menu de receitas.

### Instalação manual

```bash
npx skills add fagnerlopes/cloud-weaver \
  --agent universal claude-code codex opencode hermes-agent --skill '*' -y
```

Nesse caso, crie você mesmo o `AGENTS.md` apontando para o playbook — o CLI
`skills` só copia as skills, não escreve arquivos de bootstrap.

> **Nomenclatura:** a skill de entrada chama-se `start-cloud` (sem prefixo)
> justamente para que `/start-cloud` seja um comando real. As demais usam o
> prefixo `cloud-weaver-`.

## Licença

[FSL-1.1-ALv2](LICENSE) — Funcional Source License, converte para Apache 2.0 após dois anos.