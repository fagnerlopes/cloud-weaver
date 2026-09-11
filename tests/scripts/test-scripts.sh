#!/usr/bin/env bash
#
# Deterministic, offline tests for the cloud-weaver shell scripts, driven in
# throwaway temp dirs on the host. No container, no network, no agent.
#
#   - preflight.sh : sensitive-file guard (block + template exemptions), git
#                    sync with a local bare remote, tool detection, gh auth
#                    check, locaweb credentials presence check.
#   - version marker: skills/cloud-weaver-pre-flight-check/SKILL.md carries a
#                    cloud-weaver marker matching .claude-plugin/plugin.json.
#
# Usage: tests/scripts/test-scripts.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

PREFLIGHT="$REPO/../skills/cloud-weaver-pre-flight-check/scripts/preflight.sh"
BASH_BIN="$(command -v bash)"

# Deterministic git identity so commits work without host config.
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

# Force the locaweb credential flag deterministically regardless of host env.
unset LOCAWEB_API_KEY LOCAWEB_API_SECRET

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
FAKEHOME="$BASE/home"; mkdir -p "$FAKEHOME"
LOG="$BASE/logs"; mkdir -p "$LOG"

# pf <name> <cwd> <home> <path> — run preflight.sh with controlled cwd/HOME/PATH.
pf() {
  ( cd "$2" && HOME="$3" PATH="$4" "$BASH_BIN" "$PREFLIGHT" ) >"$LOG/$1.log" 2>&1
  printf '%s' "$?" >"$LOG/$1.rc"
}
rc() { cat "$LOG/$1.rc"; }

# mkrepo <dir> — git repo with a local bare remote, one commit pushed.
mkrepo() {
  local d="$1" bare="$1.git"
  git init --bare -q -b main "$bare"
  mkdir -p "$d"
  ( cd "$d" && git init -b main -q && git commit --allow-empty -m init -q \
     && git remote add origin "$bare" && git push -u origin main -q )
}

echo "== preflight: version marker matches plugin.json =="
PLUGIN_VERSION=$(jq -r .version "$REPO/../.claude-plugin/plugin.json")
SKILL="$REPO/../skills/cloud-weaver-pre-flight-check/SKILL.md"
expect "marker present"         file_contains "$SKILL" "CLOUD_WEAVER_VERSION"
expect "marker == plugin.json"  bash -c "grep -qF 'CLOUD_WEAVER_VERSION: $PLUGIN_VERSION -->' '$SKILL'"

echo "== preflight: sensitive file guard — untracked secrets block the sync =="
d="$BASE/s1"; mkrepo "$d"
echo "SECRET=abc" >"$d/.env"
echo "SECRET=abc" >"$d/prod.env"
touch "$d/server.key" "$d/id_rsa"
pf s1 "$d" "$FAKEHOME" "$PATH"
expect "exit 1"                       test "$(rc s1)" = 1
expect "SENSITIVE_FILES_DETECTED"     file_contains "$LOG/s1.log" "SENSITIVE_FILES_DETECTED"
for f in .env prod.env server.key id_rsa; do
  expect "lists $f"                   file_contains "$LOG/s1.log" "$f"
done
expect "nothing was committed"        test -z "$(git -C "$d" log --oneline -1 --grep='Auto-sync')"

echo "== preflight: sensitive file guard — templates and lookalikes do not block =="
d="$BASE/s2"; mkrepo "$d"
echo "SECRET=changeme" >"$d/.env.example"
echo "SECRET=changeme" >"$d/prod.env.template"
touch "$d/keyboard.md" "$d/monkey.txt"
pf s2 "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s2.log" "PREFLIGHT_PASSED"
refute "no false positive"            file_contains "$LOG/s2.log" "SENSITIVE_FILES_DETECTED"
expect "committed normally"           file_contains "$LOG/s2.log" "SYNC: Committing local changes..."

echo "== preflight: git repo with remote, clean, creds present =="
d="$BASE/s3"; mkrepo "$d"
pf s3 "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s3.log" "PREFLIGHT_PASSED"
expect "reports up to date"           file_contains "$LOG/s3.log" "SYNC: Repository is up to date."

echo "== preflight: no git — sync skipped, still passes =="
d="$BASE/s4"; mkdir -p "$d"
pf s4 "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s4.log" "PREFLIGHT_PASSED"
refute "no sync attempted"            file_contains "$LOG/s4.log" "SYNC:"

echo "== preflight: dev tools missing =="
d="$BASE/s5"; mkdir -p "$d"
pf s5 "$d" "$FAKEHOME" "/nonexistent"   # hide gh/ssh/jq
expect "NEEDS_COMPUTER_SETUP"         file_contains "$LOG/s5.log" "NEEDS_COMPUTER_SETUP: missing gh ssh jq"
expect "still PREFLIGHT_PASSED"       file_contains "$LOG/s5.log" "PREFLIGHT_PASSED"

echo "== preflight: GitHub CLI not authenticated =="
if command -v gh >/dev/null 2>&1; then
  d="$BASE/s6"; mkdir -p "$d"
  ( cd "$d" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
      GH_CONFIG_DIR="$BASE/empty-gh" HOME="$FAKEHOME" \
      "$BASH_BIN" "$PREFLIGHT" ) >"$LOG/s6.log" 2>&1
  printf '%s' "$?" >"$LOG/s6.rc"
  expect "NEEDS_GITHUB_AUTH"          file_contains "$LOG/s6.log" "NEEDS_GITHUB_AUTH"
  expect "still PREFLIGHT_PASSED"     file_contains "$LOG/s6.log" "PREFLIGHT_PASSED"
else
  printf '  SKIP  gh auth check (gh not installed)\n'
fi

echo "== preflight: locaweb credentials missing =="
d="$BASE/s7"; mkdir -p "$d"
pf s7 "$d" "$FAKEHOME" "$PATH"
expect "NEEDS_LOCAWEB_CREDENTIALS"    file_contains "$LOG/s7.log" "NEEDS_LOCAWEB_CREDENTIALS"

echo "== preflight: locaweb credentials present — no flag =="
d="$BASE/s8"; mkdir -p "$d"
( cd "$d" && LOCAWEB_API_KEY=k LOCAWEB_API_SECRET=s HOME="$FAKEHOME" \
    "$BASH_BIN" "$PREFLIGHT" ) >"$LOG/s8.log" 2>&1
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s8.log" "PREFLIGHT_PASSED"
refute "no NEEDS_LOCAWEB flag"        file_contains "$LOG/s8.log" "NEEDS_LOCAWEB_CREDENTIALS"

summary "scripts (preflight)"