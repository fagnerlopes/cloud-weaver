#!/usr/bin/env python3
"""Hermes Agent recipe deployer.

Ships the Traefik + ttyd + hermes-agent compose stack to the provisioned VM.
Pure Python 3 standard library; mirrors the deploy-hermes.py style.

Key differences from deploy-hermes.py:
- No public port for the application (Telegram long polling only).
- Traefik handles TLS via Let's Encrypt on the VM's <public_ip>.nip.io hostname.
- Basic auth password is generated and shown only in the JSON report — never
  in command output (which the agent turns into user-visible text).
- ~/.hermes/config.yaml is written via SCP before the first compose up.
"""

import argparse
import base64
import hashlib
import ipaddress
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

NAME_RE = re.compile(r"^[a-z0-9_]+$")
DEFAULT_SSH_USER = "root"
HEALTH_WAIT_SECONDS = 300


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Deploy the Hermes Agent (Telegram + LLM) recipe to a VM.")
    p.add_argument("--env-name", required=True,
                   help="Recipe/environment name ([a-z0-9_])")
    p.add_argument("--public-ip", required=True,
                   help="Public IP of the provisioned VM")
    p.add_argument("--hostname", required=True,
                   help="Full public hostname for TLS, e.g. 187.45.201.251.nip.io")
    p.add_argument("--telegram-user-id", required=True, type=int,
                   help="Telegram user ID for TELEGRAM_ALLOWED_USERS")
    p.add_argument("--ssh-user", default=DEFAULT_SSH_USER)
    p.add_argument("--ssh-private-key", required=True,
                   help="Path to the Ed25519 private key")
    p.add_argument("--terminal-user", required=True,
                   help="Username for the web terminal basic auth (whitespace is trimmed)")
    p.add_argument("--admin-pass", default=None,
                   help="Override the generated admin password (tests only)")
    p.add_argument("--staging-dir", default=None,
                   help="Where compose.yaml/.env are staged (default: tempdir)")
    p.add_argument("--output", default=None,
                   help="Write the deployment report JSON to this path")
    p.add_argument("--skip-secrets", action="store_true",
                   help="Reuse the remote .env; do not generate or upload a new one")
    p.add_argument("--dry-run", action="store_true",
                   help="Print the commands that would run without executing them")
    return p.parse_args(argv)


def validate(cfg):
    # Trim whitespace from terminal_user here so the rest of the code uses the
    # clean value — the caller (SKILL.md) may pass a string with accidental spaces.
    cfg["terminal_user"] = cfg["terminal_user"].strip()
    if not cfg["terminal_user"]:
        raise ValueError("--terminal-user cannot be empty or whitespace-only")
    if not NAME_RE.match(cfg["env_name"]):
        raise ValueError(
            "Invalid env_name '{}' — only lowercase letters, digits and "
            "_ are allowed ([a-z0-9_])".format(cfg["env_name"]))
    try:
        ipaddress.ip_address(cfg["public_ip"])
    except ValueError:
        raise ValueError("Invalid public_ip '{}'".format(cfg["public_ip"]))
    if cfg["telegram_user_id"] <= 0:
        raise ValueError(
            "telegram_user_id must be a positive integer, got {}".format(
                cfg["telegram_user_id"]))
    key = Path(cfg["ssh_private_key"])
    if not key.is_file():
        raise OSError("SSH private key not found: {}".format(key))
    if cfg["skip_secrets"] and cfg.get("admin_pass"):
        raise ValueError("--skip-secrets cannot be combined with --admin-pass")
    # Bot token is a secret — must come from the environment, never the CLI.
    # In dry-run the deployer only prints the command plan, so a missing token
    # is tolerated; build_secrets() writes a REPLACE_WITH placeholder instead.
    if not cfg.get("skip_secrets") and not cfg.get("dry_run"):
        bot_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
        if not bot_token or bot_token.startswith("REPLACE_"):
            raise ValueError(
                "TELEGRAM_BOT_TOKEN is not set. "
                "Export it in your terminal before running the deployer.")


class Runner:
    """Executes command lists, or prints them verbatim in dry-run mode."""

    def __init__(self, dry_run=False, stream=sys.stdout):
        self.dry_run = dry_run
        self.stream = stream

    def cmd(self, argv):
        # In dry-run, print every command so callers can assert the plan.
        # In real mode, suppress command lines — only STEP: markers are shown.
        if self.dry_run:
            print("CMD " + shlex.join(argv), file=self.stream, flush=True)
            return 0
        try:
            proc = subprocess.run(argv, capture_output=True, text=True)
        except OSError as exc:
            raise RuntimeError("failed to launch {}: {}".format(argv[0], exc))
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "").strip()
            raise RuntimeError("command failed ({}): {}".format(
                proc.returncode, detail))
        return proc.returncode


def gen_secret(nbytes=32):
    return secrets.token_urlsafe(nbytes)


def make_basic_auth(username, password):
    """Return an htpasswd entry using SHA1 (Traefik-compatible).

    Format: username:{SHA}base64(sha1(password))
    This avoids any non-stdlib dependency (no bcrypt/passlib).
    """
    sha1 = hashlib.sha1(password.encode("utf-8")).digest()
    b64 = base64.b64encode(sha1).decode("ascii")
    return "{}:{{SHA}}{}".format(username, b64)


def build_secrets(cfg):
    """Generate the .env secrets dict and the plaintext admin password.

    Returns (env_map, admin_pass). admin_pass is the raw password for the
    report; env_map has the hashed form suitable for Traefik basic auth.
    If --skip-secrets, returns (None, None).
    """
    if cfg["skip_secrets"]:
        return None, None
    admin_pass = cfg.get("admin_pass") or gen_secret(32)
    ttyd_basic_auth = make_basic_auth(cfg["terminal_user"], admin_pass)
    env_map = {
        # Bot token comes from the environment — never from CLI args or chat.
        # When running in dry-run mode the token may be absent or empty; write a
        # REPLACE_WITH placeholder so the generated .env template is complete.
        "TELEGRAM_BOT_TOKEN": (
            os.environ.get("TELEGRAM_BOT_TOKEN") or "REPLACE_WITH_TELEGRAM_BOT_TOKEN"),
        "TELEGRAM_ALLOWED_USERS": str(cfg["telegram_user_id"]),
        "ENV_NAME": cfg["env_name"],
        "HOSTNAME": cfg["hostname"],
        "TTYD_BASIC_AUTH": ttyd_basic_auth,
    }
    return env_map, admin_pass


def render_env(env_map):
    return "\n".join("{}={}".format(k, v) for k, v in env_map.items()) + "\n"


def prepare_staging(cfg):
    """Stage compose.yaml, .env and hermes-config.yaml for SCP transfer."""
    if cfg["staging_dir"]:
        base = Path(cfg["staging_dir"])
        base.mkdir(parents=True, exist_ok=True)
    else:
        base = Path(tempfile.mkdtemp(prefix="cr-hermes-agent-"))

    script_dir = Path(__file__).resolve().parent
    shutil.copy(script_dir / "compose" / "compose.yaml", base / "compose.yaml")
    shutil.copy(script_dir / "hermes-config.yaml", base / "hermes-config.yaml")

    env_map, admin_pass = build_secrets(cfg)
    if env_map is not None:
        env_path = base / ".env"
        env_path.write_text(render_env(env_map), encoding="utf-8")
        env_path.chmod(0o600)

    return base, admin_pass


def build_ssh_args(cfg):
    common = ["-i", cfg["ssh_private_key"],
              "-o", "BatchMode=yes",
              "-o", "StrictHostKeyChecking=accept-new",
              "-o", "ConnectTimeout=15"]
    ssh = ["ssh"] + common + ["{}@{}".format(cfg["ssh_user"], cfg["public_ip"])]
    scp = ["scp"] + common
    return ssh, scp


def deploy(runner, cfg, base, ssh, scp):
    env = cfg["env_name"]
    data = "/data/{}".format(env)
    host = "{}@{}".format(cfg["ssh_user"], cfg["public_ip"])

    # Create data directories on the persistent disk
    print("STEP: Criando diretórios na VM...", flush=True)
    runner.cmd(ssh + [
        "sudo mkdir -p {}/compose {}/hermes_data {}/acme".format(data, data, data)
    ])

    # Upload compose stack and secrets
    print("STEP: Enviando arquivos de configuração...", flush=True)
    runner.cmd(scp + ["{}/compose.yaml".format(base),
                      "{}:{}/compose/compose.yaml".format(host, data)])
    if not cfg["skip_secrets"]:
        runner.cmd(scp + ["{}/.env".format(base),
                           "{}:{}/compose/.env".format(host, data)])
        runner.cmd(ssh + ["sudo chmod 600 {}/compose/.env".format(data)])

    # Write Hermes Agent config (approvals.mode: smart)
    runner.cmd(scp + ["{}/hermes-config.yaml".format(base),
                      "{}:{}/hermes_data/config.yaml".format(host, data)])

    # Bring up the stack
    print("STEP: Iniciando containers (pode levar alguns minutos)...", flush=True)
    runner.cmd(ssh + [
        "cd {}/compose && sudo docker compose -p hermes-agent-{} "
        "-f compose.yaml --env-file .env up -d --wait --wait-timeout {}".format(
            data, env, HEALTH_WAIT_SECONDS)
    ])


def build_report(cfg, admin_pass):
    hostname = cfg["hostname"]
    return {
        "app": "hermes-agent",
        "env_name": cfg["env_name"],
        "public_ip": cfg["public_ip"],
        "hostname": hostname,
        "terminal_url": "https://{}".format(hostname),
        "admin_user": cfg["terminal_user"],
        # admin_pass is included here (report file) but never printed to stdout,
        # so it does not appear in the agent's visible session output.
        "admin_pass": admin_pass,
        "data_path": "/data/{}".format(cfg["env_name"]),
        "compose_path": "/data/{}/compose".format(cfg["env_name"]),
        "note": (
            "The Telegram bot is already configured. "
            "Run `hermes setup` in the web terminal to configure the LLM provider and GitHub."
        ),
    }


def main(argv=None):
    cfg = vars(parse_args(argv if argv is not None else sys.argv[1:]))
    try:
        validate(cfg)
    except (ValueError, OSError) as exc:
        print("FATAL: {}".format(exc))
        return 1

    base, admin_pass = prepare_staging(cfg)
    runner = Runner(dry_run=cfg["dry_run"])
    ssh, scp = build_ssh_args(cfg)
    deploy(runner, cfg, base, ssh, scp)

    report = build_report(cfg, admin_pass)
    if cfg["output"]:
        report_path = cfg["output"]
        Path(report_path).write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8")
        # Restrict permissions: the report contains admin_pass in plaintext.
        os.chmod(report_path, 0o600)
    # Print only the URL and key facts — never the admin_pass — to stdout.
    print("Deployed Hermes Agent: terminal {terminal_url}".format(**report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
