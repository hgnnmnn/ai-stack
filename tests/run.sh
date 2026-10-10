#!/usr/bin/env bash
# Runs the litellm Gateway integration tests against stub Backends.
# Usage: tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# -p keeps this off the default `ai-stack` project: the `down -v` below would
# otherwise delete the running prod stack's Postgres/Redis volumes.
export COMPOSE
COMPOSE="docker compose -p ai-stack-test -f docker-compose.yml -f docker-compose.test.yml --env-file tests/test.env"

cleanup() {
  $COMPOSE down -v
}
trap cleanup EXIT

scripts/render-litellm-config.sh tests/test.env

# Parsed, not sourced: the *_ARGS lines are unquoted flag lists with spaces,
# which bash would try to execute. The suite only reads these two.
for v in GATEWAY_PORT LITELLM_MASTER_KEY; do
  export "$v=$(grep -E "^$v=" tests/test.env | tail -n 1 | cut -d= -f2-)"
done

$COMPOSE up -d --build --wait
bats tests/*.bats
