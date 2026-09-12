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
