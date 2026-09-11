---
name: cloud-weaver-monitor
description: >
  This skill should be used after a recipe has been deployed (see
  cloud-weaver-vm-setup + the recipe skill) to confirm the application is
  actually up and to help diagnose it when it is not. It polls the app's
  health endpoint until HTTP 200 with retries and backoff, and on failure
  collects SSH diagnostics from the VM.
---

# Monitor

Confirm the deployed recipe is healthy. Called by the playbook right after the
recipe skill finishes `docker compose up` — never skip this step.

## 1. Determine the health URL

Each recipe exposes a health endpoint on its public address:

| Recipe | Health check |
|--------|--------------|
| Hermes (WAHA) | `http://<public_ip>:<api_port>/api/health` |

Use the `api_url` from the recipe report (e.g. `http://200.1.2.3:3000`).

## 2. Poll the health endpoint

Run the poller (pure stdlib, no dependencies). It waits a grace period for
cloud-init/containers to boot, then probes with exponential backoff until
HTTP 200 or the timeout budget runs out:

```bash
python3 <this-skill-dir>/scripts/health-check.py \
  --url "http://<public_ip>:<api_port>/api/health" \
  --timeout 600 --initial-delay 30
```

Give the user plain-language status updates while it runs
(`Estou aguardando a aplicação subir…`). On success the script exits 0.
Use `--output report.json` when the caller wants the attempt history.

## 3. On success — proceed

Report to the user that the app is healthy. Hand off to the playbook's final
report step.

## 4. On failure — diagnose

If the health check times out or never returns 200, collect VM diagnostics so
you can reason about the failure instead of guessing:

```bash
bash <this-skill-dir>/scripts/diagnose.sh \
  --ssh-key "$HOME/.ssh/cloud-weaver" --ip "$public_ip"
```

This gathers: `docker ps`, `/data` disk usage, memory, the docker daemon log
and uptime. Read the output and reason out loud:

- Containers not running → check `sudo docker compose -p hermes-<env> ps` and
  `sudo docker compose -p hermes-<env> logs --tail 50` on the VM.
- Container restarting (CrashLoopBackOff) → view its logs for the exit reason.
- Disk/memory pressure → the plan may be too small; consider a larger VM plan.
- Docker daemon down → `systemctl status docker` on the VM.

Use the same SSH pattern (dedicated key `~/.ssh/cloud-weaver`, user
`ubuntu`, `-o StrictHostKeyChecking=accept-new`) for any follow-up commands.
Report findings to the user in plain PT-BR and recommend the next action.

## Rollback

Automated rollback is not implemented in this version. If diagnostics show the
VM itself cannot be recovered, tell the user clearly and stop — do not delete
(or promise to delete) infrastructure manually.

## Bundled Resources

- **`scripts/health-check.py`** — HTTP poller (stdlib, backoff, report JSON)
- **`scripts/diagnose.sh`** — SSH diagnostics collector (`--dry-run` supported)