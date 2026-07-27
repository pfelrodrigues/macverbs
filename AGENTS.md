# AGENTS.md — notes for coding agents

**Humans contributing by hand:** start with [`CONTRIBUTING.md`](CONTRIBUTING.md)
and [`docs/usage.md`](docs/usage.md). This file is optimized for AI coding agents
working in a checkout of this repository.

## Product

Agent-first CLI for **macOS Mail, Reminders, Notes, and Calendar**.
Maintainer: [pfelrodrigues](https://github.com/pfelrodrigues).

## Read first

| Doc | Why |
|-----|-----|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | GitHub Flow + Conventional Commits |
| [`docs/usage.md`](docs/usage.md) | Recipes |
| [`docs/behavior.md`](docs/behavior.md) | JSON / exit-code contract |
| [`README.md`](README.md) | Install, TCC, command overview |
| [`CHANGELOG.md`](CHANGELOG.md) | Releases |
| [`docs/RELEASE.md`](docs/RELEASE.md) | Tag + Homebrew formula |
| [`SECURITY.md`](SECURITY.md) | Vuln reporting + trust model |

## Architecture

```
MacverbsCore (library)     — domain + CLI commands + seams
macverbs (executable)      — process entry only (Sources/macverbs/Entry.swift)

Calendar + Reminders  →  EventKit
Mail + Notes          →  Apple Events (osascript)
```

- Injectable seams: `EventStoreClient`, `ScriptRunner` (unit tests without live TCC).
- Side effects must be **verifiable**. Gmail archive via scripting is **unsupported** — refuse honestly.
- Package layout: tests `@testable import MacverbsCore`.

## Tooling (mise)

```bash
mise trust
mise run setup
mise run check              # format + build + test
mise run check-coverage     # optional ≥97% Sources lines
mise run run -- --help
```

Prefer `mise run …` over bare `swift …`. Config: `MACVERBS_CONFIG_DIR` (default
`~/.config/macverbs`). Never commit personal UIDs or real mailbox names.

## Workflow

1. Branch from `main` (`feat|fix|docs|test|chore|ci|refactor/…`)
2. Focused change; `mise run check`
3. Conventional Commits (hook enforces subject)
4. PR into `main`; do not push tags/tap without maintainer approval

## Rules

1. English for code, comments, CLI help, public docs.
2. Match `docs/behavior.md` shapes.
3. No secrets; fixtures `Work`, `Personal`, `Acme`.
4. No AI co-author trailers on commits.
5. Out of scope: WhatsApp, Teams, Graph, automatic email send, iOS.
