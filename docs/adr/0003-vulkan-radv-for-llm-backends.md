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
