# Native Image Studio — plan

Natywna aplikacja macOS (Swift 6, SwiftUI) do lokalnego generowania i edycji obrazów na Apple Silicon,
w pełni offline w czasie działania (bez Pythona, ComfyUI i serwera HTTP).
Sprzęt docelowy: MacBook Pro M4 Pro, 24 GB pamięci współdzielonej. Toolchain: Xcode 26.2 / Swift 6.2.3, macOS 26.2.

## Weryfikacja bibliotek (stan 2026-10-24)

| Biblioteka | Rola | Wynik weryfikacji |
|---|---|---|
| ml-explore/mlx-swift | fundament MLX | MIT, aktywnie rozwijana. ≥ 0.31.5 wymaga Swift 6.3 → przypięte **0.31.4**. Shadery Metal kompiluje tylko xcodebuild (wymaga komponentu *Metal Toolchain*). |
| VincentGourbin/flux-2-swift-mlx (Flux2Core) | backend FLUX.2 Klein | MIT, v3.1.0 (2026-09-11). Czysty Swift. T2I, I2I (warunkowanie referencjami 1–3 w publicznym API, init latents + strength), inpainting (RePaint chain), LoRA. **Brak anulowania w pętli** → vendoring z patchem (D-002). |
| jjang-ai/vmlx-flux | zapasowy | **Odrzucony**: brak licencji, stuby enkoderów tekstu, zależność `path: ../vmlx-swift-lm` (D-001). |
| apple/ml-stable-diffusion | Core ML SDXL (Etap 3) | do weryfikacji w Etapie 3 |

Szczegóły i uzasadnienia: `docs/DECISIONS.md`.

## Architektura

```
Presentation (SwiftUI, Etap 2)      ← tylko @MainActor ViewModels
Application   GenerationCoordinator (actor), GenerationQueue, BatchCoordinator (actor), EngineRegistry
Domain        GenerationRequest/Mode, InputImage, EngineCapabilities, ModelDescriptor,
              GenerationEvent, JobState, RequestValidator, ImageGenerationEngine (protokół)
Engines       MLXEngine (MLXGenerationEngine actor, MLXModelLoader, MLXPipeline + Flux2Adapter)
              CoreMLEngine (Etap 3)
Infrastructure ModelStorage (ModelRepository + manifesty JSON), MemoryManagement (MemoryBudgetManager,
              DarwinMemoryProbe), ImageInputProcessing, ImagePersistence (ImageRepository), Benchmarks
```

Pakiet SPM w katalogu głównym, źródła w `NativeImageStudio/…`. Domain/Application/Infrastructure/Engines to
osobne targety testowalne bez SwiftUI. Każda rodzina modeli ma własny adapter (`MLXPipelineAdapter`),
bez uniwersalnego loadera safetensors.

### Kluczowe kontrakty
- `ImageGenerationEngine.generate` zwraca `AsyncThrowingStream<GenerationEvent>`; `onTermination` strumienia
  ustawia flagę anulowania silnika; `cancel(requestID:)` robi to jawnie. Pętla odszumiania sprawdza flagę
  na początku każdego kroku (po `eval` poprzedniego) → stream kończy się `GenerationError.cancelled`
  dopiero w bezpiecznym punkcie. Koordynator ustawia `Cancelled` dopiero wtedy.
- `GenerationCoordinator`: jedna aktywna generacja, kolejka FIFO z priorytetami, walidacja przy `submit`,
  kontrola pamięci przed każdym zadaniem i przed ładowaniem modelu, procedura zmiany modelu
  (stop → zwolnienie referencji → synchronizacja GPU → czyszczenie cache → pomiar → ładowanie).
- `BatchCoordinator`: partia = zadania ze wspólnym `batchID`; błąd jednego nie przerywa innych; anulowanie
  partii anuluje wszystkie jej zadania; model nie jest przeładowywany między zdjęciami.

## Etapy

1. **PoC (CLI `nis-poc`)** — Flux2Core + FLUX.2 Klein 4B int4 1024², 10× T2I, edycje (1–4 referencje, img2img),
   ImageInputProcessing z testami, pomiary (cold load, czas, s/krok, peak, pamięć po unload), test anulowania,
   kontrakt `ImageGenerationEngine` dla MLX.
2. **MVP SwiftUI** — prompt editor, postęp, Stop, kolejka; edycja (drag&drop, miniatury z numeracją, kolejność,
   tryby, strength), przed/po, galeria (SwiftData + pliki), partie.
3. **Core ML + SDXL** — `CoreMLGenerationEngine` przez apple/ml-stable-diffusion (T2I, img2img), EngineRegistry,
   porównanie wydajności w równoważnych warunkach.
4. **Zaawansowane** — LoRA, inpainting z edytorem maski, kolejne modele, panel benchmarków, zarządzanie
   modelami, Model Profiles.

## Testy
- `swift test` — DomainTests, ImageInputTests, CoordinatorTests (mock silnika). Bez GPU.
- `scripts/integration-tests.sh` — EngineIntegrationTests (realna inferencja przez xcodebuild); bez wag lub
  poza xcodebuild suite raportuje SKIPPED z powodem.
- `scripts/run-etap1.sh` — pomiary do `docs/bench/etap1.jsonl`.
