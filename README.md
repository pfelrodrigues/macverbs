# macverbs

Agent-first CLI for **macOS Mail, Reminders, Notes, and Calendar**.

Stable JSON verbs for coding agents and shell scripts.

## Goals

- **Reliable** — honest results (no silent no-ops); multi-account Mail quirks documented
- **Testable** — pure command layer with injectable backends; unit tests without live apps
- **Fast where it matters** — EventKit for Calendar and Reminders
- **Safe** — least privilege, clear TCC/automation prompts, no surprise network calls

## Architecture

| Domain | Backend |
|--------|---------|
| Calendar, Reminders | EventKit |
| Mail, Notes | Apple Events (Open Scripting Architecture) |

One binary, two backends. Mail and Notes have no public EventKit surface, so they use Apple Events.

## Install

### From source (today)

Requires macOS with Swift (Xcode or Command Line Tools) and [mise](https://mise.jdx.dev/) optional for project tasks.

```bash
git clone https://github.com/pfelrodrigues/macverbs.git
cd macverbs
swift build -c release
# binary: .build/release/macverbs
cp .build/release/macverbs /usr/local/bin/   # or any dir on PATH
macverbs --version
macverbs doctor
```

### Homebrew (planned)

Formula lives at [`Formula/macverbs.rb`](Formula/macverbs.rb). Public tap + tagged
release are not published yet — see [`docs/RELEASE.md`](docs/RELEASE.md).

```bash
# after the tap is published:
# brew install pfelrodrigues/macverbs/macverbs
```

Local formula smoke (from a checkout, no tap):

```bash
brew install --build-from-source ./Formula/macverbs.rb
```

## Permissions (TCC)

Calendar and Reminders use **EventKit**. The first verb that needs data may
prompt once per entity type. Afterward:

- **System Settings → Privacy & Security → Calendars**
- **System Settings → Privacy & Security → Reminders**

`macverbs doctor` reports authorization **without** prompting (EventKit +
Automation for Mail/Notes). Denied access yields domain errors (exit 1) with
Settings paths.

Mail and Notes use **Apple Events** (Automation):

- **System Settings → Privacy & Security → Automation**

## Usage (sketch)

```bash
macverbs --json calendar list --days 7
macverbs reminders list --list Inbox
macverbs --json mail list --limit 20
macverbs mail read '<message-id>' --account Work
macverbs notes search "meeting"
macverbs doctor
```

Global: `--json` **before** the subcommand. Exit codes: `0` ok, `1` domain,
`2` system, `64` usage. Errors on stderr; successful JSON on stdout.

## Shell completions

Scripts for **fish**, **zsh**, and **bash** live under [`completions/`](completions/).
Regenerate after CLI changes: `mise run generate-completions` (or
`macverbs --generate-completion-script fish`).

```fish
# fish
mkdir -p ~/.config/fish/completions
ln -sf (pwd)/completions/macverbs.fish ~/.config/fish/completions/macverbs.fish
```

```bash
# zsh — put completions/_macverbs on fpath, then compinit
# bash — source completions/macverbs.bash from bashrc
```

## Develop

```bash
mise trust                   # once
mise run setup               # git hooks (swift format)
mise run format
mise run check               # format-check + build + test
```

See **[AGENTS.md](AGENTS.md)** for contributor conventions.

## CI

| Workflow | When | Runner | What |
|----------|------|--------|------|
| **CI** | push/PR → `main` | **Linux** | `swift format lint` only |
| **macOS check** | **manual** | macOS | format + build + test |

## Security

See [SECURITY.md](SECURITY.md) for how to report vulnerabilities.

## License

[MIT](LICENSE) © Paulo Rodrigues

macverbs is not affiliated with Apple Inc. “Mail”, “Reminders”, “Notes”, and “Calendar” are Apple product names.
