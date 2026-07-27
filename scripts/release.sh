#!/usr/bin/env bash
# Assist a macverbs release (does not push unless --push).
# Usage:
#   bash scripts/release.sh 0.1.2           # prepare notes + formula fields locally
#   bash scripts/release.sh 0.1.2 --push    # also tag, push tag, create GH release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

version="${1:-}"
push_flag="${2:-}"
if [[ -z "$version" || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <semver> [--push]" >&2
  exit 2
fi
tag="v${version}"

echo "== gate =="
mise run check

echo "== bump Version.current =="
perl -pi -e "s/static let current = \"[^\"]+\"/static let current = \"${version}\"/" \
  Sources/MacverbsCore/Macverbs.swift

echo "== build release binary =="
swift build -c release
./.build/release/macverbs --version | tee /tmp/macverbs-ver.txt
grep -q "${version}" /tmp/macverbs-ver.txt

echo "== note =="
echo "1. Commit the version bump on a PR and merge to main."
echo "2. Then: git tag -a ${tag} -m \"macverbs ${version}\" && git push origin ${tag}"
echo "3. Re-run with --push after the tag exists on GitHub, or continue below."

if [[ "$push_flag" != "--push" ]]; then
  echo "Stopped before tag/formula (pass --push after main has the version bump + tag is intended)."
  echo "After tagging, compute sha256:"
  echo "  curl -sL \"https://github.com/pfelrodrigues/macverbs/archive/refs/tags/${tag}.tar.gz\" | shasum -a 256"
  exit 0
fi

if ! git rev-parse "${tag}" >/dev/null 2>&1; then
  git tag -a "${tag}" -m "macverbs ${version}"
fi
git push origin "${tag}"
gh release create "${tag}" --generate-notes --title "${tag}" || true

echo "== formula sha256 =="
sha="$(curl -sL "https://github.com/pfelrodrigues/macverbs/archive/refs/tags/${tag}.tar.gz" | shasum -a 256 | awk '{print $1}')"
echo "sha256=${sha}"

perl -pi -e "s|refs/tags/v[0-9.]+.tar.gz|refs/tags/${tag}.tar.gz|" Formula/macverbs.rb
perl -pi -e "s/sha256 \"[a-f0-9]+\"/sha256 \"${sha}\"/" Formula/macverbs.rb
if grep -q 'version "' Formula/macverbs.rb; then
  perl -pi -e "s/version \"[0-9.]+\"/version \"${version}\"/" Formula/macverbs.rb
else
  # insert version after sha256 line if missing
  perl -pi -e "s/(sha256 \"${sha}\")/\$1\n  version \"${version}\"/" Formula/macverbs.rb
fi
perl -pi -e "s/assert_match \"[0-9.]+\"/assert_match \"${version}\"/" Formula/macverbs.rb

echo "Updated Formula/macverbs.rb — open a PR, then copy the same file to homebrew-tap."
echo "Done."
