# AGENTS.md

## What this repo is
Root orchestration for **two AMD RDNA / local LLM inference servers**. The actual
source lives in two git-cloned subdirectories that are **gitignored** — do not
try to commit changes into `hipfire/` or `llama.cpp/`; those are upstream clones
and re-clone automatically if missing.

- `hipfire/` — Rust + HIP + Redline inference server (ROCm)
- `llama.cpp/` — C++ llama.cpp with a Vulkan server build

## Run the servers (entrypoints)
```
./run_hipfire.sh      # ROCm server, model qwen3.6:35b-a3b, max-seq 262144
./run_llama_cpp.sh    # Vulkan server, model Ornith-1.5-35B-Q4_K_M.gguf
```
Each builds its Docker image, fetches the model, and runs the serve command.

## Gotchas
- **Both scripts bind port `9931`. Run only one at a time** — starting the other
  will fail to bind.
- **GPU prerequisites (RDNA AMD):** need `/dev/kfd` + `/dev/dri` (`llama.cpp` uses
  `/dev/dri`), the `video` and `render` group memberships, and `--security-opt
  seccomp=unconfined` for hipfire. Vulkan (llama.cpp) uses `/dev/dri`.
- **Model locations:** hipfire → `/models/hipfire`, llama.cpp → `/models/gguf`.
  Scripts pull/download idempotently.
- hipfire serves an **OpenAI-compatible API** (e.g. `/v1/chat/completions`).
- hipfire builds with target `full` (JIT allowed); ROCm 10.1 on Ubuntu 26.04
  (target `runtime` ships indexed packs + runtime libs only).

## Build targets (from the sub-clones)
- hipfire: `docker build -f hipfire/Containerfile --target full -t local/hipfire:full hipfire`
- llama.cpp: `docker build -f llama.cpp/.devops/vulkan.Dockerfile --target server -t local/llama.cpp:server-vulkan llama.cpp`

## Environment notes
- hipfire ships models at run time (never baked into the image) and drops from
  root to uid 1000 after granting device groups.
- hipfire GPU arches: `gfx1100 gfx1151 gfx1201`; ROCm package `10.1.0`.
