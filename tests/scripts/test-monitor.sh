#!/usr/bin/env bash
#
# Deterministic, offline tests for the cloud-weaver monitor — the health
# poller and the SSH diagnostics collector. No network is touched: the
# poller's core is exercised with stubbed requester/sleep/clock, and
# diagnose.sh runs in --dry-run mode.
#
#   - script hygiene: compiles, shebang present
#   - backoff: 5,10,20,40,60,60; budget guard never sleeps past timeout
#   - poll: 503->200 healthy; constant failure times out; connection error = 0
#   - real open_url: connection refused maps to status 0 (proxy-free)
#   - diagnose.sh: required args, FATAL messages, dry-run command generation
#
# Usage: tests/scripts/test-monitor.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

SCRIPT="$REPO/../skills/cloud-weaver-monitor/scripts/health-check.py"
DIAG="$REPO/../skills/cloud-weaver-monitor/scripts/diagnose.sh"
PYTHON="$(command -v python3)"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

HCLOAD="import importlib.util; spec = importlib.util.spec_from_file_location('hc', '$SCRIPT'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)"

echo "== monitor: script hygiene =="
expect "health-check.py compiles" "$PYTHON" -m py_compile "$SCRIPT"
expect "shebang python3"          file_contains "$SCRIPT" "env python3"
expect "diagnose.sh present"      test -f "$DIAG"

echo "== monitor: backoff sequence =="
have_backoff=$("$PYTHON" -c "$HCLOAD; print(' '.join(str(m.backoff_delay(i)) for i in range(6)))")
expect "backoff 5,10,20,40,60,60" test "$have_backoff" = "5 10 20 40 60 60"

echo "== monitor: poll healthy (503 -> 200) =="
POLL1=$("$PYTHON" -c "
$HCLOAD
t = {'now': 0.0}
def fake_sleep(s): t['now'] += s
def fake_now(): return t['now']
statuses = iter([503, 503, 200])
def req(url, to): return next(statuses)
ok, att = m.poll('http://x', timeout_s=120, initial_delay_s=30, requester=req, sleep=fake_sleep, now=fake_now)
print('OK' if ok else 'FAIL', ','.join(str(a) for a in att))
")
expect "poll returns healthy"      test "$(echo "$POLL1" | cut -d' ' -f1)" = OK
expect "attempts include 200"      bash -c "echo '$POLL1' | grep -q '200'"

echo "== monitor: poll times out on constant failure =="
POLL2=$("$PYTHON" -c "
$HCLOAD
t = {'now': 0.0}
def fake_sleep(s): t['now'] += s
def fake_now(): return t['now']
def req(url, to): return 503
ok, att = m.poll('http://x', timeout_s=10, initial_delay_s=0, requester=req, sleep=fake_sleep, now=fake_now)
print('OK' if not ok else 'FAIL', len(att), t['now'])
")
expect "poll fails after timeout"    test "$(echo "$POLL2" | cut -d' ' -f1)" = OK
expect "bounded attempts on timeout" test "$(echo "$POLL2" | cut -d' ' -f2)" -le 3
expect "did not sleep past budget"   bash -c "echo '$POLL2' | awk '{print \$3}' | grep -q '^5\.0'"

echo "== monitor: connection error mapped to 0, never 200 =="
POLL3=$("$PYTHON" -c "
$HCLOAD
t = {'now': 0.0}
def fake_sleep(s): t['now'] += s
def fake_now(): return t['now']
def req(url, to): return 0  # connect/network failure
ok, att = m.poll('http://x', timeout_s=10, initial_delay_s=0, requester=req, sleep=fake_sleep, now=fake_now)
print('OK' if not ok else 'FAIL', 200 in att)
")
expect "connect error -> unhealthy"  test "$(echo "$POLL3" | cut -d' ' -f1)" = OK
expect "no phantom 200"              test "$(echo "$POLL3" | cut -d' ' -f2)" = False

echo "== monitor: real open_url (proxy-free) =="
STATUS=$("$PYTHON" -c "$HCLOAD; print(m.open_url('http://127.0.0.1:1/', 2))")
expect "connection refused -> 0"      test "$STATUS" = "0"

echo "== monitor: CLI arg validation =="
"$PYTHON" "$SCRIPT" >"$BASE/c1.out" 2>&1
expect "missing --url rejected"       test $? != 0
expect "usage mentions --url"         file_contains "$BASE/c1.out" "--url"

echo "== monitor: CLI unhealthy exit code =="
"$PYTHON" "$SCRIPT" --url http://127.0.0.1:1/ --timeout 1 --initial-delay 0 \
  --output "$BASE/fail.report.json" >"$BASE/c2.out" 2>&1
expect "closed port exits non-zero"   test $? != 0
expect "unhealthy message"            file_contains "$BASE/c2.out" "Unhealthy"
expect "report marks ok=false"        test "$(jq -r .ok "$BASE/fail.report.json")" = "false"
expect "report final_status 0"        test "$(jq -r .final_status "$BASE/fail.report.json")" = "0"

echo "== monitor: diagnose.sh validation =="
bash "$DIAG" >"$BASE/d1.out" 2>&1
expect "missing args rejected"        test $? != 0
expect "FATAL missing --ssh-key"      file_contains "$BASE/d1.out" "FATAL: missing --ssh-key"

bash "$DIAG" --ssh-key "$BASE/no-key" --ip 200.1.2.3 >"$BASE/d2.out" 2>&1
expect "missing key file rejected"    test $? != 0
expect "FATAL key not found"          file_contains "$BASE/d2.out" "SSH private key not found"

echo "== monitor: diagnose.sh dry-run command generation =="
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQQQQ test@example.com" > "$BASE/diag.key"
chmod 600 "$BASE/diag.key"
bash "$DIAG" --ssh-key "$BASE/diag.key" --ip 200.1.2.3 --dry-run >"$BASE/d3.out" 2>&1
expect "dry-run exit 0"               test $? = 0
for probe in "sudo docker ps -a" "df -h /data" "free -h" \
             "sudo journalctl -u docker --no-pager -n 30" "uptime"; do
  expect "generates: $probe"          file_contains "$BASE/d3.out" "$probe"
done
expect "uses ded. ssh key"            file_contains "$BASE/d3.out" "-i $BASE/diag.key"
expect "targets ubuntu@200.1.2.3"     file_contains "$BASE/d3.out" "ubuntu@200.1.2.3"

summary "monitor"