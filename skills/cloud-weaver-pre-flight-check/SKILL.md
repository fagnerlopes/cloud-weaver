---
name: cloud-weaver-pre-flight-check
description: >
  This skill should be used at the very start of every session and when the
  user asks to "check my environment", "validate setup requirements", "is my
  system ready", or before any cloud-weaver operation. It verifies the
  installed skill version, dev tools, GitHub authentication, Locaweb Cloud
  credentials, and the sensitive-file guard.
---

# Pre-Flight Check

Validate that the current environment is ready for cloud-weaver work.
This is the first skill invoked at session start.

## Step 0 — Version Check

<!-- CLOUD_WEAVER_VERSION: 1.6.0 -->

The `cloud-weaver` marker above contains the loaded version of the cloud-weaver skills.

The preflight script (`scripts/preflight.sh`) handles the version check and auto-update automatically:

1. It reads the local version from the `CLOUD_WEAVER_VERSION` marker in this file.
2. It fetches the remote version from `https://api.github.com/repos/fagnerlopes/cloud-weaver/contents/.claude-plugin/plugin.json`.
3. If the remote version is newer, it runs `npx -y skills update` automatically.

Read the output of `scripts/preflight.sh` and act on these signals:

- **`SKILLS_UPDATING`:** The script detected an outdated version and is running the update — wait for the next signal.
- **`SKILLS_UPDATED`:** Update succeeded. Tell the user the skills were updated and they **must start a new session** — the current session still runs the outdated skills. **Stop** — do not proceed with other checks or tasks in this session.
- **`SKILLS_UPDATE_FAILED`:** Auto-update failed. Tell the user to run the command below manually in their OS terminal, then start a new session:

  ```sh
  npx -y skills update
  ```

- *(no update signal)* — Versions match or the fetch failed; proceed normally with the remaining checks.

## Running the Check

This skill bundles the preflight script at `scripts/preflight.sh`, relative to the
directory this `SKILL.md` lives in. Locate it from the skill's own directory and
run it with bash — resolve the path against the skill directory, not your current
working directory:

```bash
python3 <this-skill-dir>/scripts/preflight.py
```

The script exits `0` and prints `PREFLIGHT_PASSED` on success, or exits `1` and
prints `PREFLIGHT_FAILED` followed by one or more error lines on failure. Flags
(`NEEDS_*`) may be printed alongside `PREFLIGHT_PASSED` — they do not block the
session, they tell the playbook which setup skill to invoke.

## Conditions Checked

### 1. Sensitive File Guard

When inside a git repository, the script aborts if any untracked, staged, or
tracked-modified file matches credential patterns (`.env` / `<name>.env` /
`.env.*`, `id_rsa` and friends, `.npmrc`/`.netrc`/`.pypirc`, `.pem`, `.key`,
`.secret`, `.p12`, `.pfx`, `.jks`, `.keystore`, `credentials*.json`,
`secrets.yaml`). Template files (`.example`, `.sample`, `.template`, ...) and
deletions are ignored.

**On failure:** `SENSITIVE_FILES_DETECTED` with remediation per how the file is
tracked — add to `.gitignore` (untracked), `git restore --staged <file>`
(staged), or `git rm --cached <file>` plus `.gitignore` (tracked).

### 2. Git Sync

When the directory has a git repository **and** at least one remote, the script
automatically commits local changes, pulls with rebase, and pushes — so every
session starts from a fully synchronized state.

**On failure:** `GIT_SYNC_ERROR` with details. The user must resolve manually
and re-run the check.

### 3. Dev Tools

The script checks for `gh` and `ssh`. If any are missing, it prints:

```
NEEDS_COMPUTER_SETUP: missing <tool1> <tool2> ...
```

`jq` is **not** required — the `gh` CLI has a built-in `--jq` flag used throughout.

**Action:** invoke `cloud-weaver-computer-setup`.

### 4. GitHub Authentication

If `gh` is installed but not authenticated:

```
NEEDS_GITHUB_AUTH: ...
```

**Action:** ask the user to run `gh auth login` in their OS terminal and resume.

### 5. Locaweb Cloud Credentials

The script checks that `LOCAWEB_API_KEY` and `LOCAWEB_API_SECRET` are both set
in the environment (presence only — values are never printed):

```
NEEDS_LOCAWEB_CREDENTIALS: ...
```

**Action:** collect the API keys through secure means (env vars, never in the
conversation) and re-run the check.

### 6. Telegram Bot Token

The script checks that `TELEGRAM_BOT_TOKEN` is set in the environment
(presence only — value is never printed):

```
NEEDS_TELEGRAM_BOT_TOKEN: ...
```

**Action:** ask the user to export `TELEGRAM_BOT_TOKEN` in their OS terminal
and start a new session. **Never accept the value in the conversation.**

To find the token of an existing bot: open [@BotFather](https://t.me/BotFather)
on Telegram, send `/mybots`, select the bot, then tap **API Token**.

## Handling Failures

When the pre-flight check fails (`PREFLIGHT_FAILED`):

1. Display each error reason to the user in plain language
2. Provide the recommended remediation for each failure
3. **Do not proceed** — wait for the user to fix the issue and re-run

When the pre-flight check passes but prints `NEEDS_*` flags:

1. Invoke the indicated skill(s): `computer-setup` first, then resolve auth/credentials flags
2. After those complete, proceed with the session

## Bundled Resources

### Scripts

- **`scripts/preflight.sh`** — Runs all environment validations and reports pass/fail with specific error codes and `NEEDS_*` flags
