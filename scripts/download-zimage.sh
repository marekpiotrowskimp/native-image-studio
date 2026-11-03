#!/bin/zsh
# Downloads Z-Image Turbo base components (Apache-2.0) and the CyberRealistic Z-Image Turbo
# v4.0 transformer (CreativeML Open RAIL-M) into Application Support. Resumable (curl -C -).
set -u
D="$HOME/Library/Application Support/NativeImageStudio/ZImage"
B=https://huggingface.co/Tongyi-MAI/Z-Image-Turbo/resolve/main
for f in model_index.json scheduler/scheduler_config.json transformer/config.json text_encoder/config.json text_encoder/generation_config.json text_encoder/model.safetensors.index.json text_encoder/model-00001-of-00003.safetensors text_encoder/model-00002-of-00003.safetensors text_encoder/model-00003-of-00003.safetensors tokenizer/merges.txt tokenizer/tokenizer.json tokenizer/tokenizer_config.json tokenizer/vocab.json vae/config.json vae/diffusion_pytorch_model.safetensors; do
  mkdir -p "$D/base/$(dirname $f)"
  curl -sfL -C - -o "$D/base/$f" "$B/$f" && echo "ok $f" || echo "FAIL $f"
done
curl -sfL -C - -o "$D/cyberrealistic/CyberRealistic_zit_v4.0.safetensors" https://huggingface.co/cyberdelia/cyberrealistic_zimage/resolve/main/CyberRealistic_zit_v4.0.safetensors && echo "ok cyberrealistic" || echo "FAIL cyberrealistic"
echo DONE
