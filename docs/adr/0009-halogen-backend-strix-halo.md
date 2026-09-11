# halogen-flash-server replaces llama.cpp, and three Backends become one

The stack drops llama.cpp entirely and runs
`ghcr.io/peonist-ai/halogen-flash-server:0.5.6` serving
`peonist-ai/halogen-qwen3.8-flash-next`. This is not a model swap in the
sense of ADR 0005 or ADR 0008 — the inference engine, the weight format,
the GPU API, and the number of Backends all change together, because the
engine only exists for one model and the model only loads in that engine.

## Why

halogen is written for exactly this machine: gfx1151, and nothing else —
the image hard-rejects any other architecture. Upstream measures ~1,424
tok/s prefill at 32k and 41.7 tok/s speculative decode on a single stream,
against 34.1 tok/s serial. ADR 0003 chose Vulkan/RADV over ROCm because
ROCm on this iGPU was the slower and more fragile path; halogen is ROCm
(it needs `/dev/kfd` on top of `/dev/dri`), but the comparison ADR 0003
made was between general-purpose runtimes. This is a kernel set written
for one GPU and one model, so that ADR's reasoning doesn't transfer, and
its conclusion is simply not in play here.

The prompt cache is the part that changes daily use more than the decode
rate does: a follow-up turn on a 100k-token conversation goes from ~88 s
to ~2 s, flat regardless of how long the conversation has grown.

## What this costs

**`llama-coder` and `llama-fim` are gone.** halogen serves one model and
has no infill endpoint, and the memory budget leaves no room for a second
Backend beside it. What the engine measures on this host once loaded:
68.0 GiB of weights locked in RAM, 7.2 GiB of KV pool, 21.1 GiB of working
memory, 96.3 GiB in all, leaving 16.8 GiB for everything else. Upstream
recommends a dedicated machine and it is right.

The pool is at 262144 rather than upstream's 524288 default because the
engine refuses the larger one at startup -- "524288 positions need ~35.0 GiB
(plus 1.5 of margin) and host RAM cannot spare it" -- and lowers itself. Note
that this guard is an estimate the engine's own measured figures contradict:
it calls 262144 "~27.8 GiB" while actually reserving 7.2 GiB for it, and the
pre-flight line puts a 524288 pool at 14.9 GiB. So 524288 may well fit here,
and the refusal may be a pessimistic guard rather than a real ceiling. Worth
testing, but 262144 is what runs today and the compose file says so rather
than naming a number that gets overridden.

So FIM autocomplete has no replacement in this stack. ADR 0008 chose a 7B
model precisely because autocomplete latency is felt on every keystroke;
a 41 tok/s reasoning model cannot stand in for it. Clients configured
against `llama-fim` will get a 400. This was an accepted trade, not an
oversight — if autocomplete turns out to matter more than the chat gain,
the rollback below restores it.

**`llama-chat` keeps its name.** Nothing behind it is llama.cpp anymore,
let alone Llama, which makes the Model ID a double misnomer. It stays
anyway: CONTEXT.md makes the Model ID the public contract, and renaming it
would break OpenWebUI and every Key issued to a friend for a swap that is
still on trial. `HALOGEN_MODEL_ID` is set to `llama-chat` so the Backend
reports the same id at `/v1/models` and in every response.

**The response cache is now dead weight.** `llama-fim`'s raw completions
were the one workload where exact-match caching might have paid off (see
the note in `litellm/config.yaml`, and f104cfd before it). With them gone,
expect the Prometheus `litellm_*cache*` series to sit at zero. That is an
argument for `cache: false`, not for a different cache backend.

**The engine is proprietary.** `LicenseRef-Peonist-EULA`: free to run,
commercially and over a network, redistributable only unmodified. The
weights themselves are Apache-2.0. There is no source to audit, and the
container gets `/dev/kfd`, `ipc: host`, `seccomp=unconfined` and unlimited
memlock. `HALOGEN_DOWNLOAD` is deliberately left unset so the container
makes no outbound connections at all; `make halogen-fetch` pulls the
weights instead.

## Consequences worth knowing

`max_input_tokens` in `litellm/config.yaml` is the full 262144, not a
slice of it. Unlike llama.cpp's `--ctx-size / --parallel` split, halogen's
KV positions come from one shared pool, so a single request may use the
whole native context; the pool, not the slot count, is the memory knob.

`free(1)` and `MemAvailable` will under-report by roughly the size of the
model: the kernel counts the locked weights as reclaimable file cache and
they are not reclaimable. `make stats` inherits that lie. The startup log
line "host memory left for everything else" is the authoritative one.

Vision exists but is off (`HALOGEN_VISION_TOWER`), so `supports_vision` is
false. Turning it on costs ~11.8 s of prefill for a 1920x1080 image, which
is a different proposition from `llama-coder`'s projector.

The `supports_*` flags are verified against `/health` (`make
halogen-health`), which is authoritative for the running build:
`parallel_tool_calls` true over a `qwen-xml` wire format, and
`reasoning_content` present on a real completion through the Gateway.

Decode measured on an idle engine, single stream, greedy, straight at the
Backend, `in_flight` confirmed 0 between runs:

| prompt shape | tok/s |
|---|---|
| counting to 60 | 45.2, 45.6, 49.2, 49.2, 51.7 |
| code | 37.0 |
| exposition | 30.3 |
| prose | 27.6, 35.2 |

Upstream quotes 41.3 speculative against 36.5 serial for one stream, and a
43.6 mean over ten shapes. This host lands across that band, predictable text
above it and prose below, which is what upstream says to expect: acceptance
follows how predictable the text is, so a single shape is not a number worth
quoting. Through the Gateway the same prompt cost about 0.8 s of wall clock
on top, with no effect on the drafter. No thermal component: 49 C and 42 W,
and the fastest counting run was the last one of a series.

Every line the engine logs is prefixed `mtp`, so the drafter is on. Its
`commit/round` figure is NOT an acceptance rate: it exceeds the 2.0 that a
depth-1 drafter would cap at, and moves inversely to throughput across these
shapes. Upstream names it once without defining it. Left uninterpreted.

Concurrency, measured the same way: 250 tokens of prose per stream, greedy,
all streams launched together, straight at the Backend.

| streams | per stream | total | wall clock |
|---|---|---|---|
| 1 | 32.0 tok/s | 32 tok/s | 8.7 s |
| 2 | 21.3, 22.7 | 44 tok/s | 12.7 s |
| 4 | 14.6 to 16.8 | 62 tok/s | 18.4 s |
| 6 | four ran, two queued | 54 tok/s | 27.8 s |

Four is the ceiling, and two limits happen to land on the same number:
`HALOGEN_KV_SLOTS` in the compose file, and `max_parallel_requests` in
`litellm/config.yaml`, which queues at the Gateway so nothing piles up inside
the engine. A fifth request waits, it does not fail — at six streams the last
two started about 15 s in, as slots came free. Raising the slot count is a
latency policy rather than a throughput one: upstream measures the total
flattening past eight.

The pool is the other limit, and it only bites on long contexts. A request
reserves prompt + `max_tokens` positions on admission, so the running set has
to fit 262144. Four requests at the 65536 budget cap were admitted at once
with `queued` never leaving 0 — that is the pool filled exactly. By the same
arithmetic (not measured) two 131k conversations fit, or one at the full
262144.

The per-stream column is the number to weigh, not the total: speculation is
off the moment a second stream is generating, which is why one stream is
faster for a single user than four are each. Upstream's own table reads 41.3,
55.2, 74.8 for one, two and four — higher throughout because it measures a
faster prompt shape than the prose used here; the shape of the curve matches.

## Rolling back

`docker-compose.backends.yml` is untouched, so the llama.cpp stack is a
`git checkout main` away, and the three GGUF files are still in
`MODELS_DIR`. The only thing that does not come back on its own is disk:
`HALOGEN_MODELS_DIR` holds ~127 GB.
