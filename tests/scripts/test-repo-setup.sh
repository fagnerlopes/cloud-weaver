#!/usr/bin/env bash
#
# Offline tests for gen-recipe.py — no network calls, no GitHub auth.
# Verifies that recipe files are generated correctly from templates.
#
# Usage: tests/scripts/test-repo-setup.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

SCRIPT="$REPO/../skills/cloud-weaver-repo-setup/scripts/gen-recipe.py"
PYTHON="$(command -v python3)"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

echo "== gen-recipe: script compila =="
expect "compila" "$PYTHON" -m py_compile "$SCRIPT"
expect "shebang python3" grep -q "env python3" "$SCRIPT"

echo "== gen-recipe: hermes-agent — geração básica =="
"$PYTHON" "$SCRIPT" \
    --recipe hermes-agent \
    --output-dir "$BASE/ha" \
    --zone ZP01 \
    --web-plan small \
    --telegram-user-id 987654321 \
    --repo-name meu-hermes \
    >"$BASE/ha.out" 2>&1
expect "exit 0 hermes-agent" test $? = 0

expect "Dockerfile gerado"              test -f "$BASE/ha/Dockerfile"
expect "deploy.yml gerado"              test -f "$BASE/ha/.github/workflows/deploy.yml"
expect "config/deploy.yml gerado"       test -f "$BASE/ha/config/deploy.yml"
expect "config/deploy.preview.yml"      test -f "$BASE/ha/config/deploy.preview.yml"
expect "kamal secrets-common"           test -f "$BASE/ha/.kamal/secrets-common"
expect "kamal secrets.preview"          test -f "$BASE/ha/.kamal/secrets.preview"

# Variables must be substituted
expect "zona no workflow"               grep -q "ZP01" "$BASE/ha/.github/workflows/deploy.yml"
expect "web-plan no workflow"           grep -q "small" "$BASE/ha/.github/workflows/deploy.yml"
expect "telegram user no config"        grep -q "987654321" "$BASE/ha/config/deploy.preview.yml"
expect "pre-built image no Dockerfile"  grep -q "ghcr.io/fagnerlopes/cw-hermes-agent" "$BASE/ha/Dockerfile"

# GHA expressions must survive unaltered
expect "GHA secrets.LOCAWEB_API_KEY intacto" \
    grep -q 'secrets.LOCAWEB_API_KEY' "$BASE/ha/.github/workflows/deploy.yml"
expect "GHA secrets.GITHUB_TOKEN intacto" \
    grep -q 'secrets.GITHUB_TOKEN' "$BASE/ha/.github/workflows/deploy.yml"

# No leftover @[...] placeholders
refute "sem placeholders no Dockerfile" grep -q '@\[' "$BASE/ha/Dockerfile"
refute "sem placeholders no workflow"   grep -q '@\[' "$BASE/ha/.github/workflows/deploy.yml"

echo "== gen-recipe: waha — geração básica =="
"$PYTHON" "$SCRIPT" \
    --recipe waha \
    --output-dir "$BASE/waha" \
    --zone ZP02 \
    --web-plan medium \
    --repo-name meu-waha \
    >"$BASE/waha.out" 2>&1
expect "exit 0 waha" test $? = 0

expect "Dockerfile waha"                test -f "$BASE/waha/Dockerfile"
expect "waha zona ZP02"                 grep -q "ZP02" "$BASE/waha/.github/workflows/deploy.yml"
expect "waha accessory pg no workflow"  grep -q '"name":"pg"' "$BASE/waha/.github/workflows/deploy.yml"
expect "waha pre-built image"           grep -q "ghcr.io/fagnerlopes/cw-waha" "$BASE/waha/Dockerfile"
refute "sem placeholders waha workflow" grep -q '@\[' "$BASE/waha/.github/workflows/deploy.yml"

echo "== gen-recipe: validações =="
"$PYTHON" "$SCRIPT" --recipe invalid-recipe --output-dir "$BASE/bad" \
    --zone ZP01 --web-plan small --repo-name x 2>"$BASE/bad.err" || true
expect "rejeita receita inválida" grep -q "Unknown recipe" "$BASE/bad.err"

"$PYTHON" "$SCRIPT" --recipe hermes-agent --output-dir "$BASE/bad2" \
    --zone ZP01 --web-plan small --telegram-user-id 0 --repo-name x \
    2>"$BASE/bad2.err" || true
expect "rejeita telegram-user-id 0" grep -q "telegram-user-id" "$BASE/bad2.err"

echo "== gen-recipe: idempotência =="
"$PYTHON" "$SCRIPT" \
    --recipe hermes-agent \
    --output-dir "$BASE/ha" \
    --zone ZP01 \
    --web-plan small \
    --telegram-user-id 987654321 \
    --repo-name meu-hermes \
    >"$BASE/ha2.out" 2>&1
expect "exit 0 re-run" test $? = 0
expect "Dockerfile ainda lá" test -f "$BASE/ha/Dockerfile"

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
refute "sem kamal no workflow"        bash -c "grep -qi 'kamal' '$BASE/hh/.github/workflows/deploy.yml'"
refute "sem ghcr no workflow"         grep -q "ghcr.io" "$BASE/hh/.github/workflows/deploy.yml"

expect "token via env var"            grep -qF '"$TELEGRAM_BOT_TOKEN"' "$BASE/hh/.github/workflows/deploy.yml"
expect "token via scp 0600"           grep -q "cw-env-append" "$BASE/hh/.github/workflows/deploy.yml"
expect "TELEGRAM_ALLOWED_USERS"       grep -q "TELEGRAM_ALLOWED_USERS" "$BASE/hh/.github/workflows/deploy.yml"

expect "GHA locaweb secrets intactos" grep -q 'secrets.LOCAWEB_API_KEY' "$BASE/hh/.github/workflows/deploy.yml"
expect "GHA ssh-agent intacto"        grep -q 'webfactory/ssh-agent' "$BASE/hh/.github/workflows/deploy.yml"
refute "sem placeholders hermes-host" grep -q '@\[' "$BASE/hh/.github/workflows/deploy.yml"

echo "== gen-recipe: hermes-host — terminal do agente isolado via Docker =="
DEPLOY="$BASE/hh/.github/workflows/deploy.yml"
expect "docker repo oficial"        grep -q "download.docker.com/linux/ubuntu" "$DEPLOY"
expect "docker-ce instalado"        grep -q "docker-ce docker-ce-cli containerd.io" "$DEPLOY"
refute "sem snap install"           grep -q "snap install docker" "$DEPLOY"
refute "sem pacote docker.io"       grep -q "docker.io" "$DEPLOY"
expect "backend docker configurado" grep -q "hermes config set terminal.backend docker" "$DEPLOY"
expect "limite cpu no sandbox"      grep -q "terminal.container_cpu 2" "$DEPLOY"
expect "limite mem no sandbox"      grep -q "terminal.container_memory 4096" "$DEPLOY"
expect "docker info na validacao"   grep -q "docker info" "$DEPLOY"
expect "verifica backend na validacao" grep -q "hermes config get terminal.backend" "$DEPLOY"

echo "== gen-recipe: hermes-host — telegram obrigatório =="
"$PYTHON" "$SCRIPT" --recipe hermes-host --output-dir "$BASE/bad3" \
    --zone ZP01 --web-plan small --repo-name x \
    2>"$BASE/bad3.err" || true
expect "rejeita hermes-host sem telegram" grep -q "telegram-user-id" "$BASE/bad3.err"

echo "== gen-recipe: docs de bootstrap (README, AGENTS, CLAUDE) =="
expect "README.md gerado hermes-host"      test -f "$BASE/hh/README.md"
expect "AGENTS.md gerado hermes-host"      test -f "$BASE/hh/AGENTS.md"
expect "CLAUDE.md gerado hermes-host"      test -f "$BASE/hh/CLAUDE.md"
expect "README.md gerado hermes-agent"     test -f "$BASE/ha/README.md"
expect "README.md gerado waha"             test -f "$BASE/waha/README.md"
expect "repo name no README"               grep -q "meu-hermes-host" "$BASE/hh/README.md"
expect "curl install.sh no README"         grep -qF "curl -fsSL https://cloudweaver.fagnerlopes.dev/install.sh | bash" "$BASE/hh/README.md"
expect "irm install.ps1 no README"         grep -qF "irm https://cloudweaver.fagnerlopes.dev/install.ps1 | iex" "$BASE/hh/README.md"
expect "bloco AGENTS igual installer"      grep -qF "npx -y skills add fagnerlopes/cloud-weaver --agent universal claude-code codex opencode hermes-agent --skill '*' -y" "$BASE/hh/AGENTS.md"
expect "marker begin no AGENTS"            grep -qF "<!-- cloud-weaver:begin -->" "$BASE/hh/AGENTS.md"
expect "marker end no AGENTS"              grep -qF "<!-- cloud-weaver:end -->" "$BASE/hh/AGENTS.md"
expect "CLAUDE aponta AGENTS"              grep -qF "@AGENTS.md" "$BASE/hh/CLAUDE.md"
refute "sem placeholders no README"        grep -q '@\[' "$BASE/hh/README.md"
refute "sem placeholders no AGENTS"        grep -q '@\[' "$BASE/hh/AGENTS.md"
expect "docs ignoradas no deploy hh"       grep -qF '"README.md", "AGENTS.md", "CLAUDE.md"' "$BASE/hh/.github/workflows/deploy.yml"
expect "docs ignoradas no deploy ha"       grep -qF '"README.md", "AGENTS.md", "CLAUDE.md"' "$BASE/ha/.github/workflows/deploy.yml"
expect "docs ignoradas no deploy waha"     grep -qF '"README.md", "AGENTS.md", "CLAUDE.md"' "$BASE/waha/.github/workflows/deploy.yml"

summary "repo-setup"
