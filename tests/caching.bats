#!/usr/bin/env bats
# Exercises the Valkey-backed prompt cache (test/valkey-prompt-cache).

GATEWAY="http://localhost:4000"

@test "identical chat completion requests are served from the Valkey cache" {
  body='{"model": "llama-chat", "messages": [{"role": "user", "content": "cache me please"}]}'

  run curl -sf -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "$body"
  [ "$status" -eq 0 ]
  first_id=$(echo "$output" | jq -r '.id')
  [ -n "$first_id" ]

  # The stub Backend mints a fresh uuid into .id on every call, so a second
  # response with the SAME .id can only have come from the cache, not a
  # second round-trip to the Backend.
  run curl -sf -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "$body"
  [ "$status" -eq 0 ]
  second_id=$(echo "$output" | jq -r '.id')

  [ "$second_id" == "$first_id" ]
}

@test "the prompt cache actually lives in valkey, not just in-memory" {
  cd "$BATS_TEST_DIRNAME/.."
  local_compose="docker compose -f docker-compose.yml -f docker-compose.test.yml --env-file tests/test.env"

  run $local_compose exec -T valkey valkey-cli -a "$VALKEY_PASSWORD" --no-auth-warning dbsize
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}
