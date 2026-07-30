# macverbs

[![CI](https://github.com/pfelrodrigues/macverbs/actions/workflows/ci.yml/badge.svg)](https://github.com/pfelrodrigues/macverbs/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/pfelrodrigues/macverbs)](https://github.com/pfelrodrigues/macverbs/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Homebrew](https://img.shields.io/badge/homebrew-pfelrodrigues%2Ftap-orange)](https://github.com/pfelrodrigues/homebrew-tap)

Agent-first CLI for **macOS Mail, Reminders, Notes, and Calendar**.

Stable JSON verbs for coding agents and shell scripts. Human text when you omit `--json`.

```bash
# Agent
macverbs --json calendar list --days 2
# → [{ "calendar", "title", "when" }, …]

# Human
macverbs calendar list --days 2
# → - Standup | 2026-08-01 at 10:00 - 10:30 | Work
```

### Demo session

```text
$ macverbs --version
0.1.3

$ macverbs doctor
macverbs doctor 0.1.3
EventKit: eventkit (calendar=fullAccess, reminders=fullAccess)
Apple Events: osascript (wired=true, mail=authorized, notes=authorized)
ok: nothing missing

$ macverbs --json calendar list --days 1
[
  {
    "calendar" : "Work",
    "title" : "Standup",
    "when" : "2026-08-01 at 10:00 - 10:30"
  }
]
```

Questions and ideas: [GitHub Discussions](https://github.com/pfelrodrigues/macverbs/discussions). Bugs: [Issues](https://github.com/pfelrodrigues/macverbs/issues).

## Why

- **Honest results** — no silent no-ops (e.g. Gmail “archive” is refused, not faked)
- **Agent-friendly** — `--json` before the subcommand; errors on stderr; predictable exit codes
- **Fast where it matters** — EventKit for Calendar and Reminders (no icalBuddy)
- **Testable** — injectable backends; unit tests without live TCC for most paths

## Architecture

| Domain | Backend |
|--------|---------|
| Calendar, Reminders | EventKit |
| Mail, Notes | Apple Events (Open Scripting Architecture) |

One binary, two backends. Mail and Notes have no public EventKit surface.

## Install

### Homebrew (recommended)

```bash
brew install pfelrodrigues/tap/macverbs
# after: brew tap pfelrodrigues/tap
#        brew install macverbs
macverbs --version
macverbs doctor
```

Tap: [pfelrodrigues/homebrew-tap](https://github.com/pfelrodrigues/homebrew-tap).  
Formula copy in-repo: [`Formula/macverbs.rb`](Formula/macverbs.rb).  
Releases: [`docs/RELEASE.md`](docs/RELEASE.md) · [`CHANGELOG.md`](CHANGELOG.md).

### From source

Requires macOS with Swift (Xcode or Command Line Tools). [mise](https://mise.jdx.dev/) is optional for project tasks.

```bash
git clone https://github.com/pfelrodrigues/macverbs.git
cd macverbs
swift build -c release
cp .build/release/macverbs /usr/local/bin/   # or any dir on PATH
macverbs doctor
```

## First run

```bash
macverbs doctor
macverbs calendar calendars              # UIDs / titles / sources
macverbs config calendars init           # optional ~/.config/macverbs/calendars.json
# edit labels if several calendars share the same title
macverbs --json calendar list --days 7
```

More recipes: **[`docs/usage.md`](docs/usage.md)**. JSON contract: **[`docs/behavior.md`](docs/behavior.md)**.

## Commands (overview)

| Domain | Verbs |
|--------|--------|
| `calendar` | `list`, `add`, `calendars` |
| `reminders` | `lists`, `list`, `add`, `done`, `move`, `edit`, `mklist`, `delete` |
| `mail` | `accounts`, `unread`, `list`, `read`, `archive`, `delete`, `attachments`, `draft`, `compose` |
| `notes` | `list`, `read`, `create`, `search` |
| `config` | `path`, `calendars show\|init` |
| `doctor` | (no subcommand) |

```bash
macverbs --json calendar list --days 7
macverbs reminders list --list Inbox
macverbs --json mail list --limit 20
macverbs mail read 'message-id-from-list' --account Work
macverbs notes search "meeting"
macverbs doctor
```

Global: `--json` **before** the subcommand. Exit: `0` ok, `1` domain, `2` system, `64` usage.

## Permissions (TCC)

```text
  you / agent  →  macverbs  →  EventKit (Calendar, Reminders)
                           →  Apple Events (Mail, Notes apps)
```

| Domain | Settings |
|--------|----------|
| Calendar / Reminders | **Privacy & Security → Calendars / Reminders** |
| Mail / Notes | **Privacy & Security → Automation** (Terminal or agent host → Mail/Notes) |

`macverbs doctor` reports status **without** prompting. The CLI is **not** Mac App
Store sandboxed; see [SECURITY.md](SECURITY.md) for the trust model.

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| `access denied` / domain exit 1 | `macverbs doctor`; enable TCC panes above; re-run the verb once to prompt |
| Empty calendar list | Grant Calendars; check the date range (`--days`) |
| Mail/Notes osascript errors | Open Mail/Notes once; allow Automation; `doctor` mail/notes lines |
| Gmail archive “unsupported” | Expected — use delete/trash or archive in the Mail UI |
| Labels all “Calendar” | `macverbs config calendars init` and edit aliases |
| Wrong binary version | `brew upgrade macverbs` or rebuild from source |

## Calendar labels

When several calendars share a title, map UIDs → short labels in
`~/.config/macverbs/calendars.json` (`MACVERBS_CONFIG_DIR` overrides the config root).

```bash
macverbs calendar calendars
macverbs config calendars init
macverbs config calendars show
macverbs config path
```

`doctor` warns (non-blocking) about duplicate titles still without aliases.

## Shell completions

Installed by Homebrew. From source: `mise run generate-completions` or
`macverbs --generate-completion-script fish|zsh|bash`. Files under [`completions/`](completions/).

## Develop

```bash
mise trust
mise run setup               # git hooks (format + conventional commits)
mise run check               # format-check + build + test
mise run coverage            # optional line coverage (MacverbsCore)
mise run check-coverage      # coverage gate (default min 97%)
```

Layout: library **`MacverbsCore`** + thin executable **`macverbs`**. Tests import the library.

- Humans: **[CONTRIBUTING.md](CONTRIBUTING.md)** · [Code of Conduct](CODE_OF_CONDUCT.md)
- Coding agents: **[AGENTS.md](AGENTS.md)**

## CI

| Workflow | When | What |
|----------|------|------|
| [CI](.github/workflows/ci.yml) | push/PR → `main` | Linux **`swift format` only** (product is macOS-only; no EventKit on Linux) |
| [macOS check](.github/workflows/macos-check.yml) | **weekly** (+ coverage artifact), `workflow_dispatch`, or PR label **`ci-macos`** | format + build + test on macOS |

Local Mac remains the primary gate (`mise run check`). Optional local coverage on push: `git config macverbs.coveragePush true`.

## Security

See [SECURITY.md](SECURITY.md). Please use private vulnerability reporting for security issues.

## License

[MIT](LICENSE) © Paulo Rodrigues

macverbs is not affiliated with Apple Inc. “Mail”, “Reminders”, “Notes”, and “Calendar” are Apple product names.
