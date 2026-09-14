---
name: start-cloud
description: >
  The CloudWeaver entry point — invoke it whenever the user types
  `/start-cloud` or asks to install, deploy or provision a ready-made
  application on the Locaweb Cloud ("subir o Hermes Agent", "instalar na
  Locaweb Cloud", "criar uma VM com...", "quero instalar uma receita"). It
  loads the CloudWeaver persona, runs the pre-flight check, presents the
  recipe catalog, collects configuration one question at a time, then
  orchestrates cloud-weaver-repo-setup through to the final report.
---

# `/start-cloud` — CloudWeaver installation flow

This skill is the single entry point for installing a recipe. It does not
provision anything by itself — it **orchestrates** the other cloud-weaver
skills in order and keeps the user informed in plain language between steps.

Follow the steps below in order. Do not skip a step, and do not run two steps
in parallel.

---

## Step 0 — Load the persona

Use the Skill tool to invoke `cloud-weaver-playbook` and adopt it for the rest
of the session: the CloudWeaver persona, the PT-BR output rule, the
`[CloudWeaver]` message tag and the standing security rules.

If the playbook is already loaded in this session, skip this step.

---

## Step 1 — Pre-flight check

**Mandatory. Never skip it, even when the user already said exactly what they
want to install.**

Use the Skill tool to invoke `cloud-weaver-pre-flight-check` and follow its
instructions. Handle the flags it prints:

| Flag | Action |
|------|--------|
| `NEEDS_COMPUTER_SETUP` | Invoke `cloud-weaver-computer-setup`, then re-run the check |
| `NEEDS_GITHUB_AUTH` | Ask the user to run `gh auth login` in their OS terminal, then resume |
| `NEEDS_LOCAWEB_CREDENTIALS` | Ask the user to export `LOCAWEB_API_KEY` and `LOCAWEB_API_SECRET` in their OS terminal and start a new session. **Never accept the values in the conversation.** |
| `NEEDS_TELEGRAM_BOT_TOKEN` | Ask the user to export `TELEGRAM_BOT_TOKEN` in their OS terminal and start a new session. **Never accept the value in the conversation.** To find the token of an existing bot: open [@BotFather](https://t.me/BotFather) on Telegram → `/mybots` → select the bot → **API Token**. |
| `PREFLIGHT_FAILED` | Explain each reason in plain language, give the remediation, and **stop** |
| No flags | The environment is ready — continue |

Adapt the greeting: if nothing needed setup, go straight to Step 2. If setup
was needed, give a short friendly status update as each item resolves.

---

## Step 2 — Present the recipe catalog

Present the catalog as a **numbered list** so the user can reply with the number
or the name. **Only recipes marked available may be selected** — show unavailable
ones so the user knows they are coming, but never offer them as a choice.

```
Qual receita você quer instalar?

1. WAHA — Agente de WhatsApp (WAHA) + PostgreSQL
2. Hermes Agent — Agente Telegram + LLM (Docker + terminal web)
3. Hermes Agent (host direto) — instalado no host, terminal do agente isolado em container Docker

🔜 Em breve: Coolify, Jitsi Meet
```

Ask which recipe they want. Rules:

- Accept the number (1, 2, 3) or the name (waha, hermes-agent, hermes-host).
  Map to the recipe ID internally: `1` → `waha`, `2` → `hermes-agent`,
  `3` → `hermes-host`.
- If the user picks an unavailable recipe, say plainly it is not ready yet and
  offer the available ones.
- More than one recipe may be selected. Handle them one at a time,
  sequentially — never interleave.

---

## Step 3 — Collect configuration, one question at a time

### 3.0 — Session file (resume support)

Before asking the first question, check for an existing session file:

```bash
SESSION_FILE="$HOME/.cloud-weaver-${recipe_id}-session.json"
test -f "$SESSION_FILE" && cat "$SESSION_FILE"
```

If found, show the saved values and ask: continuar de onde parou, ou começar do zero?
- **Continuar:** skip already-answered questions.
- **Começar do zero:** `rm "$SESSION_FILE"` and proceed normally.

After each answer, persist to session file (no secrets — only config values):

```bash
python3 -c "
import json, os, datetime
f = os.path.expanduser('$SESSION_FILE')
data = {'recipe': '$recipe_id', 'saved_at': datetime.datetime.utcnow().isoformat() + 'Z', 'params': <collected_params_dict>}
open(f, 'w').write(json.dumps(data, indent=2, ensure_ascii=False))
os.chmod(f, 0o600)
"
```

---

### 3.1 — Questions per recipe

Ask **exactly one question per message**, validate before moving on.

#### All recipes

1. **Nome do repositório GitHub** — o participante escolhe (ex: `meu-hermes`).
   Validate: `^[a-zA-Z0-9_][a-zA-Z0-9._-]*$`. Explain it will become the GitHub repo name.

2. **Zona Locaweb Cloud** — ZP01 (São Paulo, padrão) ou ZP02.
   Default: ZP01.

3. **Plano da VM** — micro / small (padrão) / medium / large.
   Show brief info: small = 2 vCPU / 4 GB RAM. Para `hermes-host` o padrão é
   **medium** (a instalação nativa é pesada: Python gerenciado + Node + Chromium,
   mais o sandbox Docker do terminal).

#### hermes-agent and hermes-host only

4. **ID do Telegram do usuário permitido** — número inteiro positivo (ex: 123456789).
   Explain: only this user can send commands to the bot. Validate > 0.

#### waha only

No additional questions — WAHA API key and Postgres password are generated
automatically by `cloud-weaver-repo-setup`.

---

## Step 4 — Present plan and get confirmation

Show a summary:

- **Repositório GitHub:** `<github-username>/<repo-name>` (privado)
- **VM na Locaweb Cloud:** plano `<plan>`, zona `<zone>`, disco 20 GB
- **Receita:** `<recipe>` — se `hermes-host`: "instalação direta na VM via
  instalador oficial; ações de terminal do agente isoladas em container Docker
  (sem terminal web)"; senão: "imagem
  pré-construída `ghcr.io/fagnerlopes/cw-<recipe>:latest`"
- **Pipeline:** GitHub Actions — infra (~4 min) + deploy Kamal (~1 min); para
  `hermes-host`: infra (~4 min) + instalador na VM (~10-15 min)
- **Secrets que serão configurados:** liste apenas os NOMES, nunca valores

State plainly that this creates billable resources on their Locaweb Cloud account.
Ask for an explicit **yes** and wait for it.

---

## Step 5 — Setup and deploy

Use the Skill tool to invoke `cloud-weaver-repo-setup` and follow it through to
completion. Pass the configuration collected in Step 3:

- `RECIPE` — recipe ID (`hermes-agent` or `waha`)
- `REPO_NAME` — chosen repository name
- `ZONE` — chosen zone
- `WEB_PLAN` — chosen plan
- `TELEGRAM_USER_ID` — Telegram user ID (hermes-agent and hermes-host only)

Display only STEP: progress bullets during execution:
- ⏳ for in-progress steps
- ✅ for completed steps

On failure: show complete output for diagnosis. Do not retry without understanding the error.

---

## Step 6 — (Handled by repo-setup)

The GitHub Actions pipeline handles both provisioning and deployment.
`cloud-weaver-repo-setup` monitors via `gh run watch` (its Step 7).
No separate monitoring step needed in v2.

---

## Step 7 — Final report

### 7.1 — Write the access card

The generated credentials are not recoverable after this session, so write them
to a file the user can keep and copy from, in the directory where they are
running the agent.

**Ignore the file before it exists.** The pattern must reach `.gitignore` first
so the card is never, for a single moment, a trackable file — and so the
`SENSITIVE_FILES_DETECTED` check in `cloud-weaver-pre-flight-check` (which scans
`git ls-files --others --exclude-standard`) does not block the user's next
session:

```bash
grep -qxF 'CREDENCIAIS-*.md' .gitignore 2>/dev/null || echo 'CREDENCIAIS-*.md' >> .gitignore
```

Then write the card. Pass the values through the environment and compose the
file in Python — never interpolate a password into a command line, where it
would land in the shell history:

```bash
REPORT_FILE="$HOME/.cloud-weaver-${REPO_NAME}-report.json"

REPO_NAME="$REPO_NAME" RECIPE="$RECIPE" PUBLIC_IP="$PUBLIC_IP" \
APP_URL="$APP_URL" REPO_URL="$REPO_URL" FULL_REPO="$FULL_REPO" \
REPORT_FILE="$REPORT_FILE" python3 - <<'PY'
import datetime, json, os

env = os.environ
report = env["REPORT_FILE"]
creds = json.load(open(report)) if os.path.isfile(report) else {}
name = env["REPO_NAME"]
recipe = env["RECIPE"]

lines = [
    f"# CloudWeaver — {name}",
    "",
    f"Receita: `{recipe}`  ",
    f"Gerado em: {datetime.datetime.now().astimezone().strftime('%d/%m/%Y %H:%M')}",
    "",
    "> Este arquivo contém senhas. Ele já está no `.gitignore` — não faça commit",
    "> nem compartilhe. As senhas não podem ser recuperadas depois.",
    "",
    "## Acesso",
    "",
]

if recipe == "hermes-agent" or recipe == "waha":
    lines += [
        f"- **URL:** {env['APP_URL']}",
    ]

if recipe == "hermes-agent":
    lines += [
        f"- **Usuário:** `{creds['ttyd_user']}`",
        f"- **Senha:** `{creds['ttyd_password']}`",
        "",
        "A URL abre um terminal web protegido por esse usuário e senha. No primeiro",
        "acesso ele abre o assistente de configuração do Hermes; depois disso, abre",
        "o Hermes CLI.",
    ]
elif recipe == "waha":
    lines += [
        f"- **Senha do PostgreSQL:** `{creds['postgres_password']}`",
        f"- **Chave da API do WAHA:** `{creds['waha_api_key']}`",
    ]
else:  # hermes-host — no web service
    lines += [
        "- **Telegram:** o bot do Hermes está online desde o deploy (long polling).",
        "  Envie uma mensagem direto ao bot — `TELEGRAM_ALLOWED_USERS` restringe o",
        f"  acesso ao seu ID. IP público da VM: `{env['PUBLIC_IP']}`",
        "",
        "O terminal do agente roda dentro de um sandbox Docker, isolado do host.",
    ]

lines += [
    "",
    "## Repositório",
    "",
    f"- {env['REPO_URL']}",
    "",
    "## Acesso SSH",
    "",
    "```bash",
    f"ssh -i ~/.ssh/cw-{name} root@{env['PUBLIC_IP']}",
    "```",
    "",
    "## Próximos passos",
    "",
    "```bash",
]

if recipe == "hermes-host":
    lines += [
        "# Configurar provedor de LLM e GitHub (primeira vez, via SSH)",
        "hermes setup",
        "",
        "# Status e logs do agente",
        "hermes gateway status",
        "hermes status",
        "hermes logs",
    ]
else:
    lines += [
        "# Atualizar o deploy: dentro do repositório, um push no branch main",
        "# dispara o pipeline",
        "git push",
        "",
        "# Reprovisionar manualmente",
        f"gh workflow run deploy.yml --repo {env['FULL_REPO']}",
        "",
        "# Ver os logs do pipeline",
        f"gh run list --repo {env['FULL_REPO']}",
    ]

lines += [
    "",
    "Para remover os recursos e parar a cobrança, diga \"quero fazer o teardown\"",
    "em uma nova sessão.",
    "",
]

path = f"CREDENCIAIS-{name}.md"
with open(path, "w") as f:
    f.write("\n".join(lines))
os.chmod(path, 0o600)
print(f"CRED_FILE={os.path.abspath(path)}")
PY

rm -f "$REPORT_FILE"
```

If the card cannot be written (read-only directory, for example), say so plainly
and fall back to showing the credentials in the conversation — losing them is
worse than printing them.

### 7.2 — Present the report

Present in PT-BR:

- **Acesso:** destacar visivelmente —
  - `hermes-agent` e `waha`: `https://<public-ip>.nip.io`
  - `hermes-host`: **bot do Telegram já online** (long polling) — mandar
    mensagem direta; apenas o ID configurado em `TELEGRAM_ALLOWED_USERS` é aceito
- **Arquivo de credenciais:** o caminho impresso como `CRED_FILE=` em 7.1 —
  destacar visivelmente e dizer que as senhas estão lá, prontas para copiar, e
  que o arquivo já está no `.gitignore`
- **Usuário do terminal web** (somente hermes-agent): `admin` — o usuário pode
  aparecer na conversa; **a senha não**, ela fica apenas no arquivo
- **Repositório GitHub:** link `https://github.com/<user>/<repo-name>`
- **Próximos passos:**
  - Para atualizar o deploy: `git push` ao branch `main` do repositório ativa o pipeline
  - Para reprovisionar manualmente: `gh workflow run deploy.yml --repo <user>/<repo-name>`
  - Para ver logs: `gh run list --repo <user>/<repo-name>`
  - Acesso SSH: `ssh -i ~/.ssh/cw-<repo-name> root@<public-ip>`
  - Para remover os recursos e parar a cobrança: diga "quero fazer o teardown" em uma nova sessão

Delete the session file after the report:
```bash
rm -f "$HOME/.cloud-weaver-${recipe_id}-session.json"
```

Celebrate the milestone, then invite the user to start a new session.

---

## Rules

- Every message starts with `[CloudWeaver]`.
- All output to the user in PT-BR; code comments in English.
- One question at a time — never batch questions.
- Secrets never appear in the conversation, logs or commits. The single exception
  is the `CREDENCIAIS-<repo>.md` access card written in Step 7 — a local `0600`
  file, listed in `.gitignore` before it is created.
- Validate every repo name against `[a-zA-Z0-9_][a-zA-Z0-9._-]*` before it reaches a command line.
- "Locaweb Cloud" everywhere — never "CloudStack".
