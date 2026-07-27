#!/usr/bin/env bash
# Run tests with instrumentation and print line coverage for Sources/macverbs.
# Optional: COVERAGE_MIN=97 bash scripts/coverage.sh  (fail if below threshold)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash scripts/swift_test.sh --enable-code-coverage

BIN="$(find .build -type f -path '*macverbsPackageTests.xctest/Contents/MacOS/macverbsPackageTests' ! -path '*.dSYM*' | head -1)"
PROF="$(find .build -name 'default.profdata' | head -1)"

if [[ -z "$BIN" || -z "$PROF" ]]; then
  echo "error: coverage artifacts not found (bin/profdata)" >&2
  exit 2
fi

echo "== llvm-cov report (Sources/macverbs) =="
xcrun llvm-cov report "$BIN" \
  -instr-profile="$PROF" \
  -ignore-filename-regex='.build|Tests|checkouts|runner.swift|ArgumentParser'

LCOV="$(mktemp -t macverbs-cov.XXXXXX.lcov)"
xcrun llvm-cov export "$BIN" \
  -instr-profile="$PROF" \
  -format=lcov \
  -ignore-filename-regex='.build|Tests|checkouts|runner.swift|ArgumentParser' \
  >"$LCOV"

python3 - "$LCOV" "${COVERAGE_MIN:-}" <<'PY'
import sys
from collections import defaultdict

lcov_path = sys.argv[1]
min_pct = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None

cur = None
total = defaultdict(int)
hit = defaultdict(int)
missed = defaultdict(list)

with open(lcov_path) as f:
    for line in f:
        line = line.strip()
        if line.startswith("SF:"):
            path = line[3:]
            if "Sources/macverbs/" in path:
                cur = path.split("Sources/macverbs/")[-1]
            else:
                cur = None
        elif cur and line.startswith("DA:"):
            n, c = line[3:].split(",")
            total[cur] += 1
            if int(c) == 0:
                missed[cur].append(int(n))
            else:
                hit[cur] += 1
        elif line == "end_of_record":
            cur = None

print("\n== line coverage by file ==")
for name in sorted(total):
    t = total[name]
    h = hit[name]
    pct = 100.0 * h / t if t else 0.0
    print(f"{name:28s} {h:4d}/{t:4d}  {pct:5.1f}%")
    if missed[name]:
        print(f"  missed lines: {missed[name][:20]}{'…' if len(missed[name]) > 20 else ''}")

th = sum(hit.values())
tt = sum(total.values())
pct = 100.0 * th / tt if tt else 0.0
print(f"\nTOTAL lines: {th}/{tt}  {pct:.2f}%")

if min_pct:
    need = float(min_pct)
    if pct + 1e-9 < need:
        print(f"error: coverage {pct:.2f}% < COVERAGE_MIN={need}", file=sys.stderr)
        sys.exit(1)
    print(f"ok: coverage {pct:.2f}% >= {need}")
PY
