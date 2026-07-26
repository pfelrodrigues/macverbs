# macverbs

Agent-first CLI for **macOS Mail, Reminders, Notes, and Calendar**.

Stable JSON verbs for coding agents and shell scripts. Built to be dogfooded daily; distributed via Homebrew (personal tap first, homebrew-core later).

> **Status:** public scaffold + roadmap. Implementation in progress (Swift rewrite). Not installable yet.

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

## Develop (mise)

```bash
cd ~/work/Pessoal/macverbs   # or your clone
mise trust                   # once
mise run tasks-list          # roadmap status
mise run next                # next automated task id
mise run build && mise run test
mise run check               # agent gate
```

Agent instructions: **[AGENTS.md](AGENTS.md)**. Task loop: `docs/ROADMAP.md` + workflow `implement-task`.

## Not this project

- Not affiliated with Apple Inc.
- Not a deep Reminders power-user clone (e.g. RemCTL feature parity)
- Not Microsoft Graph / WhatsApp / third-party SaaS wrappers
- Not a GUI

Related but different: [macos-verbs](https://github.com/chaoz23/macos-verbs) targets system actions (app focus, clipboard, volume). **macverbs** targets Mail, Reminders, Notes, and Calendar.

## Install

Coming soon:

```bash
# planned
brew install pfelrodrigues/tap/macverbs
```

## License

[MIT](LICENSE) © Paulo Rodrigues
