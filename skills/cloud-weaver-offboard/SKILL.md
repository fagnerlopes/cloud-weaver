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

> **Nota v2:** Para destruir os recursos na Locaweb Cloud (VM, rede, IP), use
> o workflow de teardown: `gh workflow run teardown.yml --repo <user>/<repo>`.
> Este guia cobre o offboard de credenciais na máquina do evento.

## Contexto

Três segredos ficaram na máquina do evento. Cada um tem um desligamento remoto
— mais confiável do que apagar arquivos de um equipamento que você já devolveu.

| Segredo | Onde ficou | Ação |
|---------|-----------|------|
| `LOCAWEB_API_KEY` / `LOCAWEB_API_SECRET` | Shell da máquina do evento | Regerar no painel → invalida imediatamente |
| Chave SSH privada | `~/.ssh/cw-<repo-name>` na máquina do evento | Regenerar + atualizar GitHub Secret `SSH_PRIVATE_KEY` → chave antiga não abre mais a VM |
| Chave de LLM (`ANTHROPIC_API_KEY` ou equivalente) | `.env` dentro da VM | Rotacionar no painel do provedor |

Execute os quatro passos em ordem. Não pule nenhum.

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

### 2a. Identificar as chaves per-repo

Em v2 cada repositório tem uma chave dedicada `~/.ssh/cw-<repo-name>`. Listar
as chaves presentes:

```bash
ls ~/.ssh/cw-* 2>/dev/null || echo "Nenhuma chave cloud-weaver encontrada"
```

Perguntar o `REPO_NAME` de cada deployment que o participante instalou (pode
ser mais de um). O Passo 2b abaixo trata cada repositório individualmente.

### 2b. Atualizar o GitHub Secret com a nova chave

Em v2 cada repositório guarda sua própria chave SSH como GitHub Secret
(`SSH_PRIVATE_KEY`). Perguntar ao participante o nome do repositório
(`REPO_NAME`, ex: `meu-hermes`) e rodar:

```bash
GITHUB_LOGIN="$(gh api user --jq .login)"
FULL_REPO="${GITHUB_LOGIN}/${REPO_NAME}"
SSH_KEY="$HOME/.ssh/cw-${REPO_NAME}"

# Generate a new per-repo key replacing the old one
rm -f "$SSH_KEY" "$SSH_KEY.pub"
ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "cloudweaver-${REPO_NAME}"
chmod 600 "$SSH_KEY"

# Update the secret in GitHub — the pipeline will use the new key on next run
gh secret set SSH_PRIVATE_KEY --repo "$FULL_REPO" < "$SSH_KEY"
echo "Secret SSH_PRIVATE_KEY atualizado em $FULL_REPO"
```

A VM não precisa ser reiniciada: a nova chave pública deve ser adicionada ao
`authorized_keys` da VM. Fazer isso via SSH ainda com a chave antiga (se
disponível), ou orientar o participante a fazer pelo console da Locaweb Cloud.

Verificar que o novo acesso funciona:

```bash
ssh -i "$HOME/.ssh/cw-${REPO_NAME}" root@"$public_ip" echo "SSH OK"
```

---

## Passo 3 — Limpeza local

Remover os arquivos do cloud-weaver desta máquina (a **nova** máquina, se for
uma adoção; a **mesma** se for apenas limpeza pós-workshop).

```bash
# Remove all per-repo SSH keys (v2 pattern: cw-<repo-name>)
rm -f ~/.ssh/cw-* 

# Remove session and report files
rm -f ~/.cloud-weaver-*-session.json
rm -f ~/.cloud-weaver-*-report.json

# Remove the cloud-weaver block from AGENTS.md (if present)
if [ -f AGENTS.md ]; then
  sed -i '/# cloud-weaver:begin/,/# cloud-weaver:end/d' AGENTS.md
fi
```

*(No cenário de adoção — rodar na máquina de casa — o Passo 2b já criou novos pares; não remover as chaves novas.)*

---

## Passo 4 — Instruir sobre a chave de LLM na VM

A chave de LLM (`ANTHROPIC_API_KEY` ou equivalente) fica em `~/.hermes/.env`
**dentro da VM** — não na máquina do evento. Rotacionar no painel do provedor
usando o terminal web (`https://<hostname>`) ou via SSH com a nova chave:

```bash
ssh -i ~/.ssh/cloud-weaver root@"$public_ip" \
  "sudo nano /data/${env_name}/hermes_data/.env"
```

---

## Mensagem final ao participante

> ✅ Offboard concluído. A máquina do evento não tem mais acesso à sua VM.
>
> Sua VM continua rodando — você tem créditos por mais um mês.
> Para acessá-la da sua máquina de casa, use:
>
>     ssh -i ~/.ssh/cw-<repo-name> root@<public_ip>
>
> Para deletar a VM e parar a cobrança: diga "quero fazer o teardown" em uma nova sessão.
