# Vendored: xocialize/z-image-swift (core target only)

- Upstream commit: `eadca879078601d6787ad9e9ee7759def8bdcd56` (2026-10-11)
- License: MIT (see `LICENSE`)
- Omitted: the MLXEngine wrapper (mlx-engine-swift) and the CLI.

## Local changes (`NIS-PATCH`)

1. `Pipeline.generate` / `ZImageGenerator.generate` / `generateImg2Img`: optional
   `onLatents(done, total, x̂₀)` called after each denoise step with the denoised estimate
   `x̂₀ = x − σ·v` (fp32 `[1, C, H/8, W/8]`; equals the final latents on the last step), used by
   Native Image Studio for live previews. Default `nil`
   keeps the upstream behaviour.
