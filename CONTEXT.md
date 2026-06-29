# AI Stack

A self-hosted LLM inference stack: local model Backends exposed through a single Gateway, with optional image generation and monitoring.

## Language

**Backend**:
An llama.cpp inference process serving one model, running as its own container on the internal Docker network. Exposed to the Gateway only, never directly to clients.
_Avoid_: Inference server, llama server

**Gateway**:
The LiteLLM proxy. Routes client requests to the correct Backend by Model ID, issues and enforces per-Key access, and is the only component of this stack reachable from the LAN.
_Avoid_: API Gateway, Proxy (ambiguous with Reverse Proxy)

**Model ID**:
The identifier clients pass in the `model` field of API requests, exposed by the Gateway. A stable functional alias (`llama-chat`, `llama-coder`) that stays constant when the underlying model is swapped, so Clients and Keys don't need updating. It happens to coincide with the Backend's compose service name, but the two are conceptually distinct: the service name is internal plumbing, the Model ID is the public contract.
_Avoid_: model name (the real upstream model, e.g. `Ornith-1.0-35B`, is the "underlying model", not the Model ID)

**Reverse Proxy**:
A TLS-terminating proxy on a separate server, outside this stack, that forwards external HTTPS traffic to the Gateway.
_Avoid_: Proxy (ambiguous with Gateway)

**Key**:
A per-user/per-friend API credential issued by the Gateway, optionally scoped to specific Model IDs.
_Avoid_: API key (generic — in this context "Key" always means a Gateway-issued credential)

**Localhost-only**:
A component bound to `127.0.0.1` — reachable only by other containers/processes on the same host. The default exposure level for Backends, ComfyUI, and Prometheus.
_Avoid_: internal, private

**LAN-facing**:
A component bound to the host's LAN interface — reachable by any device on the local network. Used for the Gateway, the Grafana dashboard, and ComfyUI (during Imagegen Mode). The Gateway's `/v1/*` path is additionally forwarded to the internet by the Reverse Proxy; the others are LAN-only and not forwarded.
_Avoid_: external, public (too strong — this is LAN, not internet)

**Client**:
Any application that calls the Gateway's OpenAI-compatible API using a Key. OpenWebUI (hosted separately, same LAN) is the primary Client for personal use, including image generation via ComfyUI's API during Imagegen Mode; friends use their own Clients with their own Keys. Not part of this stack's deployment.
_Avoid_: User (a User/friend is the person holding a Key; the Client is the software they use)

**Imagegen Mode**:
An on-demand operating mode where ComfyUI runs (LAN-facing) and both Backends' context shrinks to 32k. Off by default; started explicitly when image generation is needed. Switching it on or off restarts both Backends, briefly interrupting and reducing context for any Client connected through the Gateway at that moment — an accepted trade-off at this scale.
_Avoid_: imagegen profile (the mechanism, not the concept)
