---
name: cloud-weaver-teardown
description: >
  Use this skill when the user asks to "deletar minha VM", "fazer teardown",
  "destruir os recursos" ou "parar de ser cobrado". Destroys the VM and all
  Locaweb Cloud resources for a deployed recipe, then optionally deletes the
  GitHub repository and cleans up local files.
---

# Teardown

This skill removes all resources created by a CloudWeaver recipe deployment:

- VM on Locaweb Cloud (and attached data disk)
- Network and public IP
- SSH keypair (on Locaweb Cloud)

It **does not** automatically delete the GitHub repository — that step is
offered separately at the end, since it requires the `delete_repo` scope.

---

## Step 1 — Identify the repository

Ask the user which repository to tear down (e.g. `meu-hermes`).

Confirm that the teardown.yml workflow exists in the repo:

```bash
GITHUB_LOGIN="$(gh api user --jq .login)"
FULL_REPO="${GITHUB_LOGIN}/${REPO_NAME}"
gh workflow list --repo "$FULL_REPO" | grep teardown || echo "TEARDOWN_WORKFLOW_MISSING"
```

If `TEARDOWN_WORKFLOW_MISSING`: the repo was created before teardown support was
added. Guide the user to add the workflow file manually:

```bash
# In the repo directory:
curl -fsSL https://cloudweaver.fagnerlopes.dev/teardown.py -o teardown.py
# Then add .github/workflows/teardown.yml manually (see template)
git add teardown.py .github/workflows/teardown.yml
git commit -m "chore: add teardown workflow"
git push
```

---

## Step 2 — Get explicit confirmation

Show what will be destroyed:

> ⚠️ **Isso vai remover permanentemente:**
> - VM na Locaweb Cloud (e o disco de dados com todos os arquivos)
> - Rede e IP público do ambiente `preview`
> - Keypair SSH `cr-preview-key`
>
> Repositório GitHub `<user>/<repo-name>` será mantido (até a confirmação final).
>
> **Os dados não podem ser recuperados.**
>
> Digite **sim** para confirmar.

Wait for explicit "sim". Any other response aborts.

---

## Step 3 — Trigger teardown workflow

```bash
gh workflow run teardown.yml --repo "$FULL_REPO"
sleep 5
RUN_ID=$(gh run list --repo "$FULL_REPO" --workflow teardown.yml \
  --limit 1 --json databaseId --jq '.[0].databaseId')
echo "Teardown iniciado — Run ID: $RUN_ID"
```

---

## Step 4 — Monitor

```bash
gh run watch "$RUN_ID" --repo "$FULL_REPO" --exit-status
```

Display progress:
- ⏳ Removendo VM e disco de dados...
- ✅ VM removida
- ⏳ Removendo rede e IP público...
- ✅ Rede removida
- ⏳ Removendo keypair SSH...
- ✅ Teardown concluído

On failure: show full log with `gh run view "$RUN_ID" --repo "$FULL_REPO" --log-failed`.

---

## Step 5 — Local cleanup

```bash
# Remove local SSH key for this repo
rm -f "$HOME/.ssh/cw-${REPO_NAME}" "$HOME/.ssh/cw-${REPO_NAME}.pub"

# Remove session and report files
rm -f "$HOME/.cloud-weaver-"*"-${REPO_NAME}-"*.json
rm -f "$HOME/.cloud-weaver-"*"-session.json"
```

Confirm to the user: "✅ Chaves e arquivos locais removidos."

---

## Step 6 — Offer to delete the GitHub repository

> O repositório `<user>/<repo-name>` ainda existe no GitHub.
> Quer deletá-lo também? (sim / não)

**If yes:**

First check if `delete_repo` scope is present:

```bash
gh auth status 2>&1 | grep -q "delete_repo" && echo "HAS_SCOPE" || echo "NEEDS_SCOPE"
```

If `NEEDS_SCOPE`, ask the user to run in their OS terminal:

```bash
gh auth refresh -h github.com -s delete_repo
```

Then start a new session (the scope refresh requires re-auth).

After scope is confirmed:

```bash
gh repo delete "$FULL_REPO" --yes
```

Confirm: "✅ Repositório deletado."

**If no:** close with:
> Repositório mantido. Você pode deletá-lo manualmente em https://github.com/<user>/<repo-name>/settings

---

## Step 7 — Final message

> 🧹 Teardown concluído! Todos os recursos na Locaweb Cloud foram removidos
> e a cobrança parou.
>
> Se quiser instalar novamente, abra uma nova sessão e use `/start-cloud`.
