# Release checklist

For maintainers shipping a tagged build and Homebrew formula. Consumers only
need `brew upgrade macverbs` (or install from the tap).

## Versioning policy

| Band | When |
|------|------|
| **0.1.x** | Bug fixes, docs, DX, packaging; dogfood may still use other tools |
| **0.2.0** | Project is the recommended primary CLI for its scope |
| **≥1.0** | Stable JSON contract commitment (breaking changes need a major bump) |

Always bump `Version.current` in
[`Sources/MacverbsCore/Macverbs.swift`](../Sources/MacverbsCore/Macverbs.swift)
in the same change set as the release notes.

Keep [`CHANGELOG.md`](../CHANGELOG.md) current: draft under `## [Unreleased]`,
then move bullets into `## [x.y.z] - YYYY-MM-DD` when tagging. Update the
compare links at the bottom of that file.

## End-to-end flow (recommended)

```text
1. PR: version bump + CHANGELOG (+ any last docs)
2. Merge to main (CI green)
3. Tag vX.Y.Z on main, push tag, create GitHub Release
4. Compute sha256 of the tag tarball
5. PR: Formula/macverbs.rb (url, sha256, version, test)
6. Copy the same formula to pfelrodrigues/homebrew-tap and push
7. Consumers: brew update && brew upgrade macverbs
```

Helper script (local assist; still follow the PR/tag order above):

```bash
bash scripts/release.sh 0.1.2           # check + bump Version.current locally
# after version is on main and you are ready to publish:
bash scripts/release.sh 0.1.2 --tag     # tag + push + GH release (no formula rewrite)
bash scripts/release.sh 0.1.2 --formula # sha256 + rewrite Formula/ (commit separately)
```

## 1. Local gate (before the version PR)

```bash
mise run check
# optional:
mise run check-coverage   # COVERAGE_MIN=97 by default
swift build -c release
.build/release/macverbs --version
```

Optional: trigger **macOS check** on GitHub
(`workflow_dispatch` on [macos-check.yml](../.github/workflows/macos-check.yml))
before tagging.

## 2. Tag and GitHub Release

After the version PR is on `main`:

```bash
git checkout main && git pull --rebase
git tag -a v0.1.2 -m "macverbs 0.1.2"
git push origin v0.1.2
gh release create v0.1.2 --generate-notes --title "v0.1.2"
```

Prefer an **annotated** tag. The tarball URL used by Homebrew is:

`https://github.com/pfelrodrigues/macverbs/archive/refs/tags/v0.1.2.tar.gz`

## 3. Formula checksum (this repo)

```bash
curl -sL "https://github.com/pfelrodrigues/macverbs/archive/refs/tags/v0.1.2.tar.gz" \
  | shasum -a 256
```

Update [`Formula/macverbs.rb`](../Formula/macverbs.rb):

- `url` → tag archive
- `sha256` → checksum above
- `version "…"`
- `test do` / `assert_match` version string

Open a short PR, merge on green. The in-repo formula is the **source of truth**
for the next tap update.

## 4. Homebrew tap

Canonical tap: **[pfelrodrigues/homebrew-tap](https://github.com/pfelrodrigues/homebrew-tap)**  

Install:

```bash
brew install pfelrodrigues/tap/macverbs
# or, after brew tap pfelrodrigues/tap:
brew install macverbs
```

Copy `Formula/macverbs.rb` from this repository into the tap’s `Formula/` and
push `main`. Keep the two files identical for each release.

## 5. Consumer verify (on their machine)

```bash
brew update
brew upgrade macverbs
macverbs --version    # expect the new version
macverbs doctor
```

## 6. homebrew-core (later)

Not required for personal-tap users. Revisit after 0.2+ and a broader install
base.
