# Cloud Recipes

Um plugin de IA que transforma agentes de código em engenheiros de infraestrutura. Instala aplicações prontas na Locaweb Cloud por conversa interativa.

## Receitas (v1)

| Receita | Descrição |
|---------|-----------|
| [Hermes Agent](skills/cloud-recipes-hermes/) | Agente WhatsApp (WAHA) + PostgreSQL |
| [Coolify](skills/cloud-recipes-coolify/) | PaaS self-hosted |
| [Jitsi Meet](skills/cloud-recipes-jitsi/) | Servidor de videoconferência |

## Instalação

```bash
npx skills add fagnerlopes/cloud-recipes --agent universal claude-code codex opencode -y
```

Após instalar, inicie com `/start-cloud` em qualquer sessão de agente suportado.

## Licença

[FSL-1.1-ALv2](LICENSE) — Funcional Source License, converte para Apache 2.0 após dois anos.