---
name: cloud-weaver-repo-setup
description: >
  Creates a GitHub repository for the recipe, generates Kamal + GHA workflow
  files, sets secrets, and triggers the deploy pipeline. Invoke after the
  user has confirmed the configuration in start-cloud Step 4.
---

# Repo Setup

This skill orchestrates the full repository setup for a CloudWeaver recipe.
Follow the steps in order. All commands run in the staging directory unless
specified otherwise.

---

## Step 1 — Verify pre-conditions

Confirm GitHub CLI is authenticated:

```bash
gh auth status
```

If it fails, stop and tell the user (in PT-BR): "Execute `gh auth login` no
terminal e inicie uma nova sessão."

Check that infra credentials are present (presence only — never print values):

```bash
[[ -z "${LOCAWEB_API_KEY:-}"    ]] && echo "MISSING: LOCAWEB_API_KEY"
[[ -z "${LOCAWEB_API_SECRET:-}" ]] && echo "MISSING: LOCAWEB_API_SECRET"
```

For hermes-agent: also check `TELEGRAM_BOT_TOKEN`.

If any credential is missing, stop and tell the user which env var to export
in their OS terminal. **Never accept values in the conversation.**

---

## Step 2 — Generate SSH key

Generate a dedicated Ed25519 key for this deployment (one key per repository):

```bash
SSH_KEY="$HOME/.ssh/cw-${REPO_NAME}"
if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "cloudweaver-${REPO_NAME}"
  echo "SSH key generated: $SSH_KEY"
else
  echo "SSH key already exists: $SSH_KEY"
fi
```

Replace `${REPO_NAME}` with the actual repository name collected in start-cloud.
Never display or log the private key content.

---

## Step 3 — Generate recipe files into a staging directory

Locate this skill's directory from the skill's own path (not from the
current working directory). Then run gen-recipe.py:

```bash
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# or, when invoked by an agent: resolve relative to this SKILL.md file.

STAGE_DIR="$(mktemp -d)"

python3 "$SKILL_DIR/scripts/gen-recipe.py" \
  --recipe     "$RECIPE" \
  --output-dir "$STAGE_DIR" \
  --zone        "$ZONE" \
  --web-plan    "$WEB_PLAN" \
  --repo-name   "$REPO_NAME" \
  [--telegram-user-id "$TELEGRAM_USER_ID"]
  # ^ include --telegram-user-id for hermes-agent only
```

Variables come from start-cloud Step 3:
- `RECIPE` — `hermes-agent` or `waha`
- `REPO_NAME` — chosen repository name (e.g. `meu-hermes`)
- `ZONE` — `ZP01` or `ZP02`
- `WEB_PLAN` — `small`, `medium`, etc.
- `TELEGRAM_USER_ID` — Telegram user ID (hermes-agent only)

If gen-recipe.py exits non-zero, show the error output and stop.

---

## Step 4 — Initialize git and create GitHub repo

```bash
cd "$STAGE_DIR"
python3 "$SKILL_DIR/scripts/repo-init.py" "$REPO_NAME" private
```

This creates a private GitHub repo under the authenticated user's account,
commits all generated files, and pushes. If the repo already exists, it
reuses it idempotently.

---

## Step 5 — Set GitHub Secrets

Set secrets from environment variables. Resolve the full `owner/repo`
reference from `gh api user`:

```bash
GITHUB_LOGIN="$(gh api user --jq .login)"
FULL_REPO="${GITHUB_LOGIN}/${REPO_NAME}"
```

### Infra secrets (all recipes):

```bash
SSH_KEY_CONTENT="$(cat "$HOME/.ssh/cw-${REPO_NAME}")"
gh secret set LOCAWEB_API_KEY    --repo "$FULL_REPO" <<< "$LOCAWEB_API_KEY"
gh secret set LOCAWEB_API_SECRET --repo "$FULL_REPO" <<< "$LOCAWEB_API_SECRET"
gh secret set SSH_PRIVATE_KEY    --repo "$FULL_REPO" <<< "$SSH_KEY_CONTENT"
```

### Recipe-specific secrets:

**hermes-agent:**
```bash
gh secret set TELEGRAM_BOT_TOKEN --repo "$FULL_REPO" <<< "$TELEGRAM_BOT_TOKEN"
```

**waha:**
```bash
# Generate and store strong secrets (never display values in chat)
POSTGRES_PASSWORD="$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")"
WAHA_API_KEY="$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")"
gh secret set POSTGRES_PASSWORD --repo "$FULL_REPO" <<< "$POSTGRES_PASSWORD"
gh secret set WAHA_API_KEY      --repo "$FULL_REPO" <<< "$WAHA_API_KEY"
# Save generated secrets to a 0600 file for the final report — not in the conversation.
REPORT_FILE="$HOME/.cloud-weaver-${REPO_NAME}-report.json"
python3 -c "
import json, os
data = {'postgres_password': '$POSTGRES_PASSWORD', 'waha_api_key': '$WAHA_API_KEY'}
open('$REPORT_FILE', 'w').write(json.dumps(data, indent=2))
os.chmod('$REPORT_FILE', 0o600)
"
```

After setting all secrets, confirm to the user (count only, no names/values):

> ✅ N secrets configurados no repositório.

---

## Step 6 — Trigger the workflow

```bash
cd "$STAGE_DIR"
gh workflow run deploy.yml --repo "$FULL_REPO"
sleep 5
RUN_ID=$(gh run list --repo "$FULL_REPO" --workflow deploy.yml \
  --limit 1 --json databaseId --jq '.[0].databaseId')
echo "Pipeline iniciado — Run ID: $RUN_ID"
```

---

## Step 7 — Monitor progress

Watch the workflow and display progress as STEP: bullets:

```bash
gh run watch "$RUN_ID" --repo "$FULL_REPO" --exit-status
```

Display status as each job changes:
- ⏳ `infra` — provisionando VM na Locaweb Cloud...
- ✅ `infra` — VM provisionada
- ⏳ `deploy` — fazendo deploy com Kamal...
- ✅ `deploy` — deploy concluído

On failure: run the following and show the full output to the user:
```bash
gh run view "$RUN_ID" --repo "$FULL_REPO" --log-failed
```

---

## Step 8 — Extract public IP and return to start-cloud

```bash
PUBLIC_IP=$(gh run view "$RUN_ID" --repo "$FULL_REPO" --log \
  | grep "INFRA_WEB_IP=" | tail -1 | cut -d= -f2 | tr -d ' \r\n')
echo "PUBLIC_IP=$PUBLIC_IP"
```

Return to start-cloud:
- `PUBLIC_IP` — the VM's public IP address
- `APP_URL` — `https://${PUBLIC_IP}.nip.io`
- `REPO_URL` — `https://github.com/${FULL_REPO}`
- `SSH_KEY` — path to the generated key (`~/.ssh/cw-${REPO_NAME}`)

---

## Security rules

- Secrets never appear in the conversation, log output, or commits.
- Private key content is read into a variable only when needed to set the GitHub Secret — never echoed or logged.
- The `~/.cloud-weaver-${REPO_NAME}-report.json` file is `0600` and is deleted after the final report is shown.
- SSH keys are `0600` (created by `ssh-keygen -N ""`).
