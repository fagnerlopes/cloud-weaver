# Hermes Agent Recipe — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adicionar ao CloudWeaver a receita Hermes Agent (Nous Research) controlada por Telegram, com renomeação da receita WAHA, rotação de chave SSH para offboarding seguro em workshop, e atualização do catálogo.

**Architecture:** Quatro subsistemas independentes, em ordem de dependência: (1) renomeação `hermes→waha` libera o nome; (2) `vm-provision.py` ganha o subcomando `rotate-ssh-key` necessário para o offboard; (3) o skill `cloud-weaver-hermes-agent` provisiona o stack Docker (Traefik + ttyd + hermes-agent); (4) o skill `cloud-weaver-offboard` orquestra os três desligamentos pós-workshop. Os testes cobrem os dois scripts Python com `--dry-run` e MockTransport. O catálogo e a versão são atualizados por último.

**Tech Stack:** Python 3 stdlib, bash, Docker Compose v2, Traefik v3, ttyd, `nousresearch/hermes-agent:latest`, `npx skills` (distribuição via plugin).

**Spec:** `docs/superpowers/specs/2026-09-11-hermes-agent-recipe-design.md`

## Global Constraints

- Toda saída ao usuário em **PT-BR**; toda mensagem começa com `[CloudWeaver]`.
- Comentários de código em **inglês**.
- Nomes de VM/env validados contra `[a-z0-9_]` antes de qualquer comando.
- Secrets gerados com `secrets.token_urlsafe(32)` — nunca exibidos no chat.
- Chaves SSH Ed25519 apenas; `chmod 600`.
- Python puro stdlib — sem dependências externas.
- `--dry-run` disponível em todo script Python; testes usam apenas `--dry-run` ou `MockTransport` (zero rede).
- Version bump: minor (0.8.0) — mudanças significativas; `scripts/stamp-version.sh` após bump.

---

### Task 1: Rename cloud-weaver-hermes → cloud-weaver-waha

**Files:**
- Rename: `skills/cloud-weaver-hermes/` → `skills/cloud-weaver-waha/`
- Modify: `skills/cloud-weaver-waha/SKILL.md` (nome e referências internas)
- Modify: `skills/cloud-weaver-playbook/SKILL.md` (tabela de skills)
- Modify: `skills/start-cloud/SKILL.md` (catálogo de receitas)

**Interfaces:**
- Produz: skill `cloud-weaver-waha` funcional com o mesmo deployer; nome `cloud-weaver-hermes` liberado para a nova receita.

- [ ] **Step 1: Renomear o diretório via git mv**

```bash
cd /home/fagner.lopes@king.local/projects/cloud-weaver
git mv skills/cloud-weaver-hermes skills/cloud-weaver-waha
```

- [ ] **Step 2: Atualizar o SKILL.md da receita WAHA**

Editar `skills/cloud-weaver-waha/SKILL.md`. Trocar todas as ocorrências de `cloud-weaver-hermes` por `cloud-weaver-waha` e atualizar o `name:` no frontmatter e o título:

```yaml
---
name: cloud-weaver-waha
description: >
  This skill should be used when deploying the WAHA recipe — the WAHA
  (WhatsApp HTTP API) service backed by PostgreSQL — onto a cloud-weaver VM
  that is already provisioned (see cloud-weaver-vm-setup). It collects the
  remaining configuration one question at a time, then ships a docker compose
  stack over SSH and starts it. Idempotent — re-runs reuse the remote .env.
---

# WAHA (WhatsApp HTTP API + PostgreSQL)
```

Atualizar a seção **Run the deployer** para apontar para o script renomeado:

```bash
python3 <this-skill-dir>/scripts/deploy-hermes.py \
  --env-name "$env_name" \
  --public-ip "$public_ip" \
  --ssh-private-key "$HOME/.ssh/cloud-weaver" \
  --api-port "$api_port"
```

*(O script em si não precisa ser renomeado — é um detalhe interno do skill.)*

- [ ] **Step 3: Atualizar a tabela de skills no playbook**

Em `skills/cloud-weaver-playbook/SKILL.md`, localizar a linha:

```
| `cloud-weaver-hermes` | Recipe: Hermes Agent (WAHA + PostgreSQL) | ✅ |
```

Substituir por:

```
| `cloud-weaver-waha` | Recipe: WAHA (WhatsApp HTTP API + PostgreSQL) | ✅ |
| `cloud-weaver-hermes-agent` | Recipe: Hermes Agent (Nous Research, Telegram) | ✅ |
| `cloud-weaver-offboard` | Offboarding seguro após workshop | ✅ |
```

- [ ] **Step 4: Atualizar o catálogo no start-cloud**

Em `skills/start-cloud/SKILL.md`, localizar a linha da tabela:

```
| Hermes Agent | `hermes` | Agente de WhatsApp (WAHA) + PostgreSQL | ✅ disponível |
```

Substituir por:

```
| WAHA | `waha` | Agente de WhatsApp (WAHA) + PostgreSQL | ✅ disponível |
| Hermes Agent | `hermes_agent` | Agente Telegram + LLM (Nous Research) | ✅ disponível |
```

E no texto "Only recipes marked available..." confirmar que `cloud-weaver-waha` e `cloud-weaver-hermes-agent` estão listados como available.

- [ ] **Step 5: Verificar integridade**

```bash
# Skill waha deve existir com SKILL.md correto
grep -q "name: cloud-weaver-waha" skills/cloud-weaver-waha/SKILL.md && echo OK

# Nenhuma referência órfã ao nome antigo (exceto histórico git)
grep -rn "cloud-weaver-hermes" skills/ && echo "ATENÇÃO: referências órfãs" || echo "Limpo"
```

Expected: linha `OK` e nenhuma ocorrência.

- [ ] **Step 6: Commit**

```bash
git add skills/cloud-weaver-waha/ skills/cloud-weaver-playbook/SKILL.md skills/start-cloud/SKILL.md
git commit -m "refactor: rename cloud-weaver-hermes → cloud-weaver-waha; free name for hermes-agent"
```

---

### Task 2: vm-provision.py — parâmetro cidrlist + subcomando rotate-ssh-key

**Files:**
- Modify: `skills/cloud-weaver-vm-setup/scripts/vm-provision.py`

**Interfaces:**
- Consome: CloudStack `stopVirtualMachine`, `resetSSHKeyForVirtualMachine`, `startVirtualMachine` via `CloudStackClient.call()`
- Produz:
  - `ensure_firewall(client, ip_id, ports, cidrlist="0.0.0.0/0")` — backward-compatible
  - `rotate_ssh_key(client, cfg)` — ciclo stop → reset → start, retorna dict com `new_keypair_name`
  - Novo subcomando CLI `rotate-ssh-key` com `--vm-id`, `--ssh-pubkey`, `--keypair-name`

- [ ] **Step 1: Escrever o teste para ensure_firewall com cidrlist customizado**

No arquivo `tests/scripts/test-vm-provision.sh`, localizar a seção `== vm-provision: firewall ==` (ou adicionar nova seção ao final, antes do `summary`):

```bash
echo "== vm-provision: ensure_firewall aceita cidrlist customizado =="
# Carrega o módulo e chama ensure_firewall com cidrlist restrito (inspeção do mock log)
prov fw1 vm-provision-empty.json \
  --env-name hermes --zone ZP01 --plan c4 \
  --ssh-pubkey "$BASE/testkey.pub" \
  --ports 22
expect "firewall exit 0"            test "$(prov_rc fw1)" = 0
expect "createFirewallRule no log" file_contains "$BASE/fw1.log" "createFirewallRule"
```

*(O MockTransport já loga os comandos; este teste verifica que o fluxo passa. O teste de cidrlist customizado será coberto pelo test-hermes-agent.sh via --dry-run inspecionando a ausência/presença do parâmetro.)*

- [ ] **Step 2: Rodar o teste para confirmar que passa (regressão zero)**

```bash
bash tests/scripts/test-vm-provision.sh
```

Expected: todos os testes existentes passam.

- [ ] **Step 3: Adicionar parâmetro cidrlist a ensure_firewall**

Em `skills/cloud-weaver-vm-setup/scripts/vm-provision.py`, localizar:

```python
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
```

Substituir por:

```python
def ensure_firewall(client, ip_id, ports, cidrlist="0.0.0.0/0"):
    """Open TCP ports on the given public IP.

    cidrlist defaults to 0.0.0.0/0 (open to world); pass a specific CIDR
    when you want to restrict a port to a known source range.
    """
    existing = find_firewall_rules(client, ip_id)
    existing_ports = {
        (int(r.get("startport", 0)), int(r.get("endport", 0))) for r in existing
    }
    for port in sorted(ports):
        if (port, port) in existing_ports:
            continue
        client.call("createFirewallRule", ipaddressid=ip_id, protocol="TCP",
                    startport=port, endport=port, cidrlist=cidrlist)
```

- [ ] **Step 4: Escrever wait_for_vm_state e rotate_ssh_key**

Logo após a função `ensure_data_disk` (e antes de `vm_internal_ip`), inserir:

```python
def wait_for_vm_state(client, vm_id, target_state, timeout=300, poll=5):
    """Poll listVirtualMachines until the VM reaches target_state or timeout."""
    import time as _time
    deadline = _time.time() + timeout
    while _time.time() < deadline:
        data = client.call("listVirtualMachines", id=vm_id, filter="id,state")
        vms = data.get("virtualmachine") or []
        if vms and vms[0].get("state") == target_state:
            return
        _time.sleep(poll)
    raise CloudStackError(
        "VM {} did not reach state '{}' within {}s".format(vm_id, target_state, timeout))


def rotate_ssh_key(client, cfg):
    """Rotate the SSH keypair on a running VM.

    Sequence required by the CloudStack API:
    1. Stop VM  (state must be Stopped before reset)
    2. Register new keypair
    3. resetSSHKeyForVirtualMachine
    4. Start VM

    Returns a dict with new_keypair_name and vm_id.
    """
    env_name = cfg["env_name"]
    network_name = "cr-{}-net".format(env_name)
    vm_name = "{}-vm".format(network_name)

    # Resolve VM id
    data = client.call("listVirtualMachines", name=vm_name, filter="id,name,state")
    vms = data.get("virtualmachine") or []
    if not vms:
        raise CloudStackError("VM '{}' not found".format(vm_name))
    vm_id = vms[0]["id"]

    # 1. Stop
    print("Stopping VM {}...".format(vm_name))
    client.call("stopVirtualMachine", id=vm_id)
    wait_for_vm_state(client, vm_id, "Stopped")

    # 2. Register new keypair
    new_keypair_name = "{}-key".format(network_name)  # reuse same name, register replaces it
    ensure_ssh_keypair(client, new_keypair_name, cfg["public_key"])

    # 3. Reset SSH key (VM must be Stopped)
    client.call("resetSSHKeyForVirtualMachine", id=vm_id, keypair=new_keypair_name)

    # 4. Start
    print("Starting VM {}...".format(vm_name))
    client.call("startVirtualMachine", id=vm_id)
    wait_for_vm_state(client, vm_id, "Running")

    return {
        "env_name": env_name,
        "vm_id": vm_id,
        "new_keypair_name": new_keypair_name,
        "status": "rotated",
    }
```

- [ ] **Step 5: Adicionar subcomando CLI rotate-ssh-key**

No `main()`, logo antes de `parser = argparse.ArgumentParser(...)`, adicionar suporte a subcomandos:

```python
def main():
    # Top-level parser with subcommands
    top = argparse.ArgumentParser(
        description="Provision and manage VMs on Locaweb Cloud (idempotent)")
    sub = top.add_subparsers(dest="command")

    # ---- subcommand: provision (default) ----
    p_prov = sub.add_parser("provision",
                             help="Provision VM, network, firewall and disk (default)")
    p_prov.add_argument("--env-name", required=True)
    p_prov.add_argument("--zone", default="ZP01")
    p_prov.add_argument("--plan", required=True)
    p_prov.add_argument("--disk-gb", type=int, default=20)
    p_prov.add_argument("--ports", default="")
    p_prov.add_argument("--ssh-pubkey")
    p_prov.add_argument("--endpoint")
    p_prov.add_argument("--output")

    # ---- subcommand: rotate-ssh-key ----
    p_rot = sub.add_parser("rotate-ssh-key",
                            help="Rotate the SSH keypair on a provisioned VM (stop→reset→start)")
    p_rot.add_argument("--env-name", required=True)
    p_rot.add_argument("--ssh-pubkey", required=True,
                       help="Path to the NEW Ed25519 public key to register")
    p_rot.add_argument("--endpoint")
    p_rot.add_argument("--output")

    args = top.parse_args()

    # Backward compat: no subcommand → treat as provision
    if args.command is None or args.command == "provision":
        _run_provision(args)
    elif args.command == "rotate-ssh-key":
        _run_rotate_ssh_key(args)
    else:
        top.print_help()
        sys.exit(1)
```

Extrair o corpo atual de `main()` para `_run_provision(args)` e adicionar:

```python
def _run_provision(args):
    """Run the VM provisioning subcommand."""
    try:
        cfg = build_cfg(args)
        mock_fixtures = os.environ.get("LOCAWEB_MOCK_FIXTURES")
        if mock_fixtures:
            transport = MockTransport(
                mock_fixtures, os.environ.get("LOCAWEB_MOCK_LOG", ""))
            api_key, secret, endpoint = "mock-key", "mock-secret", ""
        else:
            transport = None
            endpoint = resolve_endpoint(args)
            api_key = os.environ.get("LOCAWEB_API_KEY", "")
            secret = os.environ.get("LOCAWEB_API_SECRET", "")
            if not api_key or not secret:
                raise CloudStackError(
                    "LOCAWEB_API_KEY and LOCAWEB_API_SECRET must be set")
        client = CloudStackClient(endpoint, api_key, secret, transport=transport)
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


def _run_rotate_ssh_key(args):
    """Run the rotate-ssh-key subcommand."""
    try:
        # Re-use build_cfg validation for env_name and pubkey
        cfg = {
            "env_name": args.env_name.strip(),
            "ssh_pubkey": args.ssh_pubkey,
            "ports": [],
            "zone": "ZP01",
            "plan": "c4",
            "disk_gb": 20,
            "endpoint": args.endpoint,
        }
        if not NAME_RE.match(cfg["env_name"]):
            raise CloudStackError(
                "Invalid env_name '{}' — only [a-z0-9_]".format(cfg["env_name"]))
        pubkey = os.path.expanduser(cfg["ssh_pubkey"])
        if not os.path.exists(pubkey):
            raise CloudStackError("SSH public key not found: {}".format(pubkey))
        with open(pubkey, "r") as f:
            cfg["public_key"] = f.read().strip()

        mock_fixtures = os.environ.get("LOCAWEB_MOCK_FIXTURES")
        if mock_fixtures:
            transport = MockTransport(
                mock_fixtures, os.environ.get("LOCAWEB_MOCK_LOG", ""))
            api_key, secret, endpoint = "mock-key", "mock-secret", ""
        else:
            transport = None
            endpoint = resolve_endpoint(args)
            api_key = os.environ.get("LOCAWEB_API_KEY", "")
            secret = os.environ.get("LOCAWEB_API_SECRET", "")
            if not api_key or not secret:
                raise CloudStackError(
                    "LOCAWEB_API_KEY and LOCAWEB_API_SECRET must be set")
        client = CloudStackClient(endpoint, api_key, secret, transport=transport)
        result = rotate_ssh_key(client, cfg)
        out = json.dumps(result, indent=2, ensure_ascii=False)
        if args.output:
            with open(args.output, "w") as f:
                f.write(out + "\n")
        print("SSH key rotated: {}".format(out))
    except CloudStackError as exc:
        print("FATAL: {}".format(exc), file=sys.stderr)
        sys.exit(1)
```

- [ ] **Step 6: Atualizar o MockTransport para suportar stop/reset/start**

No `_MOCK_CREATE_EFFECTS` (ou na lógica do MockTransport), adicionar os efeitos de estado para os novos comandos. Localizar a classe `MockTransport` e o dict `_MOCK_CREATE_EFFECTS`:

```python
# Adicionar no dict _MOCK_CREATE_EFFECTS (sem substituir os existentes):
"stopVirtualMachine": ("listVirtualMachines", "virtualmachine",
                       lambda p: {"id": p.get("id", ["vm1"])[0],
                                  "name": "cr-hermes-net-vm",
                                  "state": "Stopped",
                                  "nic": [{"ipaddress": "10.0.0.5"}]}),
"startVirtualMachine": ("listVirtualMachines", "virtualmachine",
                        lambda p: {"id": p.get("id", ["vm1"])[0],
                                   "name": "cr-hermes-net-vm",
                                   "state": "Running",
                                   "nic": [{"ipaddress": "10.0.0.5"}]}),
```

Para `resetSSHKeyForVirtualMachine` não há efeito de lista — apenas retornar sucesso. Adicionar no método `request` do MockTransport um branch que ignora comandos sem efeito:

```python
# Dentro de MockTransport.request(), após a lógica de _MOCK_CREATE_EFFECTS:
if command in ("resetSSHKeyForVirtualMachine",):
    return {}  # No list state to update; idempotent no-op in mock
```

- [ ] **Step 7: Rodar os testes e confirmar que passam**

```bash
bash tests/scripts/test-vm-provision.sh
```

Expected: todos os testes passam (incluindo a nova seção de firewall).

- [ ] **Step 8: Commit**

```bash
git add skills/cloud-weaver-vm-setup/scripts/vm-provision.py \
        tests/scripts/test-vm-provision.sh
git commit -m "feat(vm-provision): cidrlist param in ensure_firewall + rotate-ssh-key subcommand"
```

---

### Task 3: cloud-weaver-hermes-agent — compose.yaml

**Files:**
- Create: `skills/cloud-weaver-hermes-agent/scripts/compose/compose.yaml`

**Interfaces:**
- Consome: variáveis de `.env` — `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`, `ENV_NAME`, `HOSTNAME`, `TTYD_BASIC_AUTH`
- Produz: stack Docker com Traefik (80/443 + TLS), ttyd (terminal web, basic auth), hermes-agent (Telegram long polling). Container do agente tem nome previsível `hermes-${ENV_NAME}`.

- [ ] **Step 1: Criar a estrutura de diretórios**

```bash
mkdir -p skills/cloud-weaver-hermes-agent/scripts/compose
```

- [ ] **Step 2: Escrever o compose.yaml**

Criar `skills/cloud-weaver-hermes-agent/scripts/compose/compose.yaml`:

```yaml
# cloud-weaver hermes-agent recipe
#
# Services:
#   traefik       - TLS termination via Let's Encrypt; routes / to web-terminal
#   web-terminal  - ttyd shell via docker exec into hermes-agent (basic auth)
#   hermes-agent  - Nous Research Hermes Agent; Telegram long polling only
#
# Required env vars (from /data/<env>/compose/.env):
#   TELEGRAM_BOT_TOKEN     - set by participant via `hermes setup` in terminal
#   TELEGRAM_ALLOWED_USERS - participant's Telegram user ID (integer)
#   ENV_NAME               - environment name ([a-z0-9_]), e.g. "hermes"
#   HOSTNAME               - full public hostname, e.g. cr-hermes-net-vm.publiccloud.com.br
#   TTYD_BASIC_AUTH        - htpasswd entry: admin:{SHA}<base64-sha1-of-password>
#
# Data paths on the VM host (persistent disk mounted at /data/<env>/):
#   ../hermes_data  - Hermes Agent config and state (/root/.hermes inside container)
#   ../acme         - Traefik Let's Encrypt certificate storage

services:
  traefik:
    image: traefik:v3.0
    restart: unless-stopped
    command:
      - "--log.level=INFO"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--certificatesresolvers.le.acme.tlschallenge=true"
      - "--certificatesresolvers.le.acme.email=admin@${HOSTNAME}"
      - "--certificatesresolvers.le.acme.storage=/acme/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ../acme:/acme

  web-terminal:
    # ttyd: browser-based terminal. Execs into the hermes-agent container so the
    # participant runs `hermes setup` and other hermes commands directly.
    #
    # Q1 (open): this mounts docker.sock with write access, giving the session
    # root-equivalent access. Alternative: run ttyd as a second process inside a
    # shared volume without docker.sock. Validate before the workshop.
    image: ghcr.io/tsl0922/ttyd:alpine
    restart: unless-stopped
    command:
      - "-W"
      - "docker"
      - "exec"
      - "-it"
      - "hermes-${ENV_NAME}"
      - "bash"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.terminal.rule=Host(`${HOSTNAME}`)"
      - "traefik.http.routers.terminal.entrypoints=websecure"
      - "traefik.http.routers.terminal.tls=true"
      - "traefik.http.routers.terminal.tls.certresolver=le"
      - "traefik.http.routers.terminal.middlewares=terminal-auth"
      - "traefik.http.services.terminal.loadbalancer.server.port=7681"
      - "traefik.http.middlewares.terminal-auth.basicauth.users=${TTYD_BASIC_AUTH}"
    depends_on:
      - hermes-agent

  hermes-agent:
    image: nousresearch/hermes-agent:latest
    # Explicit container name so web-terminal can docker exec into it.
    container_name: "hermes-${ENV_NAME}"
    restart: unless-stopped
    env_file: .env
    volumes:
      # hermes_data is bind-mounted from the persistent disk so config and
      # state survive container restarts and image updates.
      - ../hermes_data:/root/.hermes
    # No ports published: communication is Telegram long polling only.
    # The approvals config is written to /root/.hermes/config.yaml by the
    # deployer before the first `docker compose up`.
    healthcheck:
      # Treat the agent as healthy once its config directory exists.
      test: ["CMD", "test", "-d", "/root/.hermes"]
      interval: 5s
      timeout: 3s
      retries: 20
      start_period: 60s
```

- [ ] **Step 3: Verificar que o arquivo é YAML válido**

```bash
python3 -c "import yaml, sys; yaml.safe_load(open('skills/cloud-weaver-hermes-agent/scripts/compose/compose.yaml'))" \
  && echo "YAML válido" || echo "ERRO: YAML inválido"
```

*(Requer `pyyaml`; se ausente, use `python3 -c "import json, sys" && cat skills/cloud-weaver-hermes-agent/scripts/compose/compose.yaml` para revisão manual.)*

Se `pyyaml` não estiver disponível:
```bash
docker compose -f skills/cloud-weaver-hermes-agent/scripts/compose/compose.yaml config --quiet 2>&1 \
  && echo "Compose válido" || echo "Erro no compose"
```

- [ ] **Step 4: Commit**

```bash
git add skills/cloud-weaver-hermes-agent/scripts/compose/compose.yaml
git commit -m "feat(hermes-agent): add docker compose stack (Traefik + ttyd + hermes-agent)"
```

---

### Task 4: cloud-weaver-hermes-agent — deploy-hermes-agent.py

**Files:**
- Create: `skills/cloud-weaver-hermes-agent/scripts/deploy-hermes-agent.py`
- Create: `skills/cloud-weaver-hermes-agent/scripts/hermes-config.yaml` (template)

**Interfaces:**
- Consome: compose.yaml da Task 3; SSH private key do `cloud-weaver-computer-setup`
- Produz:
  - `deploy-hermes-agent.py` com interface CLI compatível com o padrão do projeto
  - `build_secrets(cfg) → (env_map, admin_pass)` — separação do plaintext para o report
  - `build_report(cfg, admin_pass) → dict` — inclui `admin_pass` e `terminal_url`

- [ ] **Step 1: Escrever o teste de fumaça (offline, dry-run)**

Criar `tests/scripts/test-hermes-agent.sh` com os primeiros casos para guiar a implementação:

```bash
#!/usr/bin/env bash
# Offline tests for deploy-hermes-agent.py — uses --dry-run only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$REPO/lib/assert.sh"

SCRIPT="$REPO/../skills/cloud-weaver-hermes-agent/scripts/deploy-hermes-agent.py"
COMPOSE="$REPO/../skills/cloud-weaver-hermes-agent/scripts/compose/compose.yaml"
PYTHON="$(command -v python3)"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQQQQ test@example.com" > "$BASE/key"
chmod 600 "$BASE/key"

echo "== hermes-agent: script compila =="
expect "compila" "$PYTHON" -m py_compile "$SCRIPT"
expect "shebang python3" grep -q "env python3" "$SCRIPT"

echo "== hermes-agent: validação de entrada =="
"$PYTHON" "$SCRIPT" --env-name "Bad Name" --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 123 \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v1.out" 2>&1
expect "rejeita env_name inválido" test $? != 0
expect "mensagem env_name" grep -qF "only lowercase" "$BASE/v1.out"

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip "not-ip" \
  --hostname h.example.com --telegram-user-id 123 \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v2.out" 2>&1
expect "rejeita IP inválido" test $? != 0

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 0 \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v3.out" 2>&1
expect "rejeita telegram_user_id zero" test $? != 0

summary "hermes-agent (stub)"
```

- [ ] **Step 2: Rodar o teste para confirmar que falha (script não existe)**

```bash
bash tests/scripts/test-hermes-agent.sh 2>&1 | head -20
```

Expected: FAIL em "compila" e demais (script ausente).

- [ ] **Step 3: Criar o template de config do Hermes**

Criar `skills/cloud-weaver-hermes-agent/scripts/hermes-config.yaml`:

```yaml
# Hermes Agent approval configuration
# Written to /root/.hermes/config.yaml before first boot.
# Q2: cron_mode value to confirm during smoke test on real VM.
approvals:
  mode: smart
  cron_mode: auto
```

- [ ] **Step 4: Implementar deploy-hermes-agent.py**

Criar `skills/cloud-weaver-hermes-agent/scripts/deploy-hermes-agent.py`:

```python
#!/usr/bin/env python3
"""Hermes Agent recipe deployer.

Ships the Traefik + ttyd + hermes-agent compose stack to the provisioned VM.
Pure Python 3 standard library; mirrors the deploy-hermes.py style.

Key differences from deploy-hermes.py:
- No public port for the application (Telegram long polling only).
- Traefik handles TLS via Let's Encrypt on the VM's publiccloud.com.br hostname.
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
DEFAULT_SSH_USER = "ubuntu"
HEALTH_WAIT_SECONDS = 300


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Deploy the Hermes Agent (Telegram + LLM) recipe to a VM.")
    p.add_argument("--env-name", required=True,
                   help="Recipe/environment name ([a-z0-9_])")
    p.add_argument("--public-ip", required=True,
                   help="Public IP of the provisioned VM")
    p.add_argument("--hostname", required=True,
                   help="Full public hostname for TLS, e.g. cr-hermes-net-vm.publiccloud.com.br")
    p.add_argument("--telegram-user-id", required=True, type=int,
                   help="Telegram user ID for TELEGRAM_ALLOWED_USERS")
    p.add_argument("--ssh-user", default=DEFAULT_SSH_USER)
    p.add_argument("--ssh-private-key", required=True,
                   help="Path to the Ed25519 private key")
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


class Runner:
    """Executes command lists, or prints them verbatim in dry-run mode."""

    def __init__(self, dry_run=False, stream=sys.stdout):
        self.dry_run = dry_run
        self.stream = stream

    def cmd(self, argv):
        print("CMD " + shlex.join(argv), file=self.stream, flush=True)
        if self.dry_run:
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
    ttyd_basic_auth = make_basic_auth("admin", admin_pass)
    env_map = {
        # Bot token is filled in by the participant via `hermes setup` in the
        # web terminal. The placeholder signals clearly what needs replacing.
        "TELEGRAM_BOT_TOKEN": "REPLACE_WITH_YOUR_BOT_TOKEN",
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
    runner.cmd(ssh + [
        "sudo mkdir -p {}/compose {}/hermes_data {}/acme".format(data, data, data)
    ])

    # Upload compose stack and secrets
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
        "admin_user": "admin",
        # admin_pass is included here (report file) but never printed to stdout,
        # so it does not appear in the agent's visible session output.
        "admin_pass": admin_pass,
        "data_path": "/data/{}".format(cfg["env_name"]),
        "compose_path": "/data/{}/compose".format(cfg["env_name"]),
        "note": (
            "Run `hermes setup` in the web terminal to configure the "
            "LLM provider, GitHub and the Telegram bot token."
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
        Path(cfg["output"]).write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8")
    # Print only the URL and key facts — never the admin_pass — to stdout.
    print("Deployed Hermes Agent: terminal {terminal_url}".format(**report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Rodar o teste parcial — deve compilar e passar validação**

```bash
bash tests/scripts/test-hermes-agent.sh
```

Expected: todos os casos de validação passam.

- [ ] **Step 6: Commit**

```bash
git add skills/cloud-weaver-hermes-agent/scripts/deploy-hermes-agent.py \
        skills/cloud-weaver-hermes-agent/scripts/hermes-config.yaml \
        tests/scripts/test-hermes-agent.sh
git commit -m "feat(hermes-agent): deployer + hermes-config.yaml template"
```

---

### Task 5: cloud-weaver-hermes-agent — SKILL.md

**Files:**
- Create: `skills/cloud-weaver-hermes-agent/SKILL.md`

**Interfaces:**
- Consome: `deploy-hermes-agent.py` (Task 4), report JSON com `terminal_url` e `admin_pass`
- Produz: instruções para o agente CloudWeaver: coleta de config → confirmação → deploy → relatório final

- [ ] **Step 1: Criar o SKILL.md**

Criar `skills/cloud-weaver-hermes-agent/SKILL.md`:

```markdown
---
name: cloud-weaver-hermes-agent
description: >
  This skill should be used when deploying the Hermes Agent recipe — the Nous
  Research Hermes Agent controlled via Telegram — onto a cloud-weaver VM already
  provisioned by cloud-weaver-vm-setup. It collects configuration one question
  at a time, ships a Traefik + ttyd + hermes-agent compose stack over SSH,
  and delivers the terminal URL and admin password in the final report.
  Idempotent — re-runs with --skip-secrets reuse the remote .env.
---

# Hermes Agent (Nous Research + Telegram)

One dedicated VM, three containers: `traefik` (TLS via Let's Encrypt),
`web-terminal` (ttyd browser shell behind basic auth) and `hermes-agent`
(Telegram long polling — no public port).

## 1. Gather configuration

Reuse the VM already created by `cloud-weaver-vm-setup` (`env_name`,
`public_ip`, `vm_name` from the report). Ask exactly one question at a time:

| Parameter | Notes |
|-----------|-------|
| `telegram_user_id` | The participant's Telegram **numeric user ID** (not username). Tip: send /start to @userinfobot in Telegram to get it. |

The skill derives `hostname` automatically: `<vm_name>.publiccloud.com.br`
where `vm_name` comes from the vm-setup report.

Validate `telegram_user_id` as a positive integer.

## 2. Confirm with the user

Show a short plan:

> Vou instalar o Hermes Agent na VM `<env_name>`:
> - Traefik com Let's Encrypt em `<hostname>`
> - Terminal web acessível em `https://<hostname>` com senha gerada
> - Hermes Agent conectado ao Telegram via long polling
>
> Credenciais e senha do terminal serão entregues no relatório final, nunca na conversa.

Wait for explicit confirmation.

## 3. Run the deployer

The deploy script is at `scripts/deploy-hermes-agent.py` (relative to this
SKILL.md). SSH user is `ubuntu`; SSH key is `~/.ssh/cloud-weaver` (or
`~/.ssh/cloud-weaver-<env>`).

```bash
python3 <this-skill-dir>/scripts/deploy-hermes-agent.py \
  --env-name "$env_name" \
  --public-ip "$public_ip" \
  --hostname "cr-${env_name}-net-vm.publiccloud.com.br" \
  --telegram-user-id "$telegram_user_id" \
  --ssh-private-key "$HOME/.ssh/cloud-weaver" \
  --output "$HOME/.cloud-weaver-${env_name}-hermes-agent.json"
```

For a **re-run** (config change, containers restarted), pass `--skip-secrets`
to reuse the existing `.env` on the VM:

```bash
python3 <this-skill-dir>/scripts/deploy-hermes-agent.py \
  --env-name "$env_name" --public-ip "$public_ip" \
  --hostname "cr-${env_name}-net-vm.publiccloud.com.br" \
  --telegram-user-id "$telegram_user_id" \
  --ssh-private-key "$HOME/.ssh/cloud-weaver" \
  --skip-secrets
```

## 4. What the deployer does

1. Generates an `admin_pass` with `secrets.token_urlsafe(32)`.
2. Builds `TTYD_BASIC_AUTH` with SHA1 hash of `admin_pass` (Traefik format).
3. Creates `/data/<env>/compose/`, `/data/<env>/hermes_data/`, `/data/<env>/acme/` on the VM.
4. SCPs `compose.yaml`, `.env` (mode 600), `hermes-config.yaml` to the VM.
5. Writes `hermes-config.yaml` to `/data/<env>/hermes_data/config.yaml` (sets `approvals.mode: smart`).
6. Runs `docker compose up -d --wait --wait-timeout 300`.

## 5. Report

Read the JSON report at `~/.cloud-weaver-<env>-hermes-agent.json` and present
to the user:

- **Terminal web:** `https://<hostname>` — login com usuário `admin`, senha `<admin_pass>`
- **Próximos passos:**
  1. Acesse o terminal web e faça login.
  2. Execute `hermes setup` no terminal para configurar o provedor de LLM, GitHub e o token do bot do Telegram.
  3. Envie uma mensagem ao bot no Telegram para testar.

**admin_pass está no JSON de relatório** (`admin_pass`). Exiba-o uma única vez ao usuário e instrua a anotá-lo.

## 6. Open questions (validate during smoke test)

- **Q1 — docker.sock no ttyd:** o container web-terminal monta `/var/run/docker.sock` com escrita para fazer `docker exec`. Risco: sessão de terminal equivale a root no host. Alternativa: rodar ttyd na mesma imagem do agente compartilhando o volume `hermes_data`. Validar durante o smoke test.
- **Q2 — approvals.cron_mode:** `auto` está configurado; confirmar que crons do workshop disparam sem aprovação manual.
- **Q3 — Dimensionamento:** validar que a VM large aguenta a imagem (`python 3.11 + node 26`) e medir o primeiro boot.
- **Q4 — TLS:** confirmar que `<vm_name>.publiccloud.com.br` resolve externamente e o Let's Encrypt emite o certificado.

## Idempotency

First run creates the `.env`. Re-runs must use `--skip-secrets` — this keeps
the TTYD basic auth password stable (the participant's bookmarked URL keeps
working) and still applies config/compose changes.

## Bundled Resources

- **`scripts/deploy-hermes-agent.py`** — deployer (stdlib, idempotent, `--dry-run`)
- **`scripts/compose/compose.yaml`** — Traefik + ttyd + hermes-agent stack
- **`scripts/hermes-config.yaml`** — Hermes Agent approval config template
```

- [ ] **Step 2: Verificar consistência**

```bash
grep -q "name: cloud-weaver-hermes-agent" skills/cloud-weaver-hermes-agent/SKILL.md && echo "OK"
grep -q "deploy-hermes-agent.py" skills/cloud-weaver-hermes-agent/SKILL.md && echo "script OK"
```

- [ ] **Step 3: Commit**

```bash
git add skills/cloud-weaver-hermes-agent/SKILL.md
git commit -m "feat(hermes-agent): SKILL.md with deploy instructions and open questions"
```

---

### Task 6: cloud-weaver-offboard — SKILL.md

**Files:**
- Create: `skills/cloud-weaver-offboard/SKILL.md`

**Interfaces:**
- Consome: `vm-provision.py rotate-ssh-key` (Task 2); chave SSH local `~/.ssh/cloud-weaver-<env>`
- Produz: skill de offboarding em três etapas — instrução de revogação, rotação de chave SSH via API, limpeza local

- [ ] **Step 1: Criar o SKILL.md**

Criar `skills/cloud-weaver-offboard/SKILL.md`:

```markdown
---
name: cloud-weaver-offboard
description: >
  Use this skill when the participant is returning a borrowed machine at the end
  of the workshop (or wants to take over from a new machine). It invalidates the
  three secrets that were left on the event machine without requiring physical
  access to it: Locaweb API credentials (manual rotation in the panel), SSH
  private key (rotated via the CloudStack API — stop → reset → start), and
  local cleanup of the cloud-weaver files.
---

# CloudWeaver Offboard — desligamento pós-workshop

## Contexto

Três segredos ficaram na máquina do evento. Cada um tem um desligamento remoto
— mais confiável do que apagar arquivos de um equipamento que você já devolveu.

| Segredo | Onde ficou | Ação |
|---------|-----------|------|
| `LOCAWEB_API_KEY` / `LOCAWEB_API_SECRET` | Shell da máquina do evento | Regerar no painel → invalida imediatamente |
| Chave SSH privada | `~/.ssh/cloud-weaver*` na máquina do evento | `resetSSHKeyForVirtualMachine` → invalida sem precisar da máquina |
| Chave de LLM (`ANTHROPIC_API_KEY` ou equivalente) | `~/.hermes/.env` na VM | Rotacionar no painel do provedor |

Execute os três passos em ordem. Não pule nenhum.

---

## Passo 1 — Revogar a credencial Locaweb

**Esta é a credencial mais crítica** — com ela alguém pode criar VMs na sua conta.
É o único segredo sem rotação por API; o revogador é o próprio painel da Locaweb.

Instrua o participante:

> Acesse [console.locaweb.com.br](https://console.locaweb.com.br) → **API** →
> regenere a `API Key` e o `API Secret`. Os valores antigos deixam de funcionar
> instantaneamente — mesmo que ainda estejam no shell da máquina do evento.

Aguarde confirmação de que o participante regenerou as credenciais antes de prosseguir.

Avise que as novas credenciais precisarão ser exportadas no terminal **desta** máquina
antes do Passo 2:

```bash
export LOCAWEB_API_KEY="<nova key>"
export LOCAWEB_API_SECRET="<novo secret>"
export LOCAWEB_API_ENDPOINT="https://api.cloud.locaweb.com.br/api/v1"
```

**Nunca peça nem exiba os valores na conversa.** Peça ao participante que exporte no
terminal e confirme exportando em seguida.

---

## Passo 2 — Rotacionar a chave SSH

Gerar um novo par Ed25519 local e registrar via API do CloudStack. A VM é parada
brevemente, a chave é trocada, e a VM é reiniciada — sem acesso físico à máquina do
evento.

### 2a. Gerar o novo par

```bash
ssh-keygen -t ed25519 -f ~/.ssh/cloud-weaver -C "cloud-weaver" -N ""
chmod 600 ~/.ssh/cloud-weaver
chmod 644 ~/.ssh/cloud-weaver.pub
```

*(Sobrescreve a chave existente — a chave antiga, na máquina do evento, não abre mais a VM.)*

### 2b. Rodar a rotação via vm-provision.py

```bash
VM_PROVISION="$(python3 -c "import importlib.util, pathlib; \
  p = pathlib.Path.home() / '.claude' / 'plugins'; \
  print(list(p.glob('*/cloud-weaver/*/skills/cloud-weaver-vm-setup/scripts/vm-provision.py'))[0])")"

python3 "$VM_PROVISION" rotate-ssh-key \
  --env-name "$env_name" \
  --ssh-pubkey "$HOME/.ssh/cloud-weaver.pub" \
  --output "$HOME/.cloud-weaver-${env_name}-rotate.json"
```

Aguardar a conclusão (a VM é parada e reiniciada — ~2 minutos).

Verificar que o novo acesso funciona:

```bash
ssh -i ~/.ssh/cloud-weaver ubuntu@"$public_ip" echo "SSH OK"
```

---

## Passo 3 — Limpeza local

Remover os arquivos do cloud-weaver desta máquina (a **nova** máquina, se for
uma adoção; a **mesma** se for apenas limpeza pós-workshop).

```bash
# Remove SSH keys
rm -f ~/.ssh/cloud-weaver ~/.ssh/cloud-weaver.pub \
       ~/.ssh/cloud-weaver-"${env_name}" ~/.ssh/cloud-weaver-"${env_name}".pub

# Remove credential files
rm -f ~/.cloud-weaver-"${env_name}"-*.json

# Remove the cloud-weaver block from AGENTS.md (if present)
if [ -f AGENTS.md ]; then
  sed -i '/# cloud-weaver:begin/,/# cloud-weaver:end/d' AGENTS.md
fi
```

*(No cenário de adoção — rodar na máquina de casa — o Passo 2a já criou o novo par; não remover.)*

---

## Passo 4 — Instruir sobre a chave de LLM na VM

A chave de LLM (`ANTHROPIC_API_KEY` ou equivalente) fica em `~/.hermes/.env`
**dentro da VM** — não na máquina do evento. Rotacionar no painel do provedor
usando o terminal web (`https://<hostname>`) ou via SSH com a nova chave:

```bash
ssh -i ~/.ssh/cloud-weaver ubuntu@"$public_ip" \
  "sudo nano /data/${env_name}/hermes_data/.env"
```

---

## Mensagem final ao participante

> ✅ Offboard concluído. A máquina do evento não tem mais acesso à sua VM.
>
> Sua VM continua rodando — você tem créditos por mais um mês.
> Para acessá-la da sua máquina de casa, use:
>
>     ssh -i ~/.ssh/cloud-weaver ubuntu@<public_ip>
>
> Para deletar a VM quando quiser, acesse o painel da Locaweb Cloud.
```

- [ ] **Step 2: Verificar**

```bash
grep -q "name: cloud-weaver-offboard" skills/cloud-weaver-offboard/SKILL.md && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add skills/cloud-weaver-offboard/SKILL.md
git commit -m "feat(offboard): SKILL.md with 3-step post-workshop key rotation"
```

---

### Task 7: Testes completos para hermes-agent e rotate-ssh-key

**Files:**
- Modify: `tests/scripts/test-hermes-agent.sh` (ampliar com casos de deploy e secrets)
- Modify: `tests/scripts/test-vm-provision.sh` (adicionar seção rotate-ssh-key)

**Interfaces:**
- Consome: `deploy-hermes-agent.py` (Task 4), `vm-provision.py rotate-ssh-key` (Task 2)
- Produz: suite offline completa; zero dependências de rede

- [ ] **Step 1: Ampliar test-hermes-agent.sh com os casos de deploy**

Substituir o conteúdo de `tests/scripts/test-hermes-agent.sh` pela versão completa:

```bash
#!/usr/bin/env bash
#
# Deterministic, offline tests for the Hermes Agent recipe deployer.
# Uses --dry-run so nothing executes over the network.
#
#   - input validation: env_name/ip/telegram_user_id/ssh-key/skip-secrets conflicts
#   - first deploy: staging has compose.yaml + .env (600) + hermes-config.yaml;
#     every expected SSH/SCP/docker command is generated; no secret leaks
#   - basic auth: TTYD_BASIC_AUTH uses {SHA} format; admin_pass never in stdout
#   - idempotency: --skip-secrets skips .env generation and upload
#   - re-runs: deterministic command plan
#   - bundled compose: traefik + web-terminal + hermes-agent services present
#
# Usage: tests/scripts/test-hermes-agent.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

SCRIPT="$REPO/../skills/cloud-weaver-hermes-agent/scripts/deploy-hermes-agent.py"
COMPOSE="$REPO/../skills/cloud-weaver-hermes-agent/scripts/compose/compose.yaml"
CONFIG="$REPO/../skills/cloud-weaver-hermes-agent/scripts/hermes-config.yaml"
PYTHON="$(command -v python3)"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

echo "== hermes-agent: script compila =="
expect "compila"          "$PYTHON" -m py_compile "$SCRIPT"
expect "shebang python3"  grep -q "env python3" "$SCRIPT"

echo "== hermes-agent: validação de entrada =="
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQQQQ test@example.com" > "$BASE/key"
chmod 600 "$BASE/key"

"$PYTHON" "$SCRIPT" --env-name "Bad Name" --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 123 \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v1.out" 2>&1
expect "rejeita env_name inválido"  test $? != 0
expect "mensagem env_name"          grep -qF "only lowercase" "$BASE/v1.out"

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip "not-ip" \
  --hostname h.example.com --telegram-user-id 123 \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v2.out" 2>&1
expect "rejeita IP inválido"        test $? != 0

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 0 \
  --ssh-private-key "$BASE/key" --dry-run >"$BASE/v3.out" 2>&1
expect "rejeita telegram_user_id 0" test $? != 0

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 123 \
  --ssh-private-key "$BASE/missing" --dry-run >"$BASE/v4.out" 2>&1
expect "rejeita chave ausente"      test $? != 0
expect "mensagem SSH key not found" grep -qF "SSH private key not found" "$BASE/v4.out"

"$PYTHON" "$SCRIPT" --env-name hermes --public-ip 10.0.0.1 \
  --hostname h.example.com --telegram-user-id 123 \
  --ssh-private-key "$BASE/key" --skip-secrets \
  --admin-pass "x" --dry-run >"$BASE/v5.out" 2>&1
expect "rejeita skip-secrets+admin-pass" test $? != 0

# Helper: run a dry-run deploy
deploy_run() {
  local name="$1" stage="$2"; shift 2
  "$PYTHON" "$SCRIPT" --env-name hermes --public-ip 200.1.2.3 \
    --hostname "cr-hermes-net-vm.publiccloud.com.br" \
    --telegram-user-id 123456789 \
    --ssh-private-key "$BASE/key" \
    --staging-dir "$stage" --output "$BASE/$name.report.json" --dry-run "$@" \
    >"$BASE/$name.out" 2>&1
  printf '%s' "$?" >"$BASE/$name.rc"
}

echo "== hermes-agent: primeiro deploy =="
deploy_run d1 "$BASE/stage-d1"
expect "exit 0"                      test "$(cat "$BASE/d1.rc")" = 0
expect "report escrito"              test -f "$BASE/d1.report.json"

expect "mkdir compose, hermes_data, acme" \
  grep -qF "sudo mkdir -p /data/hermes/compose /data/hermes/hermes_data /data/hermes/acme" \
  "$BASE/d1.out"
expect "scp compose.yaml"            grep -qF "compose.yaml ubuntu@200.1.2.3:/data/hermes/compose/compose.yaml" "$BASE/d1.out"
expect "scp .env"                    grep -qF ".env ubuntu@200.1.2.3:/data/hermes/compose/.env" "$BASE/d1.out"
expect "chmod 600 .env"              grep -qF "sudo chmod 600 /data/hermes/compose/.env" "$BASE/d1.out"
expect "scp hermes-config.yaml"      grep -qF "hermes-config.yaml ubuntu@200.1.2.3:/data/hermes/hermes_data/config.yaml" "$BASE/d1.out"
expect "docker compose up --wait"    grep -qF "docker compose -p hermes-agent-hermes -f compose.yaml --env-file .env up -d --wait --wait-timeout 300" "$BASE/d1.out"

expect "stage .env existe"           test -f "$BASE/stage-d1/.env"
expect "stage .env modo 600"         test "$(stat -c '%a' "$BASE/stage-d1/.env")" = "600"
expect "stage compose.yaml existe"   test -f "$BASE/stage-d1/compose.yaml"
expect "stage hermes-config.yaml"    test -f "$BASE/stage-d1/hermes-config.yaml"

expect ".env tem TELEGRAM_ALLOWED_USERS" grep -qF "TELEGRAM_ALLOWED_USERS=123456789" "$BASE/stage-d1/.env"
expect ".env tem HOSTNAME"               grep -qF "HOSTNAME=cr-hermes-net-vm.publiccloud.com.br" "$BASE/stage-d1/.env"
expect ".env tem TTYD_BASIC_AUTH"        grep -qF "TTYD_BASIC_AUTH=admin:{SHA}" "$BASE/stage-d1/.env"
expect ".env tem placeholder token"      grep -qF "TELEGRAM_BOT_TOKEN=REPLACE_WITH" "$BASE/stage-d1/.env"

echo "== hermes-agent: admin_pass não vaza para stdout =="
ADMIN_PASS="$(grep '^TTYD_BASIC_AUTH=' "$BASE/stage-d1/.env" | cut -d= -f2- | sed 's/{SHA}//')"
# stdout should only have the CMD lines and the final "Deployed" line
refute "admin_pass não no stdout"    grep -qF "$ADMIN_PASS" "$BASE/d1.out"

echo "== hermes-agent: admin_pass no report JSON =="
expect "report tem admin_pass"       python3 -c "
import json, sys
r = json.load(open('$BASE/d1.report.json'))
assert r.get('admin_pass'), 'admin_pass ausente'
assert len(r['admin_pass']) >= 32, 'admin_pass curto'
print('ok')
" >/dev/null

echo "== hermes-agent: idempotência (--skip-secrets) =="
deploy_run i1 "$BASE/stage-i1" --skip-secrets
expect "exit 0 skip-secrets"         test "$(cat "$BASE/i1.rc")" = 0
refute ".env não gerado"             test -f "$BASE/stage-i1/.env"
refute ".env não scp'd"              grep -qF "compose/.env" "$BASE/i1.out"
refute "chmod 600 não executado"     grep -qF "chmod 600" "$BASE/i1.out"
expect "compose ainda up'd"          grep -qF "docker compose -p hermes-agent-hermes" "$BASE/i1.out"

echo "== hermes-agent: re-runs têm plano determinístico =="
deploy_run r1 "$BASE/stage-r"
deploy_run r2 "$BASE/stage-r"
cmd_r1="$(grep '^CMD ' "$BASE/r1.out")"
cmd_r2="$(grep '^CMD ' "$BASE/r2.out")"
expect "plano idêntico entre runs"   test "$cmd_r1" = "$cmd_r2"

echo "== hermes-agent: compose bundled =="
expect "traefik service"             grep -qF "traefik:v3" "$COMPOSE"
expect "ttyd service"                grep -qF "ghcr.io/tsl0922/ttyd" "$COMPOSE"
expect "hermes-agent image"          grep -qF "nousresearch/hermes-agent:latest" "$COMPOSE"
expect "hermes-agent sem porta"      python3 -c "
import yaml, sys
try:
    d = yaml.safe_load(open('$COMPOSE'))
    svc = d['services']['hermes-agent']
    assert 'ports' not in svc, 'hermes-agent não deve publicar portas'
    print('ok')
except ImportError:
    print('pyyaml ausente — pular verificação YAML')
" >/dev/null || true
expect "traefik porta 80 443"        grep -qF '"80:80"' "$COMPOSE"
expect "basic auth middleware"       grep -qF "basicauth.users" "$COMPOSE"
expect "TLS certresolver"            grep -qF "certresolver=le" "$COMPOSE"

echo "== hermes-agent: hermes-config.yaml bundled =="
expect "approvals.mode: smart"       grep -qF "mode: smart" "$CONFIG"
expect "cron_mode presente"          grep -q "cron_mode" "$CONFIG"

summary "hermes-agent"
```

- [ ] **Step 2: Adicionar seção rotate-ssh-key em test-vm-provision.sh**

Ao final de `tests/scripts/test-vm-provision.sh`, antes da chamada a `summary`, adicionar:

```bash
echo "== vm-provision: rotate-ssh-key (mock) =="
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQQQQ new-key@example.com" > "$BASE/newkey.pub"
prov rot1 vm-provision-existing.json \
  rotate-ssh-key --env-name hermes --ssh-pubkey "$BASE/newkey.pub"
expect "rotate exit 0"               test "$(prov_rc rot1)" = 0
expect "stopVirtualMachine no log"   grep -qF "stopVirtualMachine" "$BASE/rot1.log"
expect "resetSSHKey no log"          grep -qF "resetSSHKeyForVirtualMachine" "$BASE/rot1.log"
expect "startVirtualMachine no log"  grep -qF "startVirtualMachine" "$BASE/rot1.log"
```

*(Requer a fixture `vm-provision-existing.json` que já existe — tem a VM em estado Running.)*

- [ ] **Step 3: Rodar todos os testes**

```bash
bash tests/scripts/test-hermes-agent.sh
bash tests/scripts/test-vm-provision.sh
```

Expected: ambos encerram com `0 failed`.

- [ ] **Step 4: Commit**

```bash
git add tests/scripts/test-hermes-agent.sh tests/scripts/test-vm-provision.sh
git commit -m "test: complete offline suite for hermes-agent deploy and rotate-ssh-key"
```

---

### Task 8: Catalog updates + version bump

**Files:**
- Modify: `skills/cloud-weaver-playbook/SKILL.md`
- Modify: `skills/start-cloud/SKILL.md`
- Modify: `.claude-plugin/plugin.json`
- Run: `scripts/stamp-version.sh`

**Interfaces:**
- Consome: skills finalizadas nas Tasks 1-6
- Produz: versão 0.8.0 publicada, catálogos atualizados, stamp propagado para `pre-flight-check`

- [ ] **Step 1: Confirmar os skills existentes no filesystem**

```bash
ls skills/
```

Expected: `cloud-weaver-computer-setup cloud-weaver-hermes-agent cloud-weaver-monitor cloud-weaver-offboard cloud-weaver-playbook cloud-weaver-pre-flight-check cloud-weaver-vm-setup cloud-weaver-waha start-cloud`

- [ ] **Step 2: Atualizar a tabela do playbook**

Em `skills/cloud-weaver-playbook/SKILL.md`, substituir a tabela de skills pela versão final:

```markdown
| Skill | Purpose | Status |
|-------|---------|--------|
| `start-cloud` | The installation flow — the entry point users type | ✅ |
| `cloud-weaver-pre-flight-check` | Version check + environment validation | ✅ |
| `cloud-weaver-computer-setup` | Install/verify `gh`, `ssh`, `jq` and the Ed25519 SSH key | ✅ |
| `cloud-weaver-vm-setup` | Provision VM + network + firewall on the Locaweb Cloud (idempotent) | ✅ |
| `cloud-weaver-waha` | Recipe: WAHA (WhatsApp HTTP API + PostgreSQL) | ✅ |
| `cloud-weaver-hermes-agent` | Recipe: Hermes Agent (Nous Research, Telegram) | ✅ |
| `cloud-weaver-monitor` | Health check + polling + rollback | ✅ |
| `cloud-weaver-offboard` | Post-workshop offboarding: credential rotation + local cleanup | ✅ |
| `cloud-weaver-coolify` | Recipe: Coolify (PaaS self-hosted) | 🔜 not implemented |
| `cloud-weaver-jitsi` | Recipe: Jitsi Meet | 🔜 not implemented |
```

- [ ] **Step 3: Atualizar o catálogo do start-cloud**

Em `skills/start-cloud/SKILL.md`, substituir a tabela de receitas:

```markdown
| Recipe | ID | Description | Status |
|--------|----|-------------|--------|
| WAHA | `waha` | Agente de WhatsApp (WAHA) + PostgreSQL | ✅ disponível |
| Hermes Agent | `hermes_agent` | Agente Telegram + LLM (Nous Research) | ✅ disponível |
| Coolify | `coolify` | PaaS self-hosted para publicar suas próprias apps | 🔜 em breve |
| Jitsi Meet | `jitsi` | Servidor de videoconferência | 🔜 em breve |
```

- [ ] **Step 4: Bumpar a versão para 0.8.0**

Editar `.claude-plugin/plugin.json`:

```json
{
  "name": "cloud-weaver",
  "description": "Um assistente que instala aplicações prontas (Hermes Agent, Coolify, Jitsi Meet) na Locaweb Cloud por conversa.",
  "version": "0.8.0"
}
```

- [ ] **Step 5: Propagar a versão para o pre-flight-check**

```bash
bash scripts/stamp-version.sh
```

Expected: `Stamped version 0.8.0 into SKILL.md`

- [ ] **Step 6: Verificar o stamp**

```bash
grep "CLOUD_WEAVER_VERSION" skills/cloud-weaver-pre-flight-check/SKILL.md
```

Expected: `<!-- CLOUD_WEAVER_VERSION: 0.8.0 -->`

- [ ] **Step 7: Commit final**

```bash
git add skills/cloud-weaver-playbook/SKILL.md \
        skills/start-cloud/SKILL.md \
        .claude-plugin/plugin.json \
        skills/cloud-weaver-pre-flight-check/SKILL.md
git commit -m "chore: bump to 0.8.0; update catalog with waha, hermes-agent, offboard"
```

---

## Self-Review

### Cobertura da spec

| Seção da spec | Task |
|---------------|------|
| 6.1 `cloud-weaver-hermes-agent/` | Tasks 3, 4, 5 |
| 6.2 `cloud-weaver-offboard/` | Task 6 |
| 6.3 `vm-provision.py` — cidrlist + rotate-ssh-key | Task 2 |
| 6.4 Renomeação hermes→waha | Task 1 |
| 6.5 Catálogo | Task 8 |
| Seção 4.1 Senha aleatória (32 bytes) | Task 4 (`token_urlsafe(32)`) |
| Seção 4.2 Camadas de segurança | Task 3 (compose), Task 4 (não exibe senha no stdout) |
| Seção 7 Máquina emprestada | Task 6 (offboard) |
| Seção 9 Testes | Task 7 |
| Q1 (docker.sock) | Documentado no compose e no SKILL.md como questão aberta |
| Q2 (cron_mode) | `auto` no template; marcado como Q2 nos comentários |
| Q3/Q4 | Documentados no SKILL.md como "validar no smoke test" |

### Placeholder scan

Nenhum "TBD", "TODO" ou "similar to" encontrado no plano.

### Consistência de tipos

- `admin_pass` é `str` em todos os contextos (Task 4).
- `rotate_ssh_key` recebe `cfg` com `env_name` e `public_key` — consistente com `build_cfg` existente.
- `ensure_firewall(client, ip_id, ports, cidrlist="0.0.0.0/0")` — backward-compatible; call sites existentes passam apenas 3 argumentos e usam o default.
- Container name `hermes-${ENV_NAME}` usado consistentemente em `compose.yaml` e no comando `ttyd`.
- Compose project name `hermes-agent-${env_name}` em `deploy-hermes-agent.py` e no comando `docker compose`.
