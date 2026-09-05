# Qwen2.5-Coder-7B, not Codestral-22B, as the FIM Backend model

`llama-fim` swaps back from `Codestral-22B-v0.1` (Q4_K_M, ~13 GB, ADR 0006)
to `Qwen2.5-Coder-7B-base` (Q6_K, ~6.3 GB). Codestral's infill quality was
real, but FIM is felt directly while typing — every keystroke pause is
visible to the user — unlike `llama-chat`/`llama-coder`, where a few extra
seconds of agentic latency is tolerable. On this bandwidth-limited Strix
Halo iGPU, a 22B model simply can't hit the response times autocomplete
needs; the same throughput-vs-parameter-count argument from ADR 0005
applies here, more acutely, since latency tolerance for FIM is much lower
than for chat/agentic coding.

Qwen2.5-Coder-7B-base is a reasonable middle ground between Codestral-22B
and the original `Qwen2.5-Coder-1.5B-base` fallback (ADR 0006 noted the
1.5B model's infills got noticeably weaker past trivial single-line
completions) — roughly a third of Codestral's parameters, and natively
FIM-trained on Qwen's own pretraining data rather than adapted after the
fact.

One thing reverts with the model swap: Qwen2.5-Coder uses llama.cpp's
default Prefix-Suffix-Middle FIM token order (`<|fim_prefix|>`/
`<|fim_suffix|>`/`<|fim_middle|>`), so `--spm-infill` is removed from
`docker-compose.backends.yml` — it's back to the same order the original
1.5B model used, before Codestral required flipping it (see ADR 0006 for
why that flag existed). Any Client-side FIM prompt template configured for
Codestral's `[SUFFIX]{suffix}[PREFIX]{prefix}` order needs to be flipped
back too. `--ctx-size` stays at 8192 and the healthcheck `start_period`
drops back to 90s (the 300s bump in ADR 0006 was specifically to cover
Codestral's longer mlock load).

Revisit if 7B infill quality proves too weak in practice — `Qwen2.5-Coder-3B-base`
is a faster middle step before falling back further to 1.5B; Codestral-22B
remains a drop-in higher-quality/higher-latency rollback if a faster host
ever runs this Backend.
