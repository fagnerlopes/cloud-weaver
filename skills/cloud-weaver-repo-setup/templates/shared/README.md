# CloudWeaver — @[REPO_NAME]

Infraestrutura provisionada na **Locaweb Cloud** e gerenciada pelo **CloudWeaver**
(plugin de IA distribuído como skills). Tudo roda por GitHub Actions a partir
deste repositório.

## O que há aqui

- `.github/workflows/deploy.yml` — provisiona a VM e instala a aplicação.
- `.github/workflows/teardown.yml` — destrói a VM na Locaweb Cloud.
- `teardown.py` — infraestrutura como código usada pelo teardown.
- `AGENTS.md` / `CLAUDE.md` — bootstrap que instrui o agente a carregar as
  skills do CloudWeaver ao abrir a sessão nesta pasta.
- `README.md` — este arquivo.

## Acesso à VM

O IP público da VM aparece no log do job `infra` (aba **Actions**) ou no
painel da Locaweb Cloud:

```bash
ssh root@<IP>
```

As credenciais da infraestrutura estão nos segredos deste repositório
(`LOCAWEB_API_KEY`, `LOCAWEB_API_SECRET`, `SSH_PRIVATE_KEY`) — nunca são
expostas na conversa nem em commits.

## Instalar o CloudWeaver numa máquina nova

Para gerenciar a infraestrutura de casa (ou de outra máquina), instale o
CloudWeaver **dentro desta pasta** e abra seu agente aqui.

**macOS / Linux / WSL / Git Bash:**

```bash
curl -fsSL https://cloudweaver.fagnerlopes.dev/install.sh | bash
```

**Windows (PowerShell):**

```powershell
irm https://cloudweaver.fagnerlopes.dev/install.ps1 | iex
```

O instalador verifica os pré-requisitos (Node, gh, Python, SSH), configura as
permissões do agente, instala as skills e grava o bootstrap em `AGENTS.md` e
`CLAUDE.md`.

## Gerenciar a infraestrutura

Com o CloudWeaver instalado, peça em português, por exemplo: "como está a VM?"
(monitoramento) ou "derruba tudo" (offboard). O menu de receitas é `/start-cloud`.

## Remover tudo

Dispare o workflow **Teardown** na aba **Actions** (`gh workflow run teardown.yml`).