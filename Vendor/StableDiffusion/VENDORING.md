# Vendored: apple/ml-stable-diffusion (Swift package only)

- Upstream: https://github.com/apple/ml-stable-diffusion
- Commit: `ea2805dc1945be20561c77e5f6d1d9a5a637cda2` (2026-09-11)
- License: MIT (see `LICENSE.md`)
- Copied: `swift/StableDiffusion` (library). CLI and tests omitted.

## Local changes

1. Removed `StableDiffusion3Pipeline.swift`, `StableDiffusion3Pipeline+Resources.swift`,
   `TextEncoderT5.swift`, `tokenizer/T5Tokenizer.swift`. They are the only code importing
   `swift-transformers`, which upstream pins `exact: "0.1.8"` — incompatible with
   Flux2Core's `swift-transformers >= 1.3.3` in one SwiftPM graph. SD 1.x/2.x/XL use the
   bundled `BPETokenizer` and are unaffected.

See `docs/DECISIONS.md` (D-004).
2. `tokenizer/BPETokenizer+Reading.swift` (`NIS-PATCH`): strip a trailing `\r` from `merges.txt`
   lines. `LocalMuseAI/coreml-realvisxl-v5-lightning-6bit-v2` ships `merges.txt` with CRLF line
   endings; upstream kept the `\r` in the second symbol, so no BPE merge ever matched, prompts were
   tokenized almost per character and the generated image ignored the prompt.
