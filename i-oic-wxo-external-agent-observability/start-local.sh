#!/usr/bin/env bash
# =============================================================================
# start-local.sh — Inicia o agente A2A localmente e expõe via Cloudflare Quick Tunnel
#
# Sem conta Cloudflare, sem domínio, sem configuração prévia.
# O cloudflared gera uma URL pública HTTPS automaticamente a cada execução.
#
# ⚠️  A URL muda a cada restart. Após reiniciar você precisa:
#     1. Copiar a nova URL impressa no terminal
#     2. Registrar novamente no wxO:
#        orchestrate agents discover -u <nova-url>
#
# Pré-requisitos:
#   1. cloudflared instalado
#      macOS:  brew install cloudflared
#      Linux:  https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
#   2. Ollama rodando:       ollama run llama3.1
#   3. Dependências Python:  pip install -r requirements.txt
#   4. .env preenchido:      cp .env.example .env  (edite as variáveis)
#
# Uso:
#   chmod +x start-local.sh
#   ./start-local.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Carregar .env se existir ───────────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# ── Configurações com defaults ─────────────────────────────────────────────────
SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
SERVER_PORT="${SERVER_PORT:-8080}"

# ── Verificações de pré-requisitos ─────────────────────────────────────────────
echo "🔍 Verificando pré-requisitos..."

if ! command -v cloudflared &>/dev/null; then
    echo "❌ cloudflared não encontrado."
    echo "   macOS:  brew install cloudflared"
    echo "   Linux:  https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    exit 1
fi

if ! command -v uvicorn &>/dev/null; then
    echo "❌ uvicorn não encontrado. Execute: pip install -r requirements.txt"
    exit 1
fi

if ! curl -sf "http://localhost:11434/api/tags" &>/dev/null; then
    OLLAMA_MODEL_NAME="${OLLAMA_MODEL:-llama3.1}"
    echo "❌ Ollama não está respondendo em localhost:11434."
    echo "   Execute em outro terminal: ollama run ${OLLAMA_MODEL_NAME}"
    exit 1
fi

: "${AGENT_API_KEY:?AGENT_API_KEY deve estar definido no .env — gere com: openssl rand -hex 32}"

echo "✅ Pré-requisitos OK"
echo ""

# ── Cleanup ao sair (Ctrl+C ou erro) ──────────────────────────────────────────
UVICORN_PID=""
CLOUDFLARED_PID=""
TUNNEL_LOG=""

cleanup() {
    echo ""
    echo "🛑 Encerrando servidor e tunnel..."
    [[ -n "${CLOUDFLARED_PID}" ]] && kill "${CLOUDFLARED_PID}" 2>/dev/null || true
    [[ -n "${UVICORN_PID}" ]]    && kill "${UVICORN_PID}"    2>/dev/null || true
    [[ -n "${TUNNEL_LOG}" ]]     && rm -f "${TUNNEL_LOG}"    2>/dev/null || true
    echo "👋 Encerrado."
    exit 0
}
trap cleanup INT TERM

# ── 1. Iniciar o servidor FastAPI A2A ─────────────────────────────────────────
echo "🚀 Iniciando servidor A2A em http://${SERVER_HOST}:${SERVER_PORT} ..."
cd "${SCRIPT_DIR}"
uvicorn server:app \
    --host "${SERVER_HOST}" \
    --port "${SERVER_PORT}" \
    --log-level info &
UVICORN_PID=$!

# Aguardar o /health responder antes de abrir o tunnel
echo "⏳ Aguardando servidor ficar pronto..."
for i in $(seq 1 20); do
    if curl -sf "http://${SERVER_HOST}:${SERVER_PORT}/health" &>/dev/null; then
        echo "✅ Servidor pronto!"
        break
    fi
    if [[ $i -eq 20 ]]; then
        echo "❌ Servidor não respondeu após 20 tentativas. Verifique os logs acima."
        kill "${UVICORN_PID}" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

echo ""

# ── 2. Iniciar o Cloudflare Quick Tunnel e capturar a URL ─────────────────────
echo "🌐 Iniciando Cloudflare Quick Tunnel..."
echo "   (Aguardando URL pública ser gerada...)"

TUNNEL_LOG="$(mktemp /tmp/cloudflared-XXXXXX.log)"

# O quick tunnel imprime a URL pública em stderr no formato:
#   INF | Your quick Tunnel has been created! Visit it at (it may take some time to be reachable): https://xxxx.trycloudflare.com
# --protocol http2 força TCP em vez de QUIC (UDP/7844), necessário quando
# a rede bloqueia UDP outbound (comum em redes corporativas).
cloudflared tunnel --url "http://${SERVER_HOST}:${SERVER_PORT}" \
    --no-autoupdate \
    --protocol http2 \
    2>"${TUNNEL_LOG}" &
CLOUDFLARED_PID=$!

# Extrair a URL do log assim que aparecer (timeout 30s).
# Usa grep -oE (POSIX Extended) em vez de -oP porque o macOS não tem grep -P.
TUNNEL_URL=""
for i in $(seq 1 30); do
    TUNNEL_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "${TUNNEL_LOG}" 2>/dev/null | head -1 || true)
    if [[ -n "${TUNNEL_URL}" ]]; then
        break
    fi
    sleep 1
done

if [[ -z "${TUNNEL_URL}" ]]; then
    echo "❌ Não foi possível obter a URL do tunnel em 30 segundos."
    echo "   Log do cloudflared:"
    cat "${TUNNEL_LOG}" 2>/dev/null || true
    cleanup
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✅ Agente A2A disponível publicamente!"
echo ""
echo "  URL pública   : ${TUNNEL_URL}"
echo "  AgentCard     : ${TUNNEL_URL}/.well-known/agent.json"
echo "  Health check  : ${TUNNEL_URL}/health"
echo "  A2A endpoint  : ${TUNNEL_URL}/"
echo ""
echo "  ⚠️  Esta URL muda a cada restart do script."
echo ""
echo "  Para registrar no wxO (execute em outro terminal):"
echo ""
echo "    orchestrate agents discover -u ${TUNNEL_URL}"
echo ""
echo "  Ou edite agent.yaml → api_url: \"${TUNNEL_URL}\""
echo "  e execute: orchestrate agents import -f agent.yaml"
echo ""
echo "  Após registrar, copie o Agent ID e defina no .env:"
echo "    WXO_AGENT_ID=<agent-id>"
echo "  Depois reinicie este script para ativar a telemetria."
echo "════════════════════════════════════════════════════════════"
echo ""
echo "📋 Logs em tempo real abaixo. Pressione Ctrl+C para encerrar tudo."
echo ""

# Redirecionar log do cloudflared para stdout junto com o uvicorn
tail -f "${TUNNEL_LOG}" &

# ── Aguardar ambos os processos ───────────────────────────────────────────────
wait "${UVICORN_PID}" "${CLOUDFLARED_PID}"
