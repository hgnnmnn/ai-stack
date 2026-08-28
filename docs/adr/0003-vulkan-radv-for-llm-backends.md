# Vulkan (RADV) as the GPU backend for the LLM Backends

`llama-chat` and `llama-coder` use llama.cpp's Vulkan backend via Mesa's RADV driver, not ROCm. ROCm is currently unusable due to a library version mismatch (ROCm 6 expected by available llama.cpp images vs. system ROCm 7.1.1). Beyond that, community benchmarks for Strix Halo (gfx1151, see [amd-strix-halo-toolboxes](https://kyuz0.github.io/amd-strix-halo-toolboxes/)) show ROCm 7.2.3 and other ROCm builds offer no meaningful performance advantage over Vulkan when serving Qwen models — so this choice isn't expected to change even if the compatibility issue gets resolved. ComfyUI's GPU backend during Imagegen Mode is a separate, still-open question (see `CONTEXT.md`, "Imagegen Mode").

## Update (2026-07): ROCm trialled directly, decision reaffirmed

The version-mismatch argument above turns out to be sidesteppable: the official `ghcr.io/ggml-org/llama.cpp:server-rocm` image bundles ROCm 7.2.1 and compiles `gfx1151` into `AMDGPU_TARGETS`, so it runs without touching the host's ROCm 7.1.1. It was trialled on `server-rocm-b9744` and rejected on two measured grounds:

1. **Idle power.** The HIP backend keeps a GPU context resident whenever a model is loaded, so the iGPU never clock-gates — it sits at its top DPM state (2900 MHz, ~40 W) at idle, with all slots idle and 0% CPU. Vulkan/RADV releases the GPU between submissions and idles down to ~13 W. This is inherent to ROCm/HIP, not a misconfiguration, and lemonade-sdk's dedicated gfx1151 builds would behave the same.
2. **No performance upside.** Token generation on Vulkan/RADV was as fast or faster than the ROCm trial on our models, consistent with the community benchmarks cited above.

So the decision stands, now backed by direct measurement rather than the compatibility argument alone. Separately, the Vulkan pin was bumped from **b9570** to **b9755**: b9755 fixes the broken `libggml-vulkan.so` regression that affected b9592–~b9744.

## Update (2026-08): long-context prefill tradeoff noted, decision unchanged

Community measurements ([Strix Halo Wiki, lhl, Nov 2025](https://llm-tracker.info/_TOORG/Strix-Halo)) on gfx1151 show the picture flips at deep context: at ~130k tokens, ROCm prefill (`pp512`) ran ~2.4x faster than Vulkan/RADV (40.6 vs 17.2 t/s on a 30B-A3B model), while RADV stayed ahead on generation (`tg128`) until a tuned ROCm build closed the gap. Both Backends here run `--ctx-size 262144`, i.e. squarely in the regime where that prefill gap would matter most (long agent/RAG prompts).

This doesn't change the decision: the idle-power measurement above (ROCm/HIP holds the iGPU at ~40 W even fully idle, vs ~13 W for Vulkan/RADV) is a standing cost paid on every hour the Backend is up, not just during inference, and this stack runs the Backends continuously rather than on-demand. A prefill win only pays off if time-to-first-token at deep context is an actual observed pain point — it isn't currently. If that changes, the cheapest way to validate is a second container on a separate port (`ghcr.io/ggml-org/llama.cpp:server-rocm`, needs `/dev/kfd` in addition to `/dev/dri`) run side-by-side for A/B measurement, not a wholesale backend switch.

## Update (2026-08-28): side-by-side A/B run — decision unchanged, both prior grounds obsolete

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
