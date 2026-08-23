#!/usr/bin/env bash
# Runs the litellm Gateway integration tests against stub Backends.
# Usage: tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# -p keeps this off the default `ai-stack` project: the `down -v` below would
# otherwise delete the running prod stack's Postgres/Redis/Grafana volumes.
export COMPOSE
COMPOSE="docker compose -p ai-stack-test -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.test.yml --env-file tests/test.env"

cleanup() {
  $COMPOSE down -v
}
trap cleanup EXIT

set -a
source tests/test.env
set +a

$COMPOSE up -d --build --wait
bats tests/*.bats
