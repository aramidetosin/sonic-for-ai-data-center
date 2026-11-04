#!/bin/bash
# fetch-dl.sh: the two downloads the image builds need, pinned by SHA-256, into images/ai-sim/dl/ (and a copy of the llama.cpp release
# into images/llm/dl/): llama.cpp release b11382 for Ubuntu x64, and Qwen2.5-0.5B-Instruct in GGUF Q4_K_M (Apache-2.0).
set -eu
cd "$(dirname "$0")"
mkdir -p ai-sim/dl llm/dl
get() {   # get <url> <file> <sha256>
  [ -s "$2" ] && echo "$3  $2" | sha256sum -c --quiet - 2>/dev/null && { echo "have $2"; return; }
  curl -fL --retry 5 -o "$2" "$1"
  echo "$3  $2" | sha256sum -c - || { echo "checksum mismatch: $2"; exit 1; }
}
get https://github.com/ggml-org/llama.cpp/releases/download/b11382/llama-b11382-bin-ubuntu-x64.tar.gz ai-sim/dl/llama.tar.gz \
    34407d59947ed4ab35fe4ab2db5f61bb4d5aedfe25e6a72f702f3ae9758a396d
get https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf ai-sim/dl/model.gguf \
    74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db
cp -p ai-sim/dl/llama.tar.gz llm/dl/llama.tar.gz
echo "ready: ai-sim/dl and llm/dl"
