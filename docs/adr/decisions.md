# Architecture Decisions

_Alte Entscheidungen — settled, no longer actively revisited._ These used to
be one file per decision, each a living document updated as new measurements
came in. The underlying questions are settled now, so they're consolidated
here as a historical record instead. Numbering is kept from the original
per-decision files so existing "ADR 000N" references elsewhere in this repo
still resolve to a section below.

Two ADRs from the original set aren't here at all, retired rather than
merged: ADR 0004 (ComfyUI for Imagegen Mode) described a feature that was
dropped before being built, and ADR 0006 (Codestral as the FIM model) was a
model choice fully reverted by ADR 0008 — neither describes anything this
stack still does.

## ADR 0001 — LiteLLM gateway exposed on LAN without firewall restriction

The LiteLLM gateway (port 4000) must be reachable by an external reverse proxy on another server, so it binds to the host's LAN-facing interface instead of `127.0.0.1` like most of the stack. We decided not to add a `firewalld` rule restricting inbound access to the reverse proxy's IP — security relies solely on LiteLLM's per-key API authentication. Revisit if the threat model changes or the reverse proxy's IP becomes stable enough to pin.

### Update (2026-08-11): reverse proxy CIDR now pinned for MCP trust, not firewalling

The reverse proxy's network is stable at `10.0.0.0/24`. This is now used to fix a LiteLLM MCP-access-control gap (a request carrying an `X-Forwarded-For` header was otherwise ignored, so the proxy's peer IP — falling inside `mcp_internal_ip_ranges` — made every external caller look internal to MCP server access control): `litellm/config.yaml` sets `general_settings.use_x_forwarded_for: true` and `mcp_trusted_proxy_ranges: ["10.0.0.0/24"]`, so only XFF headers arriving from that subnet are trusted. This is narrower than a firewall rule (it only affects MCP-internal-IP evaluation, not the port-4000 exposure decision above) — the no-firewall decision itself is unchanged, since API-key auth still covers `/v1/*`.

## ADR 0002 — KV cache quantization applied to the coder Backend only

Both Backends use flash attention, but only `llama-coder` runs with q8-quantized KV cache (k & v) to reach 128k–256k context. `llama-chat` keeps f16 KV cache at 65k context. Qwen3.6-35B-A3B uses a hybrid Gated DeltaNet/Gated Attention architecture with a vision encoder, and neither the model card nor llama.cpp document how KV cache quantization interacts with multimodal inference on this architecture — quantizing risks silently degrading or breaking vision capability. Revisit once this has been empirically validated.

### Update (2026-07-30): now applies to both Backends

`llama-chat` switched from Qwen3.6-35B-A3B to `Ornith-1.0-35B`, which has no vision encoder — the multimodal blocker above doesn't apply to it. Both `llama-chat` and `llama-coder` now run q8_0 KV cache (k & v) at `--ctx-size 262144`. The title stays as the historical record of the original per-Backend rationale; if `llama-chat` ever swaps back to a multimodal model, re-check this before quantizing its KV cache again.

### Update (2026-08-30): llama-chat is multimodal again, vision now enabled on both

`llama-chat` has since moved to `Ornith-1.5-35B-A3B` — an MoE/hybrid architecture with a vision encoder, same shape as the original Qwen3.6-35B-A3B this ADR was written about. Both Backends now run with `--mmproj` (Ornith-1.5-35B-A3B and Qwen3.8-27B each ship their own projector) while keeping q8_0 KV cache at `--ctx-size 262144`/`524288`. The original blocker — undocumented interaction between quantized KV and multimodal inference on a hybrid attention architecture — applies to `llama-chat` again and has still not been empirically validated. Watch for degraded image understanding specifically on `llama-chat`; if seen, try f16 KV there first before assuming the model/projector itself is at fault.

### Note (2026-08): f16 KV was fastest in one deep-context measurement elsewhere

A single (unverified) community measurement on a 122B-A10B MoE model found f16/f16 KV cache outperforming quantized KV at 131k context on gfx1151 hardware, contradicting the "quantize KV to buy context headroom" assumption this ADR relies on. Not yet reproduced on our models/build. If prompt-processing or generation speed at deep context ever looks off, benchmark q8_0 vs f16 KV directly with `llama-bench -d 0,65536,131072,262144` before assuming the quantized cache is a free win.

## ADR 0003 — Vulkan (RADV) as the GPU backend for the LLM Backends

`llama-chat` and `llama-coder` use llama.cpp's Vulkan backend via Mesa's RADV driver, not ROCm. ROCm is currently unusable due to a library version mismatch (ROCm 6 expected by available llama.cpp images vs. system ROCm 7.1.1). Beyond that, community benchmarks for Strix Halo (gfx1151, see [amd-strix-halo-toolboxes](https://kyuz0.github.io/amd-strix-halo-toolboxes/)) show ROCm 7.2.3 and other ROCm builds offer no meaningful performance advantage over Vulkan when serving Qwen models — so this choice isn't expected to change even if the compatibility issue gets resolved.

### Update (2026-07): ROCm trialled directly, decision reaffirmed

The version-mismatch argument above turns out to be sidesteppable: the official `ghcr.io/ggml-org/llama.cpp:server-rocm` image bundles ROCm 7.2.1 and compiles `gfx1151` into `AMDGPU_TARGETS`, so it runs without touching the host's ROCm 7.1.1. It was trialled on `server-rocm-b9744` and rejected on two measured grounds:

1. **Idle power.** The HIP backend keeps a GPU context resident whenever a model is loaded, so the iGPU never clock-gates — it sits at its top DPM state (2900 MHz, ~40 W) at idle, with all slots idle and 0% CPU. Vulkan/RADV releases the GPU between submissions and idles down to ~13 W. This is inherent to ROCm/HIP, not a misconfiguration, and lemonade-sdk's dedicated gfx1151 builds would behave the same.
2. **No performance upside.** Token generation on Vulkan/RADV was as fast or faster than the ROCm trial on our models, consistent with the community benchmarks cited above.

So the decision stands, now backed by direct measurement rather than the compatibility argument alone. Separately, the Vulkan pin was bumped from **b9570** to **b9755**: b9755 fixes the broken `libggml-vulkan.so` regression that affected b9592–~b9744.

### Update (2026-08): long-context prefill tradeoff noted, decision unchanged

Community measurements ([Strix Halo Wiki, lhl, Nov 2025](https://llm-tracker.info/_TOORG/Strix-Halo)) on gfx1151 show the picture flips at deep context: at ~130k tokens, ROCm prefill (`pp512`) ran ~2.4x faster than Vulkan/RADV (40.6 vs 17.2 t/s on a 30B-A3B model), while RADV stayed ahead on generation (`tg128`) until a tuned ROCm build closed the gap. Both Backends here run `--ctx-size 262144`, i.e. squarely in the regime where that prefill gap would matter most (long agent/RAG prompts).

This doesn't change the decision: the idle-power measurement above (ROCm/HIP holds the iGPU at ~40 W even fully idle, vs ~13 W for Vulkan/RADV) is a standing cost paid on every hour the Backend is up, not just during inference, and this stack runs the Backends continuously rather than on-demand. A prefill win only pays off if time-to-first-token at deep context is an actual observed pain point — it isn't currently. If that changes, the cheapest way to validate is a second container on a separate port (`ghcr.io/ggml-org/llama.cpp:server-rocm`, needs `/dev/kfd` in addition to `/dev/dri`) run side-by-side for A/B measurement, not a wholesale backend switch.

### Update (2026-08-28): side-by-side A/B run — decision unchanged, both prior grounds obsolete

The side-by-side A/B suggested at the end of the previous update was run on `b10666`, via the commented-out `llama-chat-rocm` service in `docker-compose.backends.yml` (port 8011, `/dev/kfd` added). **Both arguments the decision previously rested on failed to reproduce.** The decision still stands, but on a new and better-measured ground.

Setup: identical model on both arms (`bartowski/Ornith-1.5-35B-A3B-GGUF` Q4_K_M, a 35B-A3B MoE), identical build (`b10666-4e97ac86e`), identical per-slot context (131072 = `--ctx-size 524288` / `--parallel 4`). Measured through `/completions` with `cache_prompt=false` and `temp=0`, after warmup, one arm at a time.

**Prefill — the 2.4x community figure does not reproduce.** ROCm leads, but by single-to-low-double digits, not 140%:

| prompt tokens | Vulkan | ROCm | delta |
| --- | --- | --- | --- |
| 7,800 | 973.8 t/s | 1014.6 t/s | +4.2% |
| 33,760 | 728.1 t/s | 796.7 t/s | +9.4% |
| 99,140 | 427.7 t/s | 489.1 t/s | +14.4% |

At 99k that is 202.7 s vs 231.8 s time-to-first-token — 29 s saved. RADV has evidently closed most of the prefill gap since the Nov 2025 measurements cited above.

**Generation — Vulkan leads, and the gap widens with context**, i.e. exactly opposite to the prefill trend:

| context | Vulkan | ROCm | delta |
| --- | --- | --- | --- |
| ~70 | 57.7 t/s | 52.9 t/s | −8.3% |
| 7,800 | 55.2 t/s | 50.2 t/s | −9.1% |
| 33,760 | 46.8 t/s | 37.5 t/s | −19.9% |
| 99,140 | 39.1 t/s | 30.1 t/s | −23.0% |

**Idle power — does not reproduce.** With a model resident in the ROCm container, the iGPU sat at its *lowest* DPM state (600 MHz), 0% busy, ~15 W, stable across sampling. The 2026-07 claim that HIP pins the iGPU at 2900 MHz / ~40 W whenever a model is loaded no longer holds on `b10666`; the HIP backend now releases the GPU context. This removes the argument that carried both previous updates.

**The replacement ground: efficiency under load.** Sampling GPU clock and package power during generation (400 tokens, 0.2 s interval):

| | tg | sclk mean | busy% | package power |
| --- | --- | --- | --- | --- |
| Vulkan | 47.8 t/s | 2624 MHz | 83% | 101.1 W |
| ROCm | 40.3 t/s | 2663 MHz | 85% | 115.9 W |

That works out to **0.47 vs 0.35 tokens/joule — ROCm needs ~26% more energy per token while also being slower.** Note the iGPU clocks *slightly higher* under ROCm at comparable busy%, so this is not the CPU stealing the shared Strix Halo TDP budget: at equal clock and equal occupancy ROCm simply yields fewer tokens, which points at GPU-side kernel efficiency for this MoE model.

**A related CPU finding.** CPU time per generated token, measured as a cgroup `usage_usec` delta across a 300-token generation, is **8.25 ms (Vulkan) vs 45.49 ms (ROCm)** — 5.5x, or 0.39 vs 1.86 continuously busy cores. The shape (sustained busy cores while the GPU is the bottleneck) suggests HIP runtime spin-waiting on synchronisation. The extra ~1.5 cores account cleanly for the ~15 W package-power delta above.

[ggml-org/llama.cpp#25700](https://github.com/ggml-org/llama.cpp/issues/25700) is a partial but incomplete explanation: it reports the input embedding layer (`GET_ROWS(tok_embd, inp_tokens)`) pinned to CPU by a hard-coded policy in `src/llama-model.cpp` despite `-ngl 999`, running once per forward pass and so hitting generation far harder than prefill. But that policy is backend-agnostic and cannot by itself explain a 5.5x *difference* between backends, so most of the ROCm CPU cost is HIP sync overhead rather than the input layer. Worth noting anyway: that issue measures 41.33 t/s before its proposed fix and 47.24 t/s after, against our 41.3 t/s (ROCm) and 47.8 t/s (Vulkan) — if it lands, ROCm generation could reach roughly where Vulkan already is.

**Decision: unchanged, stay on Vulkan/RADV.** Not for idle power and not for lack of a prefill gap — both of those are now dead arguments — but because ROCm is slower at generation across every context depth tested *and* costs ~26% more energy per token. The prefill win is real but modest, and this stack's workload is not prefill-bound.

**Revisit when:** ggml-org/llama.cpp#25700 is fixed. It should reduce both generation latency and CPU load, and its own numbers suggest it could erase the generation deficit — which is the only thing currently keeping ROCm out. Re-run the same A/B then.

**Caveats on these numbers.** Both containers were resident simultaneously (~20 GB mlock'd each), so absolute figures are depressed by memory pressure; the relative comparison should hold since the idle arm was not computing. Each figure is a single run, not an average over repeats. Idle power was likewise measured with both models resident, so ROCm-only idle was not isolated — but the prior claim was that HIP pins the clock whenever *any* model is loaded, and it plainly did not.

## ADR 0005 — Dense Qwen3.6-27B, not MoE, as the coder Backend model

`llama-coder` runs `Qwen3.6-27B` (dense, all 27B parameters active per token), not an MoE model, despite this stack's own hardware research favoring MoE on bandwidth-limited Strix Halo: ~3B-active MoE models are expected around 85–100 t/s generation here, a dense model in the 27–32B class more like 10–15 t/s. Two MoE coder candidates exist: `Qwen3-Coder-30B-A3B` (not downloaded) and `Qwen3-Coder-Next` (80B total / ~3B active, already on disk, 47 GB, native MTP, hybrid Gated DeltaNet/Gated Attention).

SWE-bench Verified, from each model's own Hugging Face card (checked 2026-08):

| Model | Type | SWE-bench Verified |
|---|---|---|
| Qwen3.6-27B (active) | dense, 27B | 77.2% |
| Qwen3-Coder-Next | MoE, 80B / ~3B active | 70.6% |
| Qwen3-Coder-30B-A3B | MoE, 30B / 3B active | 51.9% |

The dense model scores highest despite the throughput disadvantage, for two reasons: it's simply a newer, better-trained model (Apr 2026) than either Coder-labeled MoE, and it ships its own MTP head (`-MTP-GGUF`, wired via `--spec-type draft-mtp` in the compose file already) — self-speculative decoding claws back a meaningful chunk of the bandwidth penalty a plain dense model would otherwise pay, so the real-world throughput gap to Qwen3-Coder-Next is smaller than the raw architecture numbers above suggest. The quality gap (77.2 vs 70.6) is real and matters more here: this Backend is used for agentic coding, where a wrong tool call or a subtly broken diff costs more than a few extra seconds of latency.

Revisit if agent latency, not quality, becomes the actual observed bottleneck. `Qwen3-Coder-Next` is already on disk as a drop-in `CODER_MODEL_FILE` swap for that case (see `.env.example`); no download needed to try it.

### Update (2026-09-12): live config currently runs MoE, unreconciled with this ADR

`CODER_MODEL_FILE` is currently set to `Qwen3.6-35B-A3B` (MoE, ~3B active), not the dense model this ADR argued for. No SWE-bench re-comparison or written rationale exists yet for that switch — this note exists so the drift is visible, not to relitigate the decision. Anecdotally, multimodal (vision + quantized KV) has held up better on this smaller MoE model than it did on the large dense one. Revisit and either re-affirm dense with updated numbers or update this ADR properly if the MoE pick is meant to stick.

## ADR 0007 — Redis for Gateway shared state, even though this runs a single worker

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

### What this does not fix: the response cache

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

If cache hit rates (litellm's own `litellm_*cache*` metrics, e.g. via its
`/metrics` endpoint) still look near zero, the honest move is `cache: false`,
not a third cache backend. Redis stays either way; the two decisions are
independent.

### Consequences, most surprising first

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

## ADR 0008 — Qwen2.5-Coder-7B, not Codestral-22B, as the FIM Backend model

`llama-fim` swaps back from `Codestral-22B-v0.1` (Q4_K_M, ~13 GB) to
`Qwen2.5-Coder-7B-base` (Q6_K, ~6.3 GB). Codestral's infill quality was
real, but FIM is felt directly while typing — every keystroke pause is
visible to the user — unlike `llama-chat`/`llama-coder`, where a few extra
seconds of agentic latency is tolerable. On this bandwidth-limited Strix
Halo iGPU, a 22B model simply can't hit the response times autocomplete
needs; the same throughput-vs-parameter-count argument from ADR 0005
applies here, more acutely, since latency tolerance for FIM is much lower
than for chat/agentic coding.

Qwen2.5-Coder-7B-base is a reasonable middle ground between Codestral-22B
and the original `Qwen2.5-Coder-1.5B-base` fallback that came before it —
roughly a third of Codestral's parameters, and natively FIM-trained on
Qwen's own pretraining data rather than adapted after the fact.

One thing reverts with the model swap: Qwen2.5-Coder uses llama.cpp's
default Prefix-Suffix-Middle FIM token order (`<|fim_prefix|>`/
`<|fim_suffix|>`/`<|fim_middle|>`), so `--spm-infill` is removed from
`docker-compose.backends.yml` — it's back to the same order the original
1.5B model used, before Codestral required flipping it for its native
Suffix-Prefix-Middle order. Any Client-side FIM prompt template configured
for Codestral's `[SUFFIX]{suffix}[PREFIX]{prefix}` order needs to be
flipped back too. `--ctx-size` stays at 8192 and the healthcheck
`start_period` drops back to 90s (Codestral's longer mlock load no longer
needs the 300s bump).

Revisit if 7B infill quality proves too weak in practice — `Qwen2.5-Coder-3B-base`
is a faster middle step before falling back further to 1.5B; Codestral-22B
remains a drop-in higher-quality/higher-latency rollback if a faster host
ever runs this Backend.

### Update (2026-09-12): live config currently runs MiniCPM5-2B, unreconciled with this ADR

`FIM_MODEL_FILE` is currently set to `MiniCPM5-2B`, not the Qwen2.5-Coder-7B-base this ADR settled on. No written rationale exists yet for that switch — this note exists so the drift is visible, not to relitigate the decision. Revisit and either re-affirm Qwen2.5-Coder-7B or update this ADR properly if MiniCPM5-2B is meant to stick.
