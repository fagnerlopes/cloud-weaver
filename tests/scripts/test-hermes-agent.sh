#!/usr/bin/env bash
# Offline tests for deploy-hermes-agent.py — uses --dry-run only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$REPO/lib/assert.sh"

SCRIPT="$REPO/../skills/cloud-weaver-hermes-agent/scripts/deploy-hermes-agent.py"
COMPOSE="$REPO/../skills/cloud-weaver-hermes-agent/scripts/compose/compose.yaml"
PYTHON="$(command -v python3)"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQQQQ test@example.com" > "$BASE/key"
chmod 600 "$BASE/key"

echo "== hermes-agent: script compila =="
expect "compila" "$PYTHON" -m py_compile "$SCRIPT"
expect "shebang python3" grep -q "env python3" "$SCRIPT"

echo "== hermes-agent: validação de entrada =="
"$PYTHON" "$SCRIPT" --env-name "Bad Name" --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 123 \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v1.out" 2>&1
expect "rejeita env_name inválido" test $? != 0
expect "mensagem env_name" grep -qF "only lowercase" "$BASE/v1.out"

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip "not-ip" \
  --hostname h.example.com --telegram-user-id 123 \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v2.out" 2>&1
expect "rejeita IP inválido" test $? != 0

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 0 \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v3.out" 2>&1
expect "rejeita telegram_user_id zero" test $? != 0

summary "hermes-agent (stub)"
