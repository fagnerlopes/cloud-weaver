---
name: start-cloud
description: >
  The CloudWeaver entry point — invoke it whenever the user types
  `/start-cloud` or asks to install, deploy or provision a ready-made
  application on the Locaweb Cloud ("subir o Hermes Agent", "instalar na
  Locaweb Cloud", "criar uma VM com...", "quero instalar uma receita"). It
  loads the CloudWeaver persona, runs the pre-flight check, presents the
  recipe catalog, collects configuration one question at a time, then
  orchestrates cloud-weaver-vm-setup, the recipe skill and
  cloud-weaver-monitor through to the final report.
---

# `/start-cloud` — CloudWeaver installation flow

This skill is the single entry point for installing a recipe. It does not
provision anything by itself — it **orchestrates** the other cloud-weaver
skills in order and keeps the user informed in plain language between steps.

Follow the steps below in order. Do not skip a step, and do not run two steps
in parallel.

---

## Step 0 — Load the persona

Use the Skill tool to invoke `cloud-weaver-playbook` and adopt it for the rest
of the session: the CloudWeaver persona, the PT-BR output rule, the
`[CloudWeaver]` message tag and the standing security rules.

If the playbook is already loaded in this session, skip this step.

---

## Step 1 — Pre-flight check

**Mandatory. Never skip it, even when the user already said exactly what they
want to install.**

Use the Skill tool to invoke `cloud-weaver-pre-flight-check` and follow its
instructions. Handle the flags it prints:

| Flag | Action |
|------|--------|
| `NEEDS_COMPUTER_SETUP` | Invoke `cloud-weaver-computer-setup`, then re-run the check |
| `NEEDS_GITHUB_AUTH` | Ask the user to run `gh auth login` in their OS terminal, then resume |
| `NEEDS_LOCAWEB_CREDENTIALS` | Ask the user to export `LOCAWEB_API_KEY` and `LOCAWEB_API_SECRET` in their OS terminal and start a new session. **Never accept the values in the conversation.** |
| `PREFLIGHT_FAILED` | Explain each reason in plain language, give the remediation, and **stop** |
| No flags | The environment is ready — continue |

Adapt the greeting: if nothing needed setup, go straight to Step 2. If setup
was needed, give a short friendly status update as each item resolves.

---

## Step 2 — Present the recipe catalog

Show the catalog with a one-line description each. **Only recipes marked
available may be selected** — an unavailable one is shown so the user knows it
is coming, never offered as a choice.

| Recipe | ID | Description | Status |
|--------|----|-------------|--------|
| WAHA | `waha` | Agente de WhatsApp (WAHA) + PostgreSQL | ✅ disponível |
| Hermes Agent | `hermes_agent` | Agente Telegram + LLM (Nous Research) | ✅ disponível |
| Coolify | `coolify` | PaaS self-hosted para publicar suas próprias apps | 🔜 em breve |
| Jitsi Meet | `jitsi` | Servidor de videoconferência | 🔜 em breve |

Ask which recipe they want. Rules:

- A recipe ID must match `^[a-z0-9_]+$`. Reject anything else.
- The ID must map to an **available** recipe with an installed skill
  (`cloud-weaver-<id>`). If the user picks an unavailable one, say plainly that
  it is not ready yet and offer the available ones.
- More than one available recipe may be selected. Install them one at a time,
  sequentially, on the same VM — never interleave.
- Before invoking a recipe skill, confirm the skill actually exists. If
  `cloud-weaver-<id>` is not installed, stop and tell the user rather than
  improvising a deployment.

---

## Step 3 — Collect configuration, one question at a time

Ask **exactly one question per message**, in plain language, and validate each
answer before moving on. Show progress as `Informação X de Y`.

Collect only what the chosen recipe needs. The recipe skill
(`cloud-weaver-<id>`) owns its own question list — read it before asking, so
you do not ask for something it derives or generates itself.

**Secrets are never requested in the conversation.** Generate them with:

```sh
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

…or write a `.env` template with `REPLACE_WITH_` placeholders for the user to
fill in an editor. Never echo a generated secret back into the chat.

---

## Step 4 — Present the plan and get explicit confirmation

Before touching the Locaweb Cloud, show a short summary of everything that will
be created:

- the VM (name and plan)
- the isolated network, the public IP and the static NAT
- the firewall rules and open ports
- the `/data` disk
- the application(s) that will be installed

State plainly that this creates billable resources on their Locaweb Cloud
account. Ask for an explicit **yes** and wait for it.

After confirmation, run Steps 5 and 6 through to the end without pausing for
anything that is not a real blocker.

---

## Step 5 — Provision and install

1. Use the Skill tool to invoke `cloud-weaver-vm-setup` and follow it. It is
   idempotent — an existing cloud-weaver VM is reused, not duplicated.
2. For each selected recipe, use the Skill tool to invoke `cloud-weaver-<id>`
   and follow it. It ships the docker compose stack over SSH and starts it.

Give a plain-language status update as each phase starts, e.g.
*"Estou criando sua máquina virtual — isso leva uns 2 minutos..."*. Never leave
the user staring at silence during a long step.

---

## Step 6 — Monitor startup

Use the Skill tool to invoke `cloud-weaver-monitor` and follow it. It polls the
health endpoint until HTTP 200 (default timeout 10 minutes) with retries and
backoff.

On failure, follow the monitor's diagnose path (SSH + container logs) before
reporting anything as broken, and roll back provisioned resources if the
monitor's rollback criteria are met.

---

## Step 7 — Final report

Present, in PT-BR:

- the **access URL**, made very visible
- the generated credentials, with a reminder to change them immediately
- the day-to-day operation commands (ver logs, reiniciar, parar)
- the next steps

Celebrate the milestone, then invite the user to start a new session for the
next unit of work — one install per session keeps the context clean.

---

## Rules

- Every message starts with `[CloudWeaver]`.
- All output to the user in PT-BR; code comments in English.
- One question at a time — never batch questions.
- Secrets never appear in the conversation, logs or commits.
- Validate every VM/recipe name against `[a-z0-9_]` before it reaches a
  command line.
- Never invoke a recipe skill that is not installed.
