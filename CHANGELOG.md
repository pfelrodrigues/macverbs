# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Usage guide (`docs/usage.md`), Keep a Changelog file, and expanded contributor
  notes (coverage gate, macOS CI, versioning policy).

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

[Unreleased]: https://github.com/pfelrodrigues/macverbs/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/pfelrodrigues/macverbs/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/pfelrodrigues/macverbs/releases/tag/v0.1.0
