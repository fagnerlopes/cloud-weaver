---
name: cloud-weaver-vm-setup
description: >
  This skill should be used when provisioning the virtual machine for a Cloud
  Recipes deployment — after the user confirmed the plan in /start-cloud. It
  creates (or reuses) the cloud-weaver VM on the Locaweb Cloud: isolated
  network, SSH keypair, VM, public IP with static NAT, firewall rules and a
  /data data disk. Idempotent — safe to re-run.
---

# VM Setup

Provision the virtual machine that will host the selected recipe. Called by the
playbook after plan confirmation, and before the recipe skill (which deploys via
Docker over SSH).

## 1. Gather deployment parameters

**Valores fixos — nunca perguntar ao usuário:**

| Parameter | Fixed value |
|-----------|-------------|
| `zone` | `ZP01` |
| `plan` | `large` |
| `disk_gb` | `20` |

**Único parâmetro a coletar:**

| Parameter | Notes |
|-----------|-------|
| `env_name` | Regex `[a-z0-9_]` only. Prefer a short name (e.g. `hermes`, `prod`). The network is named `cr-<env>`. |

`app_ports` comes from the recipe skill — never ask the user.

Validate `env_name` with `[[ $env_name =~ ^[a-z0-9_]+$ ]]`. Reject anything else.

## 2. Confirm the plan

Show a short summary before provisioning, exactly like the playbook's plan
step, and wait for explicit confirmation:

> Vou criar: VM `large` em `ZP01`, disco `20GB` (montado em /data),
> firewall SSH (22) + portas `<app_ports>`, URL de acesso via nip.io.

## 3. SSH key

Reuse the dedicated key from `cloud-weaver-computer-setup`:

- preview: `~/.ssh/cloud-weaver.pub`
- other envs: `~/.ssh/cloud-weaver-<env>.pub` (create if missing, Ed25519)

The public key is registered into CloudStack as a keypair so the VM accepts it.

## 4. Run the provisioner

The script lives at `scripts/vm-provision.py` (relative to this SKILL.md). It is
pure Python 3 standard library and signs every request with the CloudStack
HMAC-SHA1 scheme using `LOCAWEB_API_KEY` / `LOCAWEB_API_SECRET`. Values are
never printed. Run it with the env vars set (they should already be present from
the pre-flight check):

```bash
LOCAWEB_API_KEY="$LOCAWEB_API_KEY" LOCAWEB_API_SECRET="$LOCAWEB_API_SECRET" \
python3 <this-skill-dir>/scripts/vm-provision.py \
  --env-name "$env_name" --zone ZP01 --plan large \
  --disk-gb 20 --ports "$app_ports" \
  --ssh-pubkey "$HOME/.ssh/cloud-weaver.pub"
```

O endpoint é sempre `https://painel-cloud.locaweb.com.br/client/api` —
já embutido como padrão no script. `LOCAWEB_API_ENDPOINT` ou `--endpoint`
sobrepõem quando necessário, mas **não peça ao usuário**.

The script prints a JSON report with `network_name`, `vm_id`, `public_ip`,
`internal_ip`, `firewall_ports` and `hero_url`.

## 5. Verify reachability

Wait a reasonable time for cloud-init to finish (the VM userdata installs
Docker and mounts `/data`), then verify SSH as `ubuntu` using the dedicated
key:

```bash
ssh -i ~/.ssh/cloud-weaver -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout=15 ubuntu@<public_ip> 'docker --version && df -h /data'
```

If SSH is not ready yet, retry with backoff (up to ~5 min). Keep status
updates in plain language for the user.

## 6. Report

Pass to the recipe skill / monitor:

- `public_ip` (public address)
- `internal_ip`
- `env_name`, `network_name`, `keypair_name`
- `hero_url` (`https://<ip>.nip.io`)

## Idempotency

Re-running this flow (or the provisioner on a partially-provisioned
deployment) reuses existing network, keypair, VM, IP and disk — nothing is
duplicated. Provisioning state is safe to resume.

## Bundled Resources

### Scripts

- **`scripts/vm-provision.py`** — Idempotent CloudStack provisioner (stdlib only, signed API)
- **`scripts/userdata/boot_vm.sh`** — cloud-init bootstrap: Docker install, `/data` mount, fail2ban, DNS override