#!/usr/bin/env bash
# Regenerate shell completion scripts from the built macverbs binary.
# Usage: from repo root, after `mise run build` (or with a custom binary path):
#   bash scripts/generate-completions.sh
#   MACVERBS_BIN=/path/to/macverbs bash scripts/generate-completions.sh

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

bin="${MACVERBS_BIN:-}"
if [[ -z "$bin" ]]; then
  if [[ -x .build/debug/macverbs ]]; then
    bin=".build/debug/macverbs"
  elif [[ -x .build/release/macverbs ]]; then
    bin=".build/release/macverbs"
  else
    echo "error: no macverbs binary; run mise run build first" >&2
    exit 1
  fi
fi

if [[ ! -x "$bin" ]]; then
  echo "error: not executable: $bin" >&2
  exit 1
fi

mkdir -p completions
"$bin" --generate-completion-script fish >completions/macverbs.fish
"$bin" --generate-completion-script zsh >completions/_macverbs
"$bin" --generate-completion-script bash >completions/macverbs.bash

echo "wrote completions/macverbs.fish"
echo "wrote completions/_macverbs"
echo "wrote completions/macverbs.bash"
