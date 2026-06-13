# AI Stack

Self-hosted LLM inference stack. See [`CONTEXT.md`](CONTEXT.md) for the glossary
(Backend, Gateway, Model ID, Key, ...) and [`docs/adr/`](docs/adr/) for
architecture decisions.

## Setup

1. `make env` (copies `.env.example` to `.env`) and fill in real values:
   - `LITELLM_MASTER_KEY`: `echo "sk-$(openssl rand -hex 32)"`
   - `POSTGRES_PASSWORD`: any strong random value
   - `GRAFANA_ADMIN_PASSWORD`: any strong random value
   - `MODELS_DIR`, `QWEN35_MODEL_FILE`, `CODER_MODEL_FILE`, `RENDER_GID`,
     `VIDEO_GID`: see [Backends](#backends)
2. `make up`

The Gateway (litellm) is LAN-facing on `:4000` (see ADR 0001). Postgres backs
litellm's virtual Keys and spend tracking and is not exposed outside the
compose network.

Run `make help` for shortcuts to the commands used throughout this doc
(`up`/`down`/`logs`/`ps`/`config`/`vulkaninfo`/`stats`/`test`/...). On a
podman host, pass `COMPOSE="podman compose" CONTAINER_BIN=podman` to any
target.

## Backends

`llama-qwen35` (Model ID `Qwen3.6-35B-A3B`, `:8001`) and `llama-coder` (Model ID
`Qwen3-Coder-Next`, `:8002`) are defined in `docker-compose.backends.yml`, kept
separate from `docker-compose.yml` because they're host-specific (GPU device,
group IDs, model paths) — see ADR 0003 for Vulkan/RADV vs. ROCm and ADR 0002
for the KV cache settings. `.env.example` sets
`COMPOSE_FILE=docker-compose.yml:docker-compose.backends.yml` so plain
`docker compose up -d` includes them; `tests/run.sh` is unaffected since it
passes `-f` explicitly and overlays stub Backends instead (see
[Tests](#tests)).

### Models

Place the GGUF files under `MODELS_DIR` (e.g. `~/models`, mounted read-only
into both Backends) and point `QWEN35_MODEL_FILE`/`CODER_MODEL_FILE` at their
paths within it (subdirectories are fine, e.g.
`unsloth/Qwen3-Coder-Next-GGUF/Qwen3-Coder-Next-UD-Q4_K_XL.gguf`). For a model
split into multiple shards, point at the first shard
(`model-00001-of-000XX.gguf`) — llama.cpp finds the rest automatically.

`llama-qwen35` additionally loads `QWEN35_MMPROJ_FILE`, the multimodal
projector for its vision encoder (`--mmproj`) — without it the model still
serves text but loses the "Multimodal" capability from `CONTEXT.md`.
`llama-coder` has no projector and needs no equivalent variable.

### GPU passthrough GIDs

`RENDER_GID`/`VIDEO_GID` are the host's `render`/`video` group IDs, added to
each Backend container via `group_add` alongside `/dev/dri` passthrough:

```sh
getent group render | cut -d: -f3
getent group video | cut -d: -f3
```

### Bring-up order

Per the original hardware plan (`planed-setup.md`), bring the Backends up
incrementally rather than all at once:

1. Verify Vulkan passthrough before starting either Backend: `make vulkaninfo`
   should list the gfx1151 RADV device (ADR 0003). If `vulkaninfo` isn't in
   the image, `apt-get install -y vulkan-tools` in a one-off shell on the same
   image first.
2. `docker compose up -d llama-qwen35`, then send a chat completion to
   `http://127.0.0.1:8001/v1/chat/completions` (issue #2 acceptance check).
3. `docker compose up -d llama-coder` to bring up both Backends together,
   then send a chat completion to `http://127.0.0.1:8002/v1/chat/completions`
   (issue #3 acceptance check).
4. `docker compose up -d` for the rest of the stack (litellm, postgres,
   prometheus, grafana).

### Memory budget

`llama-coder` runs with q8-quantized KV cache (k & v) to reach 128k context;
`llama-qwen35` keeps f16 KV cache at 65k context (ADR 0002). `planed-setup.md`
estimates ~90GB combined at 65k/f16, within the 128GB unified memory budget —
`llama-coder`'s q8 cache at 128k should use comparably less, but this needs
confirming on real hardware.

To measure with both Backends running: `make stats`.

This also answers issue #3's open question: whether `llama-coder` can go from
128k (`--ctx-size 131072`) to 256k (`262144`) within the remaining budget. To
try it, edit `--ctx-size` in `docker-compose.backends.yml`, restart
`llama-coder`, and re-measure — 256k doesn't need to be the default, only
documented as feasible or not.

## Monitoring

- Grafana is LAN-facing on `:3000` (log in as `admin` / `GRAFANA_ADMIN_PASSWORD`).
  A Prometheus datasource is pre-provisioned and healthy on first boot.
- Prometheus is Localhost-only on `:9090` and scrapes litellm's `/metrics`
  endpoint (`litellm/config.yaml` enables the `prometheus` callback), giving
  request count, latency, and error metrics per Model ID/Key.

## Issuing Keys

Generate a Key for a Client, scoped to specific Model IDs:

```sh
curl -X POST http://<host>:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "models": ["Qwen3.6-35B-A3B", "Qwen3-Coder-Next"],
    "rpm_limit": 60,
    "tpm_limit": 100000
  }'
```

- `models`: restricts the Key to these Model IDs; requests for any other
  Model ID are rejected (401/403).
- `rpm_limit` / `tpm_limit`: optional per-Key rate limits (requests/tokens
  per minute). Omit for no limit.

The response's `key` field (`sk-...`) is the Client's credential. Revoke with
`POST /key/delete`, inspect with `GET /key/info?key=...`.

## Tests

```sh
make test
```

Brings up litellm + Postgres + Prometheus + Grafana alongside stub Backends
(standing in for `llama-qwen35`/`llama-coder`, see `docker-compose.test.yml`)
and runs the test suites (`tests/*.bats`) against them.
