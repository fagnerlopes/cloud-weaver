# Receita Hermes Agent — design

**Data:** 2026-09-11
**Status:** aprovado para plano de implementação
**Motivação:** workshop Hermes Agent + Locaweb Cloud no TDC São Paulo

---

## 1. Objetivo

Permitir que um participante do workshop suba, por conversa com o CloudWeaver,
uma VM na Locaweb Cloud rodando o **Hermes Agent** (Nous Research), controlado
pelo **Telegram**, pronto para receber pedidos de fork, deploy e monitoramento
de uma aplicação.

A receita existente `cloud-weaver-hermes` **não** atende: ela instala WAHA
(WhatsApp HTTP API), uma aplicação diferente.

## 2. Contexto do workshop

Cada participante recebe um cupom de créditos da Locaweb Cloud dimensionado
para:

| Recurso | Quantidade | Uso |
|---------|-----------|-----|
| VM large | 1 | Hermes Agent |
| VM small | 2 | Aplicação criada com o cofounder |
| Rede | 1 | — |
| IP público | 1 | — |

Roteiro da aula:

1. Participante instala o Hermes com o CloudWeaver na VM large.
2. Configura Telegram, provedor de LLM e GitHub.
3. Pelo Telegram, pede ao Hermes que faça fork do projeto pronto, publique na
   conta Locaweb Cloud dele, solicite modificações e deploys.
4. Cria crons de monitoramento.
5. Desliga a API da aplicação para ver o monitoramento disparar e o alerta
   chegar no Telegram.

A cadeia é: **participante → Telegram → Hermes (VM large) → skills do cofounder
→ 2 VMs small na conta do participante.** O `skills` CLI já suporta o alvo
`hermes-agent` (`.hermes/skills`), que é como o cofounder chega ao Hermes.

### Restrição que domina o desenho

Os participantes usam **máquinas emprestadas pela organizadora do evento**. Tudo
que ficar naquela máquina — credencial da Locaweb, chave SSH privada — sai do
controle do participante quando ele devolve o equipamento. Ver seção 7.

## 3. Decisões tomadas

| Decisão | Escolha | Por quê |
|---------|---------|---------|
| Distribuição | Imagem Docker oficial `nousresearch/hermes-agent:latest` | Existe e já foi validada em produção pelo autor da receita do VPS |
| Conexão com Telegram | **Long polling** (padrão) | Não exige porta aberta; webhook só compensa em plataformas que suspendem máquina ociosa |
| Terminal web | Mantido, via Traefik + Let's Encrypt | Excelente em máquina emprestada; já validado em campo |
| Senha do terminal | `secrets.token_urlsafe(32)` | Substitui a senha derivada do hostname (ver 4.1) |
| Fim do workshop | VM sobrevive; chaves rotacionadas | O participante tem um mês de crédito para usar |
| Isolamento de execução | O container do agente **é** a fronteira | Validado em campo; `terminal.backend: docker` aninhado não foi testado |

## 4. Segurança

### 4.1 Defeito corrigido em relação à receita do VPS

A receita usada no VPS deriva a senha do terminal web do hostname:

```
ADMIN_PASS = reverse(base64(hostname)[0:11]) + reverse(base64("cloud")[0:7])
```

O segundo termo é a constante `QWdvx2Y` em toda VM. O primeiro é o hostname
transformado. Não há entropia.

O hostname **não é secreto**: o Traefik emite certificado Let's Encrypt para
`<hostname>.publiccloud.com.br`, e toda emissão é publicada obrigatoriamente em
logs de Certificate Transparency. Qualquer pessoa lista os hostnames emitidos
para um domínio em tempo real — cada VM se anuncia ao subir.

Atrás dessa senha está o container `web-terminal`, que monta
`/var/run/docker.sock` com escrita: quem entra controla o daemon Docker, ou
seja, **root na VM** — onde ficam o token do GitHub, a credencial da Locaweb
Cloud e a chave de LLM do participante.

A senha fraca existia por acoplamento a um template de e-mail que não podia ser
alterado. **Esse acoplamento não existe no CloudWeaver**: quem entrega a senha é
o relatório final da sessão do agente. A receita gera
`secrets.token_urlsafe(32)`.

### 4.2 Camadas

| Camada | Controle |
|--------|----------|
| Rede | Firewall: 22, 80, 443. O container do agente **não publica porta** |
| Telegram | `TELEGRAM_ALLOWED_USERS` com o ID do participante. Default da plataforma é *deny all* quando nenhuma allowlist existe |
| Terminal web | Basic auth sobre TLS, senha aleatória de 32 bytes |
| Comandos | `approvals.mode: smart` + blocklist permanente do Hermes |
| Segredos | Gerados na VM, nunca exibidos na conversa nem commitados |

### 4.3 Risco residual aceito

Mesmo com senha forte, o `web-terminal` com `docker.sock` é root-equivalente
atrás de basic auth. Ver questão aberta Q1.

## 5. Arquitetura

Três containers, adaptados da receita validada no VPS:

```
traefik          80/443 → TLS Let's Encrypt em <host>.publiccloud.com.br
  └── web-terminal (ttyd)   :7681   basic auth
hermes-agent     nenhuma porta publicada; long polling para api.telegram.org
```

### Diferenças em relação à receita do VPS

1. **Rota `/telegram` removida.** Era config morta: o modo webhook só ativa com
   `TELEGRAM_WEBHOOK_URL` definida (ausente no compose), e a porta padrão do
   webhook é 8443, não a 5000 para onde o Traefik apontava. O bot sempre rodou
   em long polling.
2. **Senha aleatória** em vez de derivada (4.1).
3. **`phone_home` removido** — é do produto VPS, não do CloudStack.
4. **Firewall via API do CloudStack**, não `ufw` — é o que o
   `cloud-weaver-vm-setup` já faz.

## 6. Componentes

### 6.1 `skills/cloud-weaver-hermes-agent/` (nova)

Segue o padrão de `cloud-weaver-hermes`: coleta configuração uma pergunta por
vez, embarca o compose por SSH, sobe a stack, reporta.

Coleta do usuário:
- ID de usuário do Telegram (para `TELEGRAM_ALLOWED_USERS`)
- Token do bot do Telegram — **não digitado na conversa**; gravado em `.env`
  na VM a partir de um template com `REPLACE_WITH_`, ou colado pelo terminal web

Gerado pela receita, nunca exibido no chat:
- senha do basic auth (`token_urlsafe(32)`) — mostrada só no relatório final

Configurado na VM (`~/.hermes/config.yaml`):
- `approvals.mode: smart`
- `approvals.cron_mode` — definido de propósito para que o monitoramento
  não supervisionado da aula funcione

Provedor de LLM e GitHub: configurados pelo participante **no terminal web**,
via `hermes setup`. Vantagem no contexto do workshop — a chave dele não passa
pelo terminal da máquina emprestada.

### 6.2 `skills/cloud-weaver-offboard/` (nova)

Último passo da aula. Três desligamentos, em ordem:

1. **Credencial Locaweb** — instrui o participante a regerar no painel. Mata
   imediatamente o que ficou na máquina do evento. É o segredo mais valioso e o
   único sem rotação por API.
2. **Chave SSH** — gera keypair novo local, `registerSSHKeyPair`,
   `stopVirtualMachine` → `resetSSHKeyForVirtualMachine` → `startVirtualMachine`.
   A API **exige a VM parada** e aceita o nome de um keypair já registrado.
3. **Limpeza local** — remove `~/.ssh/cloud-weaver*`, `.env` e o bloco
   `cloud-weaver:begin/end` do `AGENTS.md`.

O mesmo fluxo serve para **adotar a VM em outra máquina**: mesma rotação,
rodando na máquina de casa do participante.

### 6.3 `vm-provision.py` (alterações)

- `ensure_firewall` hoje fixa `cidrlist="0.0.0.0/0"` para toda porta, inclusive
  a 22. Ganha parâmetro de origem.
- Novo subcomando de rotação de chave (ciclo stop → reset → start).

### 6.4 Renomeação

`cloud-weaver-hermes` instala WAHA, não Hermes Agent. Renomear para
`cloud-weaver-waha` e liberar o nome. Atualizar catálogo no
`cloud-weaver-playbook` e no `start-cloud`.

### 6.5 Catálogo

`start-cloud` passa a listar `hermes-agent` como disponível. `coolify` e
`jitsi` continuam 🔜.

## 7. O problema da máquina emprestada

Três segredos ficam na máquina do evento; cada um tem um desligamento remoto,
o que é mais confiável do que confiar na limpeza de um equipamento que o
participante não controla:

| Segredo | Onde | Desligamento |
|---------|------|--------------|
| `LOCAWEB_API_KEY` / `SECRET` | máquina do evento | Regerar no painel |
| Chave SSH privada | máquina do evento | `resetSSHKeyForVirtualMachine` |
| Chave de LLM | `~/.hermes/.env` na VM | Rotacionar no provedor |

Mitigação durante a aula: exportar as credenciais só na sessão do shell, nunca
em `.bashrc`; configurar a chave de LLM pelo terminal web, não pelo terminal
da máquina emprestada.

## 8. Questões abertas — validar na implementação

**Q1 — ttyd sem `docker.sock`.** O `web-terminal` usa o socket para
`docker exec` no agente. Alternativa: rodar o ttyd como segundo container da
mesma imagem, compartilhando o volume `hermes_data` e chamando `hermes`
direto. Reduz o pior caso de "root no host" para "shell no agente". Riscos a
testar: dois processos sobre o mesmo diretório de dados; o
`docker restart hermes-agent` pós-setup precisaria de outro caminho.

**Q2 — `approvals.cron_mode`.** O exemplo da doc traz `deny`. Os crons do
participante rodam sem ninguém para aprovar, e o alerta é o clímax da aula.
Confirmar o escopo exato do `deny` (todo comando ou só os classificados como
perigosos) e escolher o valor com uma `deny` list de comandos.

**Q3 — Dimensionamento.** A imagem carrega Python 3.11 e Node 26. Confirmar que
o plano "large" do cupom aguenta, e medir o tempo de primeiro boot — se for
lento demais, não cabe ao vivo.

**Q4 — Hostname e TLS.** Confirmar que a VM do CloudStack recebe
`<hostname>.publiccloud.com.br` resolvível, como no VPS. Se não, o
`tlschallenge` do Let's Encrypt falha e o terminal web não sobe com TLS.

## 9. Testes

- `tests/scripts/test-hermes-agent.sh` no padrão dos existentes, com fixtures
  para o transporte mock do provisionador.
- Teste da rotação de chave contra o `MockTransport`.
- **Teste de fumaça numa VM real antes do workshop** — é o único que cobre Q1
  a Q4, e é pré-requisito para a aula.

## 10. Fora de escopo

- Receitas Coolify e Jitsi.
- Aplicação do cofounder (levada pronta pelo instrutor).
- Expor o API server OpenAI-compatível (8642). O acesso é por Telegram; se
  alguém quiser um frontend tipo Open WebUI, roda na máquina dele apontando
  para um túnel SSH — sem exposição adicional na VM.
