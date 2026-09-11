#!/usr/bin/env bash
#
# Deterministic, offline tests for the Hermes Agent recipe deployer. Uses
# --dry-run so nothing is executed over the network; assertions check the
# generated commands, the staged compose/.env files, and the report JSON.
#
#   - input validation: env_name/ip/port/ssh-key/skip-secrets conflicts
#   - first deploy: staging dir has .env (600) + compose + initdb, every
#     expected SSH/SCP/docker command is generated, no secret leaks to stdout
#   - idempotency: --skip-secrets reuses the remote .env (no .env generated,
#     no .env scp'd), and re-runs produce identical command plans
#   - bundled compose: waha + pg services, health checks, /data mounts
#
# Usage: tests/scripts/test-hermes.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

SCRIPT="$REPO/../skills/cloud-recipes-hermes/scripts/deploy-hermes.py"
COMPOSE="$REPO/../skills/cloud-recipes-hermes/scripts/compose/compose.yaml"
INITDB="$REPO/../skills/cloud-recipes-hermes/scripts/initdb.sql"
PYTHON="$(command -v python3)"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# deploy_run <name> <staging-dir> [extra args...] — dry-run the deployer.
deploy_run() {
  local name="$1" stage="$2"; shift 2
  "$PYTHON" "$SCRIPT" --env-name hermes --public-ip 200.1.2.3 \
    --ssh-private-key "$BASE/m3key" --api-port 3000 \
    --staging-dir "$stage" --output "$BASE/$name.report.json" --dry-run "$@" \
    >"$BASE/$name.out" 2>&1
  printf '%s' "$?" >"$BASE/$name.rc"
}

echo "== hermes: script compiles =="
expect "deploy-hermes.py compiles" "$PYTHON" -m py_compile "$SCRIPT"
expect "shebang python3"           file_contains "$SCRIPT" "env python3"

echo "== hermes: input validation =="
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQQQQ test@example.com" > "$BASE/m3key"
chmod 600 "$BASE/m3key"

"$PYTHON" "$SCRIPT" --env-name "Bad Name" --public-ip 200.1.2.3 \
  --ssh-private-key "$BASE/m3key" --dry-run >"$BASE/v1.out" 2>&1
expect "rejects invalid env_name"  test $? != 0
expect "FATAL invalid env_name"    file_contains "$BASE/v1.out" "only lowercase letters"

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip "not-an-ip" \
  --ssh-private-key "$BASE/m3key" --dry-run >"$BASE/v2.out" 2>&1
expect "rejects invalid ip"        test $? != 0
expect "FATAL invalid ip"          file_contains "$BASE/v2.out" "does not appear to be an IPv4"

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 200.1.2.3 \
  --ssh-private-key "$BASE/missing-key" --dry-run >"$BASE/v3.out" 2>&1
expect "rejects missing key"       test $? != 0
expect "FATAL missing key"         file_contains "$BASE/v3.out" "SSH private key not found"

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 200.1.2.3 \
  --ssh-private-key "$BASE/m3key" --api-port 70000 --dry-run >"$BASE/v4.out" 2>&1
expect "rejects invalid port"      test $? != 0
expect "FATAL invalid port"        file_contains "$BASE/v4.out" "between 1 and 65535"

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 200.1.2.3 \
  --ssh-private-key "$BASE/m3key" --dry-run --skip-secrets \
  --postgres-password "x" >"$BASE/v5.out" 2>&1
expect "rejects skip-secrets+override" test $? != 0
expect "FATAL skip-secrets conflict"   file_contains "$BASE/v5.out" "cannot be combined"

echo "== hermes: first deploy (fresh .env) =="
deploy_run d1 "$BASE/stage-d1"
expect "exit 0"                        test "$(cat "$BASE/d1.rc")" = 0
expect "report file written"           test -f "$BASE/d1.report.json"

expect "mkdir data dirs"               file_contains "$BASE/d1.out" "sudo mkdir -p /data/hermes/compose /data/hermes/waha /data/hermes/pgdata"
expect "chown pgdata to uid 999"       file_contains "$BASE/d1.out" "sudo chown -R 999:999 /data/hermes/pgdata"
for f in compose.yaml initdb.sql .env; do
  expect "scp $f"                      file_contains "$BASE/d1.out" "$f ubuntu@200.1.2.3:/data/hermes/compose/$f"
done
expect "env 600 on host"               file_contains "$BASE/d1.out" "sudo chmod 600 /data/hermes/compose/.env"
expect "compose up --wait"             file_contains "$BASE/d1.out" "docker compose -p hermes-hermes -f compose.yaml --env-file .env up -d --wait --wait-timeout 180"

expect "stage .env exists"             test -f "$BASE/stage-d1/.env"
expect "stage .env mode 600"           test "$(stat -c '%a' "$BASE/stage-d1/.env")" = "600"
expect "stage compose.yaml exists"     test -f "$BASE/stage-d1/compose.yaml"
expect "stage initdb.sql exists"       test -f "$BASE/stage-d1/initdb.sql"
expect ".env has POSTGRES_USER"        file_contains "$BASE/stage-d1/.env" "POSTGRES_USER=hermes"
expect ".env has POSTGRES_DB"          file_contains "$BASE/stage-d1/.env" "POSTGRES_DB=hermes"
expect ".env has WAHA_PORT"            file_contains "$BASE/stage-d1/.env" "WAHA_PORT=3000"
for var in WAHA_API_KEY WAHA_DASHBOARD_PASSWORD WHATSAPP_SWAGGER_PASSWORD POSTGRES_PASSWORD; do
  expect ".env has $var key"           file_contains "$BASE/stage-d1/.env" "$var="
done
PGPW="$(grep '^POSTGRES_PASSWORD=' "$BASE/stage-d1/.env" | cut -d= -f2)"
expect "postgres password non-trivial" test "$(printf '%s' "$PGPW" | wc -c)" -ge 32

# Secrets must never leak into command output (which the agent turns into
# user-visible status / debug text).
refute "no WAHA_API_KEY leak in output"   file_contains "$BASE/d1.out" "$(grep '^WAHA_API_KEY=' "$BASE/stage-d1/.env" | cut -d= -f2)"
refute "no POSTGRES_PASSWORD leak"        file_contains "$BASE/d1.out" "$PGPW"

echo "== hermes: explicit secrets also stay out of output =="
"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 200.1.2.3 \
  --ssh-private-key "$BASE/m3key" --staging-dir "$BASE/stage-d2" \
  --postgres-password "PG-SECRET-DEADBEEF" --waha-api-key "API-DEADBEEF" \
  --dashboard-password "DASH-DEADBEEF" --swagger-password "SWAG-DEADBEEF" \
  --dry-run --output "$BASE/d2.report.json" >"$BASE/d2.out" 2>&1
expect "exit 0 with explicit secrets"    test $? = 0
for leak in PG-SECRET-DEADBEEF API-DEADBEEF DASH-DEADBEEF SWAG-DEADBEEF; do
  refute "no $leak in output"            file_contains "$BASE/d2.out" "$leak"
done

echo "== hermes: idempotency (--skip-secrets) =="
deploy_run i1 "$BASE/stage-i1" --skip-secrets
expect "exit 0"                          test "$(cat "$BASE/i1.rc")" = 0
refute "no .env generated"               test -f "$BASE/stage-i1/.env"
refute "no .env scp'd"                   file_contains "$BASE/i1.out" "compose/.env"
refute "no chmod 600 step"               file_contains "$BASE/i1.out" "chmod 600"
expect "compose still up'd"              file_contains "$BASE/i1.out" "docker compose -p hermes-hermes"
expect "report still written"            test -f "$BASE/i1.report.json"

echo "== hermes: re-runs have deterministic command plan =="
deploy_run r1 "$BASE/stage-r"
deploy_run r2 "$BASE/stage-r"
cmd_d1="$(grep '^CMD ' "$BASE/r1.out")"
cmd_r2="$(grep '^CMD ' "$BASE/r2.out")"
expect "identical commands across re-runs" test "$cmd_d1" = "$cmd_r2"

echo "== hermes: bundled compose =="
expect "waha service"                  file_contains "$COMPOSE" "devlikeapro/waha:latest"
expect "pg service"                    file_contains "$COMPOSE" "postgres:17-bookworm"
expect "waha ports mapping"            file_contains "$COMPOSE" '${WAHA_PORT}:3000'
expect "waha sessions volume"          file_contains "$COMPOSE" "../waha:/app/.sessions"
expect "pgdata volume"                 file_contains "$COMPOSE" "../pgdata:/var/lib/postgresql/data"
expect "pg healthcheck"                file_contains "$COMPOSE" "pg_isready"
expect "waha healthcheck"              file_contains "$COMPOSE" "/api/health"
expect "pg dependency gated"           file_contains "$COMPOSE" "service_healthy"
expect "initdb creates waha db"        file_contains "$INITDB" "CREATE DATABASE waha;"

summary "hermes"