#!/usr/bin/env bash
# Collects baseline SSH diagnostics from a Cloud Recipes VM — container state,
# disk, memory, docker daemon log and uptime. Best-effort: never fails the
# session, output goes to stdout and (optionally) a report file.
#
#   --ssh-key <path>   Ed25519 private key (required)
#   --ip <addr>        VM public IP (required)
#   --user <name>      SSH user (default: ubuntu)
#   --output <file>    Also write the collected diagnostics to this file
#   --dry-run          Print the commands that would run instead of running them
set -uo pipefail

KEY=""
VM_USER="ubuntu"
IP=""
OUT=""
DRY_RUN=0

usage() {
  echo "Usage: $0 --ssh-key <path> --ip <addr> [--user ubuntu] [--output FILE] [--dry-run]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-key) KEY="$2"; shift 2 ;;
    --user) VM_USER="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --output) OUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[ -n "$KEY" ] || { echo "FATAL: missing --ssh-key" >&2; exit 2; }
[ -n "$IP" ] || { echo "FATAL: missing --ip" >&2; exit 2; }
[ -f "$KEY" ] || { echo "FATAL: SSH private key not found: $KEY" >&2; exit 2; }

SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
     -o ConnectTimeout=15 "$VM_USER@$IP")

PROBES=(
  "sudo docker ps -a"
  "df -h /data"
  "free -h"
  "sudo journalctl -u docker --no-pager -n 30"
  "uptime"
)

if [ "$DRY_RUN" = "1" ]; then
  for probe in "${PROBES[@]}"; do
    printf 'CMD %s\n' "${SSH[*]} $probe"
  done
  exit 0
fi

run_probes() {
  for probe in "${PROBES[@]}"; do
    echo "== $probe =="
    "${SSH[@]}" "$probe" 2>&1
    echo
  done
}

if [ -n "$OUT" ]; then
  run_probes | tee "$OUT"
else
  run_probes
fi

exit 0