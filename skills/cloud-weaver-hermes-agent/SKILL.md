---
name: cloud-weaver-hermes-agent
description: >
  This skill should be used when deploying the Hermes Agent recipe — the Nous
  Research Hermes Agent controlled via Telegram — onto a cloud-weaver VM already
  provisioned by cloud-weaver-vm-setup. It collects configuration one question
  at a time, ships a Traefik + ttyd + hermes-agent compose stack over SSH,
  and delivers the terminal URL and admin password in the final report.
  Idempotent — re-runs with --skip-secrets reuse the remote .env.
---

# Hermes Agent (Nous Research + Telegram)

One dedicated VM, three containers: `traefik` (TLS via Let's Encrypt),
`web-terminal` (ttyd browser shell behind basic auth) and `hermes-agent`
(Telegram long polling — no public port).

## 1. Gather configuration

Reuse the VM already created by `cloud-weaver-vm-setup` (`env_name`,
`public_ip`, `vm_name` from the report). Ask exactly one question at a time:

| Parameter | Notes |
|-----------|-------|
| `telegram_user_id` | The participant's Telegram **numeric user ID** (not username). Tip: send /start to @userinfobot in Telegram to get it. |

The skill derives `hostname` automatically: `<vm_name>.publiccloud.com.br`
where `vm_name` comes from the vm-setup report.

Validate `telegram_user_id` as a positive integer.

## 2. Confirm with the user

Show a short plan:

> Vou instalar o Hermes Agent na VM `<env_name>`:
> - Traefik com Let's Encrypt em `<hostname>`
> - Terminal web acessível em `https://<hostname>` com senha gerada
> - Hermes Agent conectado ao Telegram via long polling
>
> Credenciais e senha do terminal serão entregues no relatório final, nunca na conversa.

Wait for explicit confirmation.

## 3. Run the deployer

The deploy script is at `scripts/deploy-hermes-agent.py` (relative to this
SKILL.md). SSH user is `ubuntu`; SSH key is `~/.ssh/cloud-weaver` (or
`~/.ssh/cloud-weaver-<env>`).

```bash
python3 <this-skill-dir>/scripts/deploy-hermes-agent.py \
  --env-name "$env_name" \
  --public-ip "$public_ip" \
  --hostname "cr-${env_name}-net-vm.publiccloud.com.br" \
  --telegram-user-id "$telegram_user_id" \
  --ssh-private-key "$HOME/.ssh/cloud-weaver" \
  --output "$HOME/.cloud-weaver-${env_name}-hermes-agent.json"
```

For a **re-run** (config change, containers restarted), pass `--skip-secrets`
to reuse the existing `.env` on the VM:

```bash
python3 <this-skill-dir>/scripts/deploy-hermes-agent.py \
  --env-name "$env_name" --public-ip "$public_ip" \
  --hostname "cr-${env_name}-net-vm.publiccloud.com.br" \
  --telegram-user-id "$telegram_user_id" \
  --ssh-private-key "$HOME/.ssh/cloud-weaver" \
  --skip-secrets
```

## 4. What the deployer does

1. Generates an `admin_pass` with `secrets.token_urlsafe(32)`.
2. Builds `TTYD_BASIC_AUTH` with SHA1 hash of `admin_pass` (Traefik format).
3. Creates `/data/<env>/compose/`, `/data/<env>/hermes_data/`, `/data/<env>/acme/` on the VM.
4. SCPs `compose.yaml`, `.env` (mode 600), `hermes-config.yaml` to the VM.
5. Writes `hermes-config.yaml` to `/data/<env>/hermes_data/config.yaml` (sets `approvals.mode: smart`).
6. Runs `docker compose up -d --wait --wait-timeout 300`.

## 5. Report

Read the JSON report at `~/.cloud-weaver-<env>-hermes-agent.json` and present
to the user:

- **Terminal web:** `https://<hostname>` — login com usuário `admin`, senha `<admin_pass>`
- **Próximos passos:**
  1. Acesse o terminal web e faça login.
  2. Execute `hermes setup` no terminal para configurar o provedor de LLM, GitHub e o token do bot do Telegram.
  3. Envie uma mensagem ao bot no Telegram para testar.

**admin_pass está no JSON de relatório** (`admin_pass`). Exiba-o uma única vez ao usuário e instrua a anotá-lo.

## 6. Open questions (validate during smoke test)

- **Q1 — docker.sock no ttyd:** o container web-terminal monta `/var/run/docker.sock` com escrita para fazer `docker exec`. Risco: sessão de terminal equivale a root no host. Alternativa: rodar ttyd na mesma imagem do agente compartilhando o volume `hermes_data`. Validar durante o smoke test.
- **Q2 — approvals.cron_mode:** `auto` está configurado; confirmar que crons do workshop disparam sem aprovação manual.
- **Q3 — Dimensionamento:** validar que a VM large aguenta a imagem (`python 3.11 + node 26`) e medir o primeiro boot.
- **Q4 — TLS:** confirmar que `<vm_name>.publiccloud.com.br` resolve externamente e o Let's Encrypt emite o certificado.

## Idempotency

First run creates the `.env`. Re-runs must use `--skip-secrets` — this keeps
the TTYD basic auth password stable (the participant's bookmarked URL keeps
working) and still applies config/compose changes.

## Bundled Resources

- **`scripts/deploy-hermes-agent.py`** — deployer (stdlib, idempotent, `--dry-run`)
- **`scripts/compose/compose.yaml`** — Traefik + ttyd + hermes-agent stack
- **`scripts/hermes-config.yaml`** — Hermes Agent approval config template
