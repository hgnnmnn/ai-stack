# KV cache quantization applied to the coder Backend only

Both Backends use flash attention, but only `llama-coder` runs with q8-quantized KV cache (k & v) to reach 128k–256k context. `llama-qwen35` keeps f16 KV cache at 65k context. Qwen3.6-35B-A3B uses a hybrid Gated DeltaNet/Gated Attention architecture with a vision encoder, and neither the model card nor llama.cpp document how KV cache quantization interacts with multimodal inference on this architecture — quantizing risks silently degrading or breaking vision capability. Revisit once this has been empirically validated.
