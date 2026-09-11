#!/usr/bin/env bash
set -euo pipefail

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

echo "PREFLIGHT_PASSED"
exit 0