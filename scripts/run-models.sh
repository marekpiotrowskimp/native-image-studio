#!/bin/zsh
# Measures every given model at its manifest defaults (same prompt, seeds 1–2), one process
# per model. Results: docs/bench/models.jsonl, images: out/models (git-ignored).
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=.build/xcode/Build/Products/Release/nis-poc
PROMPT="a photorealistic portrait of an elderly fisherman in a yellow raincoat on a pier at dawn"
for m in "$@"; do
  echo "\n=== $m"
  "$BIN" t2i --model "$m" --count 2 --seed 1 --prompt "$PROMPT" --note "defaults" \
    --bench-log docs/bench/models.jsonl --out out/models 2>&1 | grep -E "load\]|^\| |→|ERROR" | grep -v "^| model\|^|---"
done
