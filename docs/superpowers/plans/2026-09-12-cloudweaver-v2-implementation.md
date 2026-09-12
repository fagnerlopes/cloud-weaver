# CloudWeaver v2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the GitHub Actions + Kamal deployment model: the CloudWeaver agent generates a GitHub repo with Kamal configs and GHA workflows; pipelines handle VM provisioning and container deployment using pre-built recipe images.

**Architecture:** A new skill (`cloud-weaver-repo-setup`) generates all repository files from templates using `gen-recipe.py`, creates the GitHub repo, sets secrets, and triggers the workflow. The `locaweb/locaweb-cloud-provision` reusable workflow handles VM provisioning; Kamal deploys pre-built images from `ghcr.io/fagnerlopes`. Recipe Dockerfiles live under `recipes/` in the cloud-weaver repo and are published via `.github/workflows/build-recipes.yml`.

**Tech Stack:** Python 3 stdlib (re, pathlib, json, argparse), bash, Kamal 2, GitHub Actions, GHCR

**Spec:** `docs/superpowers/specs/2026-09-12-cloudweaver-v2-github-actions-kamal.md`

## Global Constraints

- All user-facing output in PT-BR; code comments in English.
- Every agent message tagged `[CloudWeaver]`.
- Secrets never printed or logged — presence-check only.
- VM/env names validated against `[a-z0-9_]`.
- Template delimiter `@[VAR_NAME]` (uppercase, no `${{ }}`conflict with GHA expressions).
- Kamal `forward_headers: false` non-negotiable.
- No `secrets: inherit` in GHA workflows (external reusable workflow).
- `locaweb-cloud-provision` called as `locaweb/locaweb-cloud-provision/.github/workflows/provision.yml@v1`.
- GitHub Secrets: `LOCAWEB_API_KEY`, `LOCAWEB_API_SECRET`, `SSH_PRIVATE_KEY` (infra) + recipe-specific.

---

## File Map

### New files

| Path | Responsibility |
|---|---|
| `.github/workflows/build-recipes.yml` | Builds and publishes pre-built recipe images to `ghcr.io/fagnerlopes` |
| `recipes/hermes-agent/Dockerfile` | Image source for `ghcr.io/fagnerlopes/cw-hermes-agent:latest` |
| `recipes/waha/Dockerfile` | Image source for `ghcr.io/fagnerlopes/cw-waha:latest` |
| `skills/cloud-weaver-repo-setup/SKILL.md` | Agent instructions for the full repo-setup flow |
| `skills/cloud-weaver-repo-setup/scripts/repo-init.sh` | Creates GitHub repo from current dir (idempotent) |
| `skills/cloud-weaver-repo-setup/scripts/gen-recipe.py` | Renders recipe templates into output directory |
| `skills/cloud-weaver-repo-setup/templates/hermes-agent/Dockerfile` | Participant's Dockerfile (FROM pre-built) |
| `skills/cloud-weaver-repo-setup/templates/hermes-agent/deploy.yml` | GHA workflow template |
| `skills/cloud-weaver-repo-setup/templates/hermes-agent/config-deploy.yml` | Kamal base config template |
| `skills/cloud-weaver-repo-setup/templates/hermes-agent/config-deploy-preview.yml` | Kamal env config template |
| `skills/cloud-weaver-repo-setup/templates/hermes-agent/kamal-secrets-common` | Common secrets file template |
| `skills/cloud-weaver-repo-setup/templates/hermes-agent/kamal-secrets-preview` | Preview secrets file template |
| `skills/cloud-weaver-repo-setup/templates/waha/Dockerfile` | Participant's Dockerfile (waha) |
| `skills/cloud-weaver-repo-setup/templates/waha/deploy.yml` | GHA workflow template (with Postgres accessory) |
| `skills/cloud-weaver-repo-setup/templates/waha/config-deploy.yml` | Kamal base config (waha) |
| `skills/cloud-weaver-repo-setup/templates/waha/config-deploy-preview.yml` | Kamal env config (waha + pg accessory) |
| `skills/cloud-weaver-repo-setup/templates/waha/kamal-secrets-common` | Common secrets (waha) |
| `skills/cloud-weaver-repo-setup/templates/waha/kamal-secrets-preview` | Preview secrets (waha) |
| `tests/scripts/test-repo-setup.sh` | Offline tests for gen-recipe.py |

### Modified files

| Path | Change |
|---|---|
| `skills/start-cloud/SKILL.md` | Rewrite Steps 3–7 for v2 flow (repo-setup instead of vm-setup + deploy) |
| `.claude-plugin/plugin.json` | Bump version to 1.0.0 |
| `skills/cloud-weaver-pre-flight-check/SKILL.md` | Update CLOUD_WEAVER_VERSION marker (via stamp script) |

---

## Task 1: Recipe image build pipeline

**Files:**
- Create: `.github/workflows/build-recipes.yml`
- Create: `recipes/hermes-agent/Dockerfile`
- Create: `recipes/waha/Dockerfile`

**Interfaces:**
- Produces: Docker images published to `ghcr.io/fagnerlopes/cw-hermes-agent:latest` and `ghcr.io/fagnerlopes/cw-waha:latest` (public, accessible without auth)

- [ ] **Step 1: Create `recipes/hermes-agent/Dockerfile`**

```dockerfile
# CloudWeaver hermes-agent recipe image.
#
# Bundles ttyd (web terminal on port 7681) as the main HTTP service managed
# by kamal-proxy. The Hermes Agent (Telegram bot + LLM) runs alongside ttyd
# using the entrypoint script below.
#
# Health check: ttyd responds with HTTP 200 at GET / when healthy.
# Port: 7681 (kamal proxy.app_port must match).
#
# NOTE: Replace the CMD below with the actual multi-process setup once the
# hermes-agent upstream image is confirmed. Current placeholder gives a
# working terminal accessible via the browser.

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        tini wget ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Install ttyd (web terminal)
RUN TTYD_URL="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64" && \
    wget -qO /usr/local/bin/ttyd "$TTYD_URL" && \
    chmod +x /usr/local/bin/ttyd

EXPOSE 7681

HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
    CMD curl -fsS http://localhost:7681/ > /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["ttyd", "--port", "7681", "--writable", "bash"]
```

- [ ] **Step 2: Create `recipes/waha/Dockerfile`**

```dockerfile
# CloudWeaver WAHA recipe image.
#
# Thin wrapper over the official WAHA image that adds a health check
# and documents the expected port (3000).
# WAHA connects to Postgres at host "pg" (Kamal accessory internal hostname).

FROM devlikeapro/waha:latest

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
    CMD curl -fsS http://localhost:3000/api/health > /dev/null || exit 1
```

- [ ] **Step 3: Create `.github/workflows/build-recipes.yml`**

```yaml
# Builds and publishes pre-built recipe images to ghcr.io/fagnerlopes.
# Run manually or on changes to recipes/. Images are public (no auth required
# for participants to pull them).

name: Build Recipe Images

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths:
      - "recipes/**"

permissions:
  contents: read
  packages: write

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        recipe:
          - name: hermes-agent
            context: recipes/hermes-agent
          - name: waha
            context: recipes/waha

    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v5

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.repository_owner }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push ${{ matrix.recipe.name }}
        uses: docker/build-push-action@v6
        with:
          context: ${{ matrix.recipe.context }}
          push: true
          platforms: linux/amd64
          tags: |
            ghcr.io/fagnerlopes/cw-${{ matrix.recipe.name }}:latest
            ghcr.io/fagnerlopes/cw-${{ matrix.recipe.name }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Make package public
        run: |
          # Set the package visibility to public so participants can pull without auth.
          gh api \
            --method PATCH \
            -H "Accept: application/vnd.github+json" \
            "/user/packages/container/cw-${{ matrix.recipe.name }}" \
            -f visibility=public || echo "Note: visibility change may require manual step in GHCR UI"
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 4: Commit**

```bash
git add recipes/ .github/workflows/build-recipes.yml
git commit -m "feat: recipe image build pipeline (hermes-agent, waha)

Placeholder Dockerfiles for pre-built images at ghcr.io/fagnerlopes.
build-recipes.yml publishes on push to recipes/ or manual trigger.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 2: `gen-recipe.py` — template renderer

**Files:**
- Create: `skills/cloud-weaver-repo-setup/scripts/gen-recipe.py`
- Create: `tests/scripts/test-repo-setup.sh`

**Interfaces:**
- Produces: `gen_recipe(recipe, variables, output_dir)` called as CLI:
  `python3 gen-recipe.py --recipe hermes-agent --output-dir /tmp/out --zone ZP01 --web-plan small --telegram-user-id 123456789 --repo-name meu-hermes`
- Template files under `../templates/<recipe>/` (relative to script location)
- `@[VAR_NAME]` delimiter (uppercase, alphanumeric + underscore); raises `KeyError` on unknown variable
- Output directory created if absent; existing files overwritten

- [ ] **Step 1: Write the failing test first**

Create `tests/scripts/test-repo-setup.sh`:

```bash
#!/usr/bin/env bash
#
# Offline tests for gen-recipe.py — no network calls, no GitHub auth.
# Verifies that recipe files are generated correctly from templates.
#
# Usage: tests/scripts/test-repo-setup.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

SCRIPT="$REPO/../skills/cloud-weaver-repo-setup/scripts/gen-recipe.py"
PYTHON="$(command -v python3)"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

echo "== gen-recipe: script compila =="
expect "compila" "$PYTHON" -m py_compile "$SCRIPT"
expect "shebang python3" grep -q "env python3" "$SCRIPT"

echo "== gen-recipe: hermes-agent — geração básica =="
"$PYTHON" "$SCRIPT" \
    --recipe hermes-agent \
    --output-dir "$BASE/ha" \
    --zone ZP01 \
    --web-plan small \
    --telegram-user-id 987654321 \
    --repo-name meu-hermes \
    >"$BASE/ha.out" 2>&1
expect "exit 0 hermes-agent" test $? = 0

expect "Dockerfile gerado"              test -f "$BASE/ha/Dockerfile"
expect "deploy.yml gerado"              test -f "$BASE/ha/.github/workflows/deploy.yml"
expect "config/deploy.yml gerado"       test -f "$BASE/ha/config/deploy.yml"
expect "config/deploy.preview.yml"      test -f "$BASE/ha/config/deploy.preview.yml"
expect "kamal secrets-common"           test -f "$BASE/ha/.kamal/secrets-common"
expect "kamal secrets.preview"          test -f "$BASE/ha/.kamal/secrets.preview"

# Variables must be substituted
expect "zona no workflow"               grep -q "ZP01" "$BASE/ha/.github/workflows/deploy.yml"
expect "web-plan no workflow"           grep -q "small" "$BASE/ha/.github/workflows/deploy.yml"
expect "telegram user no config"        grep -q "987654321" "$BASE/ha/config/deploy.preview.yml"
expect "pre-built image no Dockerfile"  grep -q "ghcr.io/fagnerlopes/cw-hermes-agent" "$BASE/ha/Dockerfile"

# GHA expressions must survive unaltered
expect "GHA secrets.LOCAWEB_API_KEY intacto" \
    grep -q 'secrets.LOCAWEB_API_KEY' "$BASE/ha/.github/workflows/deploy.yml"
expect "GHA secrets.GITHUB_TOKEN intacto" \
    grep -q 'secrets.GITHUB_TOKEN' "$BASE/ha/.github/workflows/deploy.yml"

# No leftover @[...] placeholders
refute "sem placeholders no Dockerfile" grep -q '@\[' "$BASE/ha/Dockerfile"
refute "sem placeholders no workflow"   grep -q '@\[' "$BASE/ha/.github/workflows/deploy.yml"

echo "== gen-recipe: waha — geração básica =="
"$PYTHON" "$SCRIPT" \
    --recipe waha \
    --output-dir "$BASE/waha" \
    --zone ZP02 \
    --web-plan medium \
    --repo-name meu-waha \
    >"$BASE/waha.out" 2>&1
expect "exit 0 waha" test $? = 0

expect "Dockerfile waha"                test -f "$BASE/waha/Dockerfile"
expect "waha zona ZP02"                 grep -q "ZP02" "$BASE/waha/.github/workflows/deploy.yml"
expect "waha accessory pg no workflow"  grep -q '"name":"pg"' "$BASE/waha/.github/workflows/deploy.yml"
expect "waha pre-built image"           grep -q "ghcr.io/fagnerlopes/cw-waha" "$BASE/waha/Dockerfile"
refute "sem placeholders waha workflow" grep -q '@\[' "$BASE/waha/.github/workflows/deploy.yml"

echo "== gen-recipe: validações =="
"$PYTHON" "$SCRIPT" --recipe invalid-recipe --output-dir "$BASE/bad" \
    --zone ZP01 --web-plan small --repo-name x 2>"$BASE/bad.err" || true
expect "rejeita receita inválida" grep -q "Unknown recipe" "$BASE/bad.err"

"$PYTHON" "$SCRIPT" --recipe hermes-agent --output-dir "$BASE/bad2" \
    --zone ZP01 --web-plan small --telegram-user-id 0 --repo-name x \
    2>"$BASE/bad2.err" || true
expect "rejeita telegram-user-id 0" grep -q "telegram-user-id" "$BASE/bad2.err"

echo "== gen-recipe: idempotência =="
"$PYTHON" "$SCRIPT" \
    --recipe hermes-agent \
    --output-dir "$BASE/ha" \
    --zone ZP01 \
    --web-plan small \
    --telegram-user-id 987654321 \
    --repo-name meu-hermes \
    >"$BASE/ha2.out" 2>&1
expect "exit 0 re-run" test $? = 0
expect "Dockerfile ainda lá" test -f "$BASE/ha/Dockerfile"

summary "repo-setup"
```

- [ ] **Step 2: Run test to confirm it fails with "script not found"**

```bash
bash tests/scripts/test-repo-setup.sh 2>&1 | head -5
```

Expected: `FAIL` — script not found or py_compile error.

- [ ] **Step 3: Create `skills/cloud-weaver-repo-setup/scripts/gen-recipe.py`**

```python
#!/usr/bin/env python3
"""Recipe file generator for CloudWeaver v2.

Reads templates from ../templates/<recipe>/ (relative to this script),
substitutes @[VAR_NAME] placeholders, and writes output files into
--output-dir preserving subdirectory structure.

Template delimiter: @[VAR_NAME] — uppercase letters, digits, underscores.
GHA expressions (${{ secrets.X }}) and YAML syntax are untouched.
"""

import argparse
import re
import sys
from pathlib import Path

# Mapping: template filename → output path relative to output-dir.
_FILE_MAP = {
    "Dockerfile": "Dockerfile",
    "deploy.yml": ".github/workflows/deploy.yml",
    "config-deploy.yml": "config/deploy.yml",
    "config-deploy-preview.yml": "config/deploy.preview.yml",
    "kamal-secrets-common": ".kamal/secrets-common",
    "kamal-secrets-preview": ".kamal/secrets.preview",
}

_KNOWN_RECIPES = {"hermes-agent", "waha"}

# Template variable delimiter: @[VAR_NAME]
_PLACEHOLDER_RE = re.compile(r"@\[([A-Z0-9_]+)\]")


def render(content: str, ctx: dict) -> str:
    """Substitute @[VAR_NAME] placeholders; raise KeyError on unknown variable."""
    def replace(m: re.Match) -> str:
        key = m.group(1)
        if key not in ctx:
            raise KeyError(f"Undefined template variable: @[{key}]")
        return str(ctx[key])
    return _PLACEHOLDER_RE.sub(replace, content)


def build_context(args: argparse.Namespace) -> dict:
    """Build the substitution context from parsed args."""
    ctx: dict = {
        "ZONE": args.zone,
        "WEB_PLAN": args.web_plan,
        "REPO_NAME": args.repo_name,
    }
    if args.recipe == "hermes-agent":
        if args.telegram_user_id is not None and args.telegram_user_id <= 0:
            print(
                "ERROR: --telegram-user-id must be a positive integer, "
                f"got {args.telegram_user_id}",
                file=sys.stderr,
            )
            sys.exit(1)
        ctx["TELEGRAM_USER_ID"] = str(args.telegram_user_id or "")
    return ctx


def generate(recipe: str, ctx: dict, output_dir: Path, template_root: Path) -> None:
    """Render all template files for the recipe into output_dir."""
    recipe_tpl_dir = template_root / recipe
    if not recipe_tpl_dir.is_dir():
        print(f"ERROR: Template directory not found: {recipe_tpl_dir}", file=sys.stderr)
        sys.exit(1)

    for tpl_name, out_rel in _FILE_MAP.items():
        tpl_path = recipe_tpl_dir / tpl_name
        if not tpl_path.is_file():
            # Not every recipe uses every file (e.g., waha has no telegram config).
            continue

        content = tpl_path.read_text(encoding="utf-8")
        rendered = render(content, ctx)

        out_path = output_dir / out_rel
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(rendered, encoding="utf-8")

    # Verify no leftover placeholders in any output file.
    for out_rel in _FILE_MAP.values():
        out_path = output_dir / out_rel
        if not out_path.is_file():
            continue
        content = out_path.read_text(encoding="utf-8")
        leftovers = _PLACEHOLDER_RE.findall(content)
        if leftovers:
            print(
                f"ERROR: Unrendered placeholders in {out_path}: {leftovers}",
                file=sys.stderr,
            )
            sys.exit(1)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Generate CloudWeaver recipe files from templates.")
    p.add_argument("--recipe", required=True,
                   help=f"Recipe name: {', '.join(sorted(_KNOWN_RECIPES))}")
    p.add_argument("--output-dir", required=True,
                   help="Directory to write generated files into (created if absent)")
    p.add_argument("--zone", default="ZP01", choices=["ZP01", "ZP02"],
                   help="Locaweb Cloud zone (default: ZP01)")
    p.add_argument("--web-plan", default="small",
                   choices=["micro", "small", "medium", "large", "xlarge", "2xlarge", "4xlarge"],
                   help="Web VM plan (default: small)")
    p.add_argument("--repo-name", required=True,
                   help="GitHub repository name (e.g. meu-hermes)")
    p.add_argument("--telegram-user-id", type=int, default=None,
                   help="Telegram user ID (required for hermes-agent)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if args.recipe not in _KNOWN_RECIPES:
        print(f"ERROR: Unknown recipe '{args.recipe}'. "
              f"Known: {', '.join(sorted(_KNOWN_RECIPES))}", file=sys.stderr)
        return 1

    if args.recipe == "hermes-agent" and not args.telegram_user_id:
        print("ERROR: --telegram-user-id is required for the hermes-agent recipe", file=sys.stderr)
        return 1

    ctx = build_context(args)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Templates live in ../templates/ relative to this script.
    template_root = Path(__file__).resolve().parent.parent / "templates"

    generate(args.recipe, ctx, output_dir, template_root)
    print(f"Generated {args.recipe} recipe files in {output_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it fails correctly (templates not yet created)**

```bash
bash tests/scripts/test-repo-setup.sh 2>&1 | head -10
```

Expected: compile passes, generation fails with "Template directory not found".

- [ ] **Step 5: Commit gen-recipe.py and test**

```bash
mkdir -p skills/cloud-weaver-repo-setup/scripts
git add skills/cloud-weaver-repo-setup/scripts/gen-recipe.py tests/scripts/test-repo-setup.sh
git commit -m "feat(repo-setup): gen-recipe.py and offline tests

Template renderer for CloudWeaver v2 recipe files. Uses @[VAR_NAME]
delimiter to avoid conflicts with GHA \${{ }} expressions.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 3: hermes-agent templates

**Files:**
- Create: `skills/cloud-weaver-repo-setup/templates/hermes-agent/Dockerfile`
- Create: `skills/cloud-weaver-repo-setup/templates/hermes-agent/deploy.yml`
- Create: `skills/cloud-weaver-repo-setup/templates/hermes-agent/config-deploy.yml`
- Create: `skills/cloud-weaver-repo-setup/templates/hermes-agent/config-deploy-preview.yml`
- Create: `skills/cloud-weaver-repo-setup/templates/hermes-agent/kamal-secrets-common`
- Create: `skills/cloud-weaver-repo-setup/templates/hermes-agent/kamal-secrets-preview`

**Interfaces:**
- Consumes: `gen-recipe.py` render loop with `@[ZONE]`, `@[WEB_PLAN]`, `@[TELEGRAM_USER_ID]`, `@[REPO_NAME]`
- Produces: files matching the test assertions in Task 2

- [ ] **Step 1: Create `templates/hermes-agent/Dockerfile`**

```dockerfile
# Generated by CloudWeaver. Uses the pre-built hermes-agent image from
# ghcr.io/fagnerlopes/cw-hermes-agent to eliminate on-the-day build time.
# Kamal builds this trivial Dockerfile (pull + re-tag), pushes to
# ghcr.io/<your-github-username>/@[REPO_NAME], and deploys to the VM.
FROM ghcr.io/fagnerlopes/cw-hermes-agent:latest
```

- [ ] **Step 2: Create `templates/hermes-agent/deploy.yml`**

Note: `${{ }}` is GHA syntax — left as-is by gen-recipe.py. `@[...]` is substituted.

```yaml
# Generated by CloudWeaver. Provisions a VM on Locaweb Cloud and deploys
# the Hermes Agent (Telegram + LLM) using Kamal.
name: Deploy

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths-ignore: [".claude/**"]

permissions:
  contents: read
  packages: write

jobs:
  infra:
    uses: locaweb/locaweb-cloud-provision/.github/workflows/provision.yml@v1
    with:
      env_name: "preview"
      zone: "@[ZONE]"
      web_plan: "@[WEB_PLAN]"
      web_disk_size_gb: 20
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.LOCAWEB_API_KEY }}
      CLOUDSTACK_SECRET_KEY: ${{ secrets.LOCAWEB_API_SECRET }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}

  deploy:
    needs: infra
    runs-on: ubuntu-latest
    env:
      TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
    steps:
      - uses: actions/checkout@v5

      - name: Load infrastructure environment
        run: echo "${{ needs.infra.outputs.infra_env }}" >> "$GITHUB_ENV"

      - name: Set repo identity
        run: |
          echo "REPO_NAME=$(echo '${{ github.event.repository.name }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"
          echo "REPO_FULL=$(echo '${{ github.repository }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"
          echo "REPO_OWNER=$(echo '${{ github.repository_owner }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"

      - uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - uses: crazy-max/ghaction-github-runtime@v3

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"

      - run: gem install kamal --no-document

      - name: Deploy with Kamal
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
        run: |
          kamal proxy boot -d preview || kamal proxy reboot -y -d preview || true
          kamal setup -d preview

      - uses: actions/delete-package-versions@v5
        with:
          package-name: ${{ env.REPO_NAME }}
          package-type: container
          min-versions-to-keep: 1
```

- [ ] **Step 3: Create `templates/hermes-agent/config-deploy.yml`**

```yaml
# Generated by CloudWeaver — base Kamal configuration (all environments).
# Do not edit service/image/registry/builder blocks — they are set by the
# deployment pipeline.

service: <%= ENV['REPO_NAME'] %>
image: <%= ENV['REPO_FULL'] %>

proxy:
  app_port: 7681      # ttyd web terminal port
  ssl: true
  forward_headers: false
  healthcheck:
    path: /
    interval: 5
    timeout: 10

ssh:
  user: ubuntu

registry:
  server: ghcr.io
  username: <%= ENV['REPO_OWNER'] %>
  password:
    - KAMAL_REGISTRY_PASSWORD

builder:
  arch: amd64
  cache:
    type: gha
    options: mode=max,ignore-error=true

logging:
  driver: json-file
  options:
    max-size: "50m"
    max-file: "5"

readiness_delay: 30
deploy_timeout: 300
drain_timeout: 30
```

- [ ] **Step 4: Create `templates/hermes-agent/config-deploy-preview.yml`**

```yaml
# Generated by CloudWeaver — environment-specific Kamal configuration.
# INFRA_WEB_IP is exported by the infra job and loaded into $GITHUB_ENV
# before Kamal runs.

servers:
  web:
    hosts:
      - <%= ENV['INFRA_WEB_IP'] %>

proxy:
  host: <%= ENV['INFRA_WEB_IP'] %>.nip.io

volumes:
  - /data/preview/hermes_data:/data/hermes_data

env:
  clear:
    ENV_NAME: preview
    TELEGRAM_ALLOWED_USERS: "@[TELEGRAM_USER_ID]"
  secret:
    - TELEGRAM_BOT_TOKEN
```

- [ ] **Step 5: Create `templates/hermes-agent/kamal-secrets-common`**

```bash
# Generated by CloudWeaver — secrets common to all Kamal environments.
# KAMAL_REGISTRY_PASSWORD is provided by GitHub Actions automatically.
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
```

- [ ] **Step 6: Create `templates/hermes-agent/kamal-secrets-preview`**

```bash
# Generated by CloudWeaver — preview-environment secrets.
# These are mapped from GitHub Secrets → runner env vars → Kamal secrets.
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
```

- [ ] **Step 7: Run tests — expect hermes-agent tests to pass**

```bash
bash tests/scripts/test-repo-setup.sh 2>&1
```

Expected: hermes-agent section passes; waha section still fails (templates missing).

- [ ] **Step 8: Commit**

```bash
git add skills/cloud-weaver-repo-setup/templates/hermes-agent/
git commit -m "feat(repo-setup): hermes-agent recipe templates

Generates: Dockerfile, GHA deploy workflow, Kamal base/env configs,
and .kamal/secrets files. Port 7681 (ttyd), env_name fixed to preview.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 4: waha templates

**Files:**
- Create: `skills/cloud-weaver-repo-setup/templates/waha/Dockerfile`
- Create: `skills/cloud-weaver-repo-setup/templates/waha/deploy.yml`
- Create: `skills/cloud-weaver-repo-setup/templates/waha/config-deploy.yml`
- Create: `skills/cloud-weaver-repo-setup/templates/waha/config-deploy-preview.yml`
- Create: `skills/cloud-weaver-repo-setup/templates/waha/kamal-secrets-common`
- Create: `skills/cloud-weaver-repo-setup/templates/waha/kamal-secrets-preview`

**Interfaces:**
- Consumes: `gen-recipe.py` with `@[ZONE]`, `@[WEB_PLAN]`, `@[REPO_NAME]`
- Produces: files matching waha test assertions in Task 2; Postgres accessory on separate VM

- [ ] **Step 1: Create `templates/waha/Dockerfile`**

```dockerfile
# Generated by CloudWeaver. Uses the pre-built WAHA image from
# ghcr.io/fagnerlopes/cw-waha to eliminate on-the-day build time.
FROM ghcr.io/fagnerlopes/cw-waha:latest
```

- [ ] **Step 2: Create `templates/waha/deploy.yml`**

```yaml
# Generated by CloudWeaver. Provisions a VM on Locaweb Cloud (web + Postgres
# accessory) and deploys WAHA using Kamal.
name: Deploy

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths-ignore: [".claude/**"]

permissions:
  contents: read
  packages: write

jobs:
  infra:
    uses: locaweb/locaweb-cloud-provision/.github/workflows/provision.yml@v1
    with:
      env_name: "preview"
      zone: "@[ZONE]"
      web_plan: "@[WEB_PLAN]"
      web_disk_size_gb: 20
      accessories: '[{"name":"pg","plan":"small","disk_size_gb":20}]'
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.LOCAWEB_API_KEY }}
      CLOUDSTACK_SECRET_KEY: ${{ secrets.LOCAWEB_API_SECRET }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}

  deploy:
    needs: infra
    runs-on: ubuntu-latest
    env:
      POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
      WAHA_API_KEY: ${{ secrets.WAHA_API_KEY }}
    steps:
      - uses: actions/checkout@v5

      - name: Load infrastructure environment
        run: echo "${{ needs.infra.outputs.infra_env }}" >> "$GITHUB_ENV"

      - name: Set repo identity
        run: |
          echo "REPO_NAME=$(echo '${{ github.event.repository.name }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"
          echo "REPO_FULL=$(echo '${{ github.repository }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"
          echo "REPO_OWNER=$(echo '${{ github.repository_owner }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"

      - uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - uses: crazy-max/ghaction-github-runtime@v3

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"

      - run: gem install kamal --no-document

      - name: Deploy with Kamal
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
        run: |
          kamal proxy boot -d preview || kamal proxy reboot -y -d preview || true
          kamal setup -d preview
          kamal accessory reboot all -d preview

      - uses: actions/delete-package-versions@v5
        with:
          package-name: ${{ env.REPO_NAME }}
          package-type: container
          min-versions-to-keep: 1
```

- [ ] **Step 3: Create `templates/waha/config-deploy.yml`**

```yaml
# Generated by CloudWeaver — base Kamal configuration for WAHA.

service: <%= ENV['REPO_NAME'] %>
image: <%= ENV['REPO_FULL'] %>

proxy:
  app_port: 3000
  ssl: true
  forward_headers: false
  healthcheck:
    path: /api/health
    interval: 5
    timeout: 10

ssh:
  user: ubuntu

registry:
  server: ghcr.io
  username: <%= ENV['REPO_OWNER'] %>
  password:
    - KAMAL_REGISTRY_PASSWORD

builder:
  arch: amd64
  cache:
    type: gha
    options: mode=max,ignore-error=true

accessories:
  pg:
    image: supabase/postgres:15.8.1.060
    host: <%= ENV['INFRA_PG_IP'] %>
    port: 5432
    env:
      clear:
        POSTGRES_DB: waha
        POSTGRES_USER: waha
      secret:
        - POSTGRES_PASSWORD
    directories:
      - /data/preview/pgdata:/var/lib/postgresql/data

logging:
  driver: json-file
  options:
    max-size: "50m"
    max-file: "5"

readiness_delay: 30
deploy_timeout: 300
drain_timeout: 30
```

- [ ] **Step 4: Create `templates/waha/config-deploy-preview.yml`**

```yaml
# Generated by CloudWeaver — preview environment Kamal config for WAHA.

servers:
  web:
    hosts:
      - <%= ENV['INFRA_WEB_IP'] %>

proxy:
  host: <%= ENV['INFRA_WEB_IP'] %>.nip.io

volumes:
  - /data/preview/waha:/app/.sessions

env:
  clear:
    ENV_NAME: preview
    WHATSAPP_DEFAULT_ENGINE: NOWEB
    POSTGRES_HOST: pg
    POSTGRES_PORT: "5432"
    POSTGRES_DB: waha
    POSTGRES_USER: waha
  secret:
    - POSTGRES_PASSWORD
    - WAHA_API_KEY
```

- [ ] **Step 5: Create `templates/waha/kamal-secrets-common`**

```bash
# Generated by CloudWeaver — secrets common to all Kamal environments.
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
```

- [ ] **Step 6: Create `templates/waha/kamal-secrets-preview`**

```bash
# Generated by CloudWeaver — preview-environment secrets for WAHA.
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
WAHA_API_KEY=$WAHA_API_KEY
```

- [ ] **Step 7: Run all tests — expect all sections to pass**

```bash
bash tests/scripts/test-repo-setup.sh
```

Expected: all assertions pass, `PASS 20/20` (or similar).

- [ ] **Step 8: Commit**

```bash
git add skills/cloud-weaver-repo-setup/templates/waha/
git commit -m "feat(repo-setup): waha recipe templates

Generates: Dockerfile, GHA deploy workflow (with Postgres accessory VM),
Kamal base/env configs, and .kamal/secrets files. Port 3000.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 5: `repo-init.sh`

**Files:**
- Create: `skills/cloud-weaver-repo-setup/scripts/repo-init.sh`

**Interfaces:**
- Produces: `bash repo-init.sh <repo-name> [private|public]`
  - Creates (or reuses) GitHub repo, sets remote, pushes current branch
  - Idempotent: if repo already exists, adds remote and pushes
  - Validates repo name against `^[a-zA-Z0-9_][a-zA-Z0-9._-]*$`
  - Requires `gh auth status` to pass before running

- [ ] **Step 1: Create `skills/cloud-weaver-repo-setup/scripts/repo-init.sh`**

```bash
#!/usr/bin/env bash
# Initialize a local git repo and create a matching remote on GitHub.
#
# Usage: bash repo-init.sh <repo-name> [private|public]
#   repo-name  : Name for the GitHub repository (e.g. "meu-hermes")
#   visibility : "private" (default) or "public"
#
# Idempotent: if the remote repo already exists, this script adds it as
# origin and pushes without failing.
set -euo pipefail

REPO_NAME="${1:?Usage: repo-init.sh <repo-name> [private|public]}"
VISIBILITY="${2:-private}"

# Validate repository name — alphanumeric, hyphens, underscores, dots;
# must not start with hyphen or dot (prevents flag injection and GitHub rejection).
if [[ ! "$REPO_NAME" =~ ^[a-zA-Z0-9_][a-zA-Z0-9._-]*$ ]]; then
  echo "ERROR: Invalid repository name '$REPO_NAME'." >&2
  echo "       Use only letters, digits, hyphens, underscores, and dots;" >&2
  echo "       must not start with '-' or '.'." >&2
  exit 1
fi

if [[ "$VISIBILITY" != "private" && "$VISIBILITY" != "public" ]]; then
  echo "ERROR: visibility must be 'private' or 'public', got '$VISIBILITY'" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: Not authenticated with GitHub. Run 'gh auth login' first." >&2
  exit 1
fi

# Initialize local git repo if needed.
if [ ! -d .git ]; then
  echo "Initializing local git repository..."
  git init -b main
fi

# Create an initial commit if the repo is empty.
if ! git rev-parse HEAD >/dev/null 2>&1; then
  echo "Creating initial commit..."
  git add -A
  git commit -m "Initial commit: CloudWeaver recipe setup" --no-gpg-sign
fi

# If remote 'origin' already set, skip creation.
if git remote get-url origin >/dev/null 2>&1; then
  echo "Remote 'origin' already set: $(git remote get-url origin)"
  BRANCH="$(git branch --show-current)"
  git push -u origin "$BRANCH" || true
  exit 0
fi

# Check whether the repo already exists on GitHub.
if gh repo view "$REPO_NAME" >/dev/null 2>&1; then
  echo "Repository '$REPO_NAME' already exists on GitHub — adding as origin."
  REMOTE_URL="$(gh repo view "$REPO_NAME" --json sshUrl --jq .sshUrl)"
  git remote add origin "$REMOTE_URL"
  BRANCH="$(git branch --show-current)"
  git fetch origin 2>/dev/null || true
  git push -u origin "$BRANCH"
else
  echo "Creating $VISIBILITY repository '$REPO_NAME' on GitHub..."
  if [[ "$VISIBILITY" == "private" ]]; then
    gh repo create "$REPO_NAME" --private --source=. --remote=origin --push
  else
    gh repo create "$REPO_NAME" --public  --source=. --remote=origin --push
  fi
fi

echo ""
echo "Repository ready:"
echo "  Local:  $(pwd)"
echo "  Remote: $(git remote get-url origin)"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x skills/cloud-weaver-repo-setup/scripts/repo-init.sh
```

- [ ] **Step 3: Commit**

```bash
git add skills/cloud-weaver-repo-setup/scripts/repo-init.sh
git commit -m "feat(repo-setup): repo-init.sh — idempotent GitHub repo creator

Adapted from cofounder. Validates repo name, creates or reuses GitHub
remote, pushes current branch. Requires gh auth.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 6: `cloud-weaver-repo-setup` SKILL.md

**Files:**
- Create: `skills/cloud-weaver-repo-setup/SKILL.md`

**Interfaces:**
- Consumed by: agent via Skill tool, invoked from `start-cloud` Step 5
- Produces: GitHub repo with all recipe files, secrets set, workflow triggered

- [ ] **Step 1: Create `skills/cloud-weaver-repo-setup/SKILL.md`**

```markdown
---
name: cloud-weaver-repo-setup
description: >
  Creates a GitHub repository for the recipe, generates Kamal + GHA workflow
  files, sets secrets, and triggers the deploy pipeline. Invoke after the
  user has confirmed the configuration in start-cloud Step 4.
---

# Repo Setup

This skill orchestrates the full repository setup for a CloudWeaver recipe.
Follow the steps in order. All commands run in the user's project directory
unless specified otherwise.

## Step 1 — Verify pre-conditions

Run these checks before creating anything:

```bash
gh auth status
```

If it fails, stop and tell the user to run `gh auth login` in their terminal.

Check required env vars (presence only — never print values):

```bash
[[ -z "${LOCAWEB_API_KEY:-}"   ]] && echo "MISSING: LOCAWEB_API_KEY"
[[ -z "${LOCAWEB_API_SECRET:-}"]] && echo "MISSING: LOCAWEB_API_SECRET"
[[ -z "${LOCAWEB_API_KEY:-}"   ]] || [[ -z "${LOCAWEB_API_SECRET:-}" ]] && exit 1 || true
```

For hermes-agent: also check `TELEGRAM_BOT_TOKEN`.

## Step 2 — Generate SSH key

Generate a dedicated Ed25519 key for this deployment (one key per repo):

```bash
SSH_KEY="$HOME/.ssh/cw-${REPO_NAME}"
if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "cloudweaver-${REPO_NAME}"
fi
```

Never display or log the private key content.

## Step 3 — Create a staging directory and generate recipe files

```bash
STAGE_DIR="$(mktemp -d)"
SKILL_DIR="<path-to-this-skill>"  # resolved at runtime from skill directory

python3 "$SKILL_DIR/scripts/gen-recipe.py" \
  --recipe     "$RECIPE" \
  --output-dir "$STAGE_DIR" \
  --zone        "$ZONE" \
  --web-plan    "$WEB_PLAN" \
  --repo-name   "$REPO_NAME" \
  [--telegram-user-id "$TELEGRAM_USER_ID"]  # hermes-agent only
```

`SKILL_DIR` is the directory where this `SKILL.md` lives. Resolve it at
runtime using the skill's own path (not the current working directory).

If gen-recipe.py exits non-zero, show the error and stop.

## Step 4 — Initialize git and create GitHub repo

```bash
cd "$STAGE_DIR"
bash "$SKILL_DIR/scripts/repo-init.sh" "$REPO_NAME" private
```

## Step 5 — Set GitHub Secrets

Set secrets from environment variables. Never echo values in the conversation.

### Infra secrets (all recipes):

```bash
# Read SSH private key into variable (never displayed)
SSH_KEY_CONTENT="$(cat "$HOME/.ssh/cw-${REPO_NAME}")"
gh secret set LOCAWEB_API_KEY    --repo "$REPO_NAME" <<< "$LOCAWEB_API_KEY"
gh secret set LOCAWEB_API_SECRET --repo "$REPO_NAME" <<< "$LOCAWEB_API_SECRET"
gh secret set SSH_PRIVATE_KEY    --repo "$REPO_NAME" <<< "$SSH_KEY_CONTENT"
```

### Recipe-specific secrets:

**hermes-agent:**
```bash
gh secret set TELEGRAM_BOT_TOKEN --repo "$REPO_NAME" <<< "$TELEGRAM_BOT_TOKEN"
```

**waha:**
```bash
POSTGRES_PASSWORD="$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")"
WAHA_API_KEY="$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")"
gh secret set POSTGRES_PASSWORD --repo "$REPO_NAME" <<< "$POSTGRES_PASSWORD"
gh secret set WAHA_API_KEY      --repo "$REPO_NAME" <<< "$WAHA_API_KEY"
# Store generated secrets for the final report — in a 0600 file, not in the conversation.
REPORT_FILE="$HOME/.cloud-weaver-${REPO_NAME}-report.json"
python3 -c "
import json, os
data = {'postgres_password': '$POSTGRES_PASSWORD', 'waha_api_key': '$WAHA_API_KEY'}
open('$REPORT_FILE', 'w').write(json.dumps(data, indent=2))
os.chmod('$REPORT_FILE', 0o600)
"
```

After setting all secrets, confirm to the user: "✅ X secrets configurados no repositório" — count only, no names or values.

## Step 6 — Trigger the workflow

```bash
cd "$STAGE_DIR"
gh workflow run deploy.yml --repo "$REPO_NAME"
```

Wait 3 seconds, then get the run ID:

```bash
sleep 3
RUN_ID=$(gh run list --repo "$REPO_NAME" --workflow deploy.yml \
  --limit 1 --json databaseId --jq '.[0].databaseId')
echo "RUN_ID=$RUN_ID"
```

## Step 7 — Monitor progress

Show progress using STEP: bullets as the workflow runs:

```bash
gh run watch "$RUN_ID" --repo "$REPO_NAME" --exit-status
```

Display each job status as it changes:
- ⏳ `infra` — provisionando VM na Locaweb Cloud...
- ✅ `infra` — VM provisionada
- ⏳ `deploy` — fazendo deploy com Kamal...
- ✅ `deploy` — deploy concluído

On failure: show `gh run view "$RUN_ID" --repo "$REPO_NAME" --log-failed` so the error is visible.

## Step 8 — Extract and return the public IP

```bash
gh run view "$RUN_ID" --repo "$REPO_NAME" --json jobs \
  --jq '.jobs[] | select(.name == "infra") | .steps[] | select(.name == "Print summary") | .conclusion'
```

The VM public IP is printed in the workflow summary. Retrieve it:

```bash
gh run view "$RUN_ID" --repo "$REPO_NAME" --log \
  | grep "INFRA_WEB_IP=" | tail -1 | cut -d= -f2
```

Return the full public IP and the derived nip.io URL to `start-cloud` for the final report.
```

- [ ] **Step 2: Commit**

```bash
git add skills/cloud-weaver-repo-setup/SKILL.md
git commit -m "feat(repo-setup): SKILL.md — agent instructions for full repo setup

Orchestrates: SSH keygen, gen-recipe.py, repo-init.sh, gh secret set,
gh workflow run, gh run watch. Returns IP for final report.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 7: Rewrite `start-cloud` SKILL.md for v2

**Files:**
- Modify: `skills/start-cloud/SKILL.md`

**Interfaces:**
- Consumes: `cloud-weaver-pre-flight-check`, `cloud-weaver-playbook`, `cloud-weaver-repo-setup`
- No longer invokes: `cloud-weaver-vm-setup`, recipe deploy scripts, `cloud-weaver-monitor`

- [ ] **Step 1: Rewrite Steps 3–7 in `skills/start-cloud/SKILL.md`**

Read the current file first, then replace Steps 3–7 with the v2 flow. Keep Steps 0–2 unchanged (persona, pre-flight, catalog). Replace from `## Step 3` to end of file with:

```markdown
## Step 3 — Collect configuration, one question at a time

### 3.0 — Session file (resume support)

Before asking the first question, check for an existing session file:

```bash
SESSION_FILE="$HOME/.cloud-weaver-${recipe_id}-session.json"
test -f "$SESSION_FILE" && cat "$SESSION_FILE"
```

If found, show collected values and ask: continuar ou começar do zero?
- **Continuar:** skip already-answered questions.
- **Começar do zero:** `rm "$SESSION_FILE"` and proceed normally.

After each answer, persist to session file (no secrets — only config values):

```bash
python3 -c "
import json, os, datetime
f = os.path.expanduser('$SESSION_FILE')
data = {'recipe': '$recipe_id', 'saved_at': datetime.datetime.utcnow().isoformat() + 'Z', 'params': <collected_params_dict>}
open(f, 'w').write(json.dumps(data, indent=2, ensure_ascii=False))
os.chmod(f, 0o600)
"
```

### 3.1 — Questions per recipe

Ask **exactly one question per message**, validate before moving on.

#### All recipes

1. **Nome do repositório GitHub** — o participante escolhe (ex: `meu-hermes`).
   Validate: `^[a-zA-Z0-9_][a-zA-Z0-9._-]*$`. Explain it will be the GitHub repo name.

2. **Zona Locaweb Cloud** — ZP01 (São Paulo, default) ou ZP02 (padrão BR sul).
   Default: ZP01.

3. **Plano da VM** — micro / small (default) / medium / large.
   Show brief description: small = 2 vCPU / 4 GB RAM.

#### hermes-agent only

4. **ID do Telegram do usuário permitido** — número inteiro positivo (ex: 123456789).
   Explain: only this user can interact with the bot. Validate > 0.

#### waha only

4. **Número da porta da API WAHA** — default 3000. Validate 1–65535.

### 3.2 — Session file cleanup after final report

After Step 7, delete the session file:

```bash
rm -f "$HOME/.cloud-weaver-${recipe_id}-session.json"
```

---

## Step 4 — Present plan and get confirmation

Show a summary:

- Repositório GitHub: `<github-username>/<repo-name>` (privado)
- VM na Locaweb Cloud: plano `<plan>`, zona `<zone>`
- Disco de dados: 20 GB em `/data`
- Receita: `<recipe>` (imagem pré-construída: `ghcr.io/fagnerlopes/cw-<recipe>:latest`)
- Secrets que serão configurados: listar NOMES apenas, nunca valores
- Workflow GitHub Actions: infra (~4 min) + deploy Kamal (~1 min)

State that this creates billable resources on their Locaweb Cloud account.
Ask for explicit **yes** and wait for it.

---

## Step 5 — Setup and deploy

Use the Skill tool to invoke `cloud-weaver-repo-setup` and follow it.

Pass the configuration collected in Step 3:
- `RECIPE` = recipe ID (hermes-agent or waha)
- `REPO_NAME` = chosen repository name
- `ZONE` = chosen zone
- `WEB_PLAN` = chosen plan
- `TELEGRAM_USER_ID` = Telegram user ID (hermes-agent only)

The skill handles: SSH keygen → generate files → create GitHub repo →
set secrets → trigger workflow → monitor pipeline → return public IP.

Display only STEP: progress bullets during execution:
- ⏳ for in-progress steps
- ✅ for completed steps
- On failure: show complete output for diagnosis

---

## Step 6 — (No-op in v2)

The GitHub Actions pipeline handles both provisioning and deployment monitoring.
`cloud-weaver-repo-setup` already monitors via `gh run watch` (Step 7 of that skill).
There is no separate monitoring step in v2.

---

## Step 7 — Final report

Present in PT-BR:

- **URL de acesso:** `https://<public-ip>.nip.io` (highlighted)
- **Repositório GitHub:** link to `github.com/<user>/<repo-name>` with pipeline status
- **Credenciais geradas** (waha only): read from `~/.cloud-weaver-<repo-name>-report.json` and show once; remind user to change them and delete the report file
- **Próximos passos:**
  - Para atualizar o deploy: `git push` ao branch main ativa o pipeline automaticamente
  - Para reprovisionar manualmente: `gh workflow run deploy.yml`
  - Para ver logs: `gh run list --repo <repo-name>`
  - Acesso SSH: `ssh -i ~/.ssh/cw-<repo-name> ubuntu@<public-ip>`
- Delete the report file if it exists: `rm -f "$HOME/.cloud-weaver-${recipe_id}-report.json"`
- Delete the session file: `rm -f "$HOME/.cloud-weaver-${recipe_id}-session.json"`

Celebrate the milestone, then invite the user to start a new session.

---

## Rules

- Every message starts with `[CloudWeaver]`.
- All output to the user in PT-BR; code comments in English.
- One question at a time — never batch questions.
- Secrets never appear in the conversation, logs or commits.
- Validate every repo name against `[a-zA-Z0-9_][a-zA-Z0-9._-]*` before it reaches a command line.
- Never invoke a recipe skill that is not installed.
- "Locaweb Cloud" everywhere — never "CloudStack".
```

- [ ] **Step 2: Apply the edit**

Open `skills/start-cloud/SKILL.md`. Keep lines 1–169 (through end of Step 2 — recipe catalog). Replace everything from `## Step 3` to end of file with the new content above.

- [ ] **Step 3: Run a quick sanity check**

```bash
grep -n "CloudStack\|vm-setup\|deploy-hermes\|cloud-weaver-monitor" \
  skills/start-cloud/SKILL.md
```

Expected: no matches (all v1 references removed).

- [ ] **Step 4: Commit**

```bash
git add skills/start-cloud/SKILL.md
git commit -m "feat(start-cloud): rewrite Steps 3-7 for v2 GitHub Actions + Kamal flow

Replace vm-setup + deploy scripts + monitor with cloud-weaver-repo-setup.
Simpler question set (repo name, zone, plan, telegram ID for hermes-agent).
Final report includes GitHub repo link and SSH access instructions.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 8: Version bump to 1.0.0

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `skills/cloud-weaver-pre-flight-check/SKILL.md` (via stamp script)

**Interfaces:**
- Produces: version `1.0.0` in plugin.json and CLOUD_WEAVER_VERSION marker

- [ ] **Step 1: Bump version in plugin.json**

Edit `.claude-plugin/plugin.json`:

```json
{
  "name": "cloud-weaver",
  "description": "Um assistente que instala aplicações prontas (Hermes Agent, Coolify, Jitsi Meet) na Locaweb Cloud por conversa.",
  "version": "1.0.0"
}
```

- [ ] **Step 2: Run stamp script**

```bash
bash scripts/stamp-version.sh
```

Expected: `CLOUD_WEAVER_VERSION: 1.0.0` updated in `skills/cloud-weaver-pre-flight-check/SKILL.md`.

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json skills/cloud-weaver-pre-flight-check/SKILL.md
git commit -m "chore: bump to 1.0.0 (CloudWeaver v2 — GitHub Actions + Kamal)

Major version: deployment model changed from local scripts to GitHub Actions
+ Kamal + pre-built images at ghcr.io/fagnerlopes.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Self-review against spec

| Spec section | Covered by |
|---|---|
| §2 Agent flow (keygen → repo → files → secrets → workflow → watch) | Task 6 SKILL.md |
| §3 Pre-built images + build pipeline | Task 1 |
| §4 Files per recipe (Dockerfile, deploy.yml, config, .kamal) | Tasks 3–4 |
| §5 Secrets (LOCAWEB_API_KEY, LOCAWEB_API_SECRET, SSH_PRIVATE_KEY, recipe secrets) | Task 6 SKILL.md Step 5 |
| §6 New `cloud-weaver-repo-setup` skill | Tasks 2, 5, 6 |
| §6 `start-cloud` updated | Task 7 |
| §7 `recipes/` + `build-recipes.yml` in cloud-weaver repo | Task 1 |
| §8 Pre-flight (gh, gh auth) already covered | No change needed — preflight.sh already checks these |
| §10.1 LOCAWEB_* → CLOUDSTACK_* mapping in workflow | Task 3 Step 2, Task 4 Step 2 |
| §10.5 Teardown workflow | **Not in this plan** — deferred to v2.1 |

Teardown workflow is the only spec requirement not covered here. It is explicitly marked as out-of-scope in §11 of the spec and deferred to a follow-up.
