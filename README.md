# AI Stack

Self-hosted LLM inference stack. See [`CONTEXT.md`](CONTEXT.md) for the glossary
(Backend, Gateway, Model ID, Key, ...) and [`docs/adr/`](docs/adr/) for
architecture decisions.

## Setup

1. Copy `.env.example` to `.env` and fill in real values:
   - `LITELLM_MASTER_KEY`: `echo "sk-$(openssl rand -hex 32)"`
   - `POSTGRES_PASSWORD`: any strong random value
   - `GRAFANA_ADMIN_PASSWORD`: any strong random value
2. `docker compose up -d`

The Gateway (litellm) is LAN-facing on `:4000` (see ADR 0001). Postgres backs
litellm's virtual Keys and spend tracking and is not exposed outside the
compose network.

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
tests/run.sh
```

Brings up litellm + Postgres + Prometheus + Grafana alongside stub Backends
(standing in for `llama-qwen35`/`llama-coder`, see `docker-compose.test.yml`)
and runs the test suites (`tests/*.bats`) against them.
