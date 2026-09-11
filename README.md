# CloudWeaver

Um plugin de IA que transforma agentes de código em engenheiros de infraestrutura. Instala aplicações prontas na Locaweb Cloud por conversa interativa.

## Receitas

| Receita | Descrição | Status |
|---------|-----------|--------|
| [Hermes Agent](skills/cloud-weaver-hermes/) | Agente WhatsApp (WAHA) + PostgreSQL | ✅ disponível |
| Coolify | PaaS self-hosted | 🔜 em breve |
| Jitsi Meet | Servidor de videoconferência | 🔜 em breve |

## Instalação

```bash
npx skills add fagnerlopes/cloud-weaver --agent universal claude-code codex opencode -y
```

Após instalar, **abra uma nova sessão** do agente e digite `/start-cloud`.

> O instalador copia cada pasta de `skills/` para o diretório de skills do agente.
> A skill de entrada chama-se `start-cloud` (sem prefixo) justamente para que
> `/start-cloud` seja um comando real — as demais usam o prefixo `cloud-weaver-`.

## Licença

[FSL-1.1-ALv2](LICENSE) — Funcional Source License, converte para Apache 2.0 após dois anos.