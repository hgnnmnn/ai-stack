#!/usr/bin/env bats

GATEWAY="http://localhost:4000"

@test "chat completion with Model ID Qwen3.6-35B-A3B routes to the qwen35 backend" {
  run curl -sf -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model": "Qwen3.6-35B-A3B", "messages": [{"role": "user", "content": "hi"}]}'

  [ "$status" -eq 0 ]
  [[ "$output" == *"response from Qwen3.6-35B-A3B"* ]]
}

@test "chat completion with Model ID Qwen3-Coder-Next routes to the coder backend" {
  run curl -sf -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model": "Qwen3-Coder-Next", "messages": [{"role": "user", "content": "hi"}]}'

  [ "$status" -eq 0 ]
  [[ "$output" == *"response from Qwen3-Coder-Next"* ]]
}

@test "a Key scoped to one Model ID is rejected for another Model ID" {
  run curl -sf -X POST "$GATEWAY/key/generate" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"models": ["Qwen3.6-35B-A3B"]}'
  [ "$status" -eq 0 ]

  scoped_key=$(echo "$output" | jq -r '.key')
  [ -n "$scoped_key" ]
  [ "$scoped_key" != "null" ]

  run curl -s -o /dev/null -w "%{http_code}" -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $scoped_key" \
    -H "Content-Type: application/json" \
    -d '{"model": "Qwen3.6-35B-A3B", "messages": [{"role": "user", "content": "hi"}]}'
  [ "$output" -eq 200 ]

  run curl -s -o /dev/null -w "%{http_code}" -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $scoped_key" \
    -H "Content-Type: application/json" \
    -d '{"model": "Qwen3-Coder-Next", "messages": [{"role": "user", "content": "hi"}]}'
  [[ "$output" == "401" || "$output" == "403" ]]
}

# Tolerates the brief window after a restart where litellm is "healthy"
# (liveness only) but its DB connection pool isn't ready yet.
spend_log_count() {
  local n
  for _ in $(seq 1 15); do
    n=$(curl -s "$GATEWAY/spend/logs" -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq 'length' 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] && { echo "$n"; return; }
    sleep 1
  done
  echo "-1"
}

@test "usage logging persists across docker compose down/up" {
  before=$(spend_log_count)

  curl -sf -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model": "Qwen3.6-35B-A3B", "messages": [{"role": "user", "content": "hi"}]}' >/dev/null

  # LiteLLM flushes spend logs to the DB on a background interval, not synchronously.
  after="$before"
  for _ in $(seq 1 30); do
    after=$(spend_log_count)
    [ "$after" -gt "$before" ] && break
    sleep 3
  done
  [ "$after" -gt "$before" ]

  cd "$BATS_TEST_DIRNAME/.."
  local_compose="docker compose -f docker-compose.yml -f docker-compose.test.yml --env-file tests/test.env"
  $local_compose down
  $local_compose up -d --wait

  persisted=$(spend_log_count)
  [ "$persisted" -ge "$after" ]
}
