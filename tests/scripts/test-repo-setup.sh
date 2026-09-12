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

summary "repo-setup"
