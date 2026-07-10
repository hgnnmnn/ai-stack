# Vulkan (RADV) as the GPU backend for the LLM Backends

`llama-chat` and `llama-coder` use llama.cpp's Vulkan backend via Mesa's RADV driver, not ROCm. ROCm is currently unusable due to a library version mismatch (ROCm 6 expected by available llama.cpp images vs. system ROCm 7.1.1). Beyond that, community benchmarks for Strix Halo (gfx1151, see [amd-strix-halo-toolboxes](https://kyuz0.github.io/amd-strix-halo-toolboxes/)) show ROCm 7.2.3 and other ROCm builds offer no meaningful performance advantage over Vulkan when serving Qwen models — so this choice isn't expected to change even if the compatibility issue gets resolved. ComfyUI's GPU backend during Imagegen Mode is a separate, still-open question (see `CONTEXT.md`, "Imagegen Mode").

## Update (2026-07): ROCm trialled directly, decision reaffirmed

The version-mismatch argument above turns out to be sidesteppable: the official `ghcr.io/ggml-org/llama.cpp:server-rocm` image bundles ROCm 7.2.1 and compiles `gfx1151` into `AMDGPU_TARGETS`, so it runs without touching the host's ROCm 7.1.1. It was trialled on `server-rocm-b9744` and rejected on two measured grounds:

1. **Idle power.** The HIP backend keeps a GPU context resident whenever a model is loaded, so the iGPU never clock-gates — it sits at its top DPM state (2900 MHz, ~40 W) at idle, with all slots idle and 0% CPU. Vulkan/RADV releases the GPU between submissions and idles down to ~13 W. This is inherent to ROCm/HIP, not a misconfiguration, and lemonade-sdk's dedicated gfx1151 builds would behave the same.
2. **No performance upside.** Token generation on Vulkan/RADV was as fast or faster than the ROCm trial on our models, consistent with the community benchmarks cited above.

So the decision stands, now backed by direct measurement rather than the compatibility argument alone. Separately, the Vulkan pin was bumped from **b9570** to **b9755**: b9755 fixes the broken `libggml-vulkan.so` regression that affected b9592–~b9744.
