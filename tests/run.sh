#!/usr/bin/env bash
# Runs the litellm Gateway integration tests against stub Backends.
# Usage: tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.test.yml --env-file tests/test.env"

cleanup() {
  $COMPOSE down -v
}
trap cleanup EXIT

set -a
source tests/test.env
set +a

$COMPOSE up -d --build --wait
bats tests/*.bats
