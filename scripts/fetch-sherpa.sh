#!/usr/bin/env bash
# Fetches the pinned sherpa-onnx macOS arm64 libraries, C header and speaker model into vendor/.
# Every download is checked against a recorded SHA-256 before it is used.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
version="1.13.8"
dest="$repo/vendor/sherpa-onnx"

lib_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v$version/sherpa-onnx-v$version-osx-arm64-shared-lib.tar.bz2"
lib_sha="ae77050cdae565496059d96f5ab33d77b397a0864282a4e4a26e3b3b3effb948" # GitHub release digest
header_url="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$version/sherpa-onnx/c-api/c-api.h"
license_url="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$version/LICENSE"
model_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx"
model_sha="c59158379255ad66e161679cca6af8d52d51e389e3224ab7d7a7baae295c2db5" # first download, 2026-10-12

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() { # url sha256 output
  curl -fsSL -o "$work/download" "$1"
  echo "$2  $work/download" | shasum -a 256 -c --quiet
  mv "$work/download" "$3"
}

mkdir -p "$dest/lib" "$dest/include/sherpa-onnx/c-api" "$dest/models"

fetch "$lib_url" "$lib_sha" "$work/lib.tar.bz2"
tar -xjf "$work/lib.tar.bz2" -C "$work"
cp "$work/sherpa-onnx-v$version-osx-arm64-shared-lib/lib/libsherpa-onnx-c-api.dylib" \
   "$work/sherpa-onnx-v$version-osx-arm64-shared-lib/lib/libonnxruntime.dylib" "$dest/lib/"

# The header and license come from the same tag. GitHub doesn't publish digests for raw files,
# so they're checked against the hashes recorded when this script was written.
fetch "$header_url" "$(cat "$repo/vendor/sherpa-onnx/c-api.h.sha256")" "$dest/include/sherpa-onnx/c-api/c-api.h"
fetch "$license_url" "$(cat "$repo/vendor/sherpa-onnx/LICENSE.sha256")" "$dest/LICENSE"
fetch "$model_url" "$model_sha" "$dest/models/3dspeaker-eres2net-en.onnx"

echo "sherpa-onnx $version ready in $dest"
