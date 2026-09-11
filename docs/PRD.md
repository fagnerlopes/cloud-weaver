# Cloud Recipes — Product Requirements Document

Versão: 0.1.0 (draft)

---

## 1. Visão Geral

**Cloud Recipes** é um plugin de IA que transforma agentes de código em engenheiros de infraestrutura. Ele permite que usuários não-técnicos instalem e configurem aplicações prontas (Hermes Agent, Coolify, Jitsi Meet, etc.) na Locaweb Cloud por meio de uma conversa interativa.

Diferente do Cofounder — que cria aplicações Go+React do zero — o Cloud Recipes **instala aplicações prontas**: provisiona a VM, configura a rede, instala via Docker e monitora até a aplicação estar operacional.

## 2. Objetivo

- **Primário:** Permitir que qualquer pessoa, independentemente do nível técnico, instale e execute aplicações complexas na Locaweb Cloud através de uma conversa com IA.
- **Secundário:** Estabelecer um padrão de "receitas" reproduzíveis para implantação de infraestrutura, com qualidade de engenharia e segurança de produção.

## 3. Público-alvo

- Usuários não-técnicos que querem rodar suas próprias aplicações (agentes de WhatsApp, videoconferência, PaaS self-hosted).
- Desenvolvedores que querem provisionar infraestrutura em minutos, sem repetir trabalho manual.
- Equipes que precisam de ambientes de staging/preview reproduzíveis.

## 4. Funcionalidades Principais

### 4.1 Comando `/start-cloud`

- Entry point universal para todos os agentes suportados (Claude Code, Codex, Cursor, OpenCode, entre outros).
- Exibe a lista de receitas disponíveis com título e descrição em linguagem simples.
- Permite seleção de uma ou múltiplas receitas.

### 4.2 Sistema de Receitas

Cada receita é um módulo autônomo composto por:

| Componente | Descrição |
|---|---|
| **Pré-requisitos** | O que a receita exige (PostgreSQL, portas, memória mínima, domínio) |
| **Coleta interativa** | Perguntas específicas da receita, uma por vez |
| **Provisionamento** | Criação de VM + rede + firewall na Locaweb Cloud |
| **Instalação** | Deploy via Docker (compose ou container único) |
| **Health check** | Verificação de disponibilidade pós-instalação |
| **Relatório** | URL, credenciais e próximos passos apresentados ao usuário |

### 4.3 Receitas Incluídas (v1)

| Receita | Aplicação | Dependências | Config Interativa |
|---|---|---|---|
| **Hermes Agent** | Agente WhatsApp (WAHA) + PostgreSQL | 1 VM + Postgres | Porta da API, domínio/URL, volume de dados |
| **Coolify** | PaaS self-hosted | 1 VM + PostgreSQL | Domínio do painel, porta, email do admin |
| **Jitsi Meet** | Servidor de videoconferência | 1 VM (all-in-one) | Domínio, porta, senha SRTP |

Novas receitas são adicionadas nas próximas versões seguindo o mesmo modelo.

### 4.4 Provisionamento na Locaweb Cloud

- Criação de VM via API CloudStack.
- Configuração de rede isolada com NAT estático.
- Regras de firewall: porta 22 (SSH) sempre aberta + portas da aplicação.
- Criação/gereção de chave SSH Ed25519 dedicada.
- Garantia de idempotência: re-executar o fluxo não duplica recursos.

### 4.5 Monitoramento de Startup

- Polling de health check até retornar HTTP 200.
- Timeout configurável por receita (padrão: 10 minutos).
- Retry automático com backoff.
- Falha → diagnóstico via SSH + logs do container + rollback dos recursos criados.

### 4.6 Relatório de Conclusão

Ao final, o agente apresenta ao usuário:

- URL(s) de acesso da aplicação.
- Credenciais geradas (com instrução de alteração imediata).
- Instruções de uso e próximos passos.
- Comandos de operação (ver logs, reiniciar, parar).

## 5. Arquitetura

### 5.1 Estrutura do Plugin

```
cloud-recipes/
├── .claude-plugin/
│   └── plugin.json              # name, description, version (fonte da verdade)
├── CLAUDE.md                    # Convenções de desenvolvimento do repo
├── README.md
├── scripts/
│   └── stamp-version.sh         # Propaga versão para o marker do pre-flight
├── skills/
│   ├── cloud-recipes-playbook/  # Persona, fluxo principal, /start-cloud
│   ├── cloud-recipes-computer-setup/  # Verifica ferramentas (gh, ssh, jq)
│   ├── cloud-recipes-pre-flight-check/ # Validação pré-sessão + versão
│   ├── cloud-recipes-vm-setup/  # Provisiona VM + rede + firewall
│   ├── cloud-recipes-monitor/   # Health check + polling + rollback
│   ├── cloud-recipes-hermes/    # Receita: Hermes Agent
│   ├── cloud-recipes-coolify/   # Receita: Coolify
│   ├── cloud-recipes-jitsi/     # Receita: Jitsi Meet
│   └── cloud-recipes-ssh-key-rotation/ # Rotação de chaves SSH
└── tests/
    ├── lib/
    │   └── assert.sh            # Helpers de assert compartilhados
    ├── scripts/
    │   └── test-scripts.sh      # Testes offline (preflight, scripts de receita)
    └── agent/
        ├── test-agent.sh        # Driver de cenários
        ├── run-agent.sh         # Adapter multi-harness
        └── judge.sh             # LLM-as-judge
```

### 5.2 Fluxo Técnico

```
/start-cloud
    ↓
[playbook] Detecta idioma, carrega persona (tag [Cloud Recipes])
    ↓
[pre-flight-check] Valida: gh auth, chave SSH, API keys, pastas sensíveis
    ↓
[playbook] Exibe lista de receitas disponíveis
    ↓
[playbook] Usuário seleciona → invoca a skill da receita
    ↓
[receita] Coleta informações interativamente (uma pergunta por vez)
    ↓
[vm-setup] Cria VM + rede + firewall via API Locaweb Cloud
    ↓
[receita] SSH + docker compose up / docker run
    ↓
[monitor] Polling do health check até HTTP 200 (ou timeout)
    ↓
[playbook] Exibe URL + credenciais + próximos passos
```

### 5.3 Mecanismo de Instalação

- Distribuição via `npx skills` (mesmo mecanismo do Cofounder):
  ```sh
  npx skills add <org>/cloud-recipes --agent universal claude-code cursor codex opencode -y
  ```
- Instalação **global**, disponível em todas as sessões dos agentes suportados.
- Versão mantida em `.claude-plugin/plugin.json` e propagada via `scripts/stamp-version.sh`.

## 6. Padrões de Segurança (herdados do Cofounder)

### 6.1 Secrets

- **Nunca aceitar ou exibir valores de secrets na conversa.**
- Secret gerado automaticamente: `python -c "import secrets; print(secrets.token_urlsafe(32))"`.
- Secret fornecido pelo usuário: gravar em arquivo `.env` com placeholder `REPLACE_WITH_`, abrir no editor do usuário e, após preenchimento, validar que não há placeholders restantes.
- Valores de secret nunca devem aparecer em logs, outputs ou commits.

### 6.2 Guard de Arquivos Sensíveis

- Pre-flight detecta e bloqueia arquivos sensíveis não rastreados/alterados: `.env`, `.npmrc`, `.netrc`, `.pem`, `.key`, `credentials*.json`, `secrets.yaml`, chaves SSH.
- Templates (`.example`, `.sample`) e remoções são ignorados.

### 6.3 Chaves SSH

- Apenas Ed25519 (`ssh-keygen -t ed25519`).
- `chmod 600` obrigatório.
- Nomenclatura: `~/.ssh/<recipe-name>` (preview) e `~/.ssh/<recipe-name>-<env>` (demais ambientes).
- Chaves reutilizadas quando já existem (idempotência).
- Rotação disponível via `cloud-recipes-ssh-key-rotation`.

### 6.4 Validação de Input

- Regex estrita para nomes de VM/receita: `[a-z0-9_]` (evita injection de flags).
- Nunca passar input do usuário direto para comandos sem validação.

### 6.5 API Keys da Locaweb Cloud

- Coletadas uma única vez pelo usuário e armazenadas em local seguro (GitHub Secrets ou variáveis de ambiente locais).
- Nunca persistidas no repositório nem exibidas na conversa.
- Após a coleta, o pre-flight valida que estão presentes antes de qualquer provisionamento.

### 6.6 Flag de Modo de Desenvolvimento

- Qualquer endpoint/caminho sensível de teste só existe quando `DEV_MODE` está ativo (mesmo padrão do Cofounder).

### 6.7 Referência: fonte dos padrões

Os padrões de segurança e arquitetura deste plugin são derivados do projeto **Cofounder** da Locaweb. Para consulta dos padrões de referência (skills, preflight, testes, mecanismos de distribuição), acessar o repositório local:

```
/home/fagner.lopes@king.local/workspaces/workspace-locaweb/repositories/cofounder
```

> **Nota:** verificar a versão atual do Cofounder antes de copiar qualquer padrão — a fonte pode evoluir.

## 7. Compatibilidade Multi-Agente

O plugin deve operar em:

| Agente | Mecanismo |
|---|---|
| **Claude Code** | `.claude/skills/` |
| **Codex** | `.agents/skills/` |
| **OpenCode** | `.opencode/skills/` |
| **Cursor** | `.cursor/skills/` |
| **agy/Antigravity (Gemini)** | `.hermes/skills/` |

- Instalação via `npx skills` com `--agent universal`.
- Harness de teste (`run-agent.sh`) normaliza as CLIs dos agentes para o mesmo conjunto de cenários.

## 8. Requisitos Não-Funcionais

| Requisito | Especificação |
|---|---|
| **Idempotência** | Todas as operações seguras para re-execução; nada de recursos duplicados |
| **Tempo de resposta** | Provisionamento até 5 min; health check até 10 min (padrão) |
| **Rollback** | Falha na instalação → limpeza dos recursos provisionados |
| **Logging** | Todas as ações do agente logadas (para debugging e auditoria) |
| **Idioma** | Toda saída ao usuário em português brasileiro; comentários de código em inglês |
| **Tag obrigatória** | Toda mensagem do agente começa com `[Cloud Recipes]` |
| **Determinismo** | Scripts com asserts sobre filesystem/exit codes, não sobre texto do agente |
| **Detecção de idioma** | Responta no idioma do usuário |

## 9. Fora do Escopo (v1)

- Criação de aplicações web do zero (escopo do Cofounder).
- Gerenciamento de DNS (registros apontados manualmente pelo usuário).
- Configuração avançada de SSL/TLS além do padrão de cada receita.
- Backup/Restore automatizado (planejado para versões futuras).
- Multi-região / alta disponibilidade (planejado para versões futuras).
- Marketplace de receitas dinâmico (receitas fixas na v1).

## 10. Modelo de Interatividade

### 10.1 Coleta de Informações

- **Uma pergunta por vez**, sempre em linguagem simples.
- Cada resposta validada antes de avançar (formato, range, existência).
- Progresso mostrado ao usuário: `Informação 2 de 5`.

### 10.2 Confirmação de Plano

- Antes de provisionar, o agente apresenta um resumo do plano (VM, plano, portas, aplicação) e pede confirmação explícita.
- Após confirmação, nada é interrompido sem aviso.

### 10.3 Durante o Provisionamento

- Status em linguagem simples: "Estou criando sua máquina virtual, isso leva ~2 minutos...".
- Sem jargão técnico sem explicação.

### 10.4 Conclusão

- Celebração + resumo executável.
- O usuário é orientado a iniciar uma nova sessão para o próximo trabalho (padrão Cofounder: uma unidade de trabalho por sessão).

## 11. Critérios de Aceite

- [ ] `/start-cloud` funciona em Claude Code, Codex, Cursor e OpenCode.
- [ ] Lista de receitas exibida corretamente, com seleção múltipla.
- [ ] Coleta interativa respeita o modelo "uma pergunta por vez".
- [ ] Nome de VM/ambiente validado contra regex `[a-z0-9_]`.
- [ ] VM provisionada na Locaweb Cloud com rede e firewall corretos.
- [ ] Aplicação instalada via Docker e acessível na porta esperada.
- [ ] Health check monitorado até sucesso (ou rollback em falha).
- [ ] URL, credenciais e próximos passos exibidos ao final.
- [ ] Nenhum secret aparece na conversa, logs ou commits.
- [ ] Pre-flight detecta arquivos sensíveis e bloqueia o fluxo.
- [ ] Scripts idempotentes (re-execução sem duplicação).
- [ ] Toda saída para o usuário em PT-BR, com tag `[Cloud Recipes]`.
- [ ] Suite de testes off-line cobre preflight + scripts de receita (asserts de filesystem).

## 12. Marcos / Roadmap

| Fase | Conteúdo | SAÍDA |
|---|---|---|
| **M0 — Scaffold** | Estrutura do repo, plugin.json, CLAUDE.md, stamp-version.sh | Repo pronto para dev |
| **M1 — Playbook + Pre-flight** | Persona, fluxo `/start-cloud`, validação de ambiente e versão | UX principal funcional |
| **M2 — VM Setup** | Provisionamento Locaweb Cloud idempotente | Infra funcional |
| **M3 — Hermes Agent** | Primeira receita completa + testes | Receita de referência |
| **M4 — Monitor** | Health check, timeout, retry, rollback | Resiliência |
| **M5 — Coolify + Jitsi** | Receitas adicionais | Catálogo v1 |
| **M6 — Testes E2E** | Suite de agentes multi-harness | Qualidade de produção |

## 13. Métricas de Sucesso

- Tempo "zero to URL" < 15 minutos para qualquer receita.
- Taxa de sucesso de instalação > 90% no primeiro tentativa.
- Sem incidentes de vazamento de secrets em produção.
- Re-execução do fluxo nunca duplica recursos (idempotência verificada por teste).
- Usuário consegue operar a aplicação (ver logs, reiniciar) seguindo apenas o relatório final.