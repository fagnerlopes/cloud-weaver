#!/usr/bin/env python3
"""Hermes Agent recipe deployer.

Ships the WAHA + PostgreSQL compose stack to the provisioned VM and starts it
with `docker compose up`. Pure Python 3 standard library, mirroring the
vm-provision.py style:

- Secrets are generated locally and written only to the VM's .env (mode 600).
- `--dry-run` prints the exact commands that would run (nothing executes),
  which is how the offline test suite asserts the deployment plan.
- `--skip-secrets` reuses the remote .env, so re-running never rotates the
  WAHA API key / dashboard password (which would invalidate clients).
- Data dirs live under /data/<env>/ on the persistent disk: grow volume is
  root-owned (the WAHA image runs as root), postgres data is chown'd to uid
  999 (the postgres image's user) BEFORE first boot.
"""

import argparse
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
PG_UID = 999  # postgres official image runs postgres as uid 999
DEFAULT_SSH_USER = "root"
HEALTH_WAIT_SECONDS = 180


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Deploy the Hermes Agent (WAHA + PostgreSQL) recipe to a VM.")
    p.add_argument("--env-name", required=True, help="Recipe/environment name ([a-z0-9_])")
    p.add_argument("--public-ip", required=True, help="Public IP of the provisioned VM")
    p.add_argument("--ssh-user", default=DEFAULT_SSH_USER, help="SSH user on the VM")
    p.add_argument("--ssh-private-key", required=True, help="Path to the Ed25519 private key")
    p.add_argument("--api-port", type=int, default=3000, help="Public TCP port for the WAHA API")
    p.add_argument("--postgres-password", default=None, help="Override the generated postgres password (tests)")
    p.add_argument("--waha-api-key", default=None, help="Override the generated WAHA API key")
    p.add_argument("--dashboard-password", default=None, help="Override the generated dashboard password")
    p.add_argument("--swagger-password", default=None, help="Override the generated swagger password")
    p.add_argument("--staging-dir", default=None, help="Where compose.yaml/.env/initdb.sql are staged")
    p.add_argument("--output", default=None, help="Write the deployment report JSON to this path")
    p.add_argument("--skip-secrets", action="store_true",
                   help="Reuse the remote .env instead of generating/scp'ing a new one")
    p.add_argument("--dry-run", action="store_true",
                   help="Print the commands that would run instead of executing them")
    return p.parse_args(argv)


def validate(cfg):
    if not NAME_RE.match(cfg["env_name"]):
        raise ValueError(
            "Invalid env_name '{}' - only lowercase letters, digits and "
            "_ are allowed ([a-z0-9_])".format(cfg["env_name"]))
    ipaddress.ip_address(cfg["public_ip"])
    if not 1 <= cfg["api_port"] <= 65535:
        raise ValueError("api_port must be between 1 and 65535")
    key = Path(cfg["ssh_private_key"])
    if not key.is_file():
        raise OSError("SSH private key not found: {}".format(key))
    if cfg["skip_secrets"] and any((cfg["postgres_password"], cfg["waha_api_key"],
                                    cfg["dashboard_password"], cfg["swagger_password"])):
        raise ValueError("--skip-secrets cannot be combined with secret overrides")


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
            raise RuntimeError("command failed ({}): {}".format(proc.returncode, detail))
        return proc.returncode


def gen_secret(nbytes):
    return secrets.token_urlsafe(nbytes)


def build_secrets(cfg):
    if cfg["skip_secrets"]:
        return None
    env_user = "hermes"
    return {
        "WAHA_PORT": str(cfg["api_port"]),
        "WAHA_API_KEY": cfg["waha_api_key"] or gen_secret(32),
        "WAHA_DASHBOARD_USERNAME": "admin",
        "WAHA_DASHBOARD_PASSWORD": cfg["dashboard_password"] or gen_secret(16),
        "WHATSAPP_SWAGGER_PASSWORD": cfg["swagger_password"] or gen_secret(16),
        "POSTGRES_DB": env_user,
        "POSTGRES_USER": env_user,
        "POSTGRES_PASSWORD": cfg["postgres_password"] or gen_secret(32),
    }


def render_env(secrets_map):
    return "\n".join("{}={}".format(k, v) for k, v in secrets_map.items()) + "\n"


def prepare_staging(cfg):
    if cfg["staging_dir"]:
        base = Path(cfg["staging_dir"])
        base.mkdir(parents=True, exist_ok=True)
    else:
        base = Path(tempfile.mkdtemp(prefix="cr-hermes-"))
    script_dir = Path(__file__).resolve().parent
    shutil.copy(script_dir / "compose" / "compose.yaml", base / "compose.yaml")
    shutil.copy(script_dir / "initdb.sql", base / "initdb.sql")
    secrets_map = build_secrets(cfg)
    env_path = base / ".env"
    if secrets_map is not None:
        env_path.write_text(render_env(secrets_map), encoding="utf-8")
        env_path.chmod(0o600)
    return base, secrets_map


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

    print("STEP: Criando diretórios na VM...", flush=True)
    runner.cmd(ssh + ["sudo mkdir -p {}/compose {}/waha {}/pgdata".format(data, data, data)])
    runner.cmd(ssh + ["sudo chown -R {}:{} {}/pgdata".format(PG_UID, PG_UID, data)])

    print("STEP: Enviando arquivos de configuração...", flush=True)
    runner.cmd(scp + ["{}/compose.yaml".format(base), "{}:{}/compose/compose.yaml".format(host, data)])
    runner.cmd(scp + ["{}/initdb.sql".format(base), "{}:{}/compose/initdb.sql".format(host, data)])
    if not cfg["skip_secrets"]:
        runner.cmd(scp + ["{}/.env".format(base), "{}:{}/compose/.env".format(host, data)])
        runner.cmd(ssh + ["sudo chmod 600 {}/compose/.env".format(data)])

    print("STEP: Iniciando containers (pode levar alguns minutos)...", flush=True)
    runner.cmd(ssh + [
        "cd {}/compose && sudo docker compose -p hermes-{} "
        "-f compose.yaml --env-file .env up -d --wait --wait-timeout {}".format(
            data, env, HEALTH_WAIT_SECONDS)])


def build_report(cfg):
    ip = cfg["public_ip"]
    port = cfg["api_port"]
    env = cfg["env_name"]
    return {
        "app": "hermes",
        "env_name": env,
        "public_ip": ip,
        "api_url": "http://{}:{}".format(ip, port),
        "dashboard_url": "http://{}:{}/dashboard".format(ip, port),
        "data_path": "/data/{}".format(env),
        "compose_path": "/data/{}/compose".format(env),
    }


def main(argv=None):
    cfg = vars(parse_args(argv if argv is not None else sys.argv[1:]))
    try:
        validate(cfg)
    except (ValueError, OSError) as exc:
        print("FATAL: {}".format(exc))
        return 1
    base, _secrets = prepare_staging(cfg)
    runner = Runner(dry_run=cfg["dry_run"])
    ssh, scp = build_ssh_args(cfg)
    deploy(runner, cfg, base, ssh, scp)
    report = build_report(cfg)
    if cfg["output"]:
        Path(cfg["output"]).write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("Deployed Hermes Agent: API {api_url} | Dashboard {dashboard_url}".format(**report))
    return 0


if __name__ == "__main__":
    sys.exit(main())