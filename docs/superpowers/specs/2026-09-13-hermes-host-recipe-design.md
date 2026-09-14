# Receita Hermes Agent (host direto) — design

**Data:** 2026-09-13
**Status:** aprovado para plano de implementação — **revisado em 2026-09-14**
(pipeline passa a instalar Docker no host e configurar `terminal.backend: docker`
para isolar as ações de terminal do agente em um container sandbox)
**Motivação:** alternativa à receita Docker — instalar o Hermes Agent (Nous
Research) direto no host da VM da Locaweb Cloud, sem Kamal e sem terminal web,
com o bot do Telegram já online após o deploy e o terminal do agente isolado em
container Docker.

---

## 1. Objetivo

Adicionar a terceira receita do CloudWeaver: `hermes-host`. Diferente da
`hermes-agent` (Docker + terminal web via Traefik) e da `waha` (WAHA +
PostgreSQL), esta receita:

- instala o Hermes Agent **direto no host** da VM, pelo instalador oficial
  `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`;
- **não usa Kamal, nem imagem em GHCR**;
- **não expõe endpoint HTTP nem terminal web** — acesso é via Telegram e SSH;
- **isola o terminal interno do agente em um container Docker** (backend
  `terminal.backend: docker`), que executa todo `terminal`/`execute_code`/file
  num sandbox com hardening (`--cap-drop ALL`, `no-new-privileges`,
  `--pids-limit 256`), persistente entre sessões;
- deixa o **bot online no fim do deploy** (gateway como serviço systemd).

O fluxo é o mesmo modelo v2 das receitas atuais: conversa `start-cloud` →
`cloud-weaver-repo-setup` gera, para cada participante, um repo GitHub com um
workflow GitHub Actions que provisiona a VM na Locaweb Cloud via
`locaweb-cloud-provision@v1` e executa a instalação.

## 2. Contexto

As receitas atuais seguem v2 com imagem Docker pré-construída
(`recipes/<x>/Dockerfile`, publicada por `.github/workflows/build-recipes.yml`)
e deploy via Kamal. O Hermes Agent também possui um **instalador oficial**,
validado pelos autores da ferramenta, que provisiona um ambiente FHS no host:

| Item | Valor |
|------|-------|
| Binário | `/usr/local/bin/hermes` |
| Biblioteca | `/usr/local/lib/hermes-agent` |
| Dados | `/root/.hermes` (`HERMES_HOME`), incluindo `.env` |
| Runtime | Python gerenciado (uv) + Node (compila node-pty) + npm ci + Playwright/Chromium |
| Peso | ~2–4 GB de disco; 5–15 min de instalação |

O instalador **não pergunta o token do Telegram** em momento algum: ele lê
`TELEGRAM_BOT_TOKEN` de `/root/.hermes/.env` em runtime. Sem `/dev/tty`, os
wizards de setup e de gateway **são pulados automaticamente** — por isso o
deploy precisa escrever o `.env` e iniciar o gateway explicitamente.

O acesso SSH nas VMs da Locaweb Cloud é como **root** (ver `ssh:` em
`templates/hermes-agent/config-deploy*.yml`).

### Restrição que domina o desenho

O pipeline nunca deve mostrar o `TELEGRAM_BOT_TOKEN`: nem em log, nem em argv, nem
em commit. O padrão do repo (`gh secret set <<<`) já grava secrets via stdin;
o template de `deploy.yml` desta receita transfere o token para a VM via stdin
do `scp` (arquivo temporário `0600`), nunca em linha de comando.

## 3. Decisões tomadas

| Decisão | Escolha | Por quê |
|---------|---------|---------|
| Posicionamento | 3ª receita `hermes-host`, mantidas as duas atuais | Duas receitas atendem contextos diferentes; não unificar |
| Instalação | Instalador oficial via `curl | bash` | O mesmo caminho que os autores validam; sem imagem para manter |
| Sem Kamal/GHCR | Job `deploy` = SSH + instalador + systemd | Deploy host-native; nenhum artefato de container no repo gerado |
| Terminal do agente | Docker instalado no host (repo oficial, não snap) + `hermes config set terminal.backend docker` | Ações de `terminal`/`execute_code`/file rodam num sandbox container persistente, isolado do host e com hardening; o snap quebraria os flags `--init`/`no-new-privileges` |
| Limites do sandbox | `terminal.container_cpu 2`, `terminal.container_memory 4096` | Evita que o container disputar CPU/RAM com o gateway na VM medium (4 vCPU / 8 GB) |
| Flags do instalador | `--skip-setup --non-interactive --skip-computer-use --no-skills` | Wizard/computer-use desligados no pipeline (sem TTY); **browser/Chromium mantido** |
| Config em deploy | Pipeline grava `TELEGRAM_BOT_TOKEN` e `TELEGRAM_ALLOWED_USERS` no `.env`, configura o backend docker e inicia o gateway | Bot já online ao final; acesso restrito por allowlist; terminal isolado |
| Token do bot | GitHub secret; transferido por stdin/`scp` `0600` | Nunca na conversa, no log ou no argv |
| ID permitido | `TELEGRAM_USER_ID` coletado 1 pergunta por vez (igual `hermes-agent`) | `TELEGRAM_ALLOWED_USERS`; default da plataforma é *deny all* |
| Provedor LLM/GitHub | Configurador pelo usuário via `hermes setup` no SSH, após o deploy | Segredo do usuário não passa pelo pipeline |
| Plano da VM | `medium` (4 vCPU / 8 GB) por padrão | Instalação pesada (Python + Node + Chromium) + sandbox Docker |
| Validação pós-deploy | Via SSH: `docker info`, `hermes config get terminal.backend` = `docker`, `hermes --version`, token presente no `.env`, gateway ativo | Sem endpoint HTTP para o monitor |
| Relatório final | Acesso SSH + guia; **sem URL web** | Não há serviço web nesta receita |
| Versão | `plugin.json` 1.5.0 (base) — revisão da receita não altera a versão | Mudança de template/testes já implementada na receita existente |

## 4. Segurança

| Camada | Controle |
|--------|----------|
| Rede | Firewall padrão da provisão; nenhum serviço web publicado. Acesso: 22 (SSH) e saída para `api.telegram.org` |
| Telegram | `TELEGRAM_ALLOWED_USERS` com o ID do participante (allowlist; default é *deny all*) |
| Token do bot | GitHub secret; no VM vive em `/root/.hermes/.env` (`0600`) |
| Segredos na VM | `/root/.hermes/.env` e credenciais do usuário nunca trafegam pela conversa |
| Semantic versioning | Restrição `[a-z0-9_]` para nomes de repo, zona e plano (herdado) |

Risco residual aceito: `hermes gateway` roda como **root** na VM. É o mesmo
modelo das receitas atuais (Kamal roda como root) e o meio de acesso é o SSH
do participante.

## 5. Arquitetura

```
participante → Telegram (bot Hermes, long polling → api.telegram.org)
                 │
                 ▼
VM Locaweb (ubuntu, plano medium, SSH root)
  ├── /usr/local/bin/hermes                    (instalador oficial)
  ├── /usr/local/lib/hermes-agent
  ├── Docker Engine (repo oficial)             (backend do terminal)
  ├── /root/.hermes/config.yaml                (terminal.backend: docker)
  ├── /root/.hermes/.env                       (TELEGRAM_BOT_TOKEN, ALLOWED_USERS)
  ├── sandbox container (hermes-agent=1)       (terminal/execute_code/files isolados)
  └── hermes gateway  (systemd service, iniciado pelo deploy)
```

Nenhuma porta HTTP aberta. O monitor HTTP das outras receitas não se aplica:
a validação de saúde é feita **via SSH** (inclui `docker info` e o backend docker).

## 6. Componentes

### 6.1 Template do participante — `skills/cloud-weaver-repo-setup/templates/hermes-host/`

Apenas dois arquivos (o `gen-recipe.py` só copia templates que existam na
pasta da receita):

```
templates/hermes-host/
├── deploy.yml        # infra + deploy SSH + configuração + validação
└── teardown.yml      # cópia do hermes-agent (reusa shared/teardown.py)
```

`deploy.yml` (placeholders `@[ZONE]`, `@[WEB_PLAN]`, `@[TELEGRAM_USER_ID]`):

1. **Job `infra`** — idêntico às outras receitas: reusa
   `locaweb/locaweb-cloud-provision/.github/workflows/provision.yml@v1` com
   `env_name: "preview"`, `zone`, `web_plan` e secrets
   `LOCAWEB_API_KEY` / `LOCAWEB_API_SECRET` / `SSH_PRIVATE_KEY`. O job emite
   `infra_env` (com `INFRA_WEB_IP`).
2. **Job `deploy`** (`needs: infra`, sem permissões extras — não há push de
   imagem):
   - `actions/checkout@v5` + carrega `infra_env` + `webfactory/ssh-agent@v0.9.0`
     com `SSH_PRIVATE_KEY`;
   - **Instalar**:
     ```
     ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 root@"$INFRA_WEB_IP" \
       'curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
        | bash -s -- --skip-setup --non-interactive --skip-computer-use --no-skills'
     ```
   - **Instalar Docker** (repo oficial do Docker, não snap — o snap quebra os
     flags de hardening do backend):
     ```
     install -m 0755 -d /etc/apt/keyrings
     curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
     chmod a+r /etc/apt/keyrings/docker.asc
     echo "deb [...] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list
     apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
     ```
   - **Configurar e iniciar o bot** — o passo tem `env` com o secret
     (`TELEGRAM_BOT_TOKEN`, mascarado pelo GHA) e o ID público
     (`TELEGRAM_USER_ID` como `@` + participante). Grava as duas linhas num
     tempfile local `0600`, `scp` para `/tmp/cw-env-append` na VM, mescla no
     `/root/.hermes/.env` (cria com `0600` se ausente), apaga o tempfile, define
     o backend docker (`hermes config set terminal.backend docker`, limites
     `terminal.container_cpu 2` e `terminal.container_memory 4096`) e roda
     `hermes gateway install || true` + `hermes gateway start`.
   - **Validar**:
     ```
     docker info >/dev/null
     test "$(hermes config get terminal.backend)" = docker
     hermes --version
     grep -q "^TELEGRAM_BOT_TOKEN=[^$]" /root/.hermes/.env
     (systemctl is-active --quiet hermes-gateway || pgrep -f "gateway") && echo "gateway OK"
     ```

### 6.2 `skills/cloud-weaver-repo-setup/scripts/gen-recipe.py`

- `_KNOWN_RECIPES = {"hermes-agent", "hermes-host", "waha"}`.
- `--telegram-user-id` passa a ser aceito **também** por `hermes-host`
  (mesma validação de inteiro positivo); vira `TELEGRAM_USER_ID` no contexto.
- O loop de cópia já pula templates ausentes — como a pasta `templates/hermes-host/`
  tem só `deploy.yml` + `teardown.yml`, **não** são gerados `Dockerfile`,
  `config/deploy*.yml`, `.kamal/*`.
- Restrição de nomes `[a-z0-9_]` e validação de placeholders herdadas.

### 6.3 `skills/cloud-weaver-repo-setup/SKILL.md`

- Step 3: `RECIPE` pode ser `hermes-agent`, `hermes-host`, `waha`;
  `--telegram-user-id` disponível para `hermes-agent` e `hermes-host`.
- Step 5 (secrets):
  - todas: `LOCAWEB_API_KEY`, `LOCAWEB_API_SECRET`, `SSH_PRIVATE_KEY`;
  - `hermes-host` e `hermes-agent`: `TELEGRAM_BOT_TOKEN` (mesmo padrão
    `gh secret set TELEGRAM_BOT_TOKEN --repo … <<< …`);
  - `hermes-host` não gera `REPORT_FILE` (sem segredos gerados pela receita).

### 6.4 `skills/start-cloud/SKILL.md`

- Step 2 — catálogo:
```
   1. WAHA — Agente de WhatsApp (WAHA) + PostgreSQL
   2. Hermes Agent (Docker + terminal web)
   3. Hermes Agent (host direto) — instalado no host, terminal do agente isolado em container Docker
   ```
  `1 → waha`, `2 → hermes-agent`, `3 → hermes-host`.
- Step 3 — perguntas: `hermes-host` pergunta o `telegram_user_id` (mesma
  pergunta do `hermes-agent`); **sem pergunta de app web**. Plano de VM padrão
  para `hermes-host` = `medium`.
- Step 4 — resumo do plano: mostra "instalação direta na VM via instalador
  oficial; ações de terminal do agente isoladas em container Docker (sem terminal
  web)"; sem linha de imagem GHCR.
- Step 7 — relatório: sem URL web; card com **acesso SSH** + estado do bot
  (online) + guia (`hermes setup`, `hermes gateway`, `hermes logs`) +
  mensagem direta no Telegram.
- `NEEDS_TELEGRAM_BOT_TOKEN` volta a ser **bloqueante** no Step 1 (as duas
  receitas Telegram exigem o token no pipeline).

### 6.5 `skills/cloud-weaver-monitor/SKILL.md`

- `hermes-host` **não tem endpoint HTTP**: a tabela de health check ganha um
  branch "SSH-only" — checagem `docker info` + `hermes config get
  terminal.backend` = `docker` + `hermes --version` + gateway via SSH. O
  `diagnose.sh` (que usa `docker ps`) **se aplica** ao sandbox do Hermes; o
  gateway é diagnosticado via systemd.

### 6.6 Catálogo de build e versão

- `.github/workflows/build-recipes.yml`: **intocado** (não há imagem para
  `hermes-host`).
- `recipes/`: **intocado** (não há Dockerfile).
- `.claude-plugin/plugin.json`: `1.4.0` → `1.5.0`, seguido de
  `scripts/stamp-version.sh` (propaga `CLOUD_WEAVER_VERSION` no pre-flight).
- `README.md`: linha nova na tabela de receitas.

## 7. Questões abertas — validar no smoke test (não bloqueiam o design)

**Q1 — systemd unit.** Confirmar o nome do serviço criado por
`hermes gateway install` (provável `hermes-gateway.service`). O check de
validação já tem fallback `pgrep -f gateway`.

**Q2 — TTY no `hermes gateway install`.** Confirmar que o subcomando `gateway
install` funciona sem `/dev/tty` (é CLI, não wizard). Documentar `script -qc`
como alternativa, se preciso.

**Q3 — Disco de 20 GB.** A instalação inteira (Python + Node + Chromium) deve
caber no mesmo `web_disk_size_gb: 20` das outras receitas; validar no smoke e
subir para 30 se estourar.

**Q4 — Chromium em root.** O instalador baixa Playwright/Chromium; confirmar
que não exige bibliotecas desktop ausentes na imagem base da Locaweb (o
`--no-skills` não é o motivo — optamos por manter o browser).

**Q5 — Primeira chamada ao sandbox.** A imagem `nikolaik/python-nodejs` do
backend docker é baixada na primeira chamada de terminal do agente, não no
deploy; confirmar no smoke que o pull acontece sem erro (egresso de rede OK) e
que o container `hermes-agent=1` sobe com os limites configurados.

## 8. Testes

- `tests/scripts/test-repo-setup.sh`: novo bloco para `hermes-host` —
  gera `deploy.yml` + `teardown.yml`; **não** gera `Dockerfile`,
  `config/`, `.kamal/`; substitui `@[ZONE]`, `@[WEB_PLAN]`, `@[TELEGRAM_USER_ID]`;
  sem placeholders residuais; **aceita rodar com `--telegram-user-id`** e
  valida rejeição quando ausente (mesma regra do `hermes-agent`); o workflow
  contém a instalação do Docker (repo oficial, sem snap/`docker.io`), o
  `hermes config set terminal.backend docker` + limites, e `docker info` na
  validação.
- **Smoke test numa VM real** — único que cobre Q1 a Q4: provisionar, instalar,
  verificar `hermes --version`, gateway ativo, `docker info` e um comando de
  terminal do bot respondendo de dentro do sandbox.

## 9. Fora de escopo

- Unificar as receitas `hermes-agent` e `hermes-host` (convivem separadas).
- Instalação de WAHA no host (mantida Docker).
- Expor qualquer endpoint HTTP/terminal web nesta receita.
- Configuração do provedor de LLM e GitHub pelo pipeline (fica para
  `hermes setup` do usuário).