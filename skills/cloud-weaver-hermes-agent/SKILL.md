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

**Fixed VM parameter for this recipe (pass to `cloud-weaver-vm-setup`, do not ask the user):**

| Parameter | Fixed value |
|-----------|-------------|
| `app_ports` | `80,443` |

> **Pré-requisito:** A VM deve ter sido provisionada com `--ports 80,443`  
> (além da porta 22 padrão). O Traefik precisa dessas portas para o desafio  
> ACME e para servir o terminal web via HTTPS.  
> Se a VM foi provisionada sem essas portas, rode vm-provision com `--ports 80,443` antes de prosseguir.

**Secret de ambiente obrigatório (verificado pelo pre-flight, nunca pedido na conversa):**

| Variável | Como obter |
|----------|-----------|
| `TELEGRAM_BOT_TOKEN` | Crie um bot via [@BotFather](https://t.me/BotFather) (`/newbot`) e copie o token. Exporte no terminal antes de iniciar a sessão. |

| Parameter | Notes |
|-----------|-------|
| `telegram_user_id` | O **ID numérico** do usuário no Telegram (não o @username). Para descobrir: abra o Telegram, pesquise por **@userinfobot** e envie qualquer mensagem — o bot responde com o seu `Id`. |

The skill derives `hostname` automatically: `<public_ip>.nip.io`
where `public_ip` comes from the vm-setup report. **Não use `vm_name` nem `publiccloud.com.br`.**

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
  --hostname "${public_ip}.nip.io" \
  --telegram-user-id "$telegram_user_id" \
  --ssh-private-key "$HOME/.ssh/cloud-weaver" \
  --output "$HOME/.cloud-weaver-${env_name}-hermes-agent.json"
```

For a **re-run** (config change, containers restarted), pass `--skip-secrets`
to reuse the existing `.env` on the VM:

```bash
python3 <this-skill-dir>/scripts/deploy-hermes-agent.py \
  --env-name "$env_name" --public-ip "$public_ip" \
  --hostname "${public_ip}.nip.io" \
  --telegram-user-id "$telegram_user_id" \
  --ssh-private-key "$HOME/.ssh/cloud-weaver" \
  --skip-secrets
```

## 3.5 Guided setup — wait for `hermes setup` completion

After the deployer exits successfully, the containers are running but the Hermes
Agent has not been configured yet. Guide the user through the setup:

1. Show the web terminal URL and credentials from the JSON report:
   - **URL:** `https://<hostname>`
   - **User:** `admin`
   - **Password:** `<admin_pass>` (display once; instruct to save it)

2. Instruct the user (in PT-BR):

   > Abra o terminal web, faça login com as credenciais acima e execute o
   > comando abaixo — ele configura o Hermes Agent e cria um marcador que
   > confirma a conclusão:
   >
   > ```
   > hermes setup && touch /root/.hermes/.setup-complete
   > ```
   >
   > Responda **"pronto"** quando terminar.

3. **Wait for the user to reply** before proceeding.

4. Validate via SSH that the sentinel file was created:

   ```bash
   ssh -i ~/.ssh/cloud-weaver ubuntu@"$public_ip" \
     "test -f /data/${env_name}/hermes_data/.setup-complete && echo OK || echo MISSING"
   ```

   - **OK** → proceed to step 3.6.
   - **MISSING** → tell the user the file was not found, ask them to run the
     command again in the terminal and reply "pronto" when done. Retry once.
     If still missing after the retry, stop and ask the user to check the
     terminal for errors.

## 3.6 Restart hermes-agent to apply the new configuration

Once the sentinel file is confirmed, restart the hermes-agent container so it
picks up any configuration written by `hermes setup`:

```bash
ssh -i ~/.ssh/cloud-weaver ubuntu@"$public_ip" \
  "docker compose -f /data/${env_name}/compose/compose.yaml restart hermes-agent"
```

Wait 10 seconds, then check the last log lines to confirm it started cleanly:

```bash
ssh -i ~/.ssh/cloud-weaver ubuntu@"$public_ip" \
  "docker compose -f /data/${env_name}/compose/compose.yaml logs hermes-agent --tail 20"
```

If the logs show an obvious crash or error, surface them to the user before
proceeding to the monitor step.

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
  1. Envie uma mensagem ao bot no Telegram para testar — o Hermes Agent já está configurado e em execução.
  2. Para abrir o terminal web novamente: acesse `https://<hostname>` e faça login com as credenciais acima.

**admin_pass está no JSON de relatório** (`admin_pass`). Exiba-o uma única vez ao usuário e instrua a anotá-lo.

## 6. Open questions (validate during smoke test)

- **Q1 — docker.sock no ttyd:** o container web-terminal monta `/var/run/docker.sock` com escrita para fazer `docker exec`. Risco: sessão de terminal equivale a root no host. Alternativa: rodar ttyd na mesma imagem do agente compartilhando o volume `hermes_data`. Validar durante o smoke test.
- **Q2 — approvals.cron_mode:** `auto` está configurado; confirmar que crons do workshop disparam sem aprovação manual.
- **Q3 — Dimensionamento:** validar que a VM large aguenta a imagem (`python 3.11 + node 26`) e medir o primeiro boot.
- **Q4 — TLS:** confirmar que `<public_ip>.nip.io` resolve externamente e o Let's Encrypt emite o certificado.

## Idempotency

First run creates the `.env`. Re-runs must use `--skip-secrets` — this keeps
the TTYD basic auth password stable (the participant's bookmarked URL keeps
working) and still applies config/compose changes.

## Bundled Resources

- **`scripts/deploy-hermes-agent.py`** — deployer (stdlib, idempotent, `--dry-run`)
- **`scripts/compose/compose.yaml`** — Traefik + ttyd + hermes-agent stack
- **`scripts/hermes-config.yaml`** — Hermes Agent approval config template
