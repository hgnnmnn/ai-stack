#!/usr/bin/env bash
# Renders litellm/config.yaml from litellm/config.yaml.tmpl. The Backend flags
# (CHAT_ARGS / CODER_ARGS / FIM_ARGS) are the single source: --ctx-size and
# --parallel (-> per-slot context) are read from them, supports_vision from *_MMPROJ_FILE.
# Usage: scripts/render-litellm-config.sh [env-file]   (default: .env)
# Output goes to LITELLM_CONFIG_FILE from the env file (the same variable
# docker-compose.yml mounts), else litellm/config.yaml. tests/test.env points
# it elsewhere so `make test` never overwrites the file the live Gateway reads.
#
# .env is parsed, not sourced: its values are unquoted flag lists with spaces
# (they must stay that way for make and compose), which bash would execute.
# A variable already set in the environment wins, as with compose.
set -euo pipefail
cd "$(dirname "$0")/.."

env_file="${1:-.env}"
[ -f "$env_file" ] || { echo "error: $env_file not found (run: make env)" >&2; exit 1; }

var() { # var NAME -> value from the environment, else last NAME= line in env_file
  if [ -n "${!1+x}" ]; then printf '%s' "${!1}"; return; fi
  { grep -E "^$1=" "$env_file" || true; } | tail -n 1 | cut -d= -f2-
}

flag() { # flag NAME ARGS FLAG -> integer after FLAG, or exit
  local v
  v="$(grep -oE "(^| )$3[ =][0-9]+( |$)" <<<"$2" | tail -n 1 | grep -oE '[0-9]+')" || true
  [ -n "$v" ] || { echo "error: $1 needs '$3 <number>' (long form)" >&2; exit 1; }
  printf '%s' "$v"
}

summary=""
for p in CHAT CODER FIM; do
  args="$(var "${p}_ARGS")"
  [ -n "$args" ] || { echo "error: ${p}_ARGS is not set in $env_file" >&2; exit 1; }
  ctx="$(flag "${p}_ARGS" "$args" --ctx-size)"
  par="$(flag "${p}_ARGS" "$args" --parallel)"
  if (( ctx % par != 0 )); then
    echo "error: ${p}_ARGS: --ctx-size $ctx is not divisible by --parallel $par" >&2
    exit 1
  fi
  export "${p}_CTX_PER_SLOT=$((ctx / par))"
  summary+=" ${p,,} ${par}x$((ctx / par))"
done
for p in CHAT CODER; do
  if [ -n "$(var "${p}_MMPROJ_FILE")" ]; then export "${p}_VISION=true"; else export "${p}_VISION=false"; fi
done

out="$(var LITELLM_CONFIG_FILE)"
out="${out:-litellm/config.yaml}"

vars='${CHAT_CTX_PER_SLOT} ${CHAT_VISION} ${CODER_CTX_PER_SLOT} ${CODER_VISION} ${FIM_CTX_PER_SLOT}'
tmp="$(mktemp "$out.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
envsubst "$vars" < litellm/config.yaml.tmpl > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$out"
trap - EXIT
echo "$out rendered:$summary"
