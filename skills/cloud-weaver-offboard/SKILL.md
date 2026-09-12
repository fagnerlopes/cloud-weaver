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

### 2a. Gerar o novo par

```bash
rm -f ~/.ssh/cloud-weaver ~/.ssh/cloud-weaver.pub
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
