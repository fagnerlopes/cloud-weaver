# Receita hermes-host (Hermes Agent nativo no host) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third CloudWeaver recipe, `hermes-host`, that installs the Hermes Agent (Nous Research) directly on the Locaweb Cloud VM host via the official installer — no Docker, no Kamal, no web terminal — and leaves the Telegram bot online when the pipeline finishes.

**Architecture:** The participant's GitHub repo gets a `deploy.yml` whose `infra` job reuses `locaweb/locaweb-cloud-provision@v1` (same as current recipes) and whose `deploy` job SSHes into the VM as root, runs the official installer (`curl … | bash -s -- --skip-setup --non-interactive --skip-computer-use --no-skills`), writes `TELEGRAM_BOT_TOKEN` + `TELEGRAM_ALLOWED_USERS` into `/root/.hermes/.env` (token transferred via stdin/scp of a `0600` file, never argv/log), then starts the gateway as a systemd service. No HTTP endpoint exists, so the monitor skill gets an SSH-only branch for this recipe.

**Tech Stack:** Python 3 (stdlib only; `gen-recipe.py`), bash, GitHub Actions templates, Markdown SKILL.md docs.

**Spec:** [docs/superpowers/specs/2026-09-13-hermes-host-recipe-design.md](../specs/2026-09-13-hermes-host-recipe-design.md)

## Global Constraints

- No `git commit` steps in this plan. Commit/push only when the user explicitly asks. (Project rule: never commit unless asked.)
- Do not add comments to code/SKILL files beyond the ones already present in the templates below.
- Template placeholder syntax is `@[VAR_NAME]`; `gen-recipe.py` raises on unknown variables and rejects any leftover placeholders in generated output.
- GHA expressions (`${{ secrets.X }}`) and YAML must survive substitution untouched.
- The `TELEGRAM_BOT_TOKEN` value must never appear in argv, logs, or commits in any artifact this plan creates (it reaches the VM via `mktemp` + `chmod 600` + `scp`, matching the repo's `gh secret set <<<` stdin convention).
- Recipe IDs: `waha`, `hermes-agent`, `hermes-host`. Only `hermes-agent` and `hermes-host` accept `--telegram-user-id`.
- Output to the user stays PT-BR; code comments/skill text stay in English.
- Version source of truth is `.claude-plugin/plugin.json`; propagated by `scripts/stamp-version.sh`.
- Project root is the repo root (call it `REPO` below): `$(cd "$(dirname …)/.." && pwd)` naming follows `tests/scripts/*.sh` conventions.

---

### Task 1: Register `hermes-host` in gen-recipe.py + create its templates

**Files:**
- Create: `skills/cloud-weaver-repo-setup/templates/hermes-host/deploy.yml`
- Create: `skills/cloud-weaver-repo-setup/templates/hermes-host/teardown.yml`
- Modify: `skills/cloud-weaver-repo-setup/scripts/gen-recipe.py` (4 small edits)
- Test: `tests/scripts/test-repo-setup.sh`

**Interfaces:**
- Consumes: existing CLI contract of `gen-recipe.py` (`--recipe`, `--output-dir`, `--zone`, `--web-plan`, `--repo-name`, `--telegram-user-id`).
- Produces:
  - For template files: placeholders `@[ZONE]`, `@[WEB_PLAN]`, `@[TELEGRAM_USER_ID]`.
  - For later tasks: the generated repo for `hermes-host` contains ONLY `.github/workflows/deploy.yml`, `.github/workflows/teardown.yml`, and `teardown.py` (from `_SHARED_FILES`) — no `Dockerfile`, no `config/`, no `.kamal/`.

- [ ] **Step 1: Write the failing tests**

Append a new section to `tests/scripts/test-repo-setup.sh`, right after the "idempotência" section and before `summary "repo-setup"`:

```bash
echo "== gen-recipe: hermes-host — geração sem Docker/Kamal =="
"$PYTHON" "$SCRIPT" \
    --recipe hermes-host \
    --output-dir "$BASE/hh" \
    --zone ZP01 \
    --web-plan medium \
    --telegram-user-id 987654321 \
    --repo-name meu-hermes-host \
    >"$BASE/hh.out" 2>&1
expect "exit 0 hermes-host" test $? = 0

expect "deploy.yml hermes-host"       test -f "$BASE/hh/.github/workflows/deploy.yml"
expect "teardown.yml hermes-host"     test -f "$BASE/hh/.github/workflows/teardown.yml"
refute "sem Dockerfile hermes-host"   test -f "$BASE/hh/Dockerfile"
refute "sem config/ hermes-host"      test -e "$BASE/hh/config"
refute "sem .kamal/ hermes-host"      test -e "$BASE/hh/.kamal"

expect "zona ZP01 hermes-host"        grep -q "ZP01" "$BASE/hh/.github/workflows/deploy.yml"
expect "web-plan medium hermes-host"  grep -q "medium" "$BASE/hh/.github/workflows/deploy.yml"
expect "telegram id no workflow"      grep -q "987654321" "$BASE/hh/.github/workflows/deploy.yml"
expect "instalador oficial"           grep -q "https://hermes-agent.nousresearch.com/install.sh" "$BASE/hh/.github/workflows/deploy.yml"
expect "flags do instalador"          grep -q -- "--skip-setup --non-interactive --skip-computer-use --no-skills" "$BASE/hh/.github/workflows/deploy.yml"
refute "sem kamal no workflow"        grep -qi "kamal" "$BASE/hh/.github/workflows/deploy.yml"
refute "sem ghcr no workflow"         grep -q "ghcr.io" "$BASE/hh/.github/workflows/deploy.yml"

expect "token via env var"            grep -qF '"$TELEGRAM_BOT_TOKEN"' "$BASE/hh/.github/workflows/deploy.yml"
expect "token via scp 0600"           grep -q "cw-env-append" "$BASE/hh/.github/workflows/deploy.yml"
expect "TELEGRAM_ALLOWED_USERS"       grep -q "TELEGRAM_ALLOWED_USERS" "$BASE/hh/.github/workflows/deploy.yml"

expect "GHA locaweb secrets intactos" grep -q 'secrets.LOCAWEB_API_KEY' "$BASE/hh/.github/workflows/deploy.yml"
expect "GHA ssh-agent intacto"        grep -q 'webfactory/ssh-agent' "$BASE/hh/.github/workflows/deploy.yml"
refute "sem placeholders hermes-host" grep -q '@\[' "$BASE/hh/.github/workflows/deploy.yml"

echo "== gen-recipe: hermes-host — telegram obrigatório =="
"$PYTHON" "$SCRIPT" --recipe hermes-host --output-dir "$BASE/bad3" \
    --zone ZP01 --web-plan small --repo-name x \
    2>"$BASE/bad3.err" || true
expect "rejeita hermes-host sem telegram" grep -q "telegram-user-id" "$BASE/bad3.err"
```

- [ ] **Step 2: Run tests to verify they fail**

Run from `REPO`:

```bash
bash tests/scripts/test-repo-setup.sh
```

Expected: FAIL on every `hermes-host` assertion (gen-recipe exits 1 with `Unknown recipe 'hermes-host'`, and the template dir does not exist yet). The pre-existing `hermes-agent`/`waha` sections must still pass.

- [ ] **Step 3: Implement — create the templates**

Create `skills/cloud-weaver-repo-setup/templates/hermes-host/deploy.yml` with exactly this content:

```yaml
# Generated by CloudWeaver. Provisions a VM on Locaweb Cloud and installs the
# Hermes Agent (Telegram + LLM) directly on the host via the official installer.
# No Docker, no Kamal, no web terminal.
name: Deploy

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths-ignore: [".claude/**"]

permissions:
  contents: read

jobs:
  infra:
    uses: locaweb/locaweb-cloud-provision/.github/workflows/provision.yml@v1
    with:
      env_name: "preview"
      zone: "@[ZONE]"
      web_plan: "@[WEB_PLAN]"
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
      TELEGRAM_USER_ID: '@[TELEGRAM_USER_ID]'
    steps:
      - uses: actions/checkout@v5

      - name: Load infrastructure environment
        run: echo "${{ needs.infra.outputs.infra_env }}" >> "$GITHUB_ENV"

      - uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - name: Install Hermes Agent on the host
        run: |
          ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 root@"$INFRA_WEB_IP" \
            'curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
             | bash -s -- --skip-setup --non-interactive --skip-computer-use --no-skills'

      - name: Configure bot token, allowed users, and start gateway
        run: |
          set -euo pipefail
          HOST="root@${INFRA_WEB_IP}"
          # The token reaches the VM only via stdin (scp of a 0600 temp file);
          # it never appears in argv, logs, or commits.
          tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
          printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USERS=%s\n' \
            "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_USER_ID" > "$tmp"
          chmod 600 "$tmp"
          scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 "$tmp" "${HOST}:/tmp/cw-env-append"
          ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 "$HOST" \
            'touch /root/.hermes/.env && chmod 600 /root/.hermes/.env
             while IFS= read -r line; do
               key="${line%%=*}"
               if grep -q "^${key}=" /root/.hermes/.env; then
                 sed -i "s|^${key}=.*|${line}|" /root/.hermes/.env
               else
                 printf "%s\n" "$line" >> /root/.hermes/.env
               fi
             done < /tmp/cw-env-append
             rm -f /tmp/cw-env-append
             hermes gateway install || true
             hermes gateway start'

      - name: Verify Hermes is up
        run: |
          ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 root@"$INFRA_WEB_IP" \
            'hermes --version && test -s /root/.hermes/.env \
             && grep -q "^TELEGRAM_BOT_TOKEN=." /root/.hermes/.env \
             && ! grep -q "^TELEGRAM_BOT_TOKEN=your-" /root/.hermes/.env \
             && (systemctl is-active --quiet hermes-gateway 2>/dev/null \
                 || pgrep -f "gateway" >/dev/null)'
```

Create `skills/cloud-weaver-repo-setup/templates/hermes-host/teardown.yml` with exactly this content (same shape as the hermes-agent teardown, only the `@[ZONE]` placeholder varies):

```yaml
# Generated by CloudWeaver. Destroys all Locaweb Cloud resources for this recipe.
# Run via: gh workflow run teardown.yml --repo <owner>/<repo>
name: Teardown

on:
  workflow_dispatch:

jobs:
  teardown:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Destroy VM, network and SSH keypair on Locaweb Cloud
        env:
          LOCAWEB_API_KEY: ${{ secrets.LOCAWEB_API_KEY }}
          LOCAWEB_API_SECRET: ${{ secrets.LOCAWEB_API_SECRET }}
        run: python3 teardown.py --env-name preview --zone @[ZONE]
```

- [ ] **Step 4: Implement — wire `hermes-host` into gen-recipe.py**

Apply these four edits to `skills/cloud-weaver-repo-setup/scripts/gen-recipe.py`:

Edit A — `_KNOWN_RECIPES` (line 33):

```python
_KNOWN_RECIPES = {"hermes-agent", "hermes-host", "waha"}
```

Edit B — `build_context` recipe guard (lines 56-64):

```python
    if args.recipe in ("hermes-agent", "hermes-host"):
        if args.telegram_user_id is not None and args.telegram_user_id <= 0:
            print(
                "ERROR: --telegram-user-id must be a positive integer, "
                f"got {args.telegram_user_id}",
                file=sys.stderr,
            )
            sys.exit(1)
        ctx["TELEGRAM_USER_ID"] = str(args.telegram_user_id or "")
```

Edit C — `--telegram-user-id` help text (line 125):

```python
                   help="Telegram user ID (required for hermes-agent and hermes-host)")
```

Edit D — required-token guard in `main()` (lines 137-139):

```python
    if args.recipe in ("hermes-agent", "hermes-host") and not args.telegram_user_id:
        print(f"ERROR: --telegram-user-id is required for the {args.recipe} recipe", file=sys.stderr)
        return 1
```

No change to `generate()` or `_SHARED_FILES` — the `_FILE_MAP` loop already skips templates that don't exist in the recipe's template dir, so `hermes-host` produces no `Dockerfile`, `config/`, or `.kamal/`.

- [ ] **Step 5: Run tests to verify they pass**

```bash
bash tests/scripts/test-repo-setup.sh
```

Expected: all sections PASS (hermes-agent, waha, validations, idempotência, and the new hermes-host block).

- [ ] **Step 6: Visual smoke of the generated workflow**

```bash
OUT=$(mktemp -d); python3 skills/cloud-weaver-repo-setup/scripts/gen-recipe.py \
  --recipe hermes-host --output-dir "$OUT" --zone ZP01 --web-plan medium \
  --telegram-user-id 987654321 --repo-name meu-hermes-host && \
  cat "$OUT/.github/workflows/deploy.yml"; rm -rf "$OUT"
```

Expected: `@[TELEGRAM_USER_ID]` renders as `'987654321'`, no `@[` leftovers, `kamal`/`ghcr` absent, and the YAML is structurally intact (the `run` blocks keep their indentation).

---

### Task 2: start-cloud — catalog, questions, plan summary

**Files:**
- Modify: `skills/start-cloud/SKILL.md` (Step 2 catalog + mapping, Step 3.1 questions + plan default, Step 4 summary, Step 5 pass-through note)
- Test: `tests/scripts/test-scripts.sh` (new "skills docs" section)

**Interfaces:**
- Consumes: recipe choices from Step 2 (`waha`, `hermes-agent`, `hermes-host`); collected `TELEGRAM_USER_ID`.
- Produces: `RECIPE`/`REPO_NAME`/`ZONE`/`WEB_PLAN`/`TELEGRAM_USER_ID` handed to `cloud-weaver-repo-setup` in Step 5.

- [ ] **Step 1: Write the failing doc-content tests**

Append a new section to `tests/scripts/test-scripts.sh`, after the "locaweb credentials present" block and before `summary "scripts (preflight)"`:

```bash
echo "== skills: catalogo e apoio hermes-host =="
START="$REPO/../skills/start-cloud/SKILL.md"
REPOSETUP="$REPO/../skills/cloud-weaver-repo-setup/SKILL.md"
MONITOR="$REPO/../skills/cloud-weaver-monitor/SKILL.md"
expect "catalogo hermes-host"        file_contains "$START" "Hermes Agent (host direto)"
expect "mapa 3 -> hermes-host"       bash -c "grep -qF '3\` → \`hermes-host' '$START'"
expect "pergunta telegram both"      file_contains "$START" "#### hermes-agent and hermes-host only"
expect "repo-setup receitas"         file_contains "$REPOSETUP" '`hermes-agent`, `hermes-host`, or `waha`'
expect "repo-setup token both"       file_contains "$REPOSETUP" "hermes-agent and hermes-host: also check"
expect "monitor hermes-host"         file_contains "$MONITOR" "hermes-host"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bash tests/scripts/test-scripts.sh
```

Expected: FAIL only on the six new `skills:` assertions; all pre-flight assertions still PASS.

- [ ] **Step 3: Implement the SKILL.md edits**

**3a. Step 2 catalog** — replace the catalog block (lines 62-69):

```markdown
Qual receita você quer instalar?

1. WAHA — Agente de WhatsApp (WAHA) + PostgreSQL
2. Hermes Agent — Agente Telegram + LLM (Docker + terminal web)
3. Hermes Agent (host direto) — sem Docker, sem terminal web

🔜 Em breve: Coolify, Jitsi Meet
```

And the mapping sentence (lines 73-74) becomes:

```markdown
- Accept the number (1, 2, 3) or the name (waha, hermes-agent, hermes-host).
  Map to the recipe ID internally: `1` → `waha`, `2` → `hermes-agent`,
  `3` → `hermes-host`.
```

**3b. Step 3.1 questions** — the VM-plan item (line 123-124) becomes:

```markdown
3. **Plano da VM** — micro / small (padrão) / medium / large.
   Show brief info: small = 2 vCPU / 4 GB RAM. Para `hermes-host` o padrão é
   **medium** (a instalação nativa é pesada: Python gerenciado + Node + Chromium).
```

The Telegram-ID heading (line 126) becomes:

```markdown
#### hermes-agent and hermes-host only
```

**3c. Step 4 summary** — replace the recipe/pipeline bullets (lines 144-146):

```markdown
- **Receita:** `<recipe>` — se `hermes-host`: "instalação direta na VM via
  instalador oficial (sem Docker, sem Kamal, sem terminal web)"; senão: "imagem
  pré-construída `ghcr.io/fagnerlopes/cw-<recipe>:latest`"
- **Pipeline:** GitHub Actions — infra (~4 min) + deploy Kamal (~1 min); para
  `hermes-host`: infra (~4 min) + instalador na VM (~10-15 min)
```

**3d. Step 5 pass-through** — update the `TELEGRAM_USER_ID` line (line 162):

```markdown
- `TELEGRAM_USER_ID` — Telegram user ID (hermes-agent and hermes-host only)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bash tests/scripts/test-scripts.sh
```

Expected: all sections PASS, including the six new `skills:` assertions.

---

### Task 3: start-cloud — final report (access card + presentation)

**Files:**
- Modify: `skills/start-cloud/SKILL.md` (Step 7.1 python block, Step 7.2 bullet list)

**Interfaces:**
- Consumes: `REPO_NAME`, `RECIPE`, `PUBLIC_IP`, `APP_URL`, `REPO_URL`, `FULL_REPO`, `REPORT_FILE` (env passed into the python heredoc).
- Produces: `CREDENCIAIS-<repo>.md` access card; `CRED_FILE=` path printed for the report.

- [ ] **Step 1: Rewrite the Step 7.1 access-card python block**

Replace the entire `python3 - <<'PY' … PY` block in Step 7.1 (currently lines 208-279) with:

```bash
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

(Keep the surrounding `grep -qxF 'CREDENCIAIS-*.md' .gitignore …`, the `REPORT_FILE=` assignment, and the fallback sentence on failure unchanged.)

- [ ] **Step 2: Update the Step 7.2 presentation bullets**

Replace the "**URL de acesso:**" bullet (line 292) with:

```markdown
- **Acesso:** destacar visivelmente —
  - `hermes-agent` e `waha`: `https://<public-ip>.nip.io`
  - `hermes-host`: **bot do Telegram já online** (long polling) — mandar
    mensagem direta; apenas o ID configurado em `TELEGRAM_ALLOWED_USERS` é aceito
```

Keep the ttyd bullet as-is but scope it explicitly (line 296-297):

```markdown
- **Usuário do terminal web** (somente hermes-agent): `admin` — o usuário pode
  aparecer na conversa; **a senha não**, ela fica apenas no arquivo
```

- [ ] **Step 3: Verify Machine-Readable Assets Not Broken**

```bash
bash tests/scripts/test-scripts.sh && bash tests/scripts/test-repo-setup.sh
```

Expected: everything PASS (start-cloud Step 2 catalog assertions still match — the new card text does not change the catalog strings).

---

### Task 4: cloud-weaver-repo-setup SKILL.md

**Files:**
- Modify: `skills/cloud-weaver-repo-setup/SKILL.md` (Step 1, Step 3, Step 5, Step 7, Step 8)

**Interfaces:**
- Consumes: `RECIPE`, `ZONE`, `WEB_PLAN`, `REPO_NAME`, `TELEGRAM_USER_ID` from start-cloud; env `TELEGRAM_BOT_TOKEN`.
- Produces: repo secrets (3 infra + `TELEGRAM_BOT_TOKEN` for hermes-host), progress bullets, return values to start-cloud.

- [ ] **Step 1: Edit Step 1** (line 35)

```markdown
For hermes-agent and hermes-host: also check `TELEGRAM_BOT_TOKEN`.
```

- [ ] **Step 2: Edit Step 3** — the comment (line 79) and the variables list (lines 82-87):

```markdown
  # ^ include --telegram-user-id for hermes-agent and hermes-host
```

```markdown
- `RECIPE` — `hermes-agent`, `hermes-host`, or `waha`
- `REPO_NAME` — chosen repository name (e.g. `meu-hermes`)
- `ZONE` — `ZP01` or `ZP02`
- `WEB_PLAN` — `small`, `medium`, etc.
- `TELEGRAM_USER_ID` — Telegram user ID (hermes-agent and hermes-host only)
```

- [ ] **Step 3: Edit Step 5** — add a `hermes-host` secret block, right before the `**waha:**` block:

```markdown
**hermes-host:**
```bash
gh secret set TELEGRAM_BOT_TOKEN --repo "$FULL_REPO" <<< "$TELEGRAM_BOT_TOKEN"
```
```
No `TTYD_PASSWORD`/`REPORT_FILE` for `hermes-host` — it generates no secrets.

- [ ] **Step 4: Edit Step 7** — scope the deploy progress bullet (lines 192-193):

```markdown
- ⏳ `deploy` — hermes-host: instalando Hermes Agent no host (~10-15 min); demais receitas: fazendo deploy com Kamal...
- ✅ `deploy` — deploy concluído
```

- [ ] **Step 5: Edit Step 8** — clarify `REPORT_FILE` (lines 216-218):

```markdown
- `REPORT_FILE` — `~/.cloud-weaver-${REPO_NAME}-report.json` (generated credentials;
  start-cloud Step 7 copies them into the `CREDENCIAIS-${REPO_NAME}.md` access card
  and then deletes this file; `hermes-host` generates no credentials, so no file
  is produced)
```

- [ ] **Step 6: Verify**

```bash
bash tests/scripts/test-scripts.sh
```

Expected: all PASS (doc-content assertions from Task 2 now check `hermes-agent and hermes-host: also check` and the recipe list, which this task wrote).

---

### Task 5: cloud-weaver-monitor SKILL.md

**Files:**
- Modify: `skills/cloud-weaver-monitor/SKILL.md` (health URL table, new SSH check subsection, diagnose note)

**Interfaces:**
- Consumes: `PUBLIC_IP`, `REPO_NAME`.
- Produces: `hermes-host` health verdict via SSH (no HTTP poll).

- [ ] **Step 1: Edit the health URL table** (lines 32-36) — add a row:

```markdown
| Recipe | Health check URL |
|--------|-----------------|
| `hermes-agent` | `https://${PUBLIC_IP}.nip.io/health` |
| `waha` | `https://${PUBLIC_IP}.nip.io/api/health` |
| `hermes-host` | sem endpoint HTTP — checagem via SSH (passo 2b) |
```

- [ ] **Step 2: Add subsection 2b** after the polling step (after line 60):

```markdown
### 2b. `hermes-host` — check via SSH (no HTTP endpoint)

`hermes-host` does not expose a web service. Instead of the HTTP poller:

```bash
ssh -i "$HOME/.ssh/cw-${REPO_NAME}" -o StrictHostKeyChecking=accept-new \
  root@"$PUBLIC_IP" \
  "hermes --version && systemctl is-active hermes-gateway"
```

Exit 0 means installed and gateway active. On failure go to section 4.
```

- [ ] **Step 3: Edit section 4** — note the diagnose path for `hermes-host` (after the `diagnose.sh` intro, lines 79-82):

```markdown
For `hermes-host`, `diagnose.sh` (docker) does not apply — the recipe has no
containers. Diagnose via systemd instead:
```bash
ssh -i "$HOME/.ssh/cw-${REPO_NAME}" -o StrictHostKeyChecking=accept-new \
  root@"$PUBLIC_IP" "journalctl -u hermes-gateway -n 50 --no-pager && hermes --version"
```
```

- [ ] **Step 4: Verify**

```bash
bash tests/scripts/test-scripts.sh
```

Expected: PASS (the `monitor hermes-host` assertion now matches).

---

### Task 6: Version 1.5.0 + stamp + README

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `README.md` (receitas table)
- Test: `tests/scripts/test-scripts.sh` (existing version-marker assertion)

- [ ] **Step 1: Bump the version**

`.claude-plugin/plugin.json` → `"version": "1.5.0"`.

- [ ] **Step 2: Run the stamp script**

```bash
bash scripts/stamp-version.sh
```

Expected: prints the pre-flight skill was stamped with `1.5.0` and that all existing recipe `Dockerfile`s now pin `:1.5.0` (hermes-agent and waha — there is no hermes-host Dockerfile, loop skips it).

- [ ] **Step 3: Update README receitas table** (lines 7-11) — the current first row links the stale `cloud-weaver-hermes` name and describes WAHA:

```markdown
| Receita | Descrição | Status |
|---------|-----------|--------|
| Hermes Agent (Docker + terminal web) | Agente Telegram + LLM | ✅ disponível |
| Hermes Agent (host direto) | Agente Telegram + LLM instalado no host (sem Docker) | ✅ disponível |
| WAHA | Agente WhatsApp (WAHA) + PostgreSQL | ✅ disponível |
| Coolify | PaaS self-hosted | 🔜 em breve |
| Jitsi Meet | Servidor de videoconferência | 🔜 em breve |
```

- [ ] **Step 4: Verify**

```bash
bash tests/scripts/test-scripts.sh
```

Expected: the pre-existing `marker == plugin.json` assertion passes with the new `1.5.0`.

---

### Task 7: Full verification

**Files:** none.

- [ ] **Step 1: Run the whole offline suite**

```bash
bash tests/scripts/test-repo-setup.sh
bash tests/scripts/test-scripts.sh
bash tests/scripts/test-monitor.sh
```

Expected: every script prints `0 failed` and exits 0.

- [ ] **Step 2: Confirm generated output shape end-to-end**

```bash
OUT=$(mktemp -d)
python3 skills/cloud-weaver-repo-setup/scripts/gen-recipe.py \
  --recipe hermes-host --output-dir "$OUT" --zone ZP01 --web-plan medium \
  --telegram-user-id 987654321 --repo-name meu-hermes-host
find "$OUT" -type f | sort
rm -rf "$OUT"
```

Expected file list (exactly):

```
.github/workflows/deploy.yml
.github/workflows/teardown.yml
teardown.py
```

- [ ] **Step 3: Grep for regressions across the tree**

```bash
git status --short
```

Expected: only the intended files modified/created in this plan are listed (plus this plan and its spec). If `git status` shows unexpected files, review before continuing.

---

## Manual smoke test (not automated — human, requires real Locaweb Cloud account)

Done after the automated suite, following spec Q1-Q4:

- [ ] Provision a real `hermes-host` run through a participant repo; the `deploy` job must:
  - run the official installer to completion (5-15 min);
  - leave `/root/.hermes/.env` with a real `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USERS`;
  - start the gateway (record the exact systemd unit name — spec Q1) and pass the Verify step.
- [ ] Confirm a Telegram message from the allowed user ID reaches the bot (Q1/Q2: `hermes gateway install` works without TTY; the bot answers).
- [ ] Confirm disk fit within the 20 GB `web_disk_size_gb` (Q3); if the installer fails on disk, bump the template to 30 and re-run Task 1 tests.
- [ ] Confirm Chromium/Playwright install works on the Locaweb base image (Q4); if an OS package is missing, add it to the installer step and re-run Task 1 tests.