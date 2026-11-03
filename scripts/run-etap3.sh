#!/bin/zsh
# Etap 3 measurements: Core ML SDXL (RealVisXL Lightning) + MLX vs Core ML under equal conditions.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=.build/xcode/Build/Products/Release/nis-poc
LOG=docs/bench/etap3.jsonl
OUT=out/etap3
SDXL=realvisxl-v5-lightning-coreml
FLUX=flux2-klein-4b
PERSON=$(head -1 out/etap1/refs.txt)
run() { echo "\n=== $* ==="; "$BIN" "$@" --bench-log "$LOG" --out "$OUT" 2>&1 | grep -vE "^  step |Needed to truncate" ; }

run t2i --model $SDXL --count 10 --seed 1 --note "10x t2i sdxl"
for s in 0.3 0.6 0.9; do
  run i2i --model $SDXL --image "$PERSON" --strength $s --edit-prompt "film photo, warm golden hour light, 35mm grain" --note "i2i strength $s"
done
run cancel --model $SDXL --cancel-after-step 2 --note "cancel after step 2"
run unload --model $SDXL --note "unload test"
run t2i --model $SDXL --count 2 --seed 1 --compute-units cpuAndGPU --note "compute units cpuAndGPU"

# Equal conditions: same prompt, 1024x1024, 4 steps, seeds 101-105, text-to-image, alternating backends.
PROMPT="a photorealistic portrait of an elderly fisherman in a yellow raincoat on a pier at dawn"
for seed in 101 102 103 104 105; do
  run t2i --model $FLUX --count 1 --seed $seed --steps 4 --prompt "$PROMPT" --note "compare equal"
  run t2i --model $SDXL --count 1 --seed $seed --steps 4 --prompt "$PROMPT" --note "compare equal"
done
