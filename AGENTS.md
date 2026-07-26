# AGENTS.md — macverbs

Agent-first CLI for **macOS Mail, Reminders, Notes, and Calendar**.

Maintainer: [pfelrodrigues](https://github.com/pfelrodrigues). Product name is **macverbs** (not a personal dump of private configs).

## Read first

| Doc | Why |
|-----|-----|
| `docs/ROADMAP.md` | Index of work; how to run the loop |
| `docs/tasks/T*.md` | One task = one workflow cycle; frontmatter `status` |
| `docs/behavior.md` | CLI/JSON contract |
| `README.md` | Public pitch and status |
| `~/nix/clis/apple` | Behavior **oracle** (Python) while porting — env `MACVERBS_APPLE_SPEC` |

## Architecture (do not fight this)

```
Calendar + Reminders  →  EventKit
Mail + Notes          →  Apple Events (osascript / NSAppleScript)
```

- One binary, two backends. **Not** EventKit-only (Mail/Notes have no public EventKit API).
- **No icalBuddy** dependency — calendar listing is EventKit.
- Test seams: `EventStoreClient`, `ScriptRunner` (inject mocks; unit tests must not require live TCC).
- Side effects that touch mail/reminders must be **verifiable** (e.g. re-count after archive). Never report success on silent no-ops. Gmail archive via Mail scripting is **unsupported** — refuse honestly.

## Tooling (mise)

Project is isolated with **mise**. From repo root:

```bash
mise trust          # once, if prompted
mise run setup      # git hooks → .githooks/
mise run tasks-list
mise run next
mise run format     # Apple `swift format` (write)
mise run format-check
mise run lint       # same engine, lint --strict
mise run build
mise run test
mise run check      # format-check + build + test (done gate)
mise run run -- --help
```

| Tool | Role | Config |
|------|------|--------|
| **`swift format`** | format + lint (official Apple toolchain) | `.swift-format` |
| **git hooks** | pre-commit format staged + lint strict | `.githooks/` via `mise run hooks-install` |

- Prefer `mise run …` over bare `swift …` so env is consistent.
- Compiler and `swift format` come from **Apple CLT/Xcode** on PATH (no third-party SwiftFormat/SwiftLint required).
- Config dir: `MACVERBS_CONFIG_DIR` (default `~/.config/macverbs`). Never commit personal calendar UIDs or account names (Vert, PYO, …).
- Before claiming a task done: **`mise run check` must pass** (includes format/lint).
- **GitHub CI:** Linux job on every push (format only). Full macOS build+test is **manual** (`macos-check` workflow) — do not assume Actions validates EventKit/Mail. Prefer local `mise run check`.

## Workflow loop

Registered workflow: **`implement-task`** (`.grok/workflows/implement-task.rhai`).

```text
args.task = "T01"   # explicit
args.task = "next"  # first pending non-manual
```

Each cycle: load task → implement only that task → `mise run check` → review → set task `status: done` if green.

**Manual tasks** (`manual: true` in frontmatter): T12, T19 — do not auto-complete; pause for the human.

## Implementation rules

1. **One task per change set.** Do not start T0N+1 inside T0N.
2. **Honor `depends`.** If a dependency is not `status: done`, stop and report.
3. **Parity over invention.** Match `apple` verb names and flag shapes unless `docs/behavior.md` says otherwise.
4. **English** for public code, comments, and user-facing CLI help. Task docs may stay bilingual as they are.
5. **No secrets** in repo. No real mailbox names from the maintainer’s machine in tests — use fixtures (`Work`, `Personal`, `Acme`).
6. **Commits:** Conventional Commits style welcome (`feat:`, `fix:`, `docs:`, `test:`). No AI co-author trailers.
7. **External publish** (Homebrew tap push, GitHub release): implement locally, then **ask the user** before any network publish.
8. **Not in scope:** WhatsApp, Teams, SharePoint, TFS, Jamie, Graph, private SQLite hacks, automatic email send.

## Related (not this repo)

- [macos-verbs](https://github.com/chaoz23/macos-verbs) — system actions (focus, clipboard). Different product; binary `verbs`.

## Done means

For automated tasks: frontmatter `status: done`, checkboxes in the task file ticked, `mise run check` passes, and behavior notes updated if a verb landed.
