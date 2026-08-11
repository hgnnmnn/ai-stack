# Dense Qwen3.6-27B, not MoE, as the coder Backend model

`llama-coder` runs `Qwen3.6-27B` (dense, all 27B parameters active per token), not an MoE model, despite this stack's own hardware research favoring MoE on bandwidth-limited Strix Halo: ~3B-active MoE models are expected around 85–100 t/s generation here, a dense model in the 27–32B class more like 10–15 t/s. Two MoE coder candidates exist: `Qwen3-Coder-30B-A3B` (not downloaded) and `Qwen3-Coder-Next` (80B total / ~3B active, already on disk, 47 GB, native MTP, hybrid Gated DeltaNet/Gated Attention).

SWE-bench Verified, from each model's own Hugging Face card (checked 2026-08):

| Model | Type | SWE-bench Verified |
|---|---|---|
| Qwen3.6-27B (active) | dense, 27B | 77.2% |
| Qwen3-Coder-Next | MoE, 80B / ~3B active | 70.6% |
| Qwen3-Coder-30B-A3B | MoE, 30B / 3B active | 51.9% |

The dense model scores highest despite the throughput disadvantage, for two reasons: it's simply a newer, better-trained model (Apr 2026) than either Coder-labeled MoE, and it ships its own MTP head (`-MTP-GGUF`, wired via `--spec-type draft-mtp` in the compose file already) — self-speculative decoding claws back a meaningful chunk of the bandwidth penalty a plain dense model would otherwise pay, so the real-world throughput gap to Qwen3-Coder-Next is smaller than the raw architecture numbers above suggest. The quality gap (77.2 vs 70.6) is real and matters more here: this Backend is used for agentic coding, where a wrong tool call or a subtly broken diff costs more than a few extra seconds of latency.

Revisit if agent latency, not quality, becomes the actual observed bottleneck. `Qwen3-Coder-Next` is already on disk as a drop-in `CODER_MODEL_FILE` swap for that case (see `.env.example`); no download needed to try it.
