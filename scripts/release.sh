#!/usr/bin/env bash
# Assist a macverbs release. Does not open PRs; does not run brew upgrade.
#
# Usage:
#   bash scripts/release.sh 0.1.2              # check + bump Version.current
#   bash scripts/release.sh 0.1.2 --tag        # on main: annotated tag, push, GH release
#   bash scripts/release.sh 0.1.2 --formula    # sha256 + rewrite Formula/macverbs.rb
#
# Typical order after a version PR is on main:
#   bash scripts/release.sh 0.1.2 --tag
#   bash scripts/release.sh 0.1.2 --formula
#   # PR Formula in this repo; copy Formula/macverbs.rb to homebrew-tap
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

version="${1:-}"
mode="${2:-}"
if [[ -z "$version" || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <semver> [--tag|--formula]" >&2
  exit 2
fi
tag="v${version}"
version_file="Sources/MacverbsCore/Macverbs.swift"

if [[ -z "$mode" ]]; then
  echo "== gate (mise run check) =="
  if command -v mise >/dev/null 2>&1; then
    mise run check
  else
    bash scripts/swift_test.sh
  fi

  echo "== bump Version.current → ${version} =="
  if [[ ! -f "$version_file" ]]; then
    echo "error: missing $version_file" >&2
    exit 1
  fi
  perl -pi -e "s/static let current = \"[^\"]+\"/static let current = \"${version}\"/" \
    "$version_file"

  echo "== release binary =="
  swift build -c release
  ./.build/release/macverbs --version | tee /tmp/macverbs-ver.txt
  grep -q "${version}" /tmp/macverbs-ver.txt

  echo
  echo "Next:"
  echo "  1. Commit Version + CHANGELOG on a PR and merge to main."
  echo "  2. On main: $0 ${version} --tag"
  echo "  3. Then:    $0 ${version} --formula  (PR Formula; copy to homebrew-tap)"
  exit 0
fi

if [[ "$mode" == "--tag" ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" != "main" ]]; then
    echo "error: --tag should run on main (current: ${branch})" >&2
    exit 1
  fi
  git pull --rebase origin main

  if ! grep -q "static let current = \"${version}\"" "$version_file"; then
    echo "error: Version.current is not ${version} on main; merge the version PR first" >&2
    exit 1
  fi

  if git rev-parse "${tag}" >/dev/null 2>&1; then
    echo "tag ${tag} already exists locally"
  else
    git tag -a "${tag}" -m "macverbs ${version}"
    echo "created annotated tag ${tag}"
  fi

  git push origin "${tag}"
  if gh release view "${tag}" >/dev/null 2>&1; then
    echo "GitHub release ${tag} already exists"
  else
    notes="See [CHANGELOG.md](https://github.com/pfelrodrigues/macverbs/blob/${tag}/CHANGELOG.md) for details."
    gh release create "${tag}" --title "${tag}" --notes "${notes}" --generate-notes
  fi
  echo "Tagged and released ${tag}."
  echo "Next: $0 ${version} --formula"
  exit 0
fi

if [[ "$mode" == "--formula" ]]; then
  if ! git rev-parse "${tag}" >/dev/null 2>&1; then
    if ! git ls-remote --tags origin "refs/tags/${tag}" | grep -q .; then
      echo "error: tag ${tag} not found; run --tag first" >&2
      exit 1
    fi
    git fetch origin "refs/tags/${tag}:refs/tags/${tag}"
  fi

  echo "== download tarball sha256 for ${tag} =="
  url="https://github.com/pfelrodrigues/macverbs/archive/refs/tags/${tag}.tar.gz"
  sha="$(curl -fsSL "$url" | shasum -a 256 | awk '{print $1}')"
  echo "sha256=${sha}"

  perl -pi -e "s|refs/tags/v[0-9.]+\\.tar\\.gz|refs/tags/${tag}.tar.gz|" Formula/macverbs.rb
  perl -pi -e "s/sha256 \"[a-f0-9]+\"/sha256 \"${sha}\"/" Formula/macverbs.rb
  if grep -q 'version "' Formula/macverbs.rb; then
    perl -pi -e "s/version \"[0-9.]+\"/version \"${version}\"/" Formula/macverbs.rb
  else
    perl -pi -e "s/(sha256 \"${sha}\")/\$1\n  version \"${version}\"/" Formula/macverbs.rb
  fi
  perl -pi -e "s/assert_match \"[0-9.]+\"/assert_match \"${version}\"/" Formula/macverbs.rb

  echo "Updated Formula/macverbs.rb"
  echo "Commit/PR this file, then copy to github.com/pfelrodrigues/homebrew-tap Formula/macverbs.rb"
  exit 0
fi

echo "unknown mode: ${mode} (use --tag or --formula)" >&2
exit 2
