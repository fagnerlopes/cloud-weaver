#!/usr/bin/env python3
"""
CloudWeaver repo initializer — cross-platform (Linux, macOS, Windows).
Replaces repo-init.sh. Requires only git and gh in PATH; no shell needed.

Usage: python3 repo-init.py <repo-name> [private|public]
  repo-name   : Name for the GitHub repository (e.g. "meu-hermes")
  visibility  : "private" (default) or "public"

Idempotent: if the remote repo already exists, it adds it as origin and pushes.
"""
import re
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def run(cmd, check: bool = True):
    """Run *cmd*, inheriting stdio so output is visible. Raises on non-zero when check=True."""
    return subprocess.run(cmd, check=check)


def capture(cmd) -> subprocess.CompletedProcess:
    """Run *cmd* silently and return the result."""
    return subprocess.run(cmd, capture_output=True, text=True)


def die(msg: str, detail: str = ""):
    print(f"ERROR: {msg}", file=sys.stderr)
    if detail:
        print(f"       {detail}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        die("Usage: repo-init.py <repo-name> [private|public]")

    repo_name  = sys.argv[1]
    visibility = sys.argv[2] if len(sys.argv) > 2 else "private"

    # Validate repository name — same rule as the bash version.
    if not re.match(r"^[a-zA-Z0-9_][a-zA-Z0-9._-]*$", repo_name):
        die(
            f"Nome de repositório inválido: '{repo_name}'.",
            "Use apenas letras, dígitos, hífens, underscores e pontos;"
            " não pode começar com '-' ou '.'.",
        )

    if visibility not in ("private", "public"):
        die(f"visibility deve ser 'private' ou 'public', recebeu '{visibility}'")

    # Check gh auth.
    if capture(["gh", "auth", "status"]).returncode != 0:
        die("Não autenticado no GitHub.", "Execute 'gh auth login' no terminal e tente novamente.")

    # Initialize local git repo if needed.
    if not Path(".git").is_dir():
        print("Inicializando repositório git local...")
        run(["git", "init", "-b", "main"])

    # Create an initial commit if the repo is empty.
    if capture(["git", "rev-parse", "HEAD"]).returncode != 0:
        print("Criando commit inicial...")
        run(["git", "add", "-A"])
        run(["git", "commit", "-m", "Initial commit: CloudWeaver recipe setup", "--no-gpg-sign"])

    # If remote 'origin' already set, just push and exit.
    origin_r = capture(["git", "remote", "get-url", "origin"])
    if origin_r.returncode == 0:
        print(f"Remote 'origin' já configurado: {origin_r.stdout.strip()}")
        branch_r = capture(["git", "branch", "--show-current"])
        branch = branch_r.stdout.strip() or "main"
        run(["git", "push", "-u", "origin", branch], check=False)
        sys.exit(0)

    # Check whether the repo already exists on GitHub.
    if capture(["gh", "repo", "view", repo_name]).returncode == 0:
        print(f"Repositório '{repo_name}' já existe no GitHub — adicionando como origin.")
        url_r = capture(
            ["gh", "repo", "view", repo_name, "--json", "sshUrl", "--jq", ".sshUrl"]
        )
        remote_url = url_r.stdout.strip()
        run(["git", "remote", "add", "origin", remote_url])
        branch_r = capture(["git", "branch", "--show-current"])
        branch = branch_r.stdout.strip() or "main"
        run(["git", "fetch", "origin"], check=False)
        run(["git", "push", "-u", "origin", branch])
    else:
        print(f"Criando repositório {visibility} '{repo_name}' no GitHub...")
        flag = "--private" if visibility == "private" else "--public"
        run(["gh", "repo", "create", repo_name, flag, "--source=.", "--remote=origin", "--push"])

    remote_url = capture(["git", "remote", "get-url", "origin"]).stdout.strip()
    print()
    print("Repositório pronto:")
    print(f"  Local:  {Path.cwd()}")
    print(f"  Remote: {remote_url}")


if __name__ == "__main__":
    main()
