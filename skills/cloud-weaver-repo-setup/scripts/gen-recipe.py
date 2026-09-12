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
    "teardown.yml": ".github/workflows/teardown.yml",
}

# Shared files (same for all recipes) — read from templates/shared/
_SHARED_FILES = [
    "teardown.py",
]

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
            # Not every recipe uses every file.
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

    # Copy shared files (verbatim, no substitution).
    shared_dir = template_root / "shared"
    for filename in _SHARED_FILES:
        src = shared_dir / filename
        if src.is_file():
            dst = output_dir / filename
            dst.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")


def parse_args(argv: list | None = None) -> argparse.Namespace:
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


def main(argv: list | None = None) -> int:
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
