#!/usr/bin/env bash
#
# Deterministic, offline tests for the cloud-weaver VM provisioner. Uses the
# MockTransport hook (LOCAWEB_MOCK_FIXTURES/LOCAWEB_MOCK_LOG) to drive the
# CloudStack API with fixture responses. No network, no real cloud.
#
#   - input validation: env_name/zone/plan regex, port range, disk range,
#     missing pubkey, missing credentials, missing endpoint
#   - provisioning from scratch: every create command runs, JSON report is correct
#   - idempotency: on an existing deployment only reads run, never re-creates
#   - request signing: deterministic, secret-sensitive
#   - bundled userdata: docker install + /data mount present
#
# Usage: tests/scripts/test-vm-provision.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

SCRIPT="$REPO/../skills/cloud-weaver-vm-setup/scripts/vm-provision.py"
USERDATA="$REPO/../skills/cloud-weaver-vm-setup/scripts/userdata/boot_vm.sh"
FIXTURES="$REPO/scripts/fixtures"
PYTHON="$(command -v python3)"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQQQQ test@example.com" > "$BASE/testkey.pub"

# prov <name> <fixture-file> [extra args...] — run the provisioner in mock
# mode, capturing stdout, exit code, and the per-run command log.
prov() {
  local name="$1" fixture="$2"; shift 2
  ( unset LOCAWEB_API_KEY LOCAWEB_API_SECRET LOCAWEB_API_ENDPOINT \
      && export LOCAWEB_MOCK_FIXTURES="$FIXTURES/$fixture" \
             LOCAWEB_MOCK_LOG="$BASE/$name.log" \
      && "$PYTHON" "$SCRIPT" "$@" ) >"$BASE/$name.out" 2>&1
  printf '%s' "$?" >"$BASE/$name.rc"
}
prov_rc() { cat "$BASE/$1.rc"; }
prov_no_mock() { local name="$1"; shift; "$PYTHON" "$SCRIPT" "$@" >"$BASE/$name.out" 2>&1; printf '%s' "$?" >"$BASE/$name.rc"; }

echo "== vm-provision: script compiles =="
expect "vm-provision.py compiles"      "$PYTHON" -m py_compile "$SCRIPT"
expect "shebang python3"               file_contains "$SCRIPT" "env python3"

echo "== vm-provision: input validation =="
prov_no_mock v1 --env-name "Bad Name" --zone ZP01 --plan c4 --ssh-pubkey "$BASE/testkey.pub"
expect "rejects invalid env_name"      test "$(prov_rc v1)" != 0
expect "FATAL invalid env_name"        file_contains "$BASE/v1.out" "only lowercase letters"

prov_no_mock v2 --env-name hermes --zone ZP01 --plan c4 --ports "22,abc" --ssh-pubkey "$BASE/testkey.pub"
expect "rejects invalid port"          test "$(prov_rc v2)" != 0
expect "FATAL invalid port"            file_contains "$BASE/v2.out" "Invalid port"

prov_no_mock v3 --env-name hermes --zone ZP01 --plan c4 --ssh-pubkey /nonexistent.pub
expect "rejects missing pubkey"        test "$(prov_rc v3)" != 0
expect "FATAL missing pubkey"          file_contains "$BASE/v3.out" "SSH public key not found"

prov_no_mock v4 --env-name hermes --zone ZP01 --plan c4 --disk-gb 2 --ssh-pubkey "$BASE/testkey.pub"
expect "rejects tiny disk"             test "$(prov_rc v4)" != 0
expect "disk range message"            file_contains "$BASE/v4.out" "between 5 and 2000"

echo "== vm-provision: missing credentials / endpoint =="
LOCAWEB_API_ENDPOINT=https://cloud.example/api prov_no_mock v5 --env-name hermes --zone ZP01 --plan c4 --ssh-pubkey "$BASE/testkey.pub"
expect "rejects missing api keys"      test "$(prov_rc v5)" != 0
expect "FATAL missing api keys"        file_contains "$BASE/v5.out" "LOCAWEB_API_KEY and LOCAWEB_API_SECRET must be set"

LOCAWEB_API_KEY=k LOCAWEB_API_SECRET=s prov_no_mock v6 --env-name hermes --zone ZP01 --plan c4 --ssh-pubkey "$BASE/testkey.pub"
expect "rejects missing endpoint"      test "$(prov_rc v6)" != 0
expect "FATAL missing endpoint"        file_contains "$BASE/v6.out" "No API endpoint"

echo "== vm-provision: requested signing is deterministic and secret-bound =="
SIGLOAD="import sys, importlib.util; spec = importlib.util.spec_from_file_location('vmp', '$SCRIPT'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)"
SIG1=$("$PYTHON" -c "$SIGLOAD; print(m.build_signed_query('listZones', {'zone': 'ZP01'}, 'apikey1', 'secret1'))")
SIG2=$("$PYTHON" -c "$SIGLOAD; print(m.build_signed_query('listZones', {'zone': 'ZP01'}, 'apikey1', 'secret1'))")
SIG3=$("$PYTHON" -c "$SIGLOAD; print(m.build_signed_query('listZones', {'zone': 'ZP01'}, 'apikey1', 'secret2'))")
expect "signature deterministic"       test "$SIG1" = "$SIG2"
expect "signature has apiKey param"    bash -c "echo '$SIG1' | grep -q 'apiKey=apikey1'"
expect "signature has signature param" bash -c "echo '$SIG1' | grep -q 'signature='"
refute "signature differs with secret" test "$SIG1" = "$SIG3"

echo "== vm-provision: provisioning from scratch (empty fixture) =="
prov vm-empty vm-provision-empty.json --env-name hermes --zone ZP01 --plan c4 --disk-gb 20 \
  --ports 8080 --ssh-pubkey "$BASE/testkey.pub" --output "$BASE/report.json"
expect "exit 0"                        test "$(prov_rc vm-empty)" = 0
expect "report file written"           test -f "$BASE/report.json"
expect "public_ip in report"           test "$(jq -r .public_ip "$BASE/report.json")" = "200.1.2.3"
expect "hero_url nip.io"               test "$(jq -r .hero_url "$BASE/report.json")" = "http://200.1.2.3.nip.io"
expect "internal_ip in report"         test "$(jq -r .internal_ip "$BASE/report.json")" = "10.0.0.5"
expect "firewall includes 22+8080"     bash -c "jq -r '.firewall_ports[]' '$BASE/report.json' | grep -qx '22' && jq -r '.firewall_ports[]' '$BASE/report.json' | grep -qx '8080'"
for cmd in createNetwork registerSSHKeyPair deployVirtualMachine \
           associateIpAddress enableStaticNat createFirewallRule \
           createVolume createTags attachVolume; do
  expect "ran $cmd"                     file_contains "$BASE/vm-empty.log" "$cmd"
done
refute "created twice (no duplicate network)" test "$(grep -c createNetwork "$BASE/vm-empty.log")" -gt 1

echo "== vm-provision: idempotent on existing deployment =="
prov vm-existing vm-provision-existing.json --env-name hermes --zone ZP01 --plan c4 --disk-gb 20 \
  --ssh-pubkey "$BASE/testkey.pub" --output "$BASE/report2.json"
expect "exit 0"                        test "$(prov_rc vm-existing)" = 0
expect "same public_ip reused"         test "$(jq -r .public_ip "$BASE/report2.json")" = "200.1.2.3"
for cmd in createNetwork registerSSHKeyPair deployVirtualMachine \
           associateIpAddress enableStaticNat createFirewallRule \
           createVolume createTags attachVolume; do
  refute "did NOT re-create $cmd"      file_contains "$BASE/vm-existing.log" "$cmd"
done

echo "== vm-provision: bundled userdata =="
expect "installs docker.io"            file_contains "$USERDATA" "docker.io"
expect "installs compose plugin"       file_contains "$USERDATA" "docker-compose-plugin"
expect "mounts /data"                  file_contains "$USERDATA" '/data'
expect "formats ext4 data disk"        file_contains "$USERDATA" "mkfs.ext4"
expect "enable fail2ban"               file_contains "$USERDATA" "fail2ban"

echo "== vm-provision: rotate-ssh-key subcommand =="
prov rot1 vm-provision-existing.json \
  rotate-ssh-key --env-name hermes --ssh-pubkey "$BASE/testkey.pub"
expect "rotate exit 0"                          test "$(prov_rc rot1)" = 0
expect "rotate ran stopVirtualMachine"          file_contains "$BASE/rot1.log" "stopVirtualMachine"
expect "rotate ran resetSSHKeyForVirtualMachine" file_contains "$BASE/rot1.log" "resetSSHKeyForVirtualMachine"
expect "rotate ran startVirtualMachine"         file_contains "$BASE/rot1.log" "startVirtualMachine"
expect "rotate output has status rotated"       file_contains "$BASE/rot1.out" "rotated"
expect "rotate did NOT run deployVirtualMachine" refute test "$(grep -c deployVirtualMachine "$BASE/rot1.log" 2>/dev/null || echo 0)" -gt 0
expect "rotate did NOT run createNetwork"        refute test "$(grep -c createNetwork "$BASE/rot1.log" 2>/dev/null || echo 0)" -gt 0

summary "vm-provision"