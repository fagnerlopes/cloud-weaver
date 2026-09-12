#!/usr/bin/env python3
"""
CloudWeaver pre-flight check — cross-platform (Linux, macOS, Windows).
Replaces preflight.sh. Requires only the Python 3 standard library (3.9+).

Exit 0  → prints PREFLIGHT_PASSED (possibly with NEEDS_* flags).
Exit 1  → prints PREFLIGHT_FAILED with error details.
"""
import base64
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).parent.parent


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def run_capture(cmd):
    """Run *cmd* and return CompletedProcess. Never raises on non-zero exit."""
    return subprocess.run(cmd, capture_output=True, text=True)


def cmd_exists(name: str) -> bool:
    return shutil.which(name) is not None


def fail(*lines: str):
    print("PREFLIGHT_FAILED")
    for line in lines:
        print(f"  - {line}")
    sys.exit(1)


# ---------------------------------------------------------------------------
# 0. Version check — auto-update when remote is newer.
# ---------------------------------------------------------------------------

def _local_version() -> str:
    try:
        text = (SKILL_DIR / "SKILL.md").read_text(encoding="utf-8")
        m = re.search(r"(\d+\.\d+\.\d+)", text)
        return m.group(1) if m else ""
    except OSError:
        return ""


def _remote_version() -> str:
    import urllib.request
    url = (
        "https://api.github.com/repos/fagnerlopes/cloud-weaver"
        "/contents/.claude-plugin/plugin.json"
    )
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cloud-weaver-preflight"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read())
            raw = base64.b64decode(data.get("content", "")).decode("utf-8")
            return json.loads(raw).get("version", "")
    except Exception:
        return ""


def _ver_tuple(v: str):
    try:
        return tuple(int(x) for x in v.split("."))
    except Exception:
        return (0, 0, 0)


def _check_version():
    local = _local_version()
    if not local:
        return
    remote = _remote_version()
    if not remote or _ver_tuple(remote) <= _ver_tuple(local):
        return

    print(f"SKILLS_UPDATING: versão local={local} → remota={remote}")
    npx_cmd = (
        ["mise", "x", "node@22", "--", "npx", "-y", "skills", "update"]
        if cmd_exists("mise")
        else ["npx", "-y", "skills", "update"]
    )
    r = subprocess.run(npx_cmd)
    if r.returncode == 0:
        print(
            f"SKILLS_UPDATED: skills atualizadas para {remote}"
            " — inicie uma nova sessão para usar a versão atualizada."
        )
    else:
        print(
            "SKILLS_UPDATE_FAILED: não foi possível atualizar automaticamente."
            " Execute: npx -y skills update"
        )
    sys.exit(0)


_check_version()


# ---------------------------------------------------------------------------
# 1. Sensitive file guard
# ---------------------------------------------------------------------------

_SENSITIVE_RE = re.compile(
    r"(\.env(\.[^/]+)?$"
    r"|(^|/)id_(rsa|dsa|ecdsa|ed25519)$"
    r"|(^|/)\.(npmrc|netrc|pypirc)$"
    r"|\.(pem|key|secret|p12|pfx|jks|keystore)$"
    r"|(credentials|sa\.?key|service\.?account)[^/]*\.json$"
    r"|(^|/)secrets?\.(ya?ml|json)$)",
    re.IGNORECASE,
)
_SAFE_RE = re.compile(
    r"\.(example|sample|template|dist|tpl|tmpl)$",
    re.IGNORECASE,
)


def _collect_git_files(args) -> set:
    r = run_capture(["git"] + args)
    return set(r.stdout.splitlines()) if r.returncode == 0 else set()


has_git = Path(".git").is_dir()
has_remote = False

if has_git:
    has_remote = bool(run_capture(["git", "remote"]).stdout.strip())
    status = run_capture(["git", "status", "--porcelain"])
    if status.stdout.strip():
        all_files = (
            _collect_git_files(["ls-files", "--others", "--exclude-standard"])
            | _collect_git_files(["diff", "--cached", "--name-only", "--diff-filter=d"])
            | _collect_git_files(["diff", "--name-only", "--diff-filter=d"])
        )
        sensitive = sorted(
            f for f in all_files
            if _SENSITIVE_RE.search(f) and not _SAFE_RE.search(f)
        )
        if sensitive:
            print("PREFLIGHT_FAILED")
            print("  - SENSITIVE_FILES_DETECTED: arquivos com possíveis credenciais detectados.")
            print("    - Não rastreado: adicione ao .gitignore")
            print("    - Staged:        execute 'git restore --staged <arquivo>'")
            print("    - Rastreado:     execute 'git rm --cached <arquivo>' e adicione ao .gitignore")
            for f in sensitive:
                print(f"    {f}")
            sys.exit(1)


# ---------------------------------------------------------------------------
# 2. Git sync
# ---------------------------------------------------------------------------

if has_git and has_remote:
    branch_r = run_capture(["git", "symbolic-ref", "--short", "HEAD"])
    current_branch = branch_r.stdout.strip()
    if not current_branch:
        fail("GIT_SYNC_ERROR: HEAD está detached — não é possível sincronizar.")

    upstream_r = run_capture(["git", "rev-parse", "--abbrev-ref", "@{upstream}"])
    upstream = upstream_r.stdout.strip() if upstream_r.returncode == 0 else ""

    if run_capture(["git", "status", "--porcelain"]).stdout.strip():
        print("SYNC: Commitando alterações locais...")
        run_capture(["git", "add", "-A"])
        r = run_capture(
            ["git", "commit", "-m",
             "Auto-sync: commit outstanding changes before session",
             "--no-gpg-sign"]
        )
        if r.returncode != 0:
            fail("GIT_SYNC_ERROR: Falha ao commitar alterações locais.")

    if upstream:
        print(f"SYNC: Pulling remote changes (upstream: {upstream})...")
        if run_capture(["git", "pull", "--rebase"]).returncode != 0:
            fail("GIT_SYNC_ERROR: Pull falhou — possível conflito. Resolva manualmente e re-execute.")
        print("SYNC: Pushing local commits...")
        if run_capture(["git", "push"]).returncode != 0:
            fail("GIT_SYNC_ERROR: Push falhou — verifique acesso ao remote e tente novamente.")
    else:
        print(f"SYNC: Sem upstream configurado, tentando origin/{current_branch}...")
        if run_capture(["git", "rev-parse", "--verify", f"origin/{current_branch}"]).returncode == 0:
            if run_capture(["git", "pull", "--rebase", "origin", current_branch]).returncode != 0:
                fail("GIT_SYNC_ERROR: Pull falhou — possível conflito. Resolva manualmente e re-execute.")
        if run_capture(["git", "push", "--set-upstream", "origin", current_branch]).returncode != 0:
            fail("GIT_SYNC_ERROR: Push falhou — verifique acesso ao remote e tente novamente.")

    print("SYNC: Repository is up to date.")


# ---------------------------------------------------------------------------
# 3. Tools
# ---------------------------------------------------------------------------

missing = [t for t in ["gh", "ssh"] if not cmd_exists(t)]
if missing:
    print(f"NEEDS_COMPUTER_SETUP: missing {' '.join(missing)}")


# ---------------------------------------------------------------------------
# 4. GitHub auth
# ---------------------------------------------------------------------------

if cmd_exists("gh") and run_capture(["gh", "auth", "status"]).returncode != 0:
    print("NEEDS_GITHUB_AUTH: GitHub CLI instalado mas não autenticado.")


# ---------------------------------------------------------------------------
# 5. Locaweb Cloud credentials
# ---------------------------------------------------------------------------

if not os.environ.get("LOCAWEB_API_KEY") or not os.environ.get("LOCAWEB_API_SECRET"):
    print(
        "NEEDS_LOCAWEB_CREDENTIALS: LOCAWEB_API_KEY e LOCAWEB_API_SECRET"
        " não estão ambas definidas no ambiente."
    )


# ---------------------------------------------------------------------------
# 6. Telegram Bot Token
# ---------------------------------------------------------------------------

if not os.environ.get("TELEGRAM_BOT_TOKEN"):
    print("NEEDS_TELEGRAM_BOT_TOKEN: TELEGRAM_BOT_TOKEN não está definida no ambiente.")


print("PREFLIGHT_PASSED")
sys.exit(0)
