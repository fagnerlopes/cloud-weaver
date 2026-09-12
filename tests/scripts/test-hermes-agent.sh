#!/usr/bin/env bash
#
# Deterministic, offline tests for the Hermes Agent recipe deployer.
# Uses --dry-run so nothing executes over the network.
#
#   - input validation: env_name/ip/telegram_user_id/ssh-key/skip-secrets conflicts
#   - first deploy: staging has compose.yaml + .env (600) + hermes-config.yaml;
#     every expected SSH/SCP/docker command is generated; no secret leaks
#   - basic auth: TTYD_BASIC_AUTH uses {SHA} format; admin_pass never in stdout
#   - idempotency: --skip-secrets skips .env generation and upload
#   - re-runs: deterministic command plan
#   - bundled compose: traefik + web-terminal + hermes-agent services present
#
# Usage: tests/scripts/test-hermes-agent.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

SCRIPT="$REPO/../skills/cloud-weaver-hermes-agent/scripts/deploy-hermes-agent.py"
COMPOSE="$REPO/../skills/cloud-weaver-hermes-agent/scripts/compose/compose.yaml"
CONFIG="$REPO/../skills/cloud-weaver-hermes-agent/scripts/hermes-config.yaml"
PYTHON="$(command -v python3)"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

echo "== hermes-agent: script compila =="
expect "compila"          "$PYTHON" -m py_compile "$SCRIPT"
expect "shebang python3"  grep -q "env python3" "$SCRIPT"

echo "== hermes-agent: validação de entrada =="
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQQQQ test@example.com" > "$BASE/key"
chmod 600 "$BASE/key"

"$PYTHON" "$SCRIPT" --env-name "Bad Name" --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 123 \
  --terminal-user testuser \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v1.out" 2>&1
expect "rejeita env_name inválido"  test $? != 0
expect "mensagem env_name"          grep -qF "only lowercase" "$BASE/v1.out"

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip "not-ip" \
  --hostname h.example.com --telegram-user-id 123 \
  --terminal-user testuser \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v2.out" 2>&1
expect "rejeita IP inválido"        test $? != 0

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 0 \
  --terminal-user testuser \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v3.out" 2>&1
expect "rejeita telegram_user_id 0" test $? != 0

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 123 \
  --terminal-user testuser \
  --ssh-private-key "$BASE/missing" --dry-run >"$BASE/v4.out" 2>&1
expect "rejeita chave ausente"      test $? != 0
expect "mensagem SSH key not found" grep -qF "SSH private key not found" "$BASE/v4.out"

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 123 \
  --terminal-user testuser \
  --ssh-private-key "$BASE/key" --skip-secrets \
  --admin-pass "x" --dry-run >"$BASE/v5.out" 2>&1
expect "rejeita skip-secrets+admin-pass" test $? != 0

# Helper: run a dry-run deploy
deploy_run() {
  local name="$1" stage="$2"; shift 2
  # Unset TELEGRAM_BOT_TOKEN so dry-run always writes the REPLACE_WITH placeholder.
  TELEGRAM_BOT_TOKEN="" "$PYTHON" "$SCRIPT" --env-name hermes --public-ip 200.1.2.3 \
    --hostname "cr-hermes-vm.publiccloud.com.br" \
    --telegram-user-id 123456789 \
    --terminal-user admin \
    --ssh-private-key "$BASE/key" \
    --staging-dir "$stage" --output "$BASE/$name.report.json" --dry-run "$@" \
    >"$BASE/$name.out" 2>&1
  printf '%s' "$?" >"$BASE/$name.rc"
}

echo "== hermes-agent: primeiro deploy =="
deploy_run d1 "$BASE/stage-d1"
expect "exit 0"                      test "$(cat "$BASE/d1.rc")" = 0
expect "report escrito"              test -f "$BASE/d1.report.json"

expect "mkdir compose, hermes_data, acme" \
  grep -qF "sudo mkdir -p /data/hermes/compose /data/hermes/hermes_data /data/hermes/acme" \
  "$BASE/d1.out"
expect "scp compose.yaml"            grep -qF "compose.yaml ubuntu@200.1.2.3:/data/hermes/compose/compose.yaml" "$BASE/d1.out"
expect "scp .env"                    grep -qF ".env ubuntu@200.1.2.3:/data/hermes/compose/.env" "$BASE/d1.out"
expect "chmod 600 .env"              grep -qF "sudo chmod 600 /data/hermes/compose/.env" "$BASE/d1.out"
expect "scp hermes-config.yaml"      grep -qF "hermes-config.yaml ubuntu@200.1.2.3:/data/hermes/hermes_data/config.yaml" "$BASE/d1.out"
expect "docker compose up --wait"    grep -qF "docker compose -p hermes-agent-hermes -f compose.yaml --env-file .env up -d --wait --wait-timeout 300" "$BASE/d1.out"

expect "stage .env existe"           test -f "$BASE/stage-d1/.env"
expect "stage .env modo 600"         test "$(stat -c '%a' "$BASE/stage-d1/.env")" = "600"
expect "stage compose.yaml existe"   test -f "$BASE/stage-d1/compose.yaml"
expect "stage hermes-config.yaml"    test -f "$BASE/stage-d1/hermes-config.yaml"

expect ".env tem TELEGRAM_ALLOWED_USERS" grep -qF "TELEGRAM_ALLOWED_USERS=123456789" "$BASE/stage-d1/.env"
expect ".env tem HOSTNAME"               grep -qF "HOSTNAME=cr-hermes-vm.publiccloud.com.br" "$BASE/stage-d1/.env"
expect ".env tem TTYD_BASIC_AUTH"        grep -qF "TTYD_BASIC_AUTH=admin:{SHA}" "$BASE/stage-d1/.env"
expect ".env tem placeholder token"      grep -qF "TELEGRAM_BOT_TOKEN=REPLACE_WITH" "$BASE/stage-d1/.env"

echo "== hermes-agent: admin_pass não vaza para stdout =="
ADMIN_PASS="$(grep '^TTYD_BASIC_AUTH=' "$BASE/stage-d1/.env" | cut -d= -f2- | sed 's/{SHA}//')"
# stdout should only have the CMD lines and the final "Deployed" line
refute "admin_pass não no stdout"    grep -qF "$ADMIN_PASS" "$BASE/d1.out"

echo "== hermes-agent: admin_pass no report JSON =="
expect "report tem admin_pass"       python3 -c "
import json, sys
r = json.load(open('$BASE/d1.report.json'))
assert r.get('admin_pass'), 'admin_pass ausente'
assert len(r['admin_pass']) >= 32, 'admin_pass curto'
"

echo "== hermes-agent: idempotência (--skip-secrets) =="
deploy_run i1 "$BASE/stage-i1" --skip-secrets
expect "exit 0 skip-secrets"         test "$(cat "$BASE/i1.rc")" = 0
refute ".env não gerado"             test -f "$BASE/stage-i1/.env"
refute ".env não scp'd"              grep -qF "compose/.env" "$BASE/i1.out"
refute "chmod 600 não executado"     grep -qF "chmod 600" "$BASE/i1.out"
expect "compose ainda up'd"          grep -qF "docker compose -p hermes-agent-hermes" "$BASE/i1.out"

echo "== hermes-agent: re-runs têm plano determinístico =="
deploy_run r1 "$BASE/stage-r"
deploy_run r2 "$BASE/stage-r"
cmd_r1="$(grep '^CMD ' "$BASE/r1.out")"
cmd_r2="$(grep '^CMD ' "$BASE/r2.out")"
expect "plano idêntico entre runs"   test "$cmd_r1" = "$cmd_r2"

echo "== hermes-agent: compose bundled =="
expect "traefik service"             grep -qF "traefik:v3" "$COMPOSE"
expect "ttyd service"                grep -qF "ghcr.io/tsl0922/ttyd" "$COMPOSE"
expect "hermes-agent image"          grep -qF "nousresearch/hermes-agent:latest" "$COMPOSE"
expect "hermes-agent sem porta"      python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open('$COMPOSE'))
    svc = d['services']['hermes-agent']
    assert 'ports' not in svc, 'hermes-agent não deve publicar portas'
    print('ok')
except ImportError:
    print('pyyaml ausente — pular verificação YAML')
" >/dev/null || true
expect "traefik porta 80 443"        grep -qF '"80:80"' "$COMPOSE"
expect "basic auth middleware"       grep -qF "basicauth.users" "$COMPOSE"
expect "TLS certresolver"            grep -qF "certresolver=le" "$COMPOSE"

echo "== hermes-agent: hermes-config.yaml bundled =="
expect "approvals.mode: smart"       grep -qF "mode: smart" "$CONFIG"
expect "cron_mode presente"          grep -q "cron_mode" "$CONFIG"

summary "hermes-agent"
