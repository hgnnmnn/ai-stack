#!/usr/bin/env bats

GATEWAY="http://localhost:${GATEWAY_PORT:-4000}"

@test "chat completion with Model ID llama-chat routes to the chat backend" {
  run curl -sf -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model": "llama-chat", "messages": [{"role": "user", "content": "hi"}]}'

  [ "$status" -eq 0 ]
  [[ "$output" == *"response from llama-chat"* ]]
}

@test "chat completion with Model ID llama-coder routes to the coder backend" {
  run curl -sf -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model": "llama-coder", "messages": [{"role": "user", "content": "hi"}]}'

  [ "$status" -eq 0 ]
  [[ "$output" == *"response from llama-coder"* ]]
}

@test "a Key scoped to one Model ID is rejected for another Model ID" {
  run curl -sf -X POST "$GATEWAY/key/generate" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"models": ["llama-chat"]}'
  [ "$status" -eq 0 ]

  scoped_key=$(echo "$output" | jq -r '.key')
  [ -n "$scoped_key" ]
  [ "$scoped_key" != "null" ]

  run curl -s -o /dev/null -w "%{http_code}" -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $scoped_key" \
    -H "Content-Type: application/json" \
    -d '{"model": "llama-chat", "messages": [{"role": "user", "content": "hi"}]}'
  [ "$output" -eq 200 ]

  run curl -s -o /dev/null -w "%{http_code}" -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $scoped_key" \
    -H "Content-Type: application/json" \
    -d '{"model": "llama-coder", "messages": [{"role": "user", "content": "hi"}]}'
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
    -d '{"model": "llama-chat", "messages": [{"role": "user", "content": "hi"}]}' >/dev/null

  # LiteLLM flushes spend logs to the DB on a background interval, not synchronously.
  after="$before"
  for _ in $(seq 1 30); do
    after=$(spend_log_count)
    [ "$after" -gt "$before" ] && break
    sleep 3
  done
  [ "$after" -gt "$before" ]

  # Reuse run.sh's exact invocation rather than restating it: the project name
  # and the compose file set both matter, and a partial restatement silently
  # targets the wrong project or an incomplete project.
  cd "$BATS_TEST_DIRNAME/.."
  $COMPOSE down
  $COMPOSE up -d --wait

  persisted=$(spend_log_count)
  [ "$persisted" -ge "$after" ]
}

# The response cache is Redis-backed (litellm/config.yaml cache_params). The
# stub mints a fresh id per call, so an identical second request coming back
# with the same id means it was served out of Redis, not from the Backend.
@test "identical requests are served from the Redis response cache" {
  body='{"model": "llama-chat", "messages": [{"role": "user", "content": "redis cache probe"}]}'

  run curl -sf -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "$body"
  [ "$status" -eq 0 ]
  first=$(echo "$output" | jq -r '.id')
  [ -n "$first" ]
  [ "$first" != "null" ]

  # LiteLLM writes the cache entry on a background task, so the hit isn't
  # guaranteed on the very next request.
  second=""
  for _ in $(seq 1 10); do
    second=$(curl -sf -X POST "$GATEWAY/v1/chat/completions" \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      -H "Content-Type: application/json" \
      -d "$body" | jq -r '.id')
    [ "$second" = "$first" ] && break
    sleep 1
  done
  [ "$second" = "$first" ]
}
