# Vendored: flux-2-swift-mlx

- Upstream: https://github.com/VincentGourbin/flux-2-swift-mlx
- Commit: `315c27e83187909bc5e1f880b4850918342d891b` (tag v3.1.0, 2026-09-12)
- License: MIT (see `LICENSE`)
- Modules copied: `FluxTextEncoders`, `Flux2Core`, `Flux2Chains` (CLI, app, Gemma VLM omitted)

## Local patches (grep `NIS-PATCH`)

1. `Package.swift`: `mlx-swift` pinned to `exact: "0.31.4"` (upstream 0.31.6 requires
   swift-tools 6.3; the target machine has Xcode 26.2 / Swift 6.2.3).
2. `Flux2Core/Pipeline/Flux2Pipeline.swift`: added `cancellationHandler` and
   `checkGenerationCancelled()`; called at the start of every denoising step (all loops)
   and before VAE decode. Throws `Flux2Error.generationCancelled` after
   synchronizing the GPU stream, so the caller observes a safe stop point.

See `docs/DECISIONS.md` (D-001, D-002) for the reasoning.

3. `Flux2Core/Pipeline/Flux2Pipeline.swift`: added `preload()` — loads transformer, VAE (and
   the text encoder when `keepTextEncoderLoaded`) up front. Upstream loads lazily inside the
   first `generate*`, which makes cold load indistinguishable from generation time.
4. `Flux2Core/Pipeline/Flux2Pipeline.swift`: added `decodePackedLatentsForPreview(_:height:width:)`
   (`NIS-PATCH`) — the checkpoint decode as a public method, so the host can decode the denoised
   estimate x̂₀ for live previews instead of the noisy step latents.
