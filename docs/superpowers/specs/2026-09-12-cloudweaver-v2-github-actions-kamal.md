# CloudWeaver v2 — GitHub Actions + Kamal Deployment Model

**Data:** 2026-09-12  
**Status:** Aprovado para implementação  
**Versão alvo:** 1.0.0

---

## 1. Contexto e motivação

O modelo v1 executa scripts Python diretamente no terminal do usuário para provisionar VMs e fazer deploy via docker-compose + SSH. Isso traz limitações:

- **Fragilidade de ambiente**: depende de credenciais exportadas no terminal local, Python 3, scp/ssh acessíveis.
- **Opacidade**: output verboso; difícil de acompanhar e retomar.
- **Workshop problem**: cada participante precisa buildar a imagem Docker localmente no dia — lento e sujeito a falhas de rede.
- **Manutenção**: a lógica de provisionamento duplica o que o `locaweb-cloud-provision` já faz.

O modelo v2 resolve todos esses pontos: o agente gera arquivos de configuração e cria um repositório GitHub; pipelines do GitHub Actions provisionam a infra e fazem o deploy. O participante vê progresso no painel do GitHub, não em um terminal.

---

## 2. Visão geral da arquitetura

```
[Agente CloudWeaver (local)]
         │
         ├── Coleta informações da receita (perguntas interativas)
         ├── Gera chave SSH Ed25519 local
         ├── gh repo create <user>/<env_name>
         ├── Gera e commita arquivos da receita
         ├── gh secret set ... (credenciais + secrets da receita)
         └── gh workflow run deploy.yml
                         │
                         ▼
         [GitHub Actions — repo do participante]
                         │
              ┌──────────┴──────────┐
              │                     │
         job: infra             job: deploy
              │                     │
              ▼                     ▼
 locaweb/locaweb-cloud-     Kamal (pull da imagem
 provision@v1               pré-construída, deploy SSH)
              │
              ▼
 VM na Locaweb Cloud
 (rede, IP público, firewall, disco)
```

### O que o agente faz

1. Faz as perguntas da receita (env_name, zona, plano de VM, secrets específicos).
2. Gera chave SSH Ed25519: `~/.ssh/cw-<env_name>`.
3. Cria o repositório GitHub via `gh repo create`.
4. Gera e commita todos os arquivos de configuração da receita.
5. Define os secrets do repositório via `gh secret set` (lê de variáveis de ambiente, nunca exibe valores).
6. Dispara o workflow: `gh workflow run deploy.yml`.
7. Acompanha via `gh run watch` e exibe apenas linhas `STEP:`.

### O que o GitHub Actions faz

- **Job `infra`**: chama `locaweb/locaweb-cloud-provision/.github/workflows/provision.yml@v1` → provisiona VM, rede, IP público, firewall, disco de dados. Exporta `INFRA_WEB_IP` e outros outputs.
- **Job `deploy`**: instala Kamal, faz `kamal setup`, que puxa a imagem pré-construída de `ghcr.io/fagnerlopes/cw-<recipe>:latest`, faz o re-tag como `ghcr.io/<user>/<env_name>:<sha>` e deploia na VM via SSH.

---

## 3. Imagens pré-construídas

### Por que pré-construir

No dia do Workshop, a infra é provisionada (~4 min) e o deploy ocorre em ~1 min porque a imagem já existe. Sem pré-construção, o build da imagem no runner do GitHub Actions levaria vários minutos adicionais por participante.

### Onde ficam

`ghcr.io/fagnerlopes/cw-<recipe>:latest`

Exemplos:
- `ghcr.io/fagnerlopes/cw-hermes-agent:latest`
- `ghcr.io/fagnerlopes/cw-waha:latest`

Imagens publicadas como **públicas** — participantes fazem pull sem autenticação.

### Dockerfile do participante

O Dockerfile no repo do participante é mínimo — apenas um re-tag:

```dockerfile
# Usa a imagem pré-construída do CloudWeaver.
# O Kamal builda este Dockerfile (trivial: pull + re-tag) e faz push
# para ghcr.io/<participante>/<env_name> antes do deploy.
FROM ghcr.io/fagnerlopes/cw-hermes-agent:latest
```

O Kamal builda este Dockerfile (operação quase instantânea — só um pull de layers já em cache no runner), faz push para `ghcr.io/<user>/<env_name>` e deploia na VM.

### Workflow de publicação das imagens (cloud-weaver repo)

Arquivo: `.github/workflows/build-recipes.yml` no repositório `cloud-weaver`.

```yaml
name: Build Recipe Images

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths:
      - "recipes/**"

permissions:
  contents: read
  packages: write

jobs:
  build:
    strategy:
      matrix:
        recipe: [hermes-agent, waha]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: fagnerlopes
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: recipes/${{ matrix.recipe }}
          push: true
          tags: |
            ghcr.io/fagnerlopes/cw-${{ matrix.recipe }}:latest
            ghcr.io/fagnerlopes/cw-${{ matrix.recipe }}:${{ github.sha }}
```

---

## 4. Arquivos gerados por receita (exemplo: hermes-agent)

Todos os arquivos abaixo são gerados pelo agente e commitados no repo do participante.

### 4.1 Estrutura do repositório

```
<env_name>/                        ← raiz do repo do participante
├── Dockerfile
├── .github/
│   └── workflows/
│       └── deploy.yml
├── config/
│   ├── deploy.yml                 ← config Kamal base
│   └── deploy.preview.yml        ← config env-specific (env_name=preview alias)
└── .kamal/
    ├── secrets-common
    └── secrets.preview
```

> **Nota sobre `env_name` vs `"preview"`**: o workflow `locaweb-cloud-provision` usa `env_name` como identificador de ambiente. Para simplicidade no Workshop, todos os participantes usam `env_name: "preview"` (o default do reusable workflow). O repositório GitHub é nomeado com o nome real da receita (ex: `meu-hermes`), mas o Kamal usa `preview` como identificador interno. Isso permite que o locaweb-cloud-provision mantenha a infra idempotente.

### 4.2 `.github/workflows/deploy.yml`

```yaml
name: Deploy

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths-ignore: [".claude/**"]

permissions:
  contents: read
  packages: write

jobs:
  infra:
    uses: locaweb/locaweb-cloud-provision/.github/workflows/provision.yml@v1
    with:
      env_name: "preview"
      zone: "ZP01"
      web_plan: "small"
      web_disk_size_gb: 20
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.LOCAWEB_API_KEY }}
      CLOUDSTACK_SECRET_KEY: ${{ secrets.LOCAWEB_API_SECRET }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}

  deploy:
    needs: infra
    runs-on: ubuntu-latest
    env:
      TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
      # Adicionar outros secrets da receita aqui
    steps:
      - uses: actions/checkout@v5

      - name: Load infrastructure environment
        run: echo "${{ needs.infra.outputs.infra_env }}" >> "$GITHUB_ENV"

      - name: Set repo identity
        run: |
          echo "REPO_NAME=$(echo '${{ github.event.repository.name }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"
          echo "REPO_FULL=$(echo '${{ github.repository }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"
          echo "REPO_OWNER=$(echo '${{ github.repository_owner }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"

      - uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - uses: crazy-max/ghaction-github-runtime@v3

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"

      - run: gem install kamal --no-document

      - name: Deploy with Kamal
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
        run: |
          kamal proxy boot -d preview || kamal proxy reboot -y -d preview || true
          kamal setup -d preview

      - uses: actions/delete-package-versions@v5
        with:
          package-name: ${{ env.REPO_NAME }}
          package-type: container
          min-versions-to-keep: 1
```

> **Mapeamento de secrets**: os nomes dos secrets no GitHub repo do participante são `LOCAWEB_API_KEY` e `LOCAWEB_API_SECRET` (alinhados com a nomenclatura CloudWeaver). Eles são passados como `CLOUDSTACK_API_KEY` e `CLOUDSTACK_SECRET_KEY` para o workflow externo, que usa esses nomes internamente.

### 4.3 `config/deploy.yml` (base Kamal)

```yaml
service: <%= ENV['REPO_NAME'] %>
image: <%= ENV['REPO_FULL'] %>

proxy:
  app_port: 3000       # porta da receita; cada recipe define a sua
  ssl: true
  forward_headers: false
  healthcheck:
    path: /health
    interval: 5
    timeout: 10

ssh:
  user: ubuntu

registry:
  server: ghcr.io
  username: <%= ENV['REPO_OWNER'] %>
  password:
    - KAMAL_REGISTRY_PASSWORD

builder:
  arch: amd64
  cache:
    type: gha
    options: mode=max,ignore-error=true

logging:
  driver: json-file
  options:
    max-size: "50m"
    max-file: "5"

readiness_delay: 30
deploy_timeout: 300
drain_timeout: 30
```

### 4.4 `config/deploy.preview.yml` (env-specific)

```yaml
servers:
  web:
    hosts:
      - <%= ENV['INFRA_WEB_IP'] %>

proxy:
  host: <%= ENV['INFRA_WEB_IP'] %>.nip.io

volumes:
  - /data/preview:/data

env:
  clear:
    ENV_NAME: preview
    DATA_PATH: /data/preview
  secret:
    - TELEGRAM_BOT_TOKEN
    # Outros secrets da receita
```

### 4.5 `.kamal/secrets-common`

```bash
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
```

### 4.6 `.kamal/secrets.preview`

```bash
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
# Outros secrets da receita
```

---

## 5. Secrets do repositório do participante

O agente define os seguintes secrets via `gh secret set` (lendo de variáveis de ambiente — nunca exibe valores):

| GitHub Secret | Origem (env var local) | Descrição |
|---|---|---|
| `LOCAWEB_API_KEY` | `$LOCAWEB_API_KEY` | Chave API Locaweb Cloud |
| `LOCAWEB_API_SECRET` | `$LOCAWEB_API_SECRET` | Secret API Locaweb Cloud |
| `SSH_PRIVATE_KEY` | `~/.ssh/cw-<env>` (gerada pelo agente) | Chave SSH para acesso à VM |
| `TELEGRAM_BOT_TOKEN` | `$TELEGRAM_BOT_TOKEN` | Token do bot Telegram |
| *(outros por receita)* | | |

A chave pública (`~/.ssh/cw-<env>.pub`) é passada para o `locaweb-cloud-provision` como `SSH_PRIVATE_KEY` (o workflow extrai a pública internamente via `ssh-keygen -y`).

---

## 6. Mudanças nas skills

### Skills removidas do fluxo de execução direta

| Skill atual | Substituído por |
|---|---|
| `cloud-weaver-vm-setup` (executa `vm-provision.py`) | Job `infra` no GitHub Actions chamando `locaweb-cloud-provision` |
| `cloud-weaver-hermes-agent` (executa `deploy-hermes-agent.py`) | Job `deploy` com Kamal |
| `cloud-weaver-waha` (executa `deploy-hermes.py`) | Job `deploy` com Kamal |

Os scripts Python existentes (`vm-provision.py`, `deploy-hermes-agent.py`, `deploy-hermes.py`) ficam no repositório como **referência histórica e para testes**, mas o agente não os executa mais como modo principal. Poderão ser removidos em v2.0.

### Nova skill: `cloud-weaver-repo-setup`

Responsável pelo fluxo completo de criação e configuração do repositório do participante.

**Estrutura:**
```
skills/cloud-weaver-repo-setup/
├── SKILL.md
├── scripts/
│   ├── repo-init.sh         # cria repo GitHub (adaptado do cofounder)
│   └── gen-recipe.py        # gera arquivos da receita a partir de templates
└── templates/
    ├── hermes-agent/
    │   ├── Dockerfile
    │   ├── deploy-workflow.yml
    │   ├── kamal-base.yml
    │   ├── kamal-env.yml
    │   ├── secrets-common
    │   └── secrets-env
    └── waha/
        └── ... (mesma estrutura)
```

### Skill `start-cloud` atualizada

O fluxo de coleta de informações e execução muda:

**Antes:**
1. Perguntas → provisionar VM (script Python local) → deploy (script Python local)

**Depois:**
1. Perguntas → verificar `gh auth status` + credenciais → gerar chave SSH → criar repo → gerar arquivos → definir secrets → disparar workflow → acompanhar com `gh run watch`

---

## 7. Estrutura do repositório `cloud-weaver` (adições)

```
cloud-weaver/
├── recipes/                          ← NOVO: fontes das imagens pré-construídas
│   ├── hermes-agent/
│   │   └── Dockerfile                ← imagem completa da receita
│   └── waha/
│       └── Dockerfile
├── skills/
│   ├── cloud-weaver-repo-setup/      ← NOVA skill
│   │   ├── SKILL.md
│   │   ├── scripts/
│   │   │   ├── repo-init.sh
│   │   │   └── gen-recipe.py
│   │   └── templates/
│   │       ├── hermes-agent/
│   │       └── waha/
│   └── ... (skills existentes mantidas)
└── .github/
    └── workflows/
        └── build-recipes.yml         ← NOVO: publica imagens para ghcr.io/fagnerlopes
```

---

## 8. Pre-flight check atualizado

O `cloud-weaver-pre-flight-check` precisa verificar:

| Verificação | Atual | v2 |
|---|---|---|
| `LOCAWEB_API_KEY` exportado | ✅ | ✅ |
| `LOCAWEB_API_SECRET` exportado | ✅ | ✅ |
| `TELEGRAM_BOT_TOKEN` exportado | ✅ | ✅ |
| `gh auth status` | ❌ (não verificado) | ✅ **novo** |
| `gh` instalado | ❌ | ✅ **novo** |
| `ssh-keygen` disponível | ❌ | ✅ **novo** |

---

## 9. Fluxo do Workshop — perspectiva do participante

**Preparação (feita antes do dia):**
1. Participante instala CloudWeaver: `npx skills add cloud-weaver`
2. Exporta suas credenciais Locaweb Cloud e Telegram no terminal
3. Executa o agente → responde as perguntas → agente cria o repo e define os secrets
4. O workflow roda uma primeira vez: infra provisionada + app deployado (~5 min)

**No dia do Workshop:**
- A VM já existe (infra cacheada pelo `locaweb-cloud-provision`)
- Participante faz push de alguma alteração (ou dispara manualmente): `gh workflow run deploy.yml`
- O job `deploy` roda sem reprovisionar infra: ~1 min (pull da imagem pré-construída + `kamal setup`)

---

## 10. Pontos de atenção e decisões pendentes

### 10.1 Nomenclatura de secrets

O `locaweb-cloud-provision` usa `CLOUDSTACK_API_KEY` / `CLOUDSTACK_SECRET_KEY` internamente. Mapeamos para `LOCAWEB_API_KEY` / `LOCAWEB_API_SECRET` (nomenclatura CloudWeaver) via o bloco `secrets:` do workflow gerado. Isso é transparente ao participante — os secrets do repo sempre têm nomes "Locaweb Cloud".

### 10.2 Conteúdo das imagens de receita

O que cada imagem `ghcr.io/fagnerlopes/cw-<recipe>:latest` contém é definido em `recipes/<recipe>/Dockerfile`. Isso é decisão de design de cada receita, separada da arquitetura de deployment.

Para o Workshop (hermes-agent): a imagem deve ser self-contained (não depende de services externos além do Telegram API). Processo único ou supervisord — a definir na spec da receita.

### 10.3 Health check

O proxy do Kamal exige um endpoint de health check (`GET /health` ou `GET /up`). Cada receita deve expor esse endpoint. Isso precisa estar documentado no Dockerfile e SKILL.md de cada receita.

### 10.4 Porta do app

O Kamal roteia tráfego da VM para a porta do container (`proxy.app_port`). Cada receita define sua porta. A comunicação TLS é tratada pelo kamal-proxy (Let's Encrypt via nip.io).

### 10.5 Teardown

O `locaweb-cloud-provision` tem um workflow de teardown. O CloudWeaver v2 deve gerar também `.github/workflows/teardown.yml` para facilitar limpeza pós-Workshop.

---

## 11. Fora do escopo desta spec

- Design interno de cada imagem de receita (conteúdo dos `recipes/*/Dockerfile`)
- Health check endpoint em cada receita
- Workflow de teardown (gerado mas não detalhado aqui)
- Suporte a múltiplos ambientes (preview + production) — v2 usa apenas `preview`
- Secrets de recipes adicionais além de hermes-agent e waha
