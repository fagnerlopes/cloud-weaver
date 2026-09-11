#!/usr/bin/env python3
"""Idempotent single-VM provisioning on Locaweb Cloud via the CloudStack API.

Creates (or reuses) the resources a Cloud Recipes deployment needs:
- isolated network ("Default Guest Network")
- SSH keypair (registers the given local Ed25519 public key)
- one VM from the Ubuntu 24 template, with cloud-init userdata
- a public IP with static NAT and firewall rules (SSH 22 + recipe ports)
- a data disk mounted at /data (see userdata/boot_vm.sh)

Pure standard library (urllib + hmac) with HMAC-SHA1 request signing, the
CloudStack authentication scheme. Credentials come from the LOCAWEB_API_KEY /
LOCAWEB_API_SECRET environment variables; values are never printed.

Idempotent: every step resolves existing resources before creating, so
re-running the script (or running it again after a partial failure) reuses
what is already provisioned.

Usage:
    LOCAWEB_API_KEY=... LOCAWEB_API_SECRET=... python3 vm-provision.py \
        --env-name myenv --plan c4 --ports 3000,8080 \
        --ssh-pubkey ~/.ssh/cloud-recipes.pub

Offline testing: set LOCAWEB_MOCK_FIXTURES=<json> and LOCAWEB_MOCK_LOG=<file>
to drive the API with fixture responses instead of the real endpoint.
"""
import argparse
import base64
import copy
import hashlib
import hmac
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

NAME_RE = re.compile(r"^[a-z0-9_]+$")
IDENT_RE = re.compile(r"^[A-Za-z0-9_-]+$")  # CloudStack names (zones, plans)
TEMPLATE_REGEX = re.compile(r"^Ubuntu.*24.*$")
NETWORK_OFFERING_NAME = "Default Guest Network"
DISK_OFFERING_NAME = "data.disk.general"
API_RETRIES = 5
API_BACKOFF = [2, 4, 8, 16, 32]
VM_RUNNING_TIMEOUT = 300  # seconds
VM_POLL_INTERVAL = 5


class CloudStackError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Request signing (CloudStack scheme)
# ---------------------------------------------------------------------------

def build_signed_query(command, params, api_key, secret):
    """Build the canonical query string and append the HMAC-SHA1 signature.

    Follows the Apache CloudStack documented Python sample: sort every
    parameter (including apiKey and command/response) by key, join as
    key=base64-ish-urlencoded pairs, then sign the whole string with the
    secret key. The signature itself is appended as the final pair.
    """
    q = dict(params)
    q["command"] = command
    q["response"] = "json"
    q["apiKey"] = api_key
    canonical = "&".join(
        "{}={}".format(k, urllib.parse.quote_plus(str(v)))
        for k, v in sorted(q.items())
    )
    digest = hmac.new(
        str(secret).encode("utf-8"), canonical.encode("utf-8"), hashlib.sha1
    ).digest()
    signature = urllib.parse.quote_plus(base64.b64encode(digest).decode("ascii"))
    return "{}&signature={}".format(canonical, signature)


# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------

class UrllibTransport:
    """Real transport: GET the signed query against the CloudStack endpoint."""

    def __init__(self, endpoint):
        self.endpoint = endpoint.rstrip("/")

    def request(self, query):
        url = "{}?{}".format(self.endpoint, query)
        with urllib.request.urlopen(url, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))


# Test-hook only: once these commands run, their produced resources appear in
# the matching *list* responses, mirroring real CloudStack state transitions.
_MOCK_CREATE_EFFECTS = {
    # (create command) -> ((list command), (list entries key), entry builder)
    "deployVirtualMachine": ("listVirtualMachines", "virtualmachine",
                             lambda p: {"id": "vm1",
                                        "name": (p.get("name") or ["cr-hermes-vm"])[0],
                                        "state": "Running",
                                        "nic": [{"ipaddress": "10.0.0.5"}]}),
    "createVolume": ("listVolumes", "volume",
                     lambda p: {"id": "vol1", "name": p["name"][0],
                                "virtualmachineid": "vm1", "state": "Ready"}),
    "createFirewallRule": ("listFirewallRules", "firewallrule",
                           lambda p: {"id": "fw-{}".format(p["startport"][0]),
                                      "startport": int(p["startport"][0]),
                                      "endport": int(p["endport"][0])}),
    "associateIpAddress": ("listPublicIpAddresses", "publicipaddress",
                           lambda p: {"id": "ip1", "ipaddress": "200.1.2.3",
                                      "issourcenat": False,
                                      "isstaticnat": False,
                                      "virtualmachineid": None}),
}
_MOCK_IP_UPDATE_AFTER = ("enableStaticNat", "publicipaddress")


class MockTransport:
    """Offline transport driven by a fixtures file (test hook only).

    LOCAWEB_MOCK_FIXTURES maps each API command to the exact JSON body the
    real endpoint would return (including the "listzonesresponse" wrapper).
    Every request is appended to LOCAWEB_MOCK_LOG so tests can assert which
    commands ran. Created resources show up in subsequent *list* responses so
    the provisioning flow can be exercised end to end offline. Never used when
    the env vars are unset.
    """

    def __init__(self, fixtures_path, log_path):
        with open(fixtures_path, "r") as f:
            self.fixtures = json.load(f)
        self.log_path = log_path
        self.called = []

    def request(self, query):
        params = urllib.parse.parse_qs(query)
        command = params.get("command", [None])[0]
        self.called.append(command)
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(command + "\n")
        if command not in self.fixtures:
            raise CloudStackError(
                "Mock: no fixture for command '{}'".format(command)
            )
        body = copy.deepcopy(self.fixtures[command])
        self._apply_effects(body, command, params)
        return body

    def _apply_effects(self, body, command, params):
        """Inject state from already-run commands into list responses."""
        response_key = command.lower() + "response"
        if response_key not in body:
            return
        payload = body[response_key]

        for create_cmd, (list_cmd, key, builder) in _MOCK_CREATE_EFFECTS.items():
            if command == list_cmd and create_cmd in self.called:
                entries = payload.setdefault(key, [])
                entry = builder(params)
                if command == "listVirtualMachines" and \
                        any(v.get("id") == entry["id"] for v in entries):
                    continue
                entries.append(entry)

        if command == "listPublicIpAddresses" and "enableStaticNat" in self.called:
            for ip in payload.setdefault("publicipaddress", []):
                if ip.get("id") == "ip1":
                    ip["isstaticnat"] = True
                    ip["virtualmachineid"] = "vm1"


class CloudStackClient:
    def __init__(self, endpoint, api_key, secret, transport=None):
        self.api_key = api_key
        self.secret = secret
        self._transport = transport or UrllibTransport(endpoint)

    def call(self, command, retries=API_RETRIES, **params):
        """Run a command; retry transient failures; raise on API errors."""
        query = build_signed_query(command, params, self.api_key, self.secret)
        last_error = None
        for attempt in range(retries + 1):
            try:
                body = self._transport.request(query)
                return _unwrap(body, command)
            except CloudStackError:
                raise
            except Exception as exc:  # network/HTTP/JSON issues are retried
                last_error = exc
                if attempt < retries:
                    time.sleep(API_BACKOFF[min(attempt, len(API_BACKOFF) - 1)])
        raise CloudStackError(
            "API call '{}' failed after {} attempts: {}".format(
                command, retries + 1, last_error
            )
        )


def _unwrap(body, command):
    """Extract the inner payload of a CloudStack JSON response."""
    response_key = command.lower() + "response"
    if isinstance(body, dict):
        if "errorresponse" in body:
            err = body["errorresponse"]
            text = err.get("errortext") or err.get("cserrorcode") or err
            raise CloudStackError(text)
        if "exceptionresponse" in body:
            err = body["exceptionresponse"]
            raise CloudStackError(err.get("errortext") or err)
        if response_key in body:
            return body[response_key]
        if len(body) == 1:
            return next(iter(body.values()))
    raise CloudStackError("Unexpected response for '{}': {}".format(command, body))


# ---------------------------------------------------------------------------
# Resolution helpers
# ---------------------------------------------------------------------------

def list_match(client, command, entries_key, name, filter_expr="id,name", **extra):
    """Return the first entry whose 'name' matches, resolving by name."""
    params = {"filter": filter_expr, **extra}
    data = client.call(command, **params)
    entries = data.get(entries_key) or []
    for entry in entries:
        if entry.get("name") == name:
            return entry
    raise CloudStackError(
        "{} named '{}' not found".format(entries_key.rstrip("s"), name)
    )


def resolve_zone(client, zone_name):
    return list_match(client, "listZones", "zone", zone_name)["id"]


def resolve_network_offering(client, name=NETWORK_OFFERING_NAME):
    return list_match(client, "listNetworkOfferings", "networkoffering", name)["id"]


def resolve_service_offering(client, plan):
    return list_match(client, "listServiceOfferings", "serviceoffering", plan)["id"]


def resolve_disk_offering(client, name=DISK_OFFERING_NAME):
    return list_match(client, "listDiskOfferings", "diskoffering", name)["id"]


def resolve_template(client, zone_id):
    data = client.call(
        "listTemplates",
        templatefilter="featured",
        keyword="Ubuntu",
        zoneid=zone_id,
        filter="id,name,created",
    )
    matches = [t for t in (data.get("template") or [])
               if TEMPLATE_REGEX.match(t.get("name", ""))]
    if not matches:
        raise CloudStackError("No Ubuntu 24 template found in zone")
    best = max(matches, key=lambda t: t.get("created", ""))
    return best["id"]


# ---------------------------------------------------------------------------
# Resource helpers (each is find-before-create)
# ---------------------------------------------------------------------------

def find_network(client, name, zone_id):
    data = client.call("listNetworks", name=name, zoneid=zone_id,
                       filter="id,name")
    for net in data.get("network") or []:
        if net.get("name") == name:
            return net["id"]
    return None


def find_keypair(client, name):
    data = client.call("listSSHKeyPairs", name=name, filter="id,name")
    return bool(data.get("sshkeypair"))


def find_vm(client, name, zone_id):
    data = client.call("listVirtualMachines", name=name, zoneid=zone_id,
                       filter="id,name,state,nic")
    for vm in data.get("virtualmachine") or []:
        if vm.get("name") == name:
            return vm
    return None


def find_volume(client, name, zone_id):
    data = client.call("listVolumes", name=name, type="DATADISK",
                       zoneid=zone_id, filter="id,name,virtualmachineid,size")
    for vol in data.get("volume") or []:
        if vol.get("name") == name:
            return vol
    return None


def find_public_ip(client, network_id, vm_id=None):
    """Find a non-source-NAT IP; if vm_id given, prefer the one NATed to it."""
    data = client.call("listPublicIpAddresses", associatednetworkid=network_id,
                       filter="id,ipaddress,issourcenat,isstaticnat,virtualmachineid")
    ips = [ip for ip in (data.get("publicipaddress") or [])
           if not ip.get("issourcenat", False)]
    for ip in ips:
        if vm_id and ip.get("virtualmachineid") == vm_id:
            return ip
    for ip in ips:
        if not ip.get("isstaticnat", False):
            return ip
    if ips:
        return ips[0]
    return None


def find_firewall_rules(client, ip_id):
    data = client.call("listFirewallRules", ipaddressid=ip_id,
                       filter="id,startport,endport")
    return data.get("firewallrule") or []


def wait_vm_running(client, vm_id, vm_name, zone_id, timeout=VM_RUNNING_TIMEOUT):
    elapsed = 0
    while elapsed < timeout:
        vm = find_vm(client, vm_name, zone_id)
        if vm and vm.get("state") == "Running":
            return vm
        time.sleep(VM_POLL_INTERVAL)
        elapsed += VM_POLL_INTERVAL
    raise CloudStackError("VM '{}' did not reach Running within {}s".format(
        vm_name, timeout))


# ---------------------------------------------------------------------------
# Provisioning steps
# ---------------------------------------------------------------------------

def ensure_network(client, env_name, zone_id, zone_name):
    network_name = "cr-{}".format(env_name)
    net_id = find_network(client, network_name, zone_id)
    if not net_id:
        data = client.call(
            "createNetwork",
            name=network_name,
            displaytext=network_name,
            networkofferingid=resolve_network_offering(client),
            zoneid=zone_id,
            networkdomain="{}.{}.internal".format(env_name, zone_name.lower()),
        )
        net_id = data["network"]["id"]
    return network_name, net_id


def ensure_ssh_keypair(client, keypair_name, public_key):
    if find_keypair(client, keypair_name):
        return
    client.call("registerSSHKeyPair", name=keypair_name, publickey=public_key)


def ensure_vm(client, vm_name, plan, template_id, zone_id, net_id, keypair_name,
              userdata_path, zone_name):
    vm = find_vm(client, vm_name, zone_id)
    if vm:
        vm_id = vm["id"]
    else:
        offering_id = resolve_service_offering(client, plan)
        userdata = ""
        if userdata_path and os.path.exists(userdata_path):
            with open(userdata_path, "rb") as f:
                userdata = base64.b64encode(f.read()).decode("ascii")
        data = client.call(
            "deployVirtualMachine",
            serviceofferingid=offering_id,
            templateid=template_id,
            zoneid=zone_id,
            networkids=net_id,
            keypair=keypair_name,
            name=vm_name,
            displayname=vm_name,
            userdata=userdata,
        )
        vm_id = data["id"]
    wait_vm_running(client, vm_id, vm_name, zone_id)
    return vm_id


def ensure_public_ip(client, net_id, vm_id):
    ip = find_public_ip(client, net_id, vm_id=vm_id)
    if not ip:
        data = client.call("associateIpAddress", networkid=net_id)
        ip = data
    if not ip.get("isstaticnat", False):
        client.call("enableStaticNat", ipaddressid=ip["id"],
                    virtualmachineid=vm_id)
    return ip


def ensure_firewall(client, ip_id, ports):
    existing = find_firewall_rules(client, ip_id)
    existing_ports = {
        (int(r.get("startport", 0)), int(r.get("endport", 0))) for r in existing
    }
    for port in sorted(ports):
        if (port, port) in existing_ports:
            continue
        client.call("createFirewallRule", ipaddressid=ip_id, protocol="TCP",
                    startport=port, endport=port, cidrlist="0.0.0.0/0")


def ensure_data_disk(client, disk_name, zone_id, disk_gb, vm_id, network_name):
    vol = find_volume(client, disk_name, zone_id)
    if vol:
        vol_id = vol["id"]
    else:
        data = client.call("createVolume", name=disk_name,
                           diskofferingid=resolve_disk_offering(client),
                           zoneid=zone_id, size=disk_gb)
        vol_id = data["id"]
        client.call("createTags", resourceids=vol_id, resourcetype="Volume",
                    **{"tags[0].key": "cloud-recipes-id",
                       "tags[0].value": network_name})
    if not vol or not vol.get("virtualmachineid"):
        client.call("attachVolume", id=vol_id, virtualmachineid=vm_id)
    return vol_id


def vm_internal_ip(client, vm_id):
    data = client.call("listVirtualMachines", id=vm_id, filter="id,nic")
    nics = (data.get("virtualmachine") or [{}])[0].get("nic") or []
    if nics:
        return nics[0].get("ipaddress", "")
    return ""


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_cfg(args):
    cfg = {
        "env_name": args.env_name.strip(),
        "zone": args.zone.strip(),
        "plan": args.plan.strip(),
        "disk_gb": args.disk_gb,
        "ports": [],
        "ssh_pubkey": args.ssh_pubkey,
        "endpoint": args.endpoint,
    }
    for token in args.ports.split(","):
        token = token.strip()
        if not token:
            continue
        if not token.isdigit():
            raise CloudStackError(
                "Invalid port '{}' — must be numeric 1-65535".format(token))
        port = int(token)
        if not 1 <= port <= 65535:
            raise CloudStackError(
                "Invalid port '{}' — must be 1-65535".format(token))
        cfg["ports"].append(port)

    # env_name is a resource name we generate the network/VM names from, so a
    # strict [a-z0-9_] guard applies. zone and plan are existing CloudStack
    # names (e.g. ZP01, c4) — still validated to block shell/config injection.
    if not NAME_RE.match(cfg["env_name"]):
        raise CloudStackError(
            "Invalid env_name '{}' — only lowercase letters, digits and "
            "_ are allowed ([a-z0-9_])".format(cfg["env_name"]))
    for key in ("zone", "plan"):
        if not IDENT_RE.match(cfg[key]):
            raise CloudStackError(
                "Invalid {} '{}' — only letters, digits, _ and - are "
                "allowed".format(key, cfg[key]))

    if not 5 <= cfg["disk_gb"] <= 2000:
        raise CloudStackError("disk_gb must be between 5 and 2000")

    pubkey = os.path.expanduser(cfg["ssh_pubkey"])
    if not os.path.exists(pubkey):
        raise CloudStackError("SSH public key not found: {}".format(pubkey))
    with open(pubkey, "r") as f:
        cfg["public_key"] = f.read().strip()
    return cfg


def resolve_endpoint(args):
    explicit = args.endpoint or os.environ.get("LOCAWEB_API_ENDPOINT")
    if not explicit:
        raise CloudStackError(
            "No API endpoint. Set LOCAWEB_API_ENDPOINT or pass --endpoint.")
    return explicit


def main():
    parser = argparse.ArgumentParser(
        description="Provision a single VM on Locaweb Cloud (idempotent)")
    parser.add_argument("--env-name", required=True,
                        help="Environment name (regex [a-z0-9_])")
    parser.add_argument("--zone", default="ZP01", help="CloudStack zone")
    parser.add_argument("--plan", required=True,
                        help="Service offering (VM plan), e.g. c4")
    parser.add_argument("--disk-gb", type=int, default=20,
                        help="Data disk size in GB (default 20)")
    parser.add_argument("--ports", default="",
                        help="Extra TCP ports for firewall (comma separated); "
                             "SSH 22 is always open")
    parser.add_argument("--ssh-pubkey",
                        help="Path to the Ed25519 public key (default: "
                             "~/.ssh/cloud-recipes-<env>.pub or ~/.ssh/cloud-recipes.pub)")
    parser.add_argument("--endpoint", help="CloudStack API endpoint URL "
                                           "(default: LOCAWEB_API_ENDPOINT)")
    parser.add_argument("--output", help="Write JSON output to a file")
    args = parser.parse_args()

    try:
        cfg = build_cfg(args)

        mock_fixtures = os.environ.get("LOCAWEB_MOCK_FIXTURES")
        if mock_fixtures:
            transport = MockTransport(
                mock_fixtures, os.environ.get("LOCAWEB_MOCK_LOG", ""))
            api_key = "mock-key"
            secret = "mock-secret"
            endpoint = ""
        else:
            transport = None
            endpoint = resolve_endpoint(args)
            api_key = os.environ.get("LOCAWEB_API_KEY", "")
            secret = os.environ.get("LOCAWEB_API_SECRET", "")
            if not api_key or not secret:
                raise CloudStackError(
                    "LOCAWEB_API_KEY and LOCAWEB_API_SECRET must be set")

        client = CloudStackClient(endpoint, api_key, secret,
                                  transport=transport)

        results = provision(client, cfg)
        out = json.dumps(results, indent=2, ensure_ascii=False)
        if args.output:
            with open(args.output, "w") as f:
                f.write(out + "\n")
            print("Output written to {}".format(args.output))
        else:
            print(out)
    except CloudStackError as exc:
        print("FATAL: {}".format(exc), file=sys.stderr)
        sys.exit(1)


def provision(client, cfg):
    """Provision the single VM deployment; returns the result dict."""
    env_name = cfg["env_name"]
    zone_name = cfg["zone"]
    ports = sorted(set([22] + cfg["ports"]))

    zone_id = resolve_zone(client, zone_name)
    network_name, net_id = ensure_network(client, env_name, zone_id, zone_name)

    keypair_name = "{}-key".format(network_name)
    ensure_ssh_keypair(client, keypair_name, cfg["public_key"])

    userdata_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 "userdata", "boot_vm.sh")
    template_id = resolve_template(client, zone_id)
    vm_name = "{}-vm".format(network_name)
    vm_id = ensure_vm(client, vm_name, cfg["plan"], template_id, zone_id,
                      net_id, keypair_name, userdata_path, zone_name)

    ip = ensure_public_ip(client, net_id, vm_id)
    ensure_firewall(client, ip["id"], ports)

    disk_name = "{}-data".format(network_name)
    vol_id = ensure_data_disk(client, disk_name, zone_id, cfg["disk_gb"],
                              vm_id, network_name)

    internal_ip = vm_internal_ip(client, vm_id)

    return {
        "env_name": env_name,
        "zone": zone_name,
        "network_name": network_name,
        "network_id": net_id,
        "keypair_name": keypair_name,
        "vm_name": vm_name,
        "vm_id": vm_id,
        "public_ip": ip.get("ipaddress", ip["id"]),
        "public_ip_id": ip.get("id", ""),
        "internal_ip": internal_ip,
        "firewall_ports": ports,
        "data_disk_name": disk_name,
        "data_disk_id": vol_id,
        "hero_url": "http://{}.nip.io".format(ip.get("ipaddress", "")),
    }


if __name__ == "__main__":
    main()