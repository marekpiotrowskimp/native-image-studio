# Postęp prac — Native Image Studio

Sprzęt pomiarowy: MacBook Pro M4 Pro, 24 GB, macOS 26.2 (25C56), Xcode 26.2 / Swift 6.2.3.
Surowe pomiary: `docs/bench/*.jsonl` (format `BenchmarkRecord`).

---

## Etap 1 — Proof of Concept (2026-10-24)

### Co działa
- **Biblioteka:** Flux2Core (flux-2-swift-mlx v3.1.0, MIT) dołączona lokalnie w `Vendor/Flux2Swift` z 3 patchami
  (mlx-swift 0.31.4 dla Swift 6.2, anulowanie między krokami, jawny `preload`). vmlx-flux odrzucony
  (brak licencji, stuby). Szczegóły: `docs/DECISIONS.md` D-001…D-003.
- **Model:** FLUX.2 Klein 4B (Apache-2.0), transformer bf16 z HF kwantyzowany w locie do **int4**, VAE standard,
  enkoder tekstu Qwen3-4B MLX 4-bit. Pobieranie: `nis-poc download` (transformer 7,75 GB + VAE 168 MB + Qwen3 ~2,3 GB).
- **Kontrakt `ImageGenerationEngine`** zaimplementowany przez `MLXGenerationEngine` (actor): strumień zdarzeń,
  `onTermination` → flaga anulowania, `cancel(requestID:)`, `unloadModel()` z procedurą: stop → zwolnienie
  referencji → `Stream.gpu.synchronize()` → `Memory.clearCache()` → pomiar.
- **Tryby edycji faktycznie obsługiwane przez model** (zweryfikowane w kodzie i generacją):
  - text-to-image,
  - edycja z referencjami (warunkowanie tokenami obrazów): **1–4 obrazy działają** (publiczne API biblioteki
    ogranicza do 3 — `guard images.count <= 3` w `generateImageToImage` — ale ścieżka ogólna `generateWithResult`
    przyjmuje 4, zgodnie z limitem 4 dla Klein z dokumentacji BFL cytowanym w `Flux2Model.maxReferenceImages`).
    Manifest: `maxReferenceImages = 4`. 5+ nie testowano (poza dokumentowanym limitem BFL),
  - image-to-image: referencja + init latents + `strength` (przy 4 krokach skokowo: strength ≤ 0,75 pomija krok),
  - inpainting: biblioteka ma `Flux2MaskedInpaintingChain` — integracja w Etapie 4.
- **ImageInputProcessing:** JPEG/PNG/HEIC/TIFF, orientacja EXIF (tagi 1–8), konwersja do 8-bit sRGB (ColorSync),
  rozmiar docelowy z proporcji + wielokrotność 32, tryby dopasuj/przytnij/dopełnij, SHA-256 wejść.
- **Infrastruktura:** `MemoryBudgetManager` (footprint procesu, wolne strony systemu, presja `kern.memorystatus_vm_pressure_level`,
  `thermalState`, cache MLX jako odzyskiwalny), `ImageRepository` (nowe pliki PNG + JSON, odmowa zapisu na wejściu),
  `ModelRepository` (manifesty JSON), `BenchmarkLog`. Warstwa Application (koordynator, kolejka, partie) — gotowa i przetestowana na mocku.
- **CLI `nis-poc`:** download / t2i / edit / i2i / refscale / cancel / unload; `scripts/run-etap1.sh` odtwarza wszystkie pomiary.

### Wyniki testów
| Zestaw | Wynik |
|---|---|
| `swift build` | bez błędów i ostrzeżeń (Swift 6, strict concurrency; ostrzeżenia kodu vendorowanego wyciszone, D-002) |
| `swift test` — DomainTests, ImageInputTests, CoordinatorTests | **70 zaliczonych**, 0 niezaliczonych (3 przebiegi, stabilne) |
| `swift test` — EngineIntegrationTests | **6 pominiętych** z komunikatem „SKIPPED: real inference needs xcodebuild…” |
| `scripts/integration-tests.sh` (xcodebuild, realna inferencja) | **6/6 zaliczonych** (103 s): T2I, edycja 2 refs (hashe wejść niezmienione), img2img, anulowanie + ponowne użycie, porzucenie strumienia → anulowanie GPU, unload/reload |

Błąd wykryty przez testy integracyjne i naprawiony: silnik zwalniał slot aktywnego zadania dopiero po zamknięciu
strumienia, więc natychmiastowe kolejne `generate` dostawało „silnik zajęty”. Teraz `didFinish` wykonuje się przed `finish()` strumienia.

### Pomiary (FLUX.2 Klein 4B int4, MLX, 4 kroki, guidance 1.0)

**10× text-to-image 1024×1024, seedy 1–10** (jeden proces, stan termiczny `nominal` przez cały czas):

| metryka | średnia | min | max |
|---|---|---|---|
| czas generacji (s) | 34,06 (σ 1,81) | 31,34 | 36,88 |
| s/krok (odszumianie) | 7,78 | 7,14 | 8,54 |
| peak pamięci MLX (GB) | 14,58 | 14,58 | 14,58 |
| footprint procesu po generacji (GB) | 4,78 | 4,76 | 4,79 |

Czas rośnie monotonicznie w serii (7,14 → 8,54 s/krok) mimo stanu `nominal` — nagrzewanie GPU.

**Cold load:** pierwsze uruchomienie 63,5 s (w tym pobranie Qwen3 ~2,3 GB). Ponowne ładowanie z plikami w cache
stron systemu: 1,9–2,3 s (kwantyzacja int4 jest leniwa). Prawdziwego zimnego odczytu z dysku (po `purge`) nie mierzono.

**Edycja (1024×1024, ten sam seed; stan `fair`):**

| tryb | wejścia | czas (s) | s/krok | peak (GB) |
|---|---|---|---|---|
| referenceEdit | 1 | 79,89 | 18,97 | 14,58 |
| referenceEdit | 2 | 129,61 | 30,36 | 14,59 |
| referenceEdit | 3 | 191,23 | 46,42 | 14,59 |
| referenceEdit | 4 | 275,10 | 69,32 | 14,60 |
| imageToImage, strength 0,3 | 1 | 22,43 | – (1 krok) | 14,58 |
| imageToImage, strength 0,6 | 1 | 39,93 | 17,60 | 14,58 |
| imageToImage, strength 0,9 | 1 | 57,39 | 17,54 | 14,58 |

Peak pamięci jest praktycznie niezależny od liczby referencji (+0,01 GB/ref): szczyt powstaje w dekodowaniu VAE
1024² (przerwanie po kroku 1–2 daje peak 6,72 GB). Koszt referencji to **czas** (dłuższa sekwencja uwagi), nie pamięć.
Profil wpisany do manifestu: rezydentnie 4,8 GB, +9,6 GB/MP, +0,02 GB/ref (zaokrąglone w górę pomiary).

Profile pamięci biblioteki (`ultraLow` / `aggressive` / `disabled`, 2 generacje każdy) dały ten sam peak 14,58 GB
i czasy w granicach rozrzutu termicznego (32,8–50,9 s) → zostawiono automatyczny wybór biblioteki.

**Anulowanie (T2I 1024²):**
- Stop wysłany w callbacku kroku 1 → zatrzymanie po 0,06 s (flaga sprawdzona na początku kroku 2).
- Stop w callbacku kroku 2 → zatrzymanie po 7,92 s (krok 3 już trwał; zatrzymanie na jego granicy).
- Wniosek: opóźnienie ≤ 1 krok (~8 s przy 1024² bez referencji, do ~70 s/krok przy 4 referencjach). Status
  Cancelled pojawia się dopiero po dojściu silnika do bezpiecznego punktu. Silnik działa poprawnie po anulowaniu.

**Pamięć po unload:** footprint 4,78 → 0,15 GB w 0,04 s (MLX active 4,53 → 0,00 GB, cache 0), po 1 s 0,06 GB;
dostępne w systemie 16,1 GB. Ponowne załadowanie 1,93 s. Zwolnienie referencji + synchronizacja + `clearCache`
oddają pamięć natychmiast — zmierzone, nie założone.

### Ocena biblioteki
Flux2Core nadaje się na fundament: stabilna (0 awarii w ~30 generacjach, w tym 4 anulowania), czysty Swift,
dobra jakość fotorealistyczna (ocena wizualna próbek), edycja zachowuje tożsamość/pozę/strój. Koszty: vendoring
z patchami (do czasu Swift 6.3) i wolna edycja wieloma referencjami.

### Znane problemy / ograniczenia
- Edycja z referencjami jest wolna (80–275 s przy 1024²); w UI warto domyślnie proponować 768² dla 3–4 referencji.
- Opóźnienie anulowania do 1 kroku (granulacja biblioteki: jeden krok = jeden graf `eval`).
- `swift build` nie kompiluje shaderów Metal — narzędzia z MLX budowane przez xcodebuild (wymaga komponentu Metal Toolchain).
- Cold load z „zimnego” dysku niezmierzony (wymaga `sudo purge`).

---

## Etap 2 — MVP SwiftUI (2026-10-24)

### Co działa
- **Aplikacja** `NativeImageStudio.app` (`scripts/build-app.sh`: xcodebuild + pakowanie bundle z zasobami SPM
  i metallib MLX, podpis ad-hoc). Nawigacja: Generowanie, Edycja zdjęć, Galeria, Modele + okno Ustawień.
- **UI nie zna silnika**: `Features` zależy tylko od Domain/Application/Infrastructure; silniki tworzy
  wyłącznie `App/DependencyContainer`. Pobieranie modeli przez protokół `ModelWeightsProvider`.
- **Generowanie:** edytor promptu, model (tylko modele wspierające tryb), proporcje, rozdzielczość, kroki,
  guidance, seed (stały/losowy), liczba obrazów, ⌘↩ Generuj, ⌘. Stop, postęp kroków, kolejka z priorytetami
  (zmiana priorytetu, anulowanie pojedynczych zadań), historia.
- **Edycja:** przeciąganie plików (drop) i wybór wielu zdjęć (panel), miniatury z numeracją „obraz N”,
  zmiana kolejności, usuwanie, tryby Transformacja / Referencje / Partia (tylko te, które deklaruje model),
  suwak siły z informacją o granulacji, proporcje „jak obraz 1” lub preset, dopasuj/przytnij/dopełnij,
  walidacja z komunikatem (np. limit referencji z `maxReferenceImages`), porównanie przed/po z suwakiem.
- **Partie:** wspólny `batchID`, postęp całości, siatka wyników, „Anuluj partię”, proporcje per zdjęcie.
- **Galeria:** SwiftData (`GalleryItem`) jako indeks + PNG/JSON na dysku jako źródło prawdy; import plików
  utworzonych poza aplikacją (CLI), filtr trybu, wyszukiwanie w promptach, szczegóły z metadanymi, obrazami
  wejściowymi (miniatury + skrót SHA-256), przed/po, „Pokaż w Finderze”.
- **Ustawienia:** folder wyników, limit pamięci procesu i margines, częstotliwość aktualizacji postępu,
  podgląd pamięci/presji/termiki.
- **Samotest UI** (`NIS_SELFCHECK_DIR=… NativeImageStudio`): aplikacja sama przechodzi scenariusz
  generowanie → postęp → wynik → edycja 2 referencji → przed/po → partia 2 zdjęć → Stop w trakcie →
  galeria → modele i zapisuje zrzuty własnego okna (bez uprawnienia nagrywania ekranu).

### Wyniki testów
| Zestaw | Wynik |
|---|---|
| `swift build` (czysty) | bez błędów i ostrzeżeń |
| `xcodebuild` aplikacji (Release) | BUILD SUCCEEDED, bez ostrzeżeń w kodzie aplikacji |
| `swift test` | **82 zaliczone** (70 + 12 nowych FeatureTests: ViewModel edycji/generowania, JobsStore, GalleryStore na SwiftData in-memory), **6 pominiętych** (EngineIntegrationTests, z komunikatem) |
| `scripts/integration-tests.sh` | **6/6 zaliczonych** (105 s) |
| Samotest UI z realnym modelem | generowanie Completed, edycja Completed, partia 2/2, Stop → Cancelled |

### Błędy znalezione samotestem UI i naprawione
1. **Fałszywe odrzucanie przez MemoryBudgetManager** (1024² „potrzeba 11,1 GB, dostępne 10,8 GB” — przy realnym
   zużyciu, które wcześniej mieściło się 30×): formuła free+inactive+purgeable+speculative pomija cache plików
   i pamięć kompresowalną. Teraz dostępność = `kern.memorystatus_level` × RAM (miara, której kernel używa dla
   presji pamięci), ze starą formułą jako zapasem.
2. **Układ:** `HSplitView` w kolumnie szczegółów macOS 26 (pływający szklany sidebar) przesuwał treść bez
   zmniejszania szerokości → prawa krawędź przycięta o ~37 pt. Zastąpiony `HStack` + `Divider`; panele
   rozciągają się na pełną wysokość.

### Znane problemy
- Zmiana kolejności zdjęć strzałkami (bez przeciągania wewnątrz paska miniatur).
- Średni czas na zdjęcie w partii jest widoczny w metadanych, ale nie jest jeszcze agregowany w UI (panel benchmarków — Etap 4).
- Zmiany folderu wyników i limitów pamięci działają po restarcie aplikacji.

---

## Etap 3 — Core ML + SDXL (2026-10-24)

### Co działa
- **CoreMLGenerationEngine** (actor) przez apple/ml-stable-diffusion (vendored bez SD3 — konflikt swift-transformers, D-004):
  text-to-image i img2img, negatywny prompt, anulowanie per krok (`progressHandler` → `false`), unload.
  Model: **RealVisXL V5.0 Lightning** Core ML 6-bit (LocalMuseAI, OpenRAIL++-M, 3,1 GB na dysku, D-005),
  pobierany przez aplikację (zakładka Modele / `nis-poc download`).
- **EngineRegistry** z dwoma silnikami; koordynator przy zmianie backendu rozładowuje drugi silnik.
  UI pokazuje tylko tryby modelu: dla SDXL Tekst→obraz i Transformacja (bez Referencji), pole negatywnego promptu,
  brak wyboru proporcji (stała 1024²). Zweryfikowane samotestem UI z modelem Core ML (generowanie + Stop).
- `GeneratedImage.stats` (s/krok, peak, termika) z obu silników — podstawa panelu benchmarków.

### Błąd znaleziony i naprawiony
Pierwsza generacja SDXL ignorowała prompt (losowa scena). Przyczyna: `merges.txt` w repozytorium modelu ma
końce linii **CRLF**; parser Apple zostawiał `\r` w każdej regule BPE → zero scaleń → tokenizacja prawie po
znakach (obcięcie promptu po ~85 znakach). Patch w vendorowanym parserze + test regresji `BPETokenizerTests`.

### Wyniki testów
| Zestaw | Wynik |
|---|---|
| `swift build` / xcodebuild aplikacji | bez błędów i ostrzeżeń w kodzie aplikacji |
| `swift test` | **87 zaliczonych** (+5: EngineUnitTests — instalacja zasobów, capabilities bez VAEEncoder, manifest, błędy bez modelu, tokenizer CRLF), **10 pominiętych** (integracyjne, z komunikatem) |
| `scripts/integration-tests.sh` | **10/10 zaliczonych**: MLX 6/6, Core ML 4/4 (T2I, img2img z niezmienionym wejściem, anulowanie + ponowne użycie, unload) |

### Pomiary (M4 Pro 24 GB; `docs/bench/etap3.jsonl`)
**Core ML, 10× T2I 1024², 6 kroków, guidance 2, cpuAndNeuralEngine:** 12,60 s (σ 0,04; 12,58–12,70), 1,82 s/krok,
szczyt footprintu procesu 4,72 GB. Cold load: pierwszy raz **123,5 s** (kompilacja pod ANE, jednorazowo per proces
xctest/aplikacja — w procesie testów ponownie ~150 s), potem **1,0 s** z cache.
`cpuAndGPU`: load 42,2 s, 15,1–20,3 s/obraz, 2,25 s/krok, szczyt 11,7 GB → ANE jest szybszy i ~2,5× oszczędniejszy.

**Porównanie w równoważnych warunkach** (ten sam prompt, T2I, 1024², **4 kroki**, seedy 101–105, naprzemiennie,
każdy przebieg w osobnym procesie z modelem w pamięci podręcznej plików; termika nominal→fair dla obu):

| backend | model | czas (s) | s/krok | szczyt footprintu procesu |
|---|---|---|---|---|
| MLX | FLUX.2 Klein 4B int4 | 31,76 (σ 1,54) | 7,30 | 14,2 GB |
| Core ML (ANE) | RealVisXL V5 Lightning 6-bit | **8,96** (σ 0,00) | **1,82** | **4,7 GB** |

Różne architektury (transformer 4B vs UNet SDXL), więc to porównanie kosztu wygenerowania obrazu 1024², nie
wydajności backendów per FLOP. Jakość (ocena wizualna): FLUX.2 Klein — naturalniejsze światło i skóra; SDXL z
DPM-Solver++ Karras — przesycony, „HDR”, przeostrzony (oczekiwane przy innym samplerze niż zalecany).

**Img2img Core ML (6 kroków):** 0,3 → 4,6 s (1 krok), 0,6 → 8,1 s, 0,9 → 11,7 s. Efekt jest skokowy: 0,6–0,75 prawie
nie zmienia obrazu, 0,9 tworzy niemal nową scenę (odstępy Karras kumulują szum w pierwszym kroku).

**Anulowanie Core ML:** stop po kroku 2 → zatrzymanie po 1,81 s (= 1 krok). **Unload:** footprint 4,71 → 4,16 GB
natychmiast, 0,41 GB po 3 s (Core ML zwalnia asynchronicznie — zmierzone, nie założone).

### Znane problemy
- Sampler: brak DPM++ SDE Karras w pipeline Apple → jakość RealVisXL Lightning gorsza niż referencyjna.
- Img2img SDXL o skokowej charakterystyce siły; stała rozdzielczość 1024²; seed 32-bit.
- Pierwsze załadowanie Core ML w nowym procesie/po aktualizacji systemu: 2–2,5 min kompilacji ANE.

---

## Etap 4 — Funkcje zaawansowane (2026-10-24)

### Co działa
- **LoRA** (MLX): sekcja „Adaptery LoRA” w Generowaniu i Edycji (pliki .safetensors, skala 0–2). Adapter FLUX.2
  przeładowuje pipeline przy zmianie zestawu (LoRA wtapiane w wagi, D-006). Weryfikacja na
  `fal/flux-2-klein-4B-background-remove-lora` (Apache-2.0): bez LoRA model rysuje „szachownicę przezroczystości”,
  z LoRA czyste białe tło; test integracyjny potwierdza, że wynik dla tego samego seeda różni się z/bez LoRA.
  Uwaga: ten LoRA trenowano na wariancie *base* — na destylowanym Klein 4B działa, ale to nie jest gwarancja dla innych.
- **Inpainting z edytorem maski**: tryb „Inpainting” (tylko gdy model deklaruje `inpainting` — FLUX.2 Klein 4B tak,
  SDXL Core ML nie), pędzel/gumka/cofnij/wyczyść nad zdjęciem, maska renderowana w rozdzielczości zdjęcia i zapisywana
  jako nowy PNG w `Application Support/NativeImageStudio/Masks` (oryginał nietknięty), wynik z przed/po i „Popraw maskę”.
  Piksele poza maską kopiowane z oryginału (test integracyjny: różnica ≤ 6/765 po lewej, niezamaskowanej stronie).
- **Panel benchmarków**: każda zakończona generacja w aplikacji zapisuje `BenchmarkRecord` (s/krok i peak z silnika,
  termika); tabela grupuje wyłącznie identyczne warunki, pomija anulowane; średni czas na zdjęcie dla partii.
- **Zarządzanie modelami**: rozmiar na dysku, usuwanie wag z potwierdzeniem (MLX: tylko transformer — VAE i Qwen3
  współdzielone są zachowywane i wymieniane; Core ML: katalog zasobów zarządzany przez aplikację; ręczne `resourcePath`
  nigdy nie są kasowane).
- **Model Profiles**: menu „Profil” (zapis bieżących ustawień, zastosowanie, usuwanie); profile niezgodne z modelem
  wyszarzone z powodem. Plik `Application Support/NativeImageStudio/profiles.json`.
- **Kolejne modele**: przykładowy, oznaczony jako niezweryfikowany manifest FLUX.2 Klein 9B (gated, niekomercyjny);
  Z-Image / Qwen-Image-Edit odłożone — brak zweryfikowanej implementacji Swift (D-006).

### Wyniki testów
| Zestaw | Wynik |
|---|---|
| `swift build` (czysty) / xcodebuild aplikacji | bez błędów i ostrzeżeń w kodzie aplikacji |
| `swift test` | **100 zaliczonych** (+13: profile i ich trwałość, podsumowania benchmarków, rejestrator, renderer maski, ViewModel inpaintingu i LoRA, round-trip profili, zarządzanie modelami), **12 pominiętych** (integracyjne, z komunikatem) |
| `scripts/integration-tests.sh` | **12/12 zaliczonych**: MLX 8 (w tym inpainting i LoRA), Core ML 4 |
| Samotest UI | generowanie, edycja 2 referencji, partia 2/2, inpainting Completed, zapis profilu, Stop → Cancelled; zrzuty: edytor maski, wynik inpaintingu, Modele z rozmiarami, Benchmarki |

### Pomiary (`docs/bench/etap4.jsonl`)
| operacja | rozdz. | czas (s) | s/krok | peak MLX (GB) |
|---|---|---|---|---|
| inpainting (maska prostokątna 28×22%) | 1024² | 31,94 | 6,93 | 14,58 |
| edycja 1 ref, bez LoRA | 768² | 36,32 | 8,58 | 11,27 |
| edycja 1 ref, z LoRA (pierwsze załadowanie z LoRA: 1,66 s) | 768² | 39,13 | 8,74 | 11,27 |

### Znane problemy
- Prostokątna maska bez rozmycia daje widoczną krawędź; pędzel w UI ma zaokrąglone końce, ale bez miękkiego rozmycia.
- LoRA tylko dla MLX; zmiana zestawu LoRA kosztuje przeładowanie (~2 s z cache, dłużej przy zimnym dysku).
- Z-Image, Qwen-Image-Edit, Klein 9B niezweryfikowane (powody w D-006).

---

## Podsumowanie całości

| Etap | Commit | Stan |
|---|---|---|
| 1. PoC MLX (FLUX.2 Klein 4B) | `60570bc` | kontrakt silnika, przetwarzanie wejść, pomiary, anulowanie, unload |
| 2. MVP SwiftUI | `f87f9eb` | generowanie, edycja (3 tryby), partie, galeria SwiftData, ustawienia, samotest UI |
| 3. Core ML + SDXL | `6d60308` | drugi silnik, EngineRegistry, porównanie w równoważnych warunkach |
| 4. Zaawansowane | (ten commit) | LoRA, inpainting z maską, benchmarki, zarządzanie modelami, profile |

**Kluczowe liczby (M4 Pro 24 GB, 1024²):** FLUX.2 Klein 4B int4 (MLX): T2I 34,1 s (4 kroki, 7,8 s/krok), peak 14,6 GB,
edycja 1–4 referencji 80–275 s; RealVisXL Lightning (Core ML/ANE): T2I 12,6 s (6 kroków) / 9,0 s (4 kroki), peak
procesu 4,7 GB. Anulowanie ≤ 1 krok w obu silnikach; unload oddaje pamięć natychmiast (MLX) lub w ~3 s (Core ML).

**Najważniejsze decyzje:** vendoring Flux2Core (Swift 6.2 + anulowanie) i ml-stable-diffusion bez SD3 (konflikt zależności);
xcodebuild dla wszystkiego, co uruchamia MLX; dostępna pamięć z `kern.memorystatus_level`; samotest UI renderujący
własne okno zamiast uprawnień do nagrywania ekranu.

**Błędy wykryte przez testy/samotesty i naprawione:** wyścig „silnik zajęty” po zakończeniu strumienia (MLX/Core ML),
fałszywe odrzucenia przez budżet pamięci, przycinanie układu przez `HSplitView` w macOS 26, CRLF w `merges.txt`
psujący tokenizację SDXL.

**Co dalej:** sampler DPM++ SDE Karras dla RealVisXL Lightning (jakość), miękkie krawędzie maski, aktualizacja do
upstreamowego Flux2Core po przejściu na Xcode z Swift 6.3, natywne adaptery Z-Image / Qwen-Image-Edit, Klein 9B
po akceptacji licencji przez użytkownika.

---

## Po Etapie 4 — CyberRealistic Z-Image Turbo, galeria, poprawki (2026-10-24)

**Nowy model:** CyberRealistic Z-Image Turbo v4.0 (MLX, adapter `ZImageAdapter`, D-007): tekst→obraz i transformacja.
Pomiary (M4 Pro 24 GB, 1024², 8 kroków, guidance 0, `docs/bench/zimage.jsonl`):

| wariant | czas (s) | s/krok | szczyt MLX (GB) | rezydentnie po załadowaniu (GB) |
|---|---|---|---|---|
| enkoder bf16 | 79,9–80,1 | 9,3–9,5 | 22,5 | 11,1 |
| enkoder 8-bit (domyślny) | 76,8–83,8 (5 przebiegów) | 9,3–10,1 | 19,4 | 8,1 |
| img2img 0,5 / 0,8 | 41,9 / 72,8 | 9,8–9,9 | 19,5 | 8,1 |

Cold load 4,3–5,8 s (z cache plików, z konwersją kluczy i kwantyzacją int4). Anulowanie: ≤ 1 krok (10,1 s).
Unload: 16,8 → 0,15 GB w 0,4 s. Pamięć stabilna przy kolejnych generacjach w jednym procesie.

**Galeria:** zaznaczanie wielu (klik/⌘/⇧/⌘A), usuwanie do Kosza lub ukrywanie.
**Poprawki:** wybór pliku LoRA (NSOpenPanel), linia przed/po (geometria w prostokącie obrazu, gest na całym panelu).
**Testy:** `swift test` 121 (zaliczone + pominięte integracyjne z komunikatem), Z-Image 1/1, Core ML 4/4, FLUX 8/8
(po ponownym pobraniu wag FLUX do Application Support — poprzednie zniknęły z `~/Library/Caches` przy czyszczeniu dysku).
Enkoder Qwen3-4B dla FLUX jest odczytywany ze wspólnego cache Hugging Face (`~/.cache/huggingface/hub`), który biblioteka
przeszukuje; jego usunięcie wymusi ponowne pobranie (~2,3 GB) przy następnym „Pobierz”.

---

## Kolejne modele (2026-10-25)

Dodane: RealVisXL V5.0, Juggernaut XL v9, CyberRealistic XL v10 (Core ML), Z-Image Turbo (MLX). Źródła: D-008.
Pomiary przy ustawieniach domyślnych z manifestów (M4 Pro 24 GB, seed 1–2, ten sam prompt, `docs/bench/models.jsonl`):

| model | backend | rozdz. | kroki / CFG | czas (s) | s/krok | szczyt (GB) | pierwsze ładowanie |
|---|---|---|---|---|---|---|---|
| RealVisXL V5.0 | Core ML / ANE | 768² | 50 / 5 | 39,7–41,1 | 0,78 | 1,6 (proces) | 124 s (kompilacja ANE) |
| Juggernaut XL v9 | Core ML / GPU | 1024² | 35 / 5 | 96,0 | 2,53 | 8,7 (proces) | 27,5 s |
| Juggernaut XL v9 | Core ML / ANE | 1024² | 35 / 5 | 196,8–197,7 | 5,56 | 4,2 (proces) | 66,6 s |
| CyberRealistic XL v10 | Core ML / ANE | 1024² | 30 / 7,5 | 56,2–56,5 | 1,82 | 4,8 (proces) | 129 s (kompilacja ANE) |
| Z-Image Turbo | MLX int4 | 1024² | 8 / 0 | 78,5–84,0 | 9,5–9,7 | 19,4 (MLX) | 7,3 s |

Wszystkie trzymają się promptu (ocena wizualna). Testy: `swift test` 124 (zaliczone + pominięte integracyjne),
integracyjne 14/14 (FLUX 8, Z-Image 1, Core ML 5 — w tym generowanie każdym zainstalowanym SDXL w natywnej rozdzielczości).

---

## Diagnoza: „minuta zanim model zacznie się ładować” (2026-10-25)

**Objaw:** po kliknięciu Generuj pamięć aplikacji przez ~1–2 min się nie zmienia.

**Pomiar:** w koordynatorze i silnikach dodano znaczniki etapów (`StageLog`, unified log, podsystem `NativeImageStudio`)
oraz próbkowano procesy systemowe co 1 s. Kolejka, zwalnianie poprzedniego modelu i budżet pamięci trwają < 0,1 s.
Cały czas przypada na `loadModel` modeli Core ML uruchamianych na Neural Engine. W tym czasie `ANECompilerService`
pracuje na ~100% CPU (do 1,5 GB RSS), a footprint aplikacji stoi w miejscu (0,05 → 0,43 GB). Pamięć kompilacji należy do
procesu systemowego, nie do aplikacji.

**Kiedy:** systemowy cache skompilowanych modeli ANE (zarządzany przez `aned`, niedostępny dla aplikacji) mieści praktycznie
jeden model SDXL 1024². Naprzemienne ładowanie (CLI, kolejne procesy, 2 kroki):

| kolejność | Lightning (1024²) | RealVisXL V5 (768²) | CyberRealistic XL (1024²) |
|---|---|---|---|
| 1. runda | 119,5 s | 11,9 s | 122,7 s |
| 2. runda | 116,7 s | 12,0 s | 119,3 s |
| ponownie ten sam model zaraz potem | 1,0 s | 0,9 s | 0,9–1,7 s |

W aplikacji: CyberRealistic XL 63,6 s / 126,7 s, Lightning 130,9 s przy zimnym cache; 0,94 s przy ciepłym. Po nocy cache też
był pusty. Modele MLX (FLUX, Z-Image) tego nie mają: Z-Image w aplikacji 5,5 s od startu ładowania.

**Odrzucona alternatywa — GPU zamiast ANE** (`--compute-units cpuAndGPU`): konwersje SPLIT_EINSUM kompilują się na GPU przy
każdym ładowaniu (22–37 s, bez trwałego cache), są wolniejsze i zajmują więcej pamięci (Lightning 2,31 vs 1,83 s/krok,
szczyt 11,7 vs 4,7 GB; RealVisXL V5 1,24 vs 0,78 s/krok, 8,6 vs 1,6 GB), a CyberRealistic XL na GPU kończy się asercją
w systemowym MPSGraph (`shape.count = 0 != strides.count = 4`). Juggernaut (już na GPU) ładuje się w 7,6–8,1 s.

**Zmiany:**
- Podczas ładowania modelu ANE ekran postępu pokazuje licznik sekund i wyjaśnienie (kompilacja dla Neural Engine, zwykle
  1–2 min) — `JobSnapshot.loadingNote`, `JobStatusView`.
- `StageLog`: `log show --last 10m --predicate 'subsystem == "NativeImageStudio"' --style compact` pokazuje czasy etapów.
- **Błąd przy okazji:** 1 krok w modelu Core ML zamykał aplikację (DPM-Solver++ z odstępami Karras w pipeline Apple:
  `Float value cannot be converted to Int because it is either infinite or NaN`). Nowe `EngineCapabilities.minSteps`
  (Core ML: 2, sprawdzone 2 kroki działają) — walidator, krokomierze w UI i zgodność profili.

**Uwaga:** w samoteście Z-Image 1024² zostało odrzucone przez budżet pamięci („potrzeba ~12,3 GB, dostępne ~11,0 GB”) przy
8,1 GB załadowanego modelu — zgodne z pomiarem szczytu 19,4 GB i stanem systemu w tej chwili; bez zmian.

**Testy:** `swift test` 126 (zaliczone + pominięte integracyjne z komunikatem).

---

## Pony Diffusion V6 XL i WAI-NSFW Illustrious V17 (2026-10-25)

Źródła i decyzje: D-010. Pomiary (M4 Pro 24 GB, 1024², ustawienia domyślne, seed 1–2, `docs/bench/models.jsonl`):

| model | jednostki | kroki / CFG | czas (s) | s/krok | szczyt procesu (GB) | ładowanie |
|---|---|---|---|---|---|---|
| Pony Diffusion V6 XL | GPU | 25 / 7 | 66,2–66,8 | 2,51–2,60 | 8,8 | 25,9–27,0 s (każde) |
| Pony Diffusion V6 XL | ANE (odrzucone) | 25 / 7 | > 1200 bez wyniku | — | — | UNet na CPU |
| WAI Illustrious V17 | ANE | 25 / 6 | 47,2–47,5 | 1,82–1,83 | 4,8 | 128–135 s (kompilacja ANE), potem ~1 s |
| WAI Illustrious V17 img2img 0,6 | ANE | 25 / 6 | 30,0 | 1,82 | 4,8 | — |

WAI kompilował się ponownie (128 s) po tym, jak między przebiegami działał tylko Pony na GPU — systemowy cache ANE
traci wpisy także bez ładowania innego modelu ANE (por. diagnoza wyżej).

Ocena wizualna: oba trzymają się promptu w zakresie postaci, stroju i tła. Pony przy tagach `score_*` + `source_anime`
dał obraz w stylu malarskim. WAI przy neutralnym prompcie wygenerował ujęcie seksualizowane (model dostrojony do NSFW) —
zapisane w ograniczeniach modelu wraz ze wskazówką o negatywnym prompcie.

Miejsce na dysku: przed pobraniem 11 GB wolnego; usunięto odtwarzalne `Vendor/*/.build` (3,1 GB, nieużywane przez build
główny); po pobraniu (3,7 + 3,3 GB) 9,2 GB wolnego.

---

## Asystent promptów — Qwen3-8B Abliterated (2026-10-25)

Nowa funkcja w zakładce Generowanie: pomysł na scenę (np. po polsku) → realistyczny opis po angielsku w formacie wybranego
modelu obrazów; podgląd na żywo, „Użyj” wstawia go do promptu, „Popraw obecny” przepisuje prompt z edytora (opcjonalnie
z opisaną zmianą). Model pobiera się i usuwa w zakładce Modele. Decyzje: D-011.

Pomiary (M4 Pro 24 GB, CLI `nis-poc prompt`, idee po polsku):

| styl (model obrazów) | całość (s) | pierwszy token (s) | słowa | footprint (GB) |
|---|---|---|---|---|
| zdania (FLUX) — 1. z ładowaniem 0,35 s | 4,83 | 2,46 | 89 | 4,32 (szczyt 4,74) |
| zdania (FLUX) — kolejne | 2,84 | 0,73 | 87 | 4,32 |
| frazy (CyberRealistic XL) | 2,55–2,62 | 0,89–1,28 | 45–51 | 4,31 |
| tagi Pony | 3,15–3,86 | 0,97–1,53 | 47–48 | 4,32 |
| tagi Danbooru (WAI) | 7,06–7,50 | 0,89–1,28 | 44–45 | 4,35 |

Pierwsza wersja instrukcji dawała 94 słowa dla SDXL (CLIP obcina po ~75 tokenach), brak przecinka po prefiksie Pony,
nieistniejący tag `source_realistic`, negację „no text or logos” i echo „50 words” w tagach — instrukcje zaostrzone,
a `PromptCleaner` wymusza prefiks, przecinek, limit słów (cięcie na granicy frazy) i usuwa artefakty (testy na tych
wyjściach). Pozostaje: przy poprawianiu model bywa, że dopisuje elementy niewizualne („faint hum of the city”).

Pamięć: po zwolnieniu MLX active 4,05 → 0 GB od razu, footprint procesu 3,98 GB → 0,09 GB po ~2 s (bez wycieku w 3 cyklach
ładuj/zwolnij). W aplikacji (log etapów): asystent 0,36 s ładowania, 2,9 s pisania; przy kolejnym zadaniu obrazu
zwolnienie 0,13 s (4,35 → 0,31 GB), potem ładowanie Z-Image.

**Testy:** `swift test` 122 (w tym tekstowa logika asystenta i wyłączny dostęp do GPU w koordynatorze); integracyjne
asystenta 3/3 (każdy styl z polskiej idei, poprawianie, oddanie pamięci); integracyjne Core ML bez zmian w kodzie silnika
poza wydzieleniem `HuggingFaceDownloader`.

Uwaga z samotestu: Z-Image 1024² nadal bywa odrzucany przez budżet pamięci, gdy inne aplikacje zajmują pamięć
(„potrzeba ~12,3 GB, dostępne ~10,8 GB”) — niezależnie od asystenta.

## Galeria: miniatury z zachowaniem proporcji (2026-10-26)

- **Problem:** komórka siatki miała tylko stałą wysokość (160 pt), a miniatura była skalowana trybem `.fill`.
  Obrazy szersze niż komórka (np. 1216×832) wychodziły poza nią w poziomie, więc rysowały się na sąsiadach
  i przejmowały ich obszar kliknięcia. Zaznaczanie trafiało w złe obrazy.
- **Poprawka:** `GalleryCell` to kwadratowa komórka o szerokości kolumny. Cały obraz jest w niej wpasowany
  (`.fit`, z marginesem), a `contentShape` ogranicza kliknięcie do komórki. Podpowiedź pokazuje wymiary.
- **Weryfikacja:** zrzut samotestu (`NIS_SELFCHECK_QUICK=1` robi teraz też `6-gallery`) na 38 obrazach:
  poziome, pionowe i kwadratowe mieszczą się w swoich komórkach i nie nachodzą na siebie.
  139 testów jednostkowych zaliczonych, build bez ostrzeżeń.

## Galeria: podgląd z powiększaniem (2026-10-26)

- **Otwieranie:** dwuklik na miniaturze lub na podglądzie w panelu szczegółów, przycisk „Powiększ”
  albo „Powiększ” w menu kontekstowym. Podgląd zakrywa galerię, a Esc lub ✕ go zamyka.
- **Powiększanie:** szczypanie i inteligentny zoom na gładziku, ⌘ + kółko myszy (zoom pod kursorem),
  ⌘+ / ⌘− (progi 10–800%), „Dopasuj” (⌘0) i „100 %” (⌘1).
  Dwuklik przełącza między dopasowaniem a 100% w klikniętym miejscu.
  Obraz jest dekodowany w pełnej rozdzielczości (z orientacją EXIF) poza wątkiem głównym.
  Przewija się gładzikiem lub paskami, a mniejszy od okna obraz jest wyśrodkowany.
- **Nawigacja:** ← / → przechodzą po obrazach z bieżącego filtra, a zaznaczenie w galerii podąża za podglądem.
  W trybie dopasowania obraz dopasowuje się ponownie przy zmianie rozmiaru okna.
- **Implementacja:** `Features/Shared/ZoomableImageView.swift` (NSScrollView z `allowsMagnification`,
  `ZoomMath`, `ZoomController`), `Features/Gallery/GalleryViewer.swift`, `GalleryStore.viewerItemID`/`viewerZoom`/`neighbor`.
- **Weryfikacja:** testy `ZoomMath` (dopasowanie, progi, dwuklik) i nawigacji, razem 143 jednostkowe zaliczone.
  Samotest (zrzuty `6b`–`6d`) na obrazie 1024×1024: dopasowanie 92%, ⌘1 i ⌘+ dają 150% z wyśrodkowanym obrazem,
  a następny obraz wraca do dopasowania (92%).

## Kolejka: kolejne obrazy odrzucane „za mało pamięci” mimo załadowanego modelu (2026-10-27)

- **Objaw:** przy kilku obrazach w kolejce pierwszy się generował, a każdy następny kończył się błędem
  „Za mało pamięci: potrzeba … dostępne …”.
- **Odtworzenie:** nowa komenda `nis-poc queue` wysyła `--count` zadań przez prawdziwy koordynator, tak jak aplikacja.
  Dla Z-Image 768² ×3 zadania 2 i 3 były odrzucone.
- **Przyczyna:** pamięć zwolniona po zadaniu wraca do systemu z opóźnieniem. Zaraz po obrazie MLX ma aktywne
  7,95 GB (sam model), ale footprint procesu wynosi jeszcze 16,83 GB, „dostępne” 3,6 GB, a jądro chwilowo
  zgłasza krytyczną presję. 1 s później footprint to 8,14 GB, a dostępne 12,7 GB.
  Koordynator uruchamiał następne zadanie natychmiast, więc kontrola pamięci oceniała nieaktualny stan.
- **Poprawka:** `GenerationCoordinator.admit` ponownie sprawdza odrzucenie co 250 ms, aż pamięć się ustabilizuje
  (limit `memorySettleTimeout`, domyślnie 5 s). Dotyczy to kontroli przed załadowaniem i przed zadaniem.
  Gdy zadanie mieści się od razu, nie ma żadnego opóźnienia. Czas oczekiwania trafia do StageLog.
- **Weryfikacja:**
  - Z-Image 768² ×3: 3/3 ukończone, oczekiwanie 0,26 s przed zadaniem 2 i 3.
  - Juggernaut XL v9 1024² ×3 (Core ML): 3/3.
  - Test `jobWaitsForMemoryFreedByThePreviousJobToSettle` przechodzi z poprawką, a bez niej pada.
  - 144 testy jednostkowe zaliczone.
- **Obserwacja (bez zmian):** budżet dla Z-Image 1024² (12,3 GB ponad model) jest ostrożny. Uruchomiony z
  pominięciem budżetu przy ~10,6 GB „dostępnych” (i 17 GB zajętego swapu) wygenerował 2/2 obrazy w 11,0–13,4 s/krok
  zamiast 9,5.

## Ikona aplikacji (2026-10-27)

- `scripts/make-icon.swift` rysuje ikonę wektorowo (CoreGraphics) na siatce ikon macOS: tło 824 pt na płótnie 1024,
  gradient od indygo do koralu, przechylone zdjęcie z krajobrazem i iskry oznaczające „wygenerowane”.
  Tworzy wszystkie rozmiary `.iconset` (16–1024 px).
- `build-app.sh` generuje `.build/AppIcon.icns` przez `iconutil`, tylko gdy skrypt się zmienił.
  Kopiuje go do `Contents/Resources` i ustawia `CFBundleIconFile`. Do repozytorium trafia tylko skrypt, bez binariów.
- **Weryfikacja:** `NSWorkspace.icon(forFile:)` dla zbudowanego `.app` zwraca nową ikonę.
  Sprawdzona też czytelność w 32 pt (64 px).

## Galeria: foldery, przenoszenie zaznaczonych, usuwanie w podglądzie (2026-10-27)

- **Foldery to prawdziwe podkatalogi** `<katalog wyników>/Foldery/<nazwa>/`, więc są widoczne też w Finderze.
  Obraz przenosi się razem ze swoim plikiem JSON. Obrazy spoza folderów zostają w katalogach dziennych.
  Nic nie jest nadpisywane: przy kolizji nazwy dostaje przyrostek `-1`, `-2` itd.
  Import z dysku podąża za plikami przeniesionymi w Finderze, bez tworzenia duplikatów.
- **Interfejs:**
  - Pasek folderów nad siatką: „Wszystkie”, „Bez folderu” i każdy folder z liczbą obrazów, plus „Nowy folder”.
    Menu kontekstowe folderu: „Zmień nazwę…”, „Usuń folder…” (obrazy wracają do galerii głównej, żaden nie
    jest usuwany), „Pokaż w Finderze”.
  - Zaznaczone obrazy: „Przenieś do” (folder, „Nowy folder…” od razu z przeniesieniem, „Usuń z folderu”)
    i „Usuń”. To samo jest w menu kontekstowym miniatury.
  - Podgląd powiększenia: nazwa folderu, menu przenoszenia i kosz (⌫, z potwierdzeniem). Po usunięciu podgląd
    przechodzi do następnego obrazu, a na końcu listy do poprzedniego.
  - Panel szczegółów pokazuje wiersz „Folder”.
- **Błąd znaleziony w samoteście:** po zmianie nazwy folderu obraz trafiał do „Bez folderu”.
  `standardizedFileURL` usuwa `/private` tylko z istniejących ścieżek, a stara ścieżka już nie istniała.
  Porównanie ścieżek nie zależy już od stanu dysku (`canonicalComponents`).
- **Samotest piaskownicy** (`NIS_SELFCHECK_GALLERY=<katalog>`): osobny katalog wyników i indeks galerii w pamięci,
  więc obrazy użytkownika nie są ruszane. Na 15 obrazach testowych sprawdzono: utworzenie folderu, przeniesienie 2,
  filtr, podgląd z nazwą folderu, usunięcie w podglądzie (przejście do następnego) i zmianę nazwy (1 obraz w „Ulubione”).
- **Testy:** 153 jednostkowe zaliczone, w tym nowe dla operacji na plikach, filtrów i liczników,
  zmiany nazwy, usuwania folderu, importu po przeniesieniu w Finderze i przechodzenia podglądu po usunięciu.

## Podgląd w trakcie generowania (2026-10-27)

W czasie generowania w miejscu wyniku widać obraz w trakcie powstawania, nad paskiem postępu, z etykietą
„Podgląd · krok N/M”. Działa w zakładkach Generowanie i Edycja. Tryb wybiera się w Ustawienia → „Podgląd
w trakcie generowania”: przybliżony (domyślny), pełne dekodowanie albo wyłączony. Decyzja: D-012.

**Dopasowanie map latent → RGB** (`nis-poc preview-fit`, 10 promptów, ostatni odłożony):

| rodzina VAE | dane | błąd na odłożonym obrazie |
|---|---|---|
| flux2 (128 kanałów, token 16×16 px) | FLUX.2 Klein, 4 kroki, 512² | 28,4/255 |
| zimage (16 kanałów) | Z-Image Turbo, 8 kroków, 512² | 14,8/255 |
| sdxl (4 kanały, wspólny dla SDXL, Pony i WAI) | RealVisXL V5 Lightning, 6 kroków, 1024² | 25,8/255 |

**Narzut** (M4 Pro 24 GB, osobny proces na każdy tryb, po 2 obrazy, prompt z latarnią morską):

| model | bez podglądu | przybliżony | pełne dekodowanie | szczyt pamięci |
|---|---|---|---|---|
| FLUX.2 Klein 1024², 4 kroki | 30,9 s (śr. z 4) | 31,4 s (śr. z 4), +1,7% | 36,4 s (śr. z 4), +15%, 2 dekodowania | MLX 14,58 GB w każdym trybie |
| Z-Image 768², 8 kroków | 42,8 / 44,7 s | 42,6 / 44,1 s | — (przybliżony) | MLX 14,40 GB w obu |
| Juggernaut XL 1024², 35 kroków (ANE) | 93,7 / 92,3 s | 94,6 / 94,4 s, +1,6% | 101,6 / 100,1 s, +8% | proces 8,63–8,66 / 8,63–8,66 / 8,71 GB |

Pomiary FLUX są naprzemienne (off/approx, off/full). Pierwsza seria dała jeden odstający przebieg 46,4 s
w trybie przybliżonym; powtórzenie go nie odtworzyło.

**Weryfikacja wizualna** (zrzuty w scratchpadzie):
- Z-Image: od kroku 2 z 8 widać kompozycję i kolory.
- SDXL: od wczesnych kroków widać zarys, a w kroku 25 z 35 prawie gotowy obraz.
- FLUX.2: podgląd przybliżony od kroku 2 z 4. Pełne dekodowanie w krokach 2 i 3 jest ostre i bliskie wynikowi.
- Samotest aplikacji (`NIS_SELFCHECK_PREVIEW=1` w piaskownicy `NIS_SELFCHECK_GALLERY`) dla Juggernaut,
  Z-Image (768²) i FLUX.2: podgląd od kroku 2, każda generacja zakończona.

**Inne zmiany:**
- `AppSettings` dekoduje brakujące klucze jako wartości domyślne. Wcześniej każde nowe pole w ustawieniach
  kasowałoby zapisany folder wyników i limity pamięci.
- Wymaganie protokołu `setLivePreview` nie ma już pustej domyślnej implementacji. Wcześniej wywołanie
  trafiało w tę implementację zamiast w metodę aktora i podgląd nigdy się nie włączał (znalezione w CLI).
- Zmiany w kodzie dostawców opisują `Vendor/Flux2Swift/VENDORING.md` (punkt 4) i nowy `Vendor/ZImageSwift/VENDORING.md`.

**Testy:** 158 jednostkowych zaliczonych. Nowe testy obejmują:
- odtworzenie znanej mapy z danych syntetycznych (błąd wag < 0,01),
- transpozycję CHW,
- skalowanie zdekodowanego obrazu,
- wczytywanie wag z zasobów,
- podgląd w `JobSnapshot` i jego usunięcie po zakończeniu zadania.
