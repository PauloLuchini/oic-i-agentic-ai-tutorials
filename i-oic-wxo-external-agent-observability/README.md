# Annualized Rate of Return — External Agent for watsonx Orchestrate

A **LangGraph ReAct agent** running fully **locally** (Llama 3.1 via Ollama), exposed publicly over the **Agent-to-Agent (A2A) protocol v0.3.0** through a **Cloudflare Quick Tunnel**, registered in **watsonx Orchestrate (wxO)** as an external collaborator, and instrumented with standard **OpenTelemetry** so every conversation, LLM call, and tool call appears in the wxO Analytics dashboard alongside natively built agents.

`agent.py` and `tools.py` contain ordinary LangGraph code with zero wxO or OpenTelemetry imports. All A2A plumbing lives in `server.py`, all telemetry in `wxo_otel.py`, and the tunnel is managed by `start-local.sh`. See [`article-wxo-agentic-control-plane-v2.md`](article-wxo-agentic-control-plane-v2.md) for the full architectural write-up.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Your laptop                                                             │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  Ollama  (localhost:11434)                                          │ │
│  │  Model: Llama 3.1                                                   │ │
│  └──────────────────────────┬──────────────────────────────────────────┘ │
│                             │ LLM calls                                  │
│  ┌──────────────────────────▼──────────────────────────────────────────┐ │
│  │  FastAPI A2A Server  (server.py · localhost:8080)                   │ │
│  │    GET  /.well-known/agent.json   AgentCard discovery               │ │
│  │    GET  /health                   liveness probe                    │ │
│  │    POST /  JSON-RPC 2.0           message/send · message/stream     │ │
│  │                                   tasks/get · tasks/cancel          │ │
│  │  ┌───────────────────────────────────────────────────────────────┐  │ │
│  │  │  LangGraph ReAct agent  (agent.py)                            │  │ │
│  │  │  Tool: calculate_annualized_return  (tools.py)                │  │ │
│  │  └───────────────────────────────────────────────────────────────┘  │ │
│  │  ┌───────────────────────────────────────────────────────────────┐  │ │
│  │  │  OTel telemetry  (wxo_otel.py)                                │  │ │
│  │  │  ASGI middleware → IAM token exchange → OTLP/HTTP exporter    │  │ │
│  │  └───────────────────────────────────────────────────────────────┘  │ │
│  └──────────────────────────────────────────────────────────────────── ┘ │
│                             │                                            │
│  ┌──────────────────────────▼──────────────────────────────────────────┐ │
│  │  Cloudflare Quick Tunnel  (cloudflared)                             │ │
│  │  https://<random>.trycloudflare.com  →  localhost:8080              │ │
│  └──────────────────────────────────────────────────────────────────── ┘ │
└──────────────────────────────────┬───────────────────────────────────────┘
                                   │  HTTPS (public)
              ┌────────────────────▼────────────────────┐
              │                                         │
              │   A2A v0.3.0 / JSON-RPC 2.0             │  OTLP/HTTP traces
              │   (wxO calls the agent)                 │  (agent pushes to wxO)
              │                                         │
              ▼                                         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  watsonx Orchestrate — Agentic Control Plane                            │
│  Registered external agent · Collaborator for native agents             │
│  Analyze → Overview · Agent dashboard · Conversations · Trace view      │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Repository layout

| File | Role |
|---|---|
| `agent.py` | LangGraph ReAct agent (Llama 3.1 via Ollama) — zero telemetry imports |
| `tools.py` | `calculate_annualized_return` tool — zero telemetry imports |
| `a2a_types.py` | A2A v0.3.0 Pydantic models (AgentCard, Task, Message, JSON-RPC envelopes) |
| `server.py` | FastAPI A2A server: JSON-RPC dispatch, AgentCard endpoint, health probe, bearer-token auth |
| `wxo_otel.py` | wxO telemetry: ASGI middleware, IAM token exchange, `TracerProvider`, span emission |
| `main.py` | Interactive CLI to test the agent locally without A2A or telemetry |
| `start-local.sh` | One-command startup: uvicorn + Cloudflare Quick Tunnel |
| `agent.yaml` | wxO registration spec for `orchestrate agents import` |
| `.well-known/agent.json` | Static AgentCard (also served dynamically by `server.py`) |
| `.env.example` | All environment variables with descriptions |
| `CLOUDFLARE_TUNNEL_SETUP.md` | Quick Tunnel setup guide |
| `article-wxo-agentic-control-plane-v2.md` | Full architectural write-up |

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Python 3.12+ | `python3 --version` |
| [Ollama](https://ollama.com) installed and running | `brew install ollama` (macOS) |
| Llama 3.1 model pulled | `ollama pull llama3.1` |
| [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) | `brew install cloudflared` (macOS) |
| watsonx Orchestrate instance (SaaS) | with the `orchestrate` ADK CLI configured |
| IBM Cloud API key | for wxO telemetry only — `ibmcloud iam api-key-create wxo-telemetry-key` |

> **No Google account, no IBM Cloud Code Engine, no Docker required.**

---

## Part 1 — Install and configure

```bash
# Clone and enter the project directory
cd i-oic-wxo-external-agent-observability

# Create and activate a virtual environment
python3 -m venv .venv && source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Copy the environment template
cp .env.example .env
```

Edit `.env` and fill in at minimum:

```bash
# Required to start the server
AGENT_API_KEY=<generate with: openssl rand -hex 32>

# wxO telemetry (fill in after Part 3 — registration)
WXO_API_KEY=<ibm-cloud-api-key>
WXO_AGENT_ID=<filled after registration>
WXO_TENANT_ID=<account-id>_<instance-id>
OTEL_EXPORT_URL=https://api.<region>.watson-orchestrate.cloud.ibm.com/instances/<instance-id>/v1/orchestrate/inject/traces
```

> **Bootstrap tip:** The middleware reads `WXO_AGENT_ID`, `WXO_TENANT_ID`, and `OTEL_EXPORT_URL` at startup — they must be non-empty. Use placeholder strings (`pending`) for the first run, then update after registration.

---

## Part 2 — Start the agent and open the tunnel

```bash
chmod +x start-local.sh
./start-local.sh
```

The script:
1. Verifies that Ollama is responding and all required env vars are set
2. Starts `uvicorn server:app` on `localhost:8080` and waits for `/health`
3. Opens a Cloudflare Quick Tunnel and captures the generated public URL
4. Prints a ready block with the URL and registration commands

**Expected output:**

```
✅ Servidor pronto!

🌐 Iniciando Cloudflare Quick Tunnel...

════════════════════════════════════════════════════════════
  ✅ Agente A2A disponível publicamente!

  URL pública   : https://xxxx-yyyy-zzzz.trycloudflare.com
  AgentCard     : https://xxxx-yyyy-zzzz.trycloudflare.com/.well-known/agent.json
  Health check  : https://xxxx-yyyy-zzzz.trycloudflare.com/health
  A2A endpoint  : https://xxxx-yyyy-zzzz.trycloudflare.com/

  ⚠️  Esta URL muda a cada restart do script.

  Para registrar no wxO (execute em outro terminal):

    orchestrate agents discover -u https://xxxx-yyyy-zzzz.trycloudflare.com
════════════════════════════════════════════════════════════
```

> **⚠️ Quick Tunnel URL changes on every restart.** Each time you stop and restart `start-local.sh`, a new URL is generated. You must re-register the agent in wxO with the new URL (Part 3).

---

## Part 3 — Register the agent with watsonx Orchestrate

With the tunnel running, open a second terminal and register:

### Option A — Auto-discovery (fastest)

```bash
orchestrate agents discover -u https://xxxx-yyyy-zzzz.trycloudflare.com
```

### Option B — YAML import (declarative)

1. Edit `agent.yaml` — set `api_url` to the tunnel URL and `auth_config.token` to your `AGENT_API_KEY`
2. Run:

```bash
orchestrate agents import -f agent.yaml
```

### After registration

Both options print an **Agent ID** (UUID). Copy it — you need it in the next step.

---

## Part 4 — Enable telemetry

Update `.env` with the real values:

| Variable | Where to find it |
|---|---|
| `WXO_AGENT_ID` | Printed by `orchestrate agents discover` / `import` in Part 3 |
| `WXO_TENANT_ID` | wxO UI → Profile → About → CRN — formatted as `<account-id>_<instance-id>` |
| `WXO_API_KEY` | `ibmcloud iam api-key-create wxo-telemetry-key --file wxo-telemetry-key.json` |
| `OTEL_EXPORT_URL` | `https://api.<region>.watson-orchestrate.cloud.ibm.com/instances/<instance-id>/v1/orchestrate/inject/traces` |
| `TOKEN_URL` | `https://iam.cloud.ibm.com/identity/token` (IBM Cloud SaaS — already set in `.env.example`) |

Then restart the script (the new URL will change — re-register once more):

```bash
# Ctrl+C to stop, then:
./start-local.sh
```

Telemetry is active when you see this line in the output after each request:

```
wxO trace queued trace_id=<32-hex> thread_id=<uuid> status=success
```

---

## Part 5 — Test end to end

In a second terminal, load the env and send a test message:

```bash
set -a && source .env && set +a

TUNNEL_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /tmp/cloudflared-*.log 2>/dev/null | tail -1)

curl -s -X POST "${TUNNEL_URL}/" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AGENT_API_KEY}" \
  -d '{
    "jsonrpc": "2.0",
    "id": "test-001",
    "method": "message/send",
    "params": {
      "message": {
        "kind": "message",
        "role": "user",
        "messageId": "msg-001",
        "parts": [{"kind": "text", "text": "I invested $10,000 and it is now $13,500 after 18 months. What is my annualized return?"}]
      }
    }
  }' | python3 -m json.tool
```

A successful response looks like:

```json
{
  "jsonrpc": "2.0",
  "id": "test-001",
  "result": {
    "kind": "task",
    "status": { "state": "completed", ... },
    "artifacts": [{ "parts": [{ "text": "Your annualized return is 22.15%." }] }]
  }
}
```

---

## Part 6 — View traces in the wxO control plane

In the wxO UI, go to **Analyze** and explore three levels:

1. **Overview** — tenant-wide dashboard. The external agent appears alongside native wxO agents.
2. **Annualized Return Agent → Agent dashboard** — token consumption, tool-call counts, latency, feedback.
3. **Annualized Return Agent → Conversations** — every conversation grouped by session. Opening one shows the full trace tree:

```
invoke_agent annualized_return_agent        ← root span (SERVER), one per A2A request
  ├─ agent.graph                            ← the full LangGraph invoke()
  ├─ gen_ai.chat → calculate_annualized_return  ← LLM turn that called the tool
  ├─ tool_call calculate_annualized_return  ← tool execution with JSON output
  └─ gen_ai.chat                            ← LLM turn that wrote the final answer
```

See [`article-wxo-agentic-control-plane-v2.md`](article-wxo-agentic-control-plane-v2.md) and the screenshots in [`img/`](img/) for what each screen looks like.

---

## Environment variables reference

### Agent & A2A server

| Variable | Required | Description |
|---|---|---|
| `AGENT_API_KEY` | recommended | Bearer token protecting `POST /` — generate with `openssl rand -hex 32` |
| `OLLAMA_MODEL` | no | Model name passed to Ollama. Default: `llama3.1` |
| `OLLAMA_BASE_URL` | no | Ollama server URL. Default: `http://localhost:11434` |
| `SERVER_HOST` | no | Bind address for uvicorn. Default: `127.0.0.1` |
| `SERVER_PORT` | no | Port for uvicorn. Default: `8080` |

### Telemetry (`wxo_otel.py`)

| Variable | Required | Description |
|---|---|---|
| `WXO_AGENT_ID` | yes | Registered agent UUID from wxO |
| `WXO_TENANT_ID` | yes | `<account-id>_<instance-id>` from wxO CRN |
| `OTEL_EXPORT_URL` | yes | wxO OTLP trace ingestion endpoint |
| `WXO_API_KEY` | yes | IBM Cloud API key exchanged for a bearer token via IAM |
| `TOKEN_URL` | yes | `https://iam.cloud.ibm.com/identity/token` for IBM Cloud SaaS |
| `ENVIRONMENT_NAME` | no | `draft` or `live`. Default: `draft` |
| `LLM_PROVIDER` | no | Value for `gen_ai.system` span attribute. Default: `ollama` |
| `WXO_AGENT_NAME` | no | Used in the root span name `invoke_agent <name>`. Default: `annualized_return_agent` |
| `WXO_CAPTURE_CONTENT` | no | Set `false` to omit `input`/`output` from traces (PII-safe mode) |
| `OTEL_SERVICE_NAME` | no | OTel resource attribute. Default: `annualized-return-agent` |

---

## Handling secrets

`.env`, `*-key.json`, and `*_key.json` are listed in `.gitignore` and must never be committed. The `AGENT_API_KEY` protects your A2A endpoint — treat it like a password.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `AGENT_API_KEY: unbound variable` | Not set in `.env` | Generate with `openssl rand -hex 32` and add to `.env` |
| `Ollama não está respondendo` | Ollama not running | `ollama run llama3.1` in another terminal |
| Tunnel URL not captured after 30s | Network blocks QUIC (UDP/7844) | Already handled — script uses `--protocol http2` (TCP) |
| `401 Unauthorized` on `POST /` | Wrong `AGENT_API_KEY` | Send `Authorization: Bearer <AGENT_API_KEY>` matching `.env` |
| `401` on OTel export | `WXO_TENANT_ID` wrong format | Must be `<account-id>_<instance-id>` with underscore, not colon |
| `No Langfuse credentials configured` | `WXO_TENANT_ID` missing the instance ID part | See row above |
| `wxO trace queued` in logs but nothing in wxO UI | `WXO_AGENT_ID` stale after re-registration | Update `WXO_AGENT_ID` in `.env` and restart |
| Trace renders as `[object Object]` in Trace View | `agent.name` or `gen_ai.input.messages` set on a span | Do not set these — see comments in `wxo_otel.py` |
| `ENVIRONMENT_NAME must be 'live' or 'draft'` | Typo in env var | Set to exactly `draft` or `live` |

---

## Day-to-day workflow

```
# Every session:

Terminal 1   ollama run llama3.1
Terminal 2   ./start-local.sh          ← prints new tunnel URL

# First run or after every restart:
Terminal 3   orchestrate agents discover -u <new-tunnel-url>
             → copy Agent ID → update WXO_AGENT_ID in .env
             → Ctrl+C Terminal 2 → ./start-local.sh again
```

---

## Further reading

- [`article-wxo-agentic-control-plane-v2.md`](article-wxo-agentic-control-plane-v2.md) — full write-up: why a control plane matters, how `wxo_otel.py` works, and what the pattern delivers.
- [`CLOUDFLARE_TUNNEL_SETUP.md`](CLOUDFLARE_TUNNEL_SETUP.md) — Quick Tunnel setup and troubleshooting.
- [Exporting observability traces with OpenTelemetry](https://developer.watson-orchestrate.ibm.com/traces/otel-export) — official wxO docs.
