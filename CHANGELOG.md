# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-07-26

Packaging and project maturity for OSS consumers. No intentional JSON contract
breakage vs 0.1.1.

### Added

- Library target **`MacverbsCore`** with thin `macverbs` executable entry.
- OSS community files: issue templates, Code of Conduct, CODEOWNERS, Dependabot
  (including security updates).
- `docs/usage.md` (recipes + FAQ), Keep a Changelog, `scripts/release.sh`.
- Expanded trust/security docs (TCC diagram, supply chain, non-sandboxed CLI).
- Root help and domain `--help` discussions with examples.
- GitHub Discussions, repository topics, README demo session.
- Optional pre-push coverage gate (`git config macverbs.coveragePush true`).
- macOS CI: SPM cache; weekly job uploads llvm-cov summary artifact;
  opt-in PR label `ci-macos`.

### Changed

- Split monolithic tests into domain files; shared mocks in `TestMocks.swift`.
- Split Mail, Reminders, and EventStore sources (models / scripts / live / CLI).
- Behavior doc framed as the public contract (not internal migration notes).
- User-facing “not wired” errors no longer reference internal task IDs.
- `Package.resolved` is tracked for reproducible SPM resolution.
- Linux CI documented as format-only (product is macOS-only).

## [0.1.1] - 2026-07-26

### Fixed

- All-day calendar `when` no longer inverts when EventKit reports end on the
  same calendar day as start (clamp inclusive last day to `start`).

### Changed

- Documented deliberate exit-code contract vs the legacy Python `apple` CLI
  (stderr `error: …`, usage exit 64).

## [0.1.0] - 2026-07-26

### Added

- Initial public release: Calendar and Reminders (EventKit), Mail and Notes
  (Apple Events), `doctor`, `config` / `calendars.json`, shell completions,
  Homebrew formula on `pfelrodrigues/tap`.
- Hybrid architecture with injectable test seams; unit tests without live TCC
  for most paths.
- GitHub Flow + Conventional Commits contributor docs.

[Unreleased]: https://github.com/pfelrodrigues/macverbs/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/pfelrodrigues/macverbs/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/pfelrodrigues/macverbs/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/pfelrodrigues/macverbs/releases/tag/v0.1.0
