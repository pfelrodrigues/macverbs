# AGENTS.md — macverbs

Agent-first CLI for **macOS Mail, Reminders, Notes, and Calendar**.

Maintainer: [pfelrodrigues](https://github.com/pfelrodrigues). Product name is **macverbs**.

## Read first

| Doc | Why |
|-----|-----|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | **GitHub Flow** + Conventional Commits (source of truth for process) |
| [`docs/behavior.md`](docs/behavior.md) | CLI / JSON contract |
| [`README.md`](README.md) | Public pitch, install, permissions |
| [`docs/RELEASE.md`](docs/RELEASE.md) | Version + Homebrew release steps |
| [`SECURITY.md`](SECURITY.md) | Vulnerability reporting |

## Architecture (do not fight this)

```
Calendar + Reminders  →  EventKit
Mail + Notes          →  Apple Events (osascript / NSAppleScript)
```

- One binary, two backends. **Not** EventKit-only (Mail/Notes have no public EventKit API).
- **No icalBuddy** dependency — calendar listing is EventKit.
- Test seams: `EventStoreClient`, `ScriptRunner` (inject mocks; unit tests must not require live TCC).
- Side effects that touch mail/reminders must be **verifiable**. Never report success on silent no-ops. Gmail archive via Mail scripting is **unsupported** — refuse honestly.

## Tooling (mise)

```bash
mise trust          # once, if prompted
mise run setup      # git hooks → .githooks/ (format + conventional commits)
mise run format
mise run format-check
mise run lint
mise run build
mise run test
mise run coverage   # optional line coverage report
mise run check      # format-check + build + test (done gate)
mise run run -- --help
```

| Tool | Role | Config |
|------|------|--------|
| **`swift format`** | format + lint (Apple toolchain) | `.swift-format` |
| **git hooks** | pre-commit format; commit-msg Conventional Commits | `.githooks/` |

Prefer `mise run …` over bare `swift …`. Config dir: `MACVERBS_CONFIG_DIR` (default `~/.config/macverbs`). Never commit personal calendar UIDs or account names.

**GitHub CI:** Linux job on every push/PR (format only). Full macOS build+test is **manual** (`macos-check` workflow). Prefer local `mise run check`.

## Workflow (GitHub Flow)

1. `git checkout main && git pull --rebase`
2. `git checkout -b feat/<topic>` (or `fix|docs|test|chore|ci|refactor/…`)
3. Implement a **focused** change set
4. `mise run check`
5. Commit with Conventional Commits (hook enforces subject shape)
6. Push branch and open a **PR into `main`**
7. Do **not** push tags, Homebrew tap changes, or other publish steps without asking the maintainer

## Implementation rules

1. **One concern per PR** when practical (reviewable diff).
2. **Parity over invention.** Match established verb names and flag shapes unless `docs/behavior.md` says otherwise.
3. **English** for public code, comments, and user-facing CLI help.
4. **No secrets** in repo. Fixtures only: `Work`, `Personal`, `Acme`.
5. **Commits:** Conventional Commits required. No AI co-author trailers.
6. **External publish** (tap push, GitHub release): prepare locally, **ask before** any network publish.
7. **Not in scope:** WhatsApp, Teams, SharePoint, TFS, Jamie, Graph, private SQLite hacks, automatic email send.
