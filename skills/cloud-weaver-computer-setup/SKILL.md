---
name: cloud-weaver-computer-setup
description: >
  This skill should be used when the user asks to "set up my computer",
  "install dev tools", "set up my environment", or when the pre-flight check
  reports NEEDS_COMPUTER_SETUP. It detects the OS and gives platform-specific
  install instructions for gh, ssh, and python3. Works on Linux, macOS,
  Windows (native or WSL). Idempotent — safe to re-run.
---

# Computer Setup

CloudWeaver v2 needs three tools locally — everything else runs in GitHub
Actions. The skill detects the OS and adapts instructions accordingly.

**Required tools:** `gh` (GitHub CLI) · `ssh` (OpenSSH client) · `python3`

`git` and `jq` are **not** required: `git` operations run in CI, and `jq` is
built into the `gh` CLI via `--jq`.

---

## Step 1 — Detect OS

```python
import platform, subprocess, os
system = platform.system()           # "Linux", "Darwin", "Windows"
# Detect WSL (Linux kernel with Microsoft in /proc/version)
is_wsl = system == "Linux" and "microsoft" in open("/proc/version").read().lower() if system == "Linux" else False
print(f"OS: {system}{'  (WSL)' if is_wsl else ''}")
```

---

## Step 2 — Install missing tools

Give the user the right commands for their platform. Only mention what is
actually missing (check with `shutil.which` first).

### Linux / WSL (Ubuntu · Debian)

```bash
# gh — official GitHub CLI repo
type -p curl >/dev/null || sudo apt install curl -y
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
  https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh -y

# ssh + python3 (usually pre-installed; install if missing)
sudo apt install -y openssh-client python3
```

### macOS

```bash
brew install gh python
# ssh ships with macOS — no install needed
```

### Windows (native — PowerShell)

```powershell
# All three via winget
winget install --id GitHub.cli       # gh
winget install --id Python.Python.3  # python3
# ssh: built-in on Windows 10+ (Settings → Apps → Optional features → OpenSSH Client)
```

> **Note:** if Claude Code is running inside WSL, use the Linux instructions
> above — the Windows native instructions apply only when running Claude Code
> directly in PowerShell or CMD.

---

## Step 3 — GitHub authentication

```bash
gh auth status
```

If not authenticated, ask the user to run in their terminal:

```bash
gh auth login
```

Then return to the session.

---

## Step 4 — Re-run the pre-flight

After setup, re-run `cloud-weaver-pre-flight-check` to confirm all tools are
present and GitHub is authenticated before proceeding.

---

## Bundled Resources

This skill has no bundled scripts — all steps run inline.
