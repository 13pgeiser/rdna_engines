# AGENTS.md

## What this repo is
Launchers + shared shell for **local LLM inference servers on AMD hardware**
(RDNA GPU and Ryzen AI XDNA2 NPU). Engine source lives in gitignored
subdirectories that are re-cloned automatically if missing — never commit
changes into `hipfire/`, `llama.cpp/`, `radiance/`, `FastFlowLM/`, or
`OpenFlowLM-Next/`.

## Entry points
```
./run_hipfire.sh      # GPU (ROCm)
./run_llama_vulkan.sh # GPU (Vulkan)
./run_llama_rocm.sh   # GPU (ROCm)
./run_radiance.sh     # GPU (HIP)
./run_fastflowlm.sh   # NPU (XDNA2)
./run_openflowlm.sh   # NPU (XDNA2)
```
Each clones its engine, builds its Docker image, pulls the model
(idempotent), and serves an **OpenAI-compatible API** on port `9931`
(override with `PORT`). All share `common.sh`: the interactive model menu
(numeric arg, `*_MODEL` env override, or prompt) plus hardware preflights.

## Hardware preflights (enforced in common.sh, exit 1)
- GPU id from `/sys/class/drm/card0/device/device`: `0x1114` = gfx1152,
  `0x7551` = gfx1201. Any other id stops **every** engine, even if it might
  support the hardware.
- NPU engines (fastflowlm/openflowlm) run on gfx1152 only; GPU engines on
  both. NPU engines also require `/dev/accel/accel0`.

## Gotchas
- **Default port 9931 is shared by all launchers** — run one at a time, or set
  `PORT`. NPU engines are a separate process and can run alongside a GPU
  engine on a different port.
- **GPU engines** need `/dev/dri` and `video`/`render` group membership;
  hipfire and radiance also pass `/dev/kfd` + `--security-opt
  seccomp=unconfined`.
- **NPU engines** need the amdxdna driver + AMD XRT stack (`/dev/accel/accel0`)
  and run with `IPC_LOCK` + memlock ulimits. They compute on the NPU, not the
  GPU.
- **First NPU builds are slow** (OpenFlowLM compiles the mlir-aie toolchain).
  Caching markers: `OpenFlowLM-Next/.oflm-deb-built` (force with
  `OFLM_REBUILD=1`), `FastFlowLM/.flm-built` (force with `FLM_REBUILD=1`).
- hipfire builds with target `full` — `runtime` cannot be used because gfx1152
  is JIT-only and compiles kernels at serve time.
- Model locations: `/models/hipfire`, `/models/gguf` (llama.cpp),
  `/models/rad`, `/models/openflowlm`, `/models/fastflowlm`.

## Verify shell changes
`./check.sh` — runs `shfmt` (formats in place) and `shellcheck` over all
`*.sh` via docker. There is no test suite; this is the only check.
