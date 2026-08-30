# KV cache quantization applied to the coder Backend only

Both Backends use flash attention, but only `llama-coder` runs with q8-quantized KV cache (k & v) to reach 128k–256k context. `llama-chat` keeps f16 KV cache at 65k context. Qwen3.6-35B-A3B uses a hybrid Gated DeltaNet/Gated Attention architecture with a vision encoder, and neither the model card nor llama.cpp document how KV cache quantization interacts with multimodal inference on this architecture — quantizing risks silently degrading or breaking vision capability. Revisit once this has been empirically validated.

## Update (2026-07-30): now applies to both Backends

`llama-chat` switched from Qwen3.6-35B-A3B to `Ornith-1.0-35B`, which has no vision encoder — the multimodal blocker above doesn't apply to it. Both `llama-chat` and `llama-coder` now run q8_0 KV cache (k & v) at `--ctx-size 262144`. The title stays as the historical record of the original per-Backend rationale; if `llama-chat` ever swaps back to a multimodal model, re-check this before quantizing its KV cache again.

## Update (2026-08-30): llama-chat is multimodal again, vision now enabled on both

`llama-chat` has since moved to `Ornith-1.5-35B-A3B` — an MoE/hybrid architecture with a vision encoder, same shape as the original Qwen3.6-35B-A3B this ADR was written about. Both Backends now run with `--mmproj` (Ornith-1.5-35B-A3B and Qwen3.8-27B each ship their own projector) while keeping q8_0 KV cache at `--ctx-size 262144`/`524288`. The original blocker — undocumented interaction between quantized KV and multimodal inference on a hybrid attention architecture — applies to `llama-chat` again and has still not been empirically validated. Watch for degraded image understanding specifically on `llama-chat`; if seen, try f16 KV there first before assuming the model/projector itself is at fault.

## Note (2026-08): f16 KV was fastest in one deep-context measurement elsewhere

A single (unverified) community measurement on a 122B-A10B MoE model found f16/f16 KV cache outperforming quantized KV at 131k context on gfx1151 hardware, contradicting the "quantize KV to buy context headroom" assumption this ADR relies on. Not yet reproduced on our models/build. If prompt-processing or generation speed at deep context ever looks off, benchmark q8_0 vs f16 KV directly with `llama-bench -d 0,65536,131072,262144` before assuming the quantized cache is a free win.
