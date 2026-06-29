# Technische Anforderungsbeschreibung — Lokaler LLM Inference Stack

## Ziel

Aufbau eines vollständig containerisierten, lokal betriebenen LLM-Inference-Stacks auf einem AMD Strix Halo Mini-Workstation. Der Stack soll mehrere Sprachmodelle parallel hosten, über einen API-Gateway mit Key-Management nach außen exponieren und optional Bildgenerierung integrieren. Ein externer Reverse Proxy übernimmt TLS-Terminierung und Weiterleitung.

---

## Hardware

| Eigenschaft | Wert |
|---|---|
| CPU/APU | AMD Ryzen AI MAX+ 395 „Strix Halo", 16 Cores / 32 Threads |
| GPU | Integrierte Radeon 8060S (RDNA 3.5, gfx1151) |
| Memory | 128 GB unified LPDDR5X, shared zwischen CPU und GPU |
| Storage | ~168 GB GGUF-Modelle unter `~/models` |
| OS | Fedora Linux 44, Kernel 7.x, btrfs |

GPU-Zugriff im Container erfolgt via `/dev/dri` Device-Passthrough (Vulkan-Backend). ROCm ist aufgrund einer Library-Inkompatibilität (ROCm 6 vs. Systemlibs ROCm 7.1.1) nicht nutzbar.

---

## Inference-Stack

### Backend

- **llama.cpp** (`server-vulkan` Container-Image von `ghcr.io/ggerganov/llama.cpp`)
- Vulkan als einziges funktionierendes GPU-Backend auf dieser Hardware
- Kein LM Studio im Produktivbetrieb — native llama-server-Prozesse im Container

### Modelle (Auswahl — zwei parallel)

| Modell | Größe | Typ | Zweck |
|---|---|---|---|
| Qwen3.6-35B-A3B (Q6_K) | ~28 GB | MoE, Vision | Daily Driver, Multimodal |
| Qwen3-Coder-Next (Q4_K_XL) | ~46 GB | MoE | Coding, agentic Tasks |

Speicherbedarf parallel (je 65k Context, f16 KV-Cache): ~90 GB — passt in 128 GB unified Memory. Bei gleichzeitigem Betrieb von Bildgenerierung: Context auf 32k reduzieren.

---

## Containerisierung

### Anforderungen

- Vollständig containerisiert via **Docker Compose** — ein `docker compose up -d` startet den gesamten Stack
- GPU-Passthrough: `/dev/dri` wird in alle GPU-nutzenden Container gemountet, Container-User erhält Membership in `video`- und `render`-Gruppe
- Modell-Weights werden als **read-only Volume** (`~/models`) in die llama-Container gemountet
- Alle Services binden ausschließlich auf `127.0.0.1` — kein direkter Außenzugriff

### Services im Compose-Stack

| Service | Image | Port | Funktion |
|---|---|---|---|
| `llama-chat` | `ghcr.io/ggerganov/llama.cpp:server-vulkan` | 8001 | Qwen3.6-35B Inference |
| `llama-coder` | `ghcr.io/ggerganov/llama.cpp:server-vulkan` | 8002 | Qwen3-Coder Inference |
| `litellm` | `ghcr.io/berriai/litellm:main-stable` | 4000 | API Gateway |
| `comfyui` | `yanwk/comfyui-boot:latest` | 8188 | Bildgenerierung |
| `prometheus` | `prom/prometheus:latest` | 9090 | Metriken |
| `grafana` | `grafana/grafana:latest` | 3000 | Monitoring Dashboard |

---

## API Gateway

**LiteLLM Proxy** übernimmt:

- **API-Key-Management** — pro User/Freund ein separater Key mit optional zugewiesenen Modellen
- **Routing** — Anfragen werden anhand des Modellnamens an den zuständigen llama-server weitergeleitet (interne Docker-DNS-Namen, z.B. `http://llama-chat:8001/v1`)
- **Usage-Logging** — alle Requests werden protokolliert (SQLite lokal)
- **Rate Limiting** — konfigurierbar pro Key
- **OpenAI-kompatibler Endpunkt** — bestehende Tools und Clients ohne Anpassung nutzbar

Master-Key-Erzeugung: `openssl rand -hex 32`

User-Keys werden über LiteLLM REST-API angelegt:
```bash
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer <master-key>" \
  -d '{"models": ["qwen3-35b", "coder"], "alias": "name"}'
```

---

## Bildgenerierung

**ComfyUI** als Bildgenerierungs-Backend:

- Node-basierter Workflow, leichtgewichtig gegenüber Automatic1111
- Vulkan/CPU-Fallback über `yanwk/comfyui-boot`-Image
- Empfohlene Modelle für diese Hardware: **FLUX.1-schnell** (~7 GB) oder SD3.5-Medium
- Eigenes Volume für Diffusion-Weights (`~/comfy-models`)
- Anbindung an LiteLLM über Image-Endpoint-Adapter (separater Schritt nach Erstinbetriebnahme)

---

## Netzwerk & Zugang

### Externer Reverse Proxy

Ein bereits vorhandener externer Reverse Proxy (anderer Server) übernimmt:

- TLS-Terminierung (HTTPS :443)
- Weiterleitung an diesen Server:

| Pfad | Ziel |
|---|---|
| `/v1/*` | `http://<server-ip>:4000` (LLM API) |
| `/comfy/*` | `http://<server-ip>:8188` (optional, Bildgenerierung) |

Kein Caddy oder lokale TLS-Terminierung notwendig.

### Firewall

Alle Ports binden auf `127.0.0.1` — einzige Ausnahme ist Port 4000, der für den externen Proxy erreichbar sein muss.

---

## Monitoring

- **Prometheus** sammelt Metriken von LiteLLM (Request-Count, Latenz, Token/s, Fehlerrate)
- **Grafana** visualisiert die Metriken (Dashboard auf `127.0.0.1:3000`)
- LiteLLM-Konfiguration: `success_callback` und `failure_callback` auf `prometheus`

---

## Inbetriebnahme — Reihenfolge

1. Vulkan-Passthrough im Container verifizieren (`vulkaninfo --summary` im `server-vulkan`-Container)
2. `llama-chat` einzeln starten, Inference gegen `:8001` testen
3. `llama-coder` dazu starten, Speicherauslastung prüfen
4. LiteLLM hochfahren, Routing gegen beide llama-Server testen
5. Externer Proxy auf Port 4000 zeigen lassen, End-to-End-Test
6. ComfyUI starten, FLUX.1-schnell laden, Bildgenerierung testen
7. Prometheus + Grafana aktivieren

---

## Offene Punkte

- ComfyUI → LiteLLM Adapter (Image-API-Endpoint) — noch nicht implementiert
- Grafana Dashboard-Template — noch nicht erstellt
- Vulkan-Passthrough-Verhalten bei gleichzeitiger Last beider llama-Container — zu validieren
