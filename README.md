# Native Image Studio

Natywna aplikacja macOS (Swift 6, SwiftUI) do lokalnego generowania i edycji obrazów na Apple Silicon.
Działa offline: bez Pythona, ComfyUI i lokalnego serwera. Inferencja przez MLX (FLUX.2 Klein) i Core ML (SDXL).

## Wymagania
- macOS 15+ na Apple Silicon (docelowo M4 Pro, 24 GB)
- Xcode 26.2 (Swift 6.2) + komponent Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`

## Budowanie i testy
```sh
swift build                    # kompilacja (Swift 6, strict concurrency)
swift test --skip EngineIntegrationTests   # testy jednostkowe (bez GPU)
scripts/build-cli.sh           # nis-poc (xcodebuild — kompiluje shadery Metal dla MLX)
scripts/integration-tests.sh   # EngineIntegrationTests z realną inferencją (wymaga wag)
scripts/build-app.sh           # .build/NativeImageStudio.app
```
Samotest UI (scenariusz end-to-end + zrzuty okna): `NIS_SELFCHECK_DIR=/tmp/nis NIS_SELFCHECK_INPUTS=a.png:b.png .build/NativeImageStudio.app/Contents/MacOS/NativeImageStudio`
Czasy etapów zadań (kolejka, zwalnianie, ładowanie, pierwszy krok): `log show --last 10m --predicate 'subsystem == "NativeImageStudio"' --style compact`.
`swift build` nie kompiluje shaderów Metal, więc wszystko, co uruchamia MLX, budujemy przez `xcodebuild`
(patrz `docs/DECISIONS.md`, D-003).

## Modele
`nis-poc download` pobiera FLUX.2 Klein 4B (transformer bf16 kwantyzowany w locie do int4, VAE, enkoder Qwen3-4B 4-bit)
do `~/Library/Application Support/NativeImageStudio/MLXModels` (nie do `~/Library/Caches`, które bywa czyszczone). Z-Image: `scripts/download-zimage.sh` lub przycisk Pobierz w zakładce Modele. Wagi nie są commitowane.

## Asystent promptów
Qwen3-8B Abliterated v2 (MLX, 4,1 GB) pisze prompty w formacie wybranego modelu obrazów. Pobieranie: zakładka Modele
albo `nis-poc prompt-download`; test z linii poleceń: `nis-poc prompt --model <id> --prompt "pomysł na scenę"`.

## Dokumentacja
- `docs/PLAN.md` — plan i architektura
- `docs/DECISIONS.md` — decyzje (wybór bibliotek, vendoring, toolchain)
- `docs/PROGRESS.md` — raporty etapów, wyniki testów i pomiary
- `docs/bench/*.jsonl` — surowe pomiary
- `docs/manifests/` — przykładowe manifesty modeli (np. Klein 9B, niezweryfikowany)
