#!/usr/bin/env python3
"""
CloudWeaver teardown — remove all Locaweb Cloud resources for one env_name.

Resources removed (in order):
  1. VM (stopped → destroyed with expunge=true → data disk removed automatically)
  2. Network (releases source NAT IP + port forwarding rules)
  3. SSH keypair

Usage:
    LOCAWEB_API_KEY=... LOCAWEB_API_SECRET=... python3 teardown.py \
        --env-name preview --zone ZP01
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.parse
import urllib.request

DEFAULT_ENDPOINT = "https://painel-cloud.locaweb.com.br/client/api"
POLL_INTERVAL = 5   # seconds
STOP_TIMEOUT  = 120 # seconds to wait for VM to stop
EXPUNGE_TIMEOUT = 300  # seconds to wait for VM to be expunged


# ---------------------------------------------------------------------------
# CloudStack signing (same scheme as vm-provision.py)
# ---------------------------------------------------------------------------

def _signed_query(command: str, params: dict, api_key: str, secret: str) -> str:
    q = dict(params)
    q["command"] = command
    q["response"] = "json"
    q["apiKey"] = api_key
    canonical = "&".join(
        "{}={}".format(k, urllib.parse.quote(str(v), safe=""))
        for k, v in sorted(q.items())
    )
    digest = hmac.new(
        secret.encode("utf-8"), canonical.lower().encode("utf-8"), hashlib.sha1
    ).digest()
    sig = urllib.parse.quote_plus(base64.b64encode(digest).decode("ascii"))
    return "{}&signature={}".format(canonical, sig)


class CSError(RuntimeError):
    pass


def _call(endpoint: str, api_key: str, secret: str, command: str, **params) -> dict:
    """Sign and execute one CloudStack API call; raise CSError on API error."""
    query = _signed_query(command, params, api_key, secret)
    url = "{}?{}".format(endpoint, query)
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:
        raise CSError("HTTP error calling {}: {}".format(command, exc)) from exc

    if "errorresponse" in body:
        msg = body["errorresponse"].get("errortext") or str(body)
        raise CSError(msg)

    rk = command.lower() + "response"
    if rk in body:
        return body[rk]
    if len(body) == 1:
        return next(iter(body.values()))
    raise CSError("Unexpected response for '{}': {}".format(command, body))


# ---------------------------------------------------------------------------
# Teardown steps
# ---------------------------------------------------------------------------

def _resolve_zone(endpoint: str, api_key: str, secret: str, zone_name: str) -> str:
    data = _call(endpoint, api_key, secret, "listZones", filter="id,name")
    for z in data.get("zone") or []:
        if z.get("name") == zone_name:
            return z["id"]
    raise CSError("Zona '{}' não encontrada".format(zone_name))


def _find_vm(endpoint: str, api_key: str, secret: str,
             vm_name: str, zone_id: str) -> "dict | None":
    data = _call(endpoint, api_key, secret, "listVirtualMachines",
                 name=vm_name, zoneid=zone_id, filter="id,name,state")
    for vm in data.get("virtualmachine") or []:
        if vm.get("name") == vm_name:
            return vm
    return None


def _wait_vm_state(endpoint: str, api_key: str, secret: str,
                   vm_id: str, zone_id: str, target: str, timeout: int) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        data = _call(endpoint, api_key, secret, "listVirtualMachines",
                     id=vm_id, zoneid=zone_id, filter="id,state")
        vms = data.get("virtualmachine") or []
        if vms and vms[0].get("state") == target:
            return
        if not vms:
            return  # VM already gone — treat as success for Expunging case
        time.sleep(POLL_INTERVAL)
    raise CSError("VM não atingiu estado '{}' em {}s".format(target, timeout))


def _destroy_vm(endpoint: str, api_key: str, secret: str,
                env_name: str, zone_id: str) -> None:
    network_name = "cr-{}".format(env_name)
    vm_name = "{}-vm".format(network_name)

    vm = _find_vm(endpoint, api_key, secret, vm_name, zone_id)
    if not vm:
        print("  ℹ️  VM '{}' não encontrada (já removida?)".format(vm_name), flush=True)
        return

    vm_id = vm["id"]
    state = vm.get("state", "")

    if state in ("Destroyed", "Expunging", "Expunged"):
        print("  ℹ️  VM já em estado de remoção: {}".format(state), flush=True)
        return

    if state == "Running":
        print("  Parando VM {}...".format(vm_name), flush=True)
        _call(endpoint, api_key, secret, "stopVirtualMachine", id=vm_id)
        _wait_vm_state(endpoint, api_key, secret, vm_id, zone_id,
                       "Stopped", STOP_TIMEOUT)
        print("  VM parada.", flush=True)

    print("  Destruindo VM e disco de dados (expunge=true)...", flush=True)
    _call(endpoint, api_key, secret, "destroyVirtualMachine", id=vm_id, expunge=True)

    # Poll until the VM disappears from the listing.
    deadline = time.time() + EXPUNGE_TIMEOUT
    while time.time() < deadline:
        vm_now = _find_vm(endpoint, api_key, secret, vm_name, zone_id)
        if not vm_now:
            break
        st = vm_now.get("state", "?")
        if st in ("Expunged",):
            break
        print("  VM estado: {} — aguardando remoção...".format(st), flush=True)
        time.sleep(POLL_INTERVAL)
    else:
        print("  ⚠️  Timeout aguardando expunge da VM — verifique no painel.", flush=True)
        return

    print("  ✅ VM e disco de dados removidos.", flush=True)


def _delete_network(endpoint: str, api_key: str, secret: str,
                    env_name: str, zone_id: str) -> None:
    network_name = "cr-{}".format(env_name)
    data = _call(endpoint, api_key, secret, "listNetworks",
                 name=network_name, zoneid=zone_id, filter="id,name")
    nets = [n for n in (data.get("network") or []) if n.get("name") == network_name]
    if not nets:
        print("  ℹ️  Rede '{}' não encontrada.".format(network_name), flush=True)
        return
    net_id = nets[0]["id"]
    _call(endpoint, api_key, secret, "deleteNetwork", id=net_id)
    print("  ✅ Rede '{}' e IP público removidos.".format(network_name), flush=True)


def _delete_keypair(endpoint: str, api_key: str, secret: str, env_name: str) -> None:
    keypair_name = "cr-{}-key".format(env_name)
    data = _call(endpoint, api_key, secret, "listSSHKeyPairs",
                 name=keypair_name, filter="id,name")
    if not data.get("sshkeypair"):
        print("  ℹ️  Keypair '{}' não encontrado.".format(keypair_name), flush=True)
        return
    _call(endpoint, api_key, secret, "deleteSSHKeyPair", name=keypair_name)
    print("  ✅ Keypair SSH '{}' removido.".format(keypair_name), flush=True)


def teardown(endpoint: str, api_key: str, secret: str,
             env_name: str, zone: str) -> None:
    print("STEP: Resolvendo zona {}...".format(zone), flush=True)
    zone_id = _resolve_zone(endpoint, api_key, secret, zone)

    print("STEP: Removendo VM e disco de dados...", flush=True)
    _destroy_vm(endpoint, api_key, secret, env_name, zone_id)

    print("STEP: Removendo rede e IP público...", flush=True)
    _delete_network(endpoint, api_key, secret, env_name, zone_id)

    print("STEP: Removendo keypair SSH...", flush=True)
    _delete_keypair(endpoint, api_key, secret, env_name)

    print("", flush=True)
    print("✅ Teardown concluído — todos os recursos na Locaweb Cloud foram removidos.", flush=True)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(
        description="Remove all CloudWeaver resources from Locaweb Cloud")
    p.add_argument("--env-name", default="preview",
                   help="Environment name used during provisioning (default: preview)")
    p.add_argument("--zone", default="ZP01",
                   help="Locaweb Cloud zone where resources were provisioned (default: ZP01)")
    p.add_argument("--endpoint", default="",
                   help="CloudStack API endpoint (optional, overrides LOCAWEB_API_ENDPOINT)")
    args = p.parse_args()

    api_key = os.environ.get("LOCAWEB_API_KEY", "").strip()
    api_secret = os.environ.get("LOCAWEB_API_SECRET", "").strip()
    if not api_key or not api_secret:
        print("FATAL: LOCAWEB_API_KEY e LOCAWEB_API_SECRET devem estar definidos",
              file=sys.stderr)
        sys.exit(1)

    endpoint = (args.endpoint
                or os.environ.get("LOCAWEB_API_ENDPOINT", "")
                or DEFAULT_ENDPOINT)

    try:
        teardown(endpoint, api_key, api_secret, args.env_name, args.zone)
    except CSError as exc:
        print("FATAL: {}".format(exc), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
