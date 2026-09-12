---
name: cloud-weaver-computer-setup
description: >
  This skill should be used when the user asks to "set up my computer",
  "install dev tools", "set up my environment", or when the pre-flight check
  reports NEEDS_COMPUTER_SETUP or a missing SSH key. It verifies gh, ssh, and
  python3, and ensures a dedicated Ed25519 SSH key exists for CloudWeaver.
  Works on Linux, macOS, and Windows (Git for Windows or WSL).
---

# Computer Setup

**This is a sanity check, not a full install path.** CloudWeaver v2 needs
`gh` (GitHub CLI), the OpenSSH client (`ssh`), and `python3`. Everything else
runs in GitHub Actions — nothing heavy is required locally.

Idempotent — safe to re-run.

## 1. Check tools

Run via Python (cross-platform):

```python
import shutil
missing = [t for t in ["gh", "ssh", "python3"] if not shutil.which(t)]
print("Missing:", missing or "none")
```

Or in a shell:

```bash
# Linux / macOS / Git Bash
command -v gh && command -v ssh && command -v python3
```

If any are missing, tell the user to install them:

### `gh` (GitHub CLI)
- **macOS:** `brew install gh`
- **Debian/Ubuntu:** `sudo apt install gh`
- **Windows:** `winget install --id GitHub.cli` — or download from https://cli.github.com

### `ssh` (OpenSSH client)
- **macOS / Linux:** already present; `sudo apt install openssh-client` if missing
- **Windows:** built-in on Windows 10+ (`Settings → Optional features → OpenSSH Client`)

### `python3`
- **macOS:** `brew install python`
- **Debian/Ubuntu:** `sudo apt install python3`
- **Windows:** `winget install --id Python.Python.3` — or download from https://python.org

> **Windows without WSL:** install **Git for Windows** (https://git-scm.com/download/win) —
> it provides Git, Git Bash, and SSH in a single installer. Then add Python from python.org.
> `jq` is **not** required — CloudWeaver v2 uses `gh`'s built-in `--jq` flag.

## 2. GitHub authentication

```bash
gh auth status
```

If not authenticated, ask the user to run `gh auth login` in their OS
terminal and return to the session.

## 3. Re-run the pre-flight

After setup, re-run `cloud-weaver-pre-flight-check` to confirm the
environment is ready before proceeding.

## Bundled Resources

This skill has no bundled scripts — all steps run inline.
