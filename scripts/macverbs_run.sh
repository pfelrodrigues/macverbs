#!/usr/bin/env bash
# Run the macverbs product without injecting a spurious empty argv entry.
# mise's {{arg(..., default='')}} passes "" when no args are given; ArgumentParser
# treats that as Unexpected argument ''.
set -euo pipefail
cd "$(dirname "$0")/.."

args=()
for a in "$@"; do
  if [[ -n "$a" ]]; then
    args+=("$a")
  fi
done

if [[ ${#args[@]} -eq 0 ]]; then
  exec swift run macverbs
fi
exec swift run macverbs "${args[@]}"
