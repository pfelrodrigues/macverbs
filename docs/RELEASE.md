# Release checklist

External steps (tag push, GitHub release, tap formula) require **explicit
maintainer approval** unless the maintainer is doing the release themselves.

## Versioning policy

| Band | When |
|------|------|
| **0.1.x** | Bug fixes, docs, small DX while dogfood runs alongside legacy tools |
| **0.2.0** | Maintainer dogfood stable; ready to treat macverbs as the primary CLI |
| **≥1.0** | Stable JSON contract commitment (breaking changes need major bump) |

Bump `Version.current` in `Sources/macverbs/Macverbs.swift` in the same PR as
the release. Keep [`CHANGELOG.md`](../CHANGELOG.md) updated under
`## [Unreleased]` then move notes into the version section at tag time.

## 1. Local gate

```bash
mise run check
# optional higher bar:
mise run check-coverage   # COVERAGE_MIN=97 by default
swift build -c release
.build/release/macverbs --version
```

Helper (bumps `Version.current`, runs check/build; does not push without flag):

```bash
bash scripts/release.sh 0.1.2           # prepare locally
# after version PR is on main and you intend to publish:
bash scripts/release.sh 0.1.2 --push    # tag, GH release, rewrite Formula sha256
```

Optional: run the **macOS check** workflow (`workflow_dispatch` or wait for the
weekly schedule) before tagging.

## 2. Tag and GitHub release

```bash
git checkout main && git pull --rebase
git tag -a v0.1.2 -m "macverbs 0.1.2"
git push origin v0.1.2
gh release create v0.1.2 --generate-notes
```

## 3. Formula checksum

```bash
curl -sL "https://github.com/pfelrodrigues/macverbs/archive/refs/tags/v0.1.2.tar.gz" \
  | shasum -a 256
```

Update `Formula/macverbs.rb` in this repo: `url`, `sha256`, `version`, and the
`test do` version assertion. Open a PR, merge on green.

## 4. Homebrew tap

Canonical tap: **`pfelrodrigues/homebrew-tap`**  
Install: **`brew install pfelrodrigues/tap/macverbs`** (or `brew install macverbs`
after `brew tap pfelrodrigues/tap`).

Copy the formula into the tap repo, commit, push `main`.

## 5. Install verify

```bash
brew update
brew upgrade macverbs   # or reinstall
macverbs --version
macverbs doctor
```

## 6. homebrew-core (later)

Not required for personal tap users. Track as a separate effort after 0.2+
and a stable install base.
