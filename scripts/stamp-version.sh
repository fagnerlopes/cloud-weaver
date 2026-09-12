#!/usr/bin/env bash
# Stamps the version from plugin.json into the pre-flight-check skill marker.
# Run this after bumping the version in plugin.json.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$REPO_DIR/.claude-plugin/plugin.json"
VERSION=$(jq -r .version "$PLUGIN_JSON")
SKILL="$REPO_DIR/skills/cloud-weaver-pre-flight-check/SKILL.md"

# Portable in-place edit: BSD sed (macOS) and GNU sed (Linux CI) disagree on
# the -i flag's syntax, so write through a temp file instead.
tmp=$(mktemp)
sed "s/CLOUD_WEAVER_VERSION: .*/CLOUD_WEAVER_VERSION: $VERSION -->/" "$SKILL" > "$tmp" && mv "$tmp" "$SKILL"

echo "Stamped version $VERSION into $(basename "$SKILL")"

# The generated recipe Dockerfiles pin the pre-built image by version tag
# rather than :latest, so a participant always gets the image this release was
# tested against. build-recipes.yml publishes that tag from the same
# plugin.json version, so the two cannot drift.
for dockerfile in "$REPO_DIR"/skills/cloud-weaver-repo-setup/templates/*/Dockerfile; do
    [ -f "$dockerfile" ] || continue
    tmp=$(mktemp)
    sed -E "s|(FROM ghcr\.io/fagnerlopes/cw-[a-z-]+):.*|\1:$VERSION|" "$dockerfile" > "$tmp" \
        && mv "$tmp" "$dockerfile"
    echo "Stamped version $VERSION into templates/$(basename "$(dirname "$dockerfile")")/Dockerfile"
done