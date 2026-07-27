#!/usr/bin/env bash
# Configure this clone to use repo-managed hooks under .githooks/
set -euo pipefail
cd "$(dirname "$0")/.."

chmod +x .githooks/pre-commit .githooks/commit-msg 2>/dev/null || true
git config core.hooksPath .githooks
echo "git core.hooksPath → .githooks"
echo "pre-commit:  swift format (staged) + swift format lint --strict"
echo "commit-msg:  Conventional Commits subject check"
