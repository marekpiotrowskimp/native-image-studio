# Native Image Studio

A native macOS app (Swift 6, SwiftUI) for local image generation and editing on Apple Silicon.
Works fully offline: no Python, no ComfyUI, no local server. Inference runs on MLX (FLUX.2 Klein) and Core ML (SDXL).

## Features

- Text-to-image and image editing with FLUX.2 Klein (MLX) and SDXL (Core ML)
- Live preview while generating (predicted image x̂₀ at every step — approximate or decoded by the VAE)
- Gallery with folders (subdirectories on disk), moving selected images, deleting from the preview
- Models tab: download and select image models
- Prompt assistant: a local LLM that writes prompts in the format of the selected image model
- Job queue with per-stage timings logged to the unified log

## Requirements

- macOS 15+ on Apple Silicon (target machine: M4 Pro, 24 GB)
- Xcode 26.2 (Swift 6.2) + the Metal Toolchain component: `xcodebuild -downloadComponent MetalToolchain`

## Build and test

```sh
swift build                                # compile (Swift 6, strict concurrency)
swift test --skip EngineIntegrationTests   # unit tests (no GPU)
scripts/build-cli.sh                       # nis-poc CLI (xcodebuild — compiles the Metal shaders for MLX)
scripts/integration-tests.sh               # EngineIntegrationTests with real inference (requires weights)
scripts/build-app.sh                       # .build/NativeImageStudio.app
```

UI self-check (end-to-end scenario + window screenshots):

```sh
NIS_SELFCHECK_DIR=/tmp/nis NIS_SELFCHECK_INPUTS=a.png:b.png .build/NativeImageStudio.app/Contents/MacOS/NativeImageStudio
```

Job stage timings (queue, unload, load, first step):

```sh
log show --last 10m --predicate 'subsystem == "NativeImageStudio"' --style compact
```

`swift build` does not compile Metal shaders, so everything that runs MLX is built with `xcodebuild`
(see `docs/DECISIONS.md`, D-003).

## Models

`nis-poc download` fetches FLUX.2 Klein 4B (bf16 transformer quantized to int4 on the fly, VAE, Qwen3-4B 4-bit text encoder)
into `~/Library/Application Support/NativeImageStudio/MLXModels` (not `~/Library/Caches`, which may be purged).
Z-Image: `scripts/download-zimage.sh` or the Download button in the Models tab. Weights are not committed.

## Prompt assistant

Qwen3-8B Abliterated v2 (MLX, 4.1 GB) writes prompts in the format of the selected image model. Download it from the Models tab
or with `nis-poc prompt-download`; try it from the command line: `nis-poc prompt --model <id> --prompt "scene idea"`.

## Documentation (in Polish)

- `docs/PLAN.md` — plan and architecture
- `docs/DECISIONS.md` — decisions (library choice, vendoring, toolchain)
- `docs/PROGRESS.md` — milestone reports, test results and measurements
- `docs/bench/*.jsonl` — raw measurements
- `docs/manifests/` — sample model manifests (e.g. Klein 9B, unverified)

## License

Code: MIT — see [LICENSE](LICENSE). Model weights are not included and are subject to their own licenses.
