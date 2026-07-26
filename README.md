# macverbs

Agent-first CLI for **macOS Mail, Reminders, Notes, and Calendar**.

Stable JSON verbs for coding agents and shell scripts. Distributed via Homebrew (personal tap first; homebrew-core later).

> **Status:** under active development. Not installable via Homebrew yet.

## Goals

- **Reliable** — honest results (no silent no-ops); multi-account Mail quirks documented
- **Testable** — pure command layer with injectable backends; unit tests without live apps
- **Fast where it matters** — EventKit for Calendar and Reminders
- **Safe** — least privilege, clear TCC/automation prompts, no surprise network calls

## Architecture (planned)

| Domain | Backend |
|--------|---------|
| Calendar, Reminders | EventKit |
| Mail, Notes | Apple Events (Open Scripting Architecture) |

One binary, two backends. Not EventKit-only (Mail and Notes have no public EventKit surface).

## Permissions (TCC)

Calendar and Reminders use **EventKit**. The first verb that needs data calls
`requestAccess` once per entity type (Calendar events / Reminders). macOS shows
the system prompt; afterward the choice lives under:

- **System Settings → Privacy & Security → Calendars**
- **System Settings → Privacy & Security → Reminders**

`macverbs doctor` reports authorization **without** prompting. Denied or
restricted access yields domain errors (exit 1) with the same Settings path.
Full access is required for list/read verbs; write-only is treated as
insufficient.

Mail and Notes use **Apple Events** (Automation) when those verbs land; grant
control for Mail / Notes when prompted.

## Develop (mise)

```bash
cd ~/work/Pessoal/macverbs   # or your clone
mise trust                   # once
mise run setup               # install git pre-commit hooks
mise run tasks-list          # roadmap status
mise run next                # next automated task id
mise run format              # Apple `swift format` (write)
mise run format-check        # lint mode --strict
mise run check               # format-check + build + test
```

| Tool | Via |
|------|-----|
| Format + lint | Apple **`swift format`** (`.swift-format`) |
| Hooks | `.githooks/pre-commit` → format staged + lint |

Agent instructions: **[AGENTS.md](AGENTS.md)**. Task loop: `docs/ROADMAP.md` + workflow `implement-task`.

## CI

| Workflow | When | Runner | What |
|----------|------|--------|------|
| **CI** | push/PR → `main` | **Linux** | `swift format lint` only (cheap) |
| **macOS check** | **manual** (`workflow_dispatch`) | macOS | format + `swift build` + `swift test` |

Default PR gate: Linux format only. Full build/test: run **`mise run check` on a Mac**, or trigger **macOS check** manually (Actions → Run workflow).

## Install

Coming soon:

```bash
# planned
brew install pfelrodrigues/tap/macverbs
```

## License

[MIT](LICENSE) © Paulo Rodrigues

macverbs is not affiliated with Apple Inc. “Mail”, “Reminders”, “Notes”, and “Calendar” are Apple product names.
