# Codestral-22B, not a tiny base model, for the FIM Backend

`llama-fim` swaps from `Qwen2.5-Coder-1.5B-base` (Q8_0, ~1.6 GB) to
`Codestral-22B-v0.1` (Q4_K_M, ~13 GB). The previous choice optimized purely
for latency — a 1.5B base model completes in single-digit milliseconds of
prompt processing — but produced noticeably weaker infills on anything past
trivial single-line completions. Codestral is Mistral's model built and
tuned specifically for fill-in-the-middle, at a size this host's unified
memory can still serve alongside `llama-chat`/`llama-coder` without
contention (mlock load takes longer, hence the healthcheck `start_period`
bump to 300s already in place before this swap).

Two things follow directly from the model swap, not from general FIM
tuning:

- **`--spm-infill`.** Codestral's tokenizer has dedicated `[PREFIX]` /
  `[SUFFIX]` / `[MIDDLE]` control tokens (confirmed by inspecting the GGUF's
  `tokenizer.ggml.tokens`/`token_type`), but no `tokenizer.ggml.fim_*_id`
  metadata — llama.cpp falls back to matching these token strings, which is
  the same mechanism `--spm-infill` toggles between Prefix-Suffix-Middle
  (llama.cpp's default, and what the previous Qwen2.5-Coder FIM model used)
  and Codestral's native Suffix-Prefix-Middle order. Without this flag,
  `/infill` and any hand-built raw completion prompt would present prefix
  and suffix in the order the model wasn't trained on, degrading completions
  silently rather than erroring.
- **`--ctx-size` 4096 → 8192.** The 1.5B model had little use for more
  context; Codestral's quality scales with how much surrounding code (other
  functions, imports) it can see, so the slot was doubled to actually
  exercise that.

This Backend still serves raw `/v1/completions`, not llama.cpp's `/infill`
endpoint (see README) — the editor/Client, not this stack, builds the FIM
prompt. Swapping models here means reconfiguring that Client's FIM template
from Qwen's `<|fim_prefix|>`/`<|fim_suffix|>`/`<|fim_middle|>` tags to
Codestral's `[SUFFIX]{suffix}[PREFIX]{prefix}` order — outside this repo's
scope, but easy to miss since the Backend itself won't complain about a
wrong prompt, it'll just infill badly.

Revisit if load time or steady-state memory pressure from running three
Backends at once (35B + 27B + 22B) becomes a problem in practice; the old
1.5B `FIM_MODEL_FILE` is left commented in `.env.example` as a fast
low-quality fallback.
