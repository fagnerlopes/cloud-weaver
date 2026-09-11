---
name: cloud-weaver-hermes
description: >
  This skill should be used when deploying the Hermes Agent recipe — the WAHA
  (WhatsApp HTTP API) service backed by PostgreSQL — onto a cloud-weaver VM
  that is already provisioned (see cloud-weaver-vm-setup). It collects the
  remaining configuration one question at a time, then ships a docker compose
  stack over SSH and starts it. Idempotent — re-runs reuse the remote .env.
---

# Hermes Agent (WAHA + PostgreSQL)

One dedicated VM, two containers: `waha` (WhatsApp HTTP API, port 3000) and
`pg` (PostgreSQL 17, healthcheck-gated). Persistent data lives on the VM's
attached disk under `/data/<env>/`.

## 1. Gather configuration

Prefer reusing the previous VM already created by `cloud-weaver-vm-setup`
(`env_name`, `public_ip`, `ssh` key). Ask exactly one question at a time:

| Parameter | Default | Notes |
|-----------|---------|-------|
| `api_port` | `3000` | Public TCP port for the WAHA API/dashboard (must match the firewall rule from vm-setup). |
| universe | — | WhatsApp account is connected later by the user via the dashboard QR code. |

Validate `env_name` against `[a-z0-9_]` and the port against 1–65535.

## 2. Confirm with the user

Show a short plan before deploying:

> Vou instalar o Hermes Agent na VM `<env_name>`: WAHA na porta `<api_port>`
> + PostgreSQL, dados persistentes em /data, credenciais geradas e guardadas
> no .env da VM (nunca na conversa).

Wait for explicit confirmation.

## 3. Run the deployer

The deploy script lives at `scripts/deploy-hermes.py` (relative to this
SKILL.md). Pure Python 3 stdlib. The SSH key is the dedicated
`~/.ssh/cloud-weaver` (or `~/.ssh/cloud-weaver-<env>`) from
`cloud-weaver-computer-setup`; SSH user is `ubuntu`.

```bash
python3 <this-skill-dir>/scripts/deploy-hermes.py \
  --env-name "$env_name" \
  --public-ip "$public_ip" \
  --ssh-private-key "$HOME/.ssh/cloud-weaver" \
  --api-port "$api_port"
```

For a **re-run** (config change, containers restarted), pass `--skip-secrets`
so the existing `.env` on the VM is reused and credentials are never rotated:

```bash
python3 <this-skill-dir>/scripts/deploy-hermes.py \
  --env-name "$env_name" --public-ip "$public_ip" \
  --ssh-private-key "$HOME/.ssh/cloud-weaver" --skip-secrets
```

There is a `--dry-run` flag that prints every SSH/SCP/docker command without
executing them — use it for a rehearsed plan or for offline testing.

## 4. What the deployer does

1. `mkdir -p /data/<env>/{compose,waha,pgdata}` on the VM.
2. `chown -R 999:999 /data/<env>/pgdata` **before** the first boot — the
   postgres image runs as uid 999; mis-owned pgdata is the classic Docker
   permission failure.
3. `scp` `compose.yaml`, `initdb.sql` and (first run) `.env` to
   `/data/<env>/compose/`; `.env` is chmod 600 on the VM.
4. `docker compose up -d --wait` — waits until both health checks pass
   (`pg_isready`, `curl .../api/health`).
5. Prints a JSON report via `--output` and a summary line.

## 5. Report

Pass to the user:

- API: `http://<public_ip>:<api_port>`
- Dashboard: `http://<public_ip>:<api_port>/dashboard`
- Data: `/data/<env>/`

Credentials are generated and live only in the VM file
`/data/<env>/compose/.env` (600). Tell the user they can view them with:

```bash
ssh -i ~/.ssh/cloud-weaver ubuntu@<public_ip> sudo cat /data/<env>/compose/.env
```

Remind them to change `WAHA_DASHBOARD_PASSWORD` and `WAHA_API_KEY` from
the dashboard/profile settings. Connecting a WhatsApp number happens in the
dashboard (QR code).

## Idempotency

First run creates the `.env`. Re-runs must use `--skip-secrets` — this keeps
the WAHA API key and dashboard password stable (clients/sessions stay valid)
and still applies config/volume changes.

## Permission model

- **WAHA** runs as root by design (no `USER` in the upstream image); its
  session dir `/data/<env>/waha` is root-owned on the host. Host-side
  maintenance uses `sudo`, matching every other cloud-weaver step.
- **PostgreSQL** runs as uid 999; `/data/<env>/pgdata` is `chown -R 999:999`
  before first boot.
- All dirs live under `/data/` (attached, snapshot-backed disk) — never mount
  containers from other paths.

## Bundled Resources

- **`scripts/deploy-hermes.py`** — deployer (stdlib, idempotent, `--dry-run`)
- **`scripts/compose/compose.yaml`** — WAHA + PostgreSQL compose stack
- **`scripts/initdb.sql`** — postgres first-boot init (creates the `waha` DB)