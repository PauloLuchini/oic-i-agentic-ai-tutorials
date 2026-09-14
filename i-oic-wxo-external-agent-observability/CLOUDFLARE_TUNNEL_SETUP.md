# Cloudflare Quick Tunnel — Como usar

Expõe o agente local ao watsonx Orchestrate sem conta Cloudflare, sem domínio e sem configuração prévia. O `cloudflared` gera uma URL pública `https://<random>.trycloudflare.com` automaticamente.

> **⚠️ A URL muda a cada restart.** Após reiniciar `start-local.sh`, registre o agente novamente no wxO com a nova URL.

---

## Pré-requisitos

Apenas o `cloudflared` instalado — sem login, sem conta:

```bash
# macOS
brew install cloudflared

# Linux (Debian/Ubuntu)
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb

# Verificar instalação
cloudflared --version
```

---

## Uso

```bash
# 1. Garantir que o Ollama está rodando
ollama run llama3.1

# 2. Preencher o .env (apenas as variáveis obrigatórias)
cp .env.example .env
# edite: AGENT_API_KEY (gere com: openssl rand -hex 32)

# 3. Subir tudo
chmod +x start-local.sh
./start-local.sh
```

O script imprime a URL gerada assim que o tunnel estiver ativo:

```
════════════════════════════════════════════════════════════
  ✅ Agente A2A disponível publicamente!

  URL pública   : https://xxxx-yyyy-zzzz.trycloudflare.com
  AgentCard     : https://xxxx-yyyy-zzzz.trycloudflare.com/.well-known/agent.json
  Health check  : https://xxxx-yyyy-zzzz.trycloudflare.com/health
  A2A endpoint  : https://xxxx-yyyy-zzzz.trycloudflare.com/

  ⚠️  Esta URL muda a cada restart do script.

  Para registrar no wxO (execute em outro terminal):

    orchestrate agents discover -u https://xxxx-yyyy-zzzz.trycloudflare.com
...
════════════════════════════════════════════════════════════
```

---

## Registrar no wxO (primeira vez e a cada restart)

Em outro terminal, com o agente rodando:

```bash
# Opção A — auto-discovery (mais rápido)
orchestrate agents discover -u https://xxxx-yyyy-zzzz.trycloudflare.com

# Opção B — YAML declarativo
# Edite agent.yaml → api_url com a nova URL
# Edite agent.yaml → auth_config.token com seu AGENT_API_KEY
orchestrate agents import -f agent.yaml
```

Copie o **Agent ID** retornado e defina no `.env`:
```bash
WXO_AGENT_ID=<agent-id-retornado>
```

Reinicie o script para ativar a telemetria com o ID correto:
```bash
# Ctrl+C para parar, depois:
./start-local.sh
```

---

## Fluxo a cada sessão de trabalho

```
1. ollama run llama3.1          (Terminal 1)
2. ./start-local.sh             (Terminal 2)
3. Copiar nova URL do terminal
4. orchestrate agents discover -u <nova-url>
5. Atualizar WXO_AGENT_ID no .env
6. Ctrl+C + ./start-local.sh    (reiniciar para telemetria)
```

---

## Troubleshooting

| Sintoma | Causa | Solução |
|---|---|---|
| `cloudflared: command not found` | Não instalado | `brew install cloudflared` |
| URL não aparece em 30s | Problema de rede | Verifique conexão com internet |
| `401 Unauthorized` no wxO | `AGENT_API_KEY` divergente | `agent.yaml auth_config.token` deve ser igual ao `.env AGENT_API_KEY` |
| wxO não alcança o agente | URL expirada (tunnel reiniciado) | Registre novamente com a nova URL |
| Telemetria não aparece no wxO | `WXO_AGENT_ID` desatualizado | Atualize no `.env` e reinicie o script |
