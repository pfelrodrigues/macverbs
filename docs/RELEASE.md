# Release checklist (v0.1.0+)

External steps require **explicit maintainer approval** (push tag, create tap, publish formula).

## 1. Local gate

```bash
mise run check
.build/release/macverbs --version   # after: swift build -c release
```

## 2. Tag (GitHub)

```bash
git tag -a v0.1.0 -m "macverbs 0.1.0"
# only after approval:
git push origin v0.1.0
gh release create v0.1.0 --generate-notes
```

## 3. Formula archive checksum

```bash
curl -sL "https://github.com/pfelrodrigues/macverbs/archive/refs/tags/v0.1.0.tar.gz" | shasum -a 256
```

Update `Formula/macverbs.rb`: `url` → tag archive, set `sha256`, set `version "0.1.0"`.

## 4. Homebrew tap (one-time)

```bash
# after approval — creates public repo
gh repo create pfelrodrigues/homebrew-macverbs --public --description "Homebrew tap for macverbs"
```

Copy formula to `homebrew-macverbs/Formula/macverbs.rb` and push.

## 5. Install verify

```bash
brew tap pfelrodrigues/macverbs
brew install macverbs
macverbs --version
macverbs doctor
```

## 6. Close roadmap tasks

- T23: tag + formula + post-install version
- T25: README install section (no “scaffold only”)
