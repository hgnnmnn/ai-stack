# Redis for Gateway shared state, even though this runs a single worker

LiteLLM v1.98.0 added a startup banner: *"No Redis configured. Redis is highly
recommended"*, listing rate limits, budgets, router state, and cache
invalidation as per-worker without it. The banner offers an explicit out —
`LITELLM_DISABLE_NO_REDIS_WARNING=true` — for exactly our situation: one
Gateway worker, where "per-worker" and "global" are the same thing. We added
Redis instead.

**Nothing on the banner's list is broken here today.** Every item on
[LiteLLM's list](https://docs.litellm.ai/docs/proxy/redis_requirements) is a
multi-worker consistency problem: limits enforced N times over, spend
overshooting by a factor of N, cooldowns not propagating between workers. With
one worker N is 1. Suppressing the banner would have been defensible and this
ADR does not claim otherwise.

The reasons to run it anyway are smaller and worth stating plainly, because
they are not the ones the banner gives:

- Upstream is steadily moving proxy state *into* Redis rather than out of it,
  and the components that read it (rate limiting, budget accounting, router
  cooldowns, config propagation) are the ones we actually rely on. Being on
  the supported path costs one 512 MB-capped container on a host already
  carrying 35B + 27B + 22B of weights.
- Suppressing a warning with an env var means the next real warning gets read
  as "the usual banner". Configuring the thing is the cheaper end state.

## What this does not fix: the response cache

Commit `f104cfd` (2026-07-09) **removed** a Valkey-backed cache from this stack
because exact-match caching produced near-zero hit rates for multi-turn chat —
every request carries the full message history, so every request is unique. A
later commit re-enabled caching as `type: local`. That history matters here:
having a Redis container again does **not** make exact-match caching work, and
this ADR is not a re-pitch of it.

`cache_params` was pointed at the new Redis anyway, on the narrow grounds that
`type: local` is an in-process LRU hardcoded to 200 entries shared by every
Model ID (`Cache()` takes no `max_size_in_memory`; there is no env knob), so it
was never doing much either. Moving it costs nothing now that the container
exists. The workload where it could plausibly pay off is `llama-fim`, whose
raw completions repeat far more than chat turns do — and that is a hypothesis,
not a result.

If the Prometheus `litellm_*cache*` series shows hit rates still near zero, the
honest move is `cache: false`, not a third cache backend. Redis stays either
way; the two decisions are independent.

## Consequences, most surprising first

- **The response cache now survives a Gateway restart.** An identical request
  replays its stored answer for the full `ttl` (600s) as before, but
  `make restart` no longer clears it — "regenerate" in a Client returning
  identical text at `--temp 1.0` is now true across runs, not just within one.
  `make clean` (`down -v`) drops `redis-data` for a genuine flush.
- **Redis is a cache, not a database.** Keys and spend stay in Postgres.
  Losing `redis-data` costs a cold cache and reset counters, nothing durable.
  Configured to match: `maxmemory 512mb` with `allkeys-lru`, and
  `stop-writes-on-bgsave-error no` so a failed snapshot degrades to "not
  persisted" instead of Redis rejecting writes and taking rate limiting down
  with it. Every key LiteLLM writes carries a TTL (verified: cache 600s, spend
  and token buckets ~60s, `litellm_config:param:*` ~20s), so `allkeys-lru` and
  `volatile-lru` behave identically in practice; `allkeys-lru` is kept because
  it cannot return OOM to a write.
- **Two config blocks, not one.** `litellm_settings.cache_params` and
  `router_settings` each take their own Redis coordinates; LiteLLM does not
  derive one from the other. Setting only `cache_params` leaves the v1.98.0
  banner up — a good way to conclude the change didn't work.
- **A broken Redis is now a broken Gateway,** not a degraded one, via
  `depends_on: service_healthy`. Accepted: a Gateway with no rate limiting is
  not a state worth staying up in at this scale.
