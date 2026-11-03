# Decyzje architektoniczne i technologiczne

Format: data · decyzja · powód · konsekwencje. Najnowsze na dole.

---

## D-001 · 2026-10-24 · Flux2Core (flux-2-swift-mlx) jako fundament silnika MLX

**Zweryfikowano (stan na 2026-10-24):**

| Kryterium | flux-2-swift-mlx (VincentGourbin) | vmlx-flux (jjang-ai) |
|---|---|---|
| Utrzymanie | v3.1.0, 2026-09-11, ostatni push 2026-09-12 | ostatni commit 2026-04-13 |
| Licencja | MIT | **brak** („TBD (likely MIT)” w README) |
| Wymagania | macOS 15+, Swift tools 6.0, mlx-swift **exact 0.31.6** | tools 5.10, fork `osaurus-ai/mlx-swift` + **lokalna ścieżka `../vmlx-swift-lm`** |
| Bez Pythona w runtime | tak (czysty Swift + MLX, tokenizer przez swift-transformers) | tak, ale… |
| Stan implementacji | pełny pipeline T2I/I2I, LoRA, inpainting (RePaint chain) | wg własnego PROGRESS.md: enkodery tekstu to „zero-tensor stubs”, QwenImage/Edit to stuby, RoPE z TODO |
| Format wag | safetensors z HF (`black-forest-labs/FLUX.2-klein-4B`, bf16) + kwantyzacja „w locie” (int4/qint8) | safetensors/JANG |
| Tryby edycji (z kodu) | I2I „conditioning”: **1–3 obrazy referencyjne** (`guard images.count <= 3`), opcjonalnie `initLatents + strength` (img2img), `Flux2MaskedInpaintingChain` (maska) | deklarowane, niezaimplementowane |

**Decyzja:** Flux2Core jest backendem MLX. vmlx-flux odrzucony: brak licencji, nie da się go zbudować samodzielnie (zależność `path: "../vmlx-swift-lm"`), a kluczowe komponenty to stuby.

## D-002 · 2026-10-24 · Vendoring Flux2Core zamiast zależności zdalnej

**Problem 1 — toolchain.** mlx-swift ≥ 0.31.5 ma `swift-tools-version: 6.3`. Na maszynie docelowej jest Xcode 26.2 / Swift 6.2.3, więc upstreamowy pin `exact: "0.31.6"` się nie rozwiązuje. 0.31.4 to najnowsze wydanie z tools 5.12.

**Problem 2 — anulowanie.** Flux2Core nie sprawdza anulowania w pętli odszumiania (brak `Task.isCancelled`/`checkCancellation` w całym module; `onProgress` i `onStep` są nie-rzucające). Wymaganie: anulowanie między krokami inferencji.

**Decyzja:** kopia modułów `FluxTextEncoders`, `Flux2Core`, `Flux2Chains` z commita `315c27e` (v3.1.0) w `Vendor/Flux2Swift` (licencja MIT zachowana), z dwiema zmianami opisanymi w `Vendor/Flux2Swift/VENDORING.md`:
1. mlx-swift przypięty do `exact: "0.31.4"`,
2. `Flux2Pipeline.cancellationHandler` + `checkGenerationCancelled()` wywoływane na początku każdego kroku odszumiania (3 pętle + krok 0 ścieżki KV) i przed dekodowaniem VAE (oznaczone `NIS-PATCH`).

Ostrzeżenia kompilatora w kodzie vendorowanym są wyciszone (`-suppress-warnings`) — wymaganie „zero ostrzeżeń” dotyczy kodu aplikacji. Po aktualizacji Xcode do 26.4+ można wrócić do upstreamu i zgłosić patch anulowania jako PR.

## D-003 · 2026-10-24 · Budowanie: `swift build` kompiluje, runtime MLX wymaga `xcodebuild`

SwiftPM z linii poleceń nie kompiluje shaderów Metal (README mlx-swift). `swift build`/`swift test` służą do kompilacji i testów jednostkowych (bez GPU). Narzędzie CLI i `EngineIntegrationTests` uruchamiane są z buildu `xcodebuild`, który dołącza `mlx.metallib` (skrypt `scripts/integration-tests.sh`).

## D-004 · 2026-10-24 · Core ML: apple/ml-stable-diffusion dołączony bez SD3

**Zweryfikowano:** MIT, ostatni commit 2026-09-11 (`ea2805d`), macOS 13+/tools 5.8. SDXL obsługuje T2I i img2img
(`startingImage` + `strength`, wymaga `VAEEncoder.mlmodelc`), brak ControlNet dla SDXL, brak inpaintingu
(`// case inPainting` zakomentowane). Inferencja bez Pythona; zasoby muszą być wcześniej skonwertowane.
`progressHandler` zwracający `false` przerywa pętlę → naturalny punkt anulowania per krok.

**Problem:** pakiet przypina `swift-transformers exact: "0.1.8"`, Flux2Core wymaga `>= 1.3.3` — konflikt w jednym
grafie SwiftPM. swift-transformers jest używany wyłącznie przez SD3 (tokenizer T5).

**Decyzja:** kopia samego targetu `StableDiffusion` w `Vendor/StableDiffusion` bez 4 plików SD3 (bez innych zmian).

## D-005 · 2026-10-24 · Model Core ML: RealVisXL V5.0 Lightning (LocalMuseAI, 6-bit)

Kandydaci z HF (stan 2026-10-24): `apple/coreml-stable-diffusion-xl-base` (zip 7 GB z 2023, bez informacji o VAEEncoder,
SDXL base ~30 kroków), kilka konwersji RealVisXL. Wybrano `LocalMuseAI/coreml-realvisxl-v5-lightning-6bit-v2`:
3,3 GB, OpenRAIL++-M, udokumentowane pochodzenie (hashe źródła, wersja konwertera Apple), zawiera **VAEEncoder**
(img2img), Lightning (4–6 kroków). Ograniczenia: stała rozdzielczość 1024², SPLIT_EINSUM (pod ANE), autor zaleca
sampler DPM++ SDE Karras — w pipeline Apple dostępny jest DPM-Solver++ (multistep) z odstępami Karras; jakość
oceniana wizualnie w raporcie Etapu 3. Konwersji nie wykonywano lokalnie — gotowe, skompilowane zasoby z udokumentowanym pochodzeniem wystarczają (konwersja wymagałaby offline środowiska Python z PyTorch i coremltools).

## D-006 · 2026-10-24 · Etap 4: LoRA, inpainting, kolejne modele

- **LoRA (MLX/FLUX.2):** Flux2Core wtapia LoRA w wagi transformera przy ładowaniu i nie umie ich „odwtopić”.
  Adapter przeładowuje pipeline, gdy zmienia się zestaw LoRA w żądaniu (z cache plików ~1,7–2 s), i wraca do
  czystego modelu przy błędzie. Core ML: brak LoRA (wagi skompilowane), `supportsLoRA = false`.
- **Inpainting:** `Flux2MaskedInpaintingChain` (RePaint, maska biała = generuj) z `compositeOnOriginal: true` —
  piksele poza maską są kopiowane z oryginału. Pipeline Core ML nie ma inpaintingu (zakomentowany w upstreamie).
- **Kolejne modele edycyjne:**
  - FLUX.2 Klein 9B — ten sam adapter (`flux2Model: klein-9b`), ale repozytorium BFL jest gated i ma licencję
    niekomercyjną; nie pobierano bez zgody/tokena użytkownika. Przykładowy manifest (oznaczony jako niezweryfikowany):
    `docs/manifests/flux2-klein-9b.example.json` → kopiować do `~/Library/Application Support/NativeImageStudio/Models/`.
  - Z-Image Turbo, Qwen-Image(-Edit): brak zweryfikowanej natywnej implementacji Swift/MLX (vmlx-flux ma stuby, D-001);
    implementacja od zera wykracza poza Etap 4. Architektura (adapter per rodzina + manifest) jest na to gotowa.
- **Model Profiles** zamiast przełączników: profil = model + workflow + kroki/guidance/rozdzielczość/siła/
  negatywny prompt/prefiks promptu/dopasowanie/LoRA; profil niekompatybilny z możliwościami modelu jest w menu
  wyszarzony z opisem przyczyny (`ModelProfile.incompatibilities`).

## D-007 · 2026-10-24 · CyberRealistic Z-Image Turbo przez z-image-swift; wagi MLX poza Caches

- **Port:** `xocialize/z-image-swift` (MIT, commit `eadca87`, 2026-10-11) — dołączony tylko rdzeń `ZImage`
  (`Vendor/ZImageSwift`), bez warstwy `mlx-engine-swift`. Zależności zgodne z mlx-swift 0.31.4
  (mlx-swift-lm 3.31.4, mlx-exact-conv 0.31.4..<0.33); minimalny macOS obniżony z 26 do 15 (kompiluje się).
- **Wagi:** `cyberdelia/cyberrealistic_zimage` → `CyberRealistic_zit_v4.0.safetensors` (najnowsza wersja Turbo na HF,
  CreativeML OpenRAIL-M, 12,3 GB bf16, format ComfyUI) + enkoder Qwen3-4B, VAE, tokenizer z `Tongyi-MAI/Z-Image-Turbo`
  (Apache-2.0). Konwersja kluczy przy ładowaniu (`ZImageCheckpoint`: rozbicie fused `qkv`, zmiany nazw), bez kopii na dysku.
  Odrzucone: konwersje 4-bit (LocalMuseAI, mflux) — port ładuje tylko bf16; GGUF — brak loadera.
- **Pamięć:** transformer int4 przy ładowaniu; enkoder tekstu 8-bit (szczyt 19,4 vs 22,5 GB przy bf16, obraz praktycznie
  identyczny przy tym samym seedzie); `Memory.clearCache()` po generacji. Oferowane rozdzielczości: 768 i 1024 — 1280²
  nie zmierzone, a ekstrapolacja przekracza 24 GB (MemoryBudgetManager je odrzuca).
- **Lokalizacja wag FLUX:** upstream trzyma je w `~/Library/Caches/models`; katalog został wyczyszczony przy zwalnianiu
  miejsca i ~10 GB wag zniknęło. `MLXModelStorage` przekierowuje Flux2Core i FluxTextEncoders do
  `~/Library/Application Support/NativeImageStudio/MLXModels/models` (`NIS_MLX_MODELS_DIR` nadpisuje).

## D-008 · 2026-10-25 · RealVisXL V5, Juggernaut XL, CyberRealistic XL (Core ML) i Z-Image Turbo

Źródła wybrane po weryfikacji zawartości paczek (pliki, metadane UNetu, karty modeli):

| model | repozytorium | natywna rozdzielczość | img2img | uwagi |
|---|---|---|---|---|
| RealVisXL V5.0 | `BulentOngun/coreml-realvisxl-v5` (6-bit, SPLIT_EINSUM) | 768² (latent 96) | nie (brak VAEEncoder) | jedyna znaleziona kompletna konwersja pełnego V5; `belgrat` = zip bez opisu |
| Juggernaut XL v9 | `Gatchamn/coreml-juggernaut-xl-v9-8bit` | 1024² | nie | na ANE 2× wolniej niż na GPU → `computeUnits: cpuAndGPU` |
| CyberRealistic XL v10 | `LocalMuseAI/coreml-cyberrealistic-xl-v10-6bit` | 1024² | tak | pochodzenie z hashami (PROVENANCE.json) |
| Z-Image Turbo | `Comfy-Org/Z-Image-Turbo` (`z_image_turbo_bf16.safetensors`, Apache-2.0) | ≤ 1024² | tak | ten sam format ComfyUI co CyberRealistic Z-Image; enkoder/VAE współdzielone |

Rozdzielczość modelu Core ML jest odczytywana z metadanych UNetu (`sample` [2,4,H/8,W/8]) zamiast stałej 1024.
Konwersje społecznościowe (BulentOngun, Gatchamn) nie mają historii pobrań — zweryfikowane tym, że generują
poprawne obrazy w testach integracyjnych i pomiarach.

## D-009 · 2026-10-25 · Modele Core ML zostają na Neural Engine mimo kompilacji przy przełączaniu

System trzyma skompilowany dla ANE praktycznie jeden model SDXL 1024²; przełączenie wymusza kompilację 60–130 s
(pomiary w PROGRESS.md). Nie ma publicznego API do sterowania tym cache. GPU odrzucone: kompilacja 22–37 s przy każdym
ładowaniu, wolniejsze kroki, 2–5× więcej pamięci, a CyberRealistic XL na GPU się wywraca. Aplikacja informuje o kompilacji
na ekranie postępu zamiast milczeć. Najszybsza praca: trzymać się jednego modelu SDXL w sesji.

## D-010 · 2026-10-25 · Pony Diffusion V6 XL i WAI-NSFW Illustrious V17 (Core ML)

| model | repozytorium | rozdz. | img2img | jednostki | licencja |
|---|---|---|---|---|---|
| Pony Diffusion V6 XL | `Gatchamn/coreml-pony-diffusion-v6-xl-8bit` (UNet 8-bit, niedzielony) | 1024² | nie (brak VAEEncoder) | **GPU** | CreativeML Open RAIL-M (karty HF bazy i konwersji) |
| WAI Illustrious SDXL V17 | `LocalMuseAI/coreml-wai-illustrious-sdxl-v17-6bit` (UNet 6-bit w 2 częściach) | 1024² | tak | ANE | Fair AI Public License 1.0-SD (Civitai 827184 v2883731) |

Jedyne znalezione konwersje Core ML (wyszukiwanie HF „coreml” + pony/illustrious/wai, 2026-10-25). Pony z jednostkami
ANE: Core ML wykonywał UNet na CPU (stos: `Espresso::parallel_softmax_chunk`, BNNS; ~950% CPU, po 20 min brak pierwszego
obrazu) — na GPU 2,5 s/krok. WAI ma udokumentowane pochodzenie (PROVENANCE.json z SHA-256). Oba modele nie są
fotorealistyczne (anime/postacie); WAI jest dostrojony do NSFW.

## D-011 · 2026-10-25 · Asystent promptów: Qwen3-8B Abliterated v2 przez mlx-swift-lm

- **Model:** `huihui-ai/Huihui-Qwen3-8B-abliterated-v2` (Apache-2.0, ~25 tys. pobrań — najpopularniejszy wariant
  „Qwen3-8B abliterated”) w konwersji MLX MXFP4 `mlx-community/Qwen3-8B-abliterated-v2-mxfp4`, rewizja przypięta
  `0310576b`. 4,1 GB na dysku, ~4,3 GB w pamięci. Odrzucone: bf16 (16 GB pobierania), wersje „Josiefied” (inny fine-tune),
  GGUF (brak loadera).
- **Biblioteka:** `mlx-swift-lm` 3.31.4 — już w grafie (zależność Z-Image), obsługuje Qwen3 i MXFP4 przy mlx-swift 0.31.4.
  Tokenizer: własny most do swift-transformers (bez makr MLXHuggingFace i swift-syntax). Tryb bez rozumowania
  (`enable_thinking: false`), próbkowanie z karty Qwen3 dla tego trybu (T 0,7, top-p 0,8, top-k 20).
- **Pamięć:** LLM i model obrazów nie mieszczą się razem w 24 GB. `GenerationCoordinator.withExclusiveGPU` czeka na koniec
  kolejki, wstrzymuje nowe zadania i zwalnia modele obrazów; asystent jest `GPUResident` — koordynator zwalnia go przed
  załadowaniem modelu obrazów. Zwolnienie czeka (≤ 3 s), aż footprint faktycznie spadnie (opóźnienie systemu ~2 s).
- **Styl promptu** zależy od wybranego modelu obrazów (`PromptStyle`; manifest `promptStyle` albo architektura):
  zdania (FLUX, Z-Image), frazy ≤ 55 słów (SDXL — CLIP czyta ~75 tokenów), tagi Pony ze `score_*`, tagi Danbooru
  (Illustrious). Prefiksy jakości i limit słów są wymuszane deterministycznie po generacji (`PromptCleaner`).
- Instrukcja systemowa opisuje każdą osobę jako dorosłą.

## D-012 · 2026-10-27 · Podgląd w trakcie generowania: x̂₀ przez dopasowaną mapę liniową lub VAE

**Kontekst:** użytkownik chciał widzieć obraz w trakcie generowania, a nie tylko pasek postępu.

**Decyzja:**
- Podgląd pokazuje **przewidywany obraz końcowy x̂₀**, a nie zaszumione latenty x_t. W modelach
  destylowanych (FLUX.2 Klein, 4 kroki) x_t z kroków 1–3 to praktycznie czysty szum (sprawdzone na zrzutach).
  - Core ML: `useDenoisedIntermediates`, czyli predykcja x₀ z DPM-Solver++.
  - Z-Image: łatka `NIS-PATCH` liczy x̂₀ = x − σ·v w pętli.
  - FLUX.2: v jest odtwarzane z dwóch kolejnych stanów kroku Eulera, więc pierwszy krok nie ma podglądu.
- **Tryb „przybliżony” (domyślny):** liniowa mapa latent → RGB (jeden kolor na pozycję latentu plus
  wygładzenie [1 2 1]). Wagi są dopasowane metodą najmniejszych kwadratów na końcowych latentach i
  zdekodowanych wynikach (`nis-poc preview-fit`, 9 obrazów do dopasowania i 1 odłożony). Nie użyliśmy
  współczynników z innych projektów.
- **Tryb „pełne dekodowanie”:** VAE co `max(1, kroki/4)` kroków, bez ostatniego kroku (ten i tak jest
  dekodowany jako wynik). Działa dla FLUX.2 (łatka `decodePackedLatentsForPreview`) i SDXL
  (`progress.currentImages`). Z-Image w tym trybie pokazuje podgląd przybliżony.
- Dla FLUX.2 odrzuciliśmy mapę 2×2 podpikseli na token: dała podobny błąd i widoczny szum kolorów.
- Dla FLUX.2 odrzuciliśmy też checkpointy biblioteki: dekodują x_t, więc w trybie pełnym pokazywały szum.

**Konsekwencje:** każda nowa rodzina VAE potrzebuje własnego `LatentRGB/<architecture>.json`. Bez niego
silnik nie wysyła podglądu przybliżonego.
