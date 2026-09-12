#!/usr/bin/env bash
set -euo pipefail

# 0. Version check — auto-update if the remote is newer than the loaded skills.
#    Runs before everything else so the rest of the check uses updated code.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_VERSION=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$SKILL_DIR/SKILL.md" \
  | head -1 || echo "")

if [[ -n "$LOCAL_VERSION" ]]; then
  REMOTE_VERSION=$(curl -fsSL --max-time 8 \
    "https://api.github.com/repos/fagnerlopes/cloud-weaver/contents/.claude-plugin/plugin.json" \
    2>/dev/null \
    | python3 -c "
import sys, json, base64
try:
    data = json.load(sys.stdin)
    content = base64.b64decode(data.get('content','')).decode()
    print(json.loads(content).get('version',''))
except Exception:
    pass
" 2>/dev/null || echo "")

  if [[ -n "$REMOTE_VERSION" && "$REMOTE_VERSION" != "$LOCAL_VERSION" ]]; then
    # Compare as tuples to handle 0.9.x > 0.8.x correctly.
    IS_NEWER=$(python3 -c "
import sys
l = tuple(int(x) for x in '${LOCAL_VERSION}'.split('.'))
r = tuple(int(x) for x in '${REMOTE_VERSION}'.split('.'))
print('yes' if r > l else 'no')
" 2>/dev/null || echo "no")

    if [[ "$IS_NEWER" == "yes" ]]; then
      echo "SKILLS_UPDATING: versão local=$LOCAL_VERSION → remota=$REMOTE_VERSION"
      if command -v mise &>/dev/null; then NPX="mise x node@22 -- npx"
      else NPX="npx"; fi

      # Run update; capture exit code without triggering set -e.
      _update_exit=0
      $NPX -y skills update || _update_exit=$?

      if [[ $_update_exit -eq 0 ]]; then
        echo "SKILLS_UPDATED: skills atualizadas para $REMOTE_VERSION — inicie uma nova sessão para usar a versão atualizada."
      else
        echo "SKILLS_UPDATE_FAILED: não foi possível atualizar automaticamente. Execute: npx -y skills update"
      fi
    fi
  fi
fi

errors=()

# 1. Sensitive file guard — only when inside a git repo, before any sync.
#    Blocks when untracked, staged, or tracked-modified files match credential
#    patterns. Template files (.example, .sample, ...) and deletions are
#    ignored (removing a secret is the desired cleanup). Mirrors the Cofounder
#    preflight guard.
if [[ -d ".git" ]]; then
  has_git=true
  if [[ -n "$(git remote 2>/dev/null)" ]]; then
    has_remote=true
  else
    has_remote=false
  fi

  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    sensitive=$(
      {
        git ls-files --others --exclude-standard 2>/dev/null       # untracked
        git diff --cached --name-only --diff-filter=d 2>/dev/null  # staged, minus deletions
        git diff --name-only --diff-filter=d 2>/dev/null           # tracked+modified, minus deletions
      } | sort -u \
        | grep -Ei \
            '\.env(\.[^/]+)?$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|(^|/)\.(npmrc|netrc|pypirc)$|\.(pem|key|secret|p12|pfx|jks|keystore)$|(credentials|sa.?key|service.?account)[^/]*\.json$|(^|/)secrets?\.(ya?ml|json)$' \
        | grep -Eiv '\.(example|sample|template|dist|tpl|tmpl)$' \
      || true
    )
    if [[ -n "$sensitive" ]]; then
      echo "PREFLIGHT_FAILED"
      echo "  - SENSITIVE_FILES_DETECTED: Files that may contain secrets are untracked, staged, or modified."
      echo "    - Untracked: add it to .gitignore"
      echo "    - Staged:    run 'git restore --staged <file>'"
      echo "    - Tracked:   run 'git rm --cached <file>' and add it to .gitignore"
      printf '%s\n' "$sensitive" | sed 's/^/    /'
      exit 1
    fi
  fi
else
  has_git=false
  has_remote=false
fi

# Report errors collected so far.
if [[ ${#errors[@]} -gt 0 ]]; then
  echo "PREFLIGHT_FAILED"
  for err in "${errors[@]}"; do
    echo "  - $err"
  done
  exit 1
fi

# 2. Git sync — commit/push local changes and pull remote commits. Only runs
#    when a git repo with at least one remote exists.
if $has_git && $has_remote; then
  current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ -z "$current_branch" ]]; then
    echo "PREFLIGHT_FAILED"
    echo "  - GIT_SYNC_ERROR: HEAD is detached — cannot sync."
    exit 1
  fi

  upstream=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || true)

  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "SYNC: Committing local changes..."
    git add -A
    git commit -m "Auto-sync: commit outstanding changes before session" --no-gpg-sign || {
      echo "PREFLIGHT_FAILED"
      echo "  - GIT_SYNC_ERROR: Failed to commit local changes."
      exit 1
    }
  fi

  if [[ -n "$upstream" ]]; then
    echo "SYNC: Pulling remote changes (upstream: $upstream)..."
    git pull --rebase || {
      echo "PREFLIGHT_FAILED"
      echo "  - GIT_SYNC_ERROR: Pull failed — possible merge conflict. Resolve manually and re-run."
      exit 1
    }
    echo "SYNC: Pushing local commits..."
    git push || {
      echo "PREFLIGHT_FAILED"
      echo "  - GIT_SYNC_ERROR: Push failed — check remote access and try again."
      exit 1
    }
  else
    echo "SYNC: No upstream configured, trying origin/$current_branch..."
    if git rev-parse --verify "origin/$current_branch" >/dev/null 2>&1; then
      git pull --rebase origin "$current_branch" || {
        echo "PREFLIGHT_FAILED"
        echo "  - GIT_SYNC_ERROR: Pull failed — possible merge conflict. Resolve manually and re-run."
        exit 1
      }
    fi
    git push --set-upstream origin "$current_branch" || {
      echo "PREFLIGHT_FAILED"
      echo "  - GIT_SYNC_ERROR: Push failed — check remote access and try again."
      exit 1
    }
  fi

  echo "SYNC: Repository is up to date."
fi

# 3. Tools — report any missing so the caller can load computer-setup.
missing_tools=()
command -v gh  >/dev/null 2>&1 || missing_tools+=("gh")
command -v ssh >/dev/null 2>&1 || missing_tools+=("ssh")
command -v jq  >/dev/null 2>&1 || missing_tools+=("jq")
if [[ ${#missing_tools[@]} -gt 0 ]]; then
  echo "NEEDS_COMPUTER_SETUP: missing ${missing_tools[*]}"
fi

# 4. GitHub auth — needed to create secrets / repos that back the recipes.
if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
  echo "NEEDS_GITHUB_AUTH: GitHub CLI is installed but not authenticated."
fi

# 5. Locaweb Cloud API keys — presence check only; values live in env/secret
#    stores and are never printed.
if [[ -z "${LOCAWEB_API_KEY:-}" || -z "${LOCAWEB_API_SECRET:-}" ]]; then
  echo "NEEDS_LOCAWEB_CREDENTIALS: LOCAWEB_API_KEY and LOCAWEB_API_SECRET are not both set in the environment."
fi

# 6. Telegram Bot Token — presence check only; value is never printed.
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "NEEDS_TELEGRAM_BOT_TOKEN: TELEGRAM_BOT_TOKEN is not set in the environment."
fi

echo "PREFLIGHT_PASSED"
exit 0