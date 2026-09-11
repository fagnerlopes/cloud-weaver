---
name: cloud-weaver-computer-setup
description: >
  This skill should be used when the user asks to "set up my computer",
  "install dev tools", "set up my environment", or when the pre-flight check
  reports NEEDS_COMPUTER_SETUP or a missing SSH key. It verifies gh, ssh, and
  jq, and ensures a dedicated Ed25519 SSH key exists for CloudWeaver.
---

# Computer Setup

**This is a sanity check, not a full install path.** cloud-weaver only needs
`gh`, the OpenSSH client, and `jq`. This skill verifies they are present and
creates/verifies the dedicated Ed25519 SSH key used to reach the provisioned
VMs. Idempotent — safe to re-run.

## 1. Check tools

```bash
command -v gh && command -v ssh && command -v jq
```

If any are missing, tell the user to open a fresh OS terminal and install
them, then return:

- **`gh` (GitHub CLI):**
  - macOS: `brew install gh`
  - Debian/Ubuntu: `sudo apt install gh`
  - Windows/WSL: `winget install --id GitHub.cli`
- **OpenSSH client (`ssh`):** already present on macOS and most Linux
  distros; `sudo apt install openssh-client` otherwise.
- **`jq`:** `sudo apt install jq` (or `brew install jq`).

## 2. GitHub authentication

```bash
gh auth status
```

If not authenticated, ask the user to run `gh auth login` in their OS
terminal and return to the session.

## 3. Dedicated Ed25519 SSH key

Use the same key for all cloud-weaver VMs — the key is provisioned into each
new VM. Naming follows the recipe convention:

- preview: `~/.ssh/cloud-weaver`
- other envs: `~/.ssh/cloud-weaver-<env>`

Create it if missing (never overwrite an existing key):

```bash
SSHKEY="$HOME/.ssh/cloud-weaver"
[[ -f "$SSHKEY" ]] || ssh-keygen -t ed25519 -N "" -f "$SSHKEY" -C "cloud-weaver"
chmod 600 "$SSHKEY"
```

Verify:

```bash
ssh-keygen -y -f "$SSHKEY" >/dev/null && echo OK
```

## 4. Re-run the pre-flight

After setup, re-run `cloud-weaver-pre-flight-check` to confirm the
environment is ready before proceeding.

## Bundled Resources

This skill has no bundled scripts — all steps run inline. The require and
verify of the SSH key also lives in `cloud-weaver-vm-setup`.