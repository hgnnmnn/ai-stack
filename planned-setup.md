# Planned Setup — Local LLM Inference Stack

## Goal

Build a fully containerized, locally-run LLM inference stack on an AMD Strix Halo Mini-Workstation. The stack shall host multiple language models in parallel, expose them through an API gateway with key management, and optionally integrate image generation. An external reverse proxy handles TLS termination and forwarding.

---

## Hardware

| Property | Value |
|---|---|
| CPU/APU | AMD Ryzen AI MAX+ 395 "Strix Halo", 16 Cores / 32 Threads |
| GPU | Integrated Radeon 8060S (RDNA 3.5, gfx1151) |
| Memory | 128 GB unified LPDDR5X, shared between CPU and GPU |
| Storage | ~168 GB GGUF models under `~/models` |
| OS | Fedora Linux 44, Kernel 7.x, btrfs |

GPU access in the container is via `/dev/dri` device passthrough (Vulkan backend). ROCm is not usable due to a library incompatibility (ROCm 6 vs. system libs ROCm 7.1.1).

---

## Inference Stack

### Backend

- **llama.cpp** (`server-vulkan` container image from `ghcr.io/ggerganov/llama.cpp`)
- Vulkan as the only working GPU backend on this hardware
- No LM Studio in production — native llama-server processes in the container

### Models (selection — two in parallel)

| Model | Size | Type | Purpose |
|---|---|---|---|
| Qwen3.6-35B-A3B (Q6_K) | ~28 GB | MoE, Vision | Daily Driver, Multimodal |
| Qwen3-Coder-Next (Q4_K_XL) | ~46 GB | MoE | Coding, agentic Tasks |

Memory usage in parallel (65k context each, f16 KV cache): ~90 GB — fits in 128 GB unified memory. When running image generation simultaneously, reduce context to 32k.

---

## Containerization

### Requirements

- Fully containerized via **Docker Compose** — a single `docker compose up -d` starts the entire stack
- GPU passthrough: `/dev/dri` is mounted into all GPU-using containers, container user gets membership in `video` and `render` groups
- Model weights are mounted as a **read-only volume** (`~/models`) into the llama containers
- All services bind exclusively to `127.0.0.1` — no direct external access

### Services in the Compose Stack

| Service | Image | Port | Function |
|---|---|---|---|
| `llama-chat` | `ghcr.io/ggerganov/llama.cpp:server-vulkan` | 8001 | Qwen3.6-35B Inference |
| `llama-coder` | `ghcr.io/ggerganov/llama.cpp:server-vulkan` | 8002 | Qwen3-Coder Inference |
| `litellm` | `ghcr.io/berriai/litellm:main-stable` | 4000 | API Gateway |
| `comfyui` | `yanwk/comfyui-boot:latest` | 8188 | Image Generation |
| `prometheus` | `prom/prometheus:latest` | 9090 | Metrics |
| `grafana` | `grafana/grafana:latest` | 3000 | Monitoring Dashboard |

---

## API Gateway

**LiteLLM Proxy** handles:

- **API Key Management** — one key per user/friend, optionally assigned to specific models
- **Routing** — requests are forwarded to the appropriate llama-server based on model name (internal Docker DNS names, e.g. `http://llama-chat:8001/v1`)
- **Usage Logging** — all requests are logged (SQLite locally)
- **Rate Limiting** — configurable per key
- **OpenAI-compatible endpoint** — existing tools and clients usable without modification

Master key generation: `openssl rand -hex 32`

User keys are created via LiteLLM REST API:
```bash
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer <master-key>" \
  -d '{"models": ["qwen3-35b", "coder"], "alias": "name"}'
```

---

## Image Generation

**ComfyUI** as the image generation backend:

- Node-based workflow, lightweight compared to Automatic1111
- Vulkan/CPU fallback via `yanwk/comfyui-boot` image
- Recommended models for this hardware: **FLUX.1-schnell** (~7 GB) or SD3.5-Medium
- Own volume for diffusion weights (`~/comfy-models`)
- Connection to LiteLLM via image endpoint adapter (separate step after initial setup)

---

## Network & Access

### External Reverse Proxy

An already-existing external reverse proxy (separate server) handles:

- TLS termination (HTTPS :443)
- Forwarding to this server:

| Path | Target |
|---|---|
| `/v1/*` | `http://<server-ip>:4000` (LLM API) |
| `/comfy/*` | `http://<server-ip>:8188` (optional, image generation) |

No Caddy or local TLS termination required.

### Firewall

All ports bind to `127.0.0.1` — the only exception is port 4000, which must be reachable by the external proxy.

---

## Monitoring

- **Prometheus** collects metrics from LiteLLM (request count, latency, tokens/s, error rate)
- **Grafana** visualizes the metrics (dashboard on `127.0.0.1:3000`)
- LiteLLM configuration: `success_callback` and `failure_callback` set to `prometheus`

---

## Startup — Order

1. Verify Vulkan passthrough in the container (`vulkaninfo --summary` in the `server-vulkan` container)
2. Start `llama-chat` individually, test inference against `:8001`
3. Start `llama-coder`, check memory usage
4. Start LiteLLM, test routing against both llama servers
5. Point external proxy to port 4000, end-to-end test
6. Start ComfyUI, load FLUX.1-schnell, test image generation
7. Enable Prometheus + Grafana

---

## Open Items

- ComfyUI → LiteLLM adapter (image API endpoint) — not yet implemented
- Grafana dashboard template — not yet created
- Vulkan passthrough behavior under simultaneous load from both llama containers — to be validated
