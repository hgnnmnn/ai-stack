#!/usr/bin/env bats

GATEWAY="http://localhost:4000"
PROMETHEUS="http://localhost:9090"
GRAFANA="http://localhost:3000"
GRAFANA_AUTH="admin:$GRAFANA_ADMIN_PASSWORD"
DS_UID="prometheus"

@test "prometheus and grafana are up" {
  run curl -sf "$PROMETHEUS/-/healthy"
  [ "$status" -eq 0 ]

  run curl -sf "$GRAFANA/api/health"
  [ "$status" -eq 0 ]
}

@test "prometheus scrapes litellm metrics" {
  run curl -sf --data-urlencode 'query=up{job="litellm"}' "$PROMETHEUS/api/v1/query"
  [ "$status" -eq 0 ]

  value=$(echo "$output" | jq -r '.data.result[0].value[1]')
  [ "$value" = "1" ]
}

@test "grafana's Prometheus datasource is healthy" {
  run curl -sf -u "$GRAFANA_AUTH" "$GRAFANA/api/datasources/uid/$DS_UID/health"
  [ "$status" -eq 0 ]

  status_field=$(echo "$output" | jq -r '.status')
  [ "$status_field" = "OK" ]
}

@test "a Grafana query against the Prometheus datasource returns LiteLLM request metrics" {
  curl -sf -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model": "llama-chat", "messages": [{"role": "user", "content": "hi"}]}' >/dev/null

  # Prometheus scrapes litellm on a 15s interval.
  count=0
  for _ in $(seq 1 20); do
    run curl -sf -u "$GRAFANA_AUTH" \
      --data-urlencode 'query=litellm_proxy_total_requests_metric_total{requested_model="llama-chat"}' \
      "$GRAFANA/api/datasources/proxy/uid/$DS_UID/api/v1/query"
    [ "$status" -eq 0 ]
    count=$(echo "$output" | jq '.data.result | length')
    [ "$count" -gt 0 ] && break
    sleep 3
  done
  [ "$count" -gt 0 ]
}
