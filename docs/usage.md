# Usage guide

Practical recipes for humans and agents. JSON contract details live in
[`behavior.md`](behavior.md).

Global flags go **before** the domain:

```bash
macverbs --json calendar list --days 7
```

Exit codes: `0` ok, `1` domain, `2` system, `64` usage. Errors on **stderr**
(`error: …`). Successful `--json` is one JSON value on stdout.

## First run

```bash
macverbs doctor
macverbs calendar calendars              # discover UIDs / titles / sources
macverbs config calendars init           # optional labels map
# edit ~/.config/macverbs/calendars.json if you care about short labels
macverbs config calendars show
```

`doctor` never prompts for TCC. Calendar/Reminders may prompt on first real
read/write. Mail/Notes need Automation permission for the Terminal (or agent
host) under **System Settings → Privacy & Security → Automation**.

Config directory: `~/.config/macverbs` (override with `MACVERBS_CONFIG_DIR`).

## Completions

Homebrew installs fish/zsh/bash completions with the formula. From a source
checkout:

```bash
mise run generate-completions
# or: macverbs --generate-completion-script fish
```

## Domain recipes

### doctor / config

```bash
macverbs doctor
macverbs --json doctor
macverbs config path
macverbs config calendars show
macverbs config calendars init           # refuse if file exists
macverbs config calendars init --force   # overwrite
```

### calendar

```bash
macverbs calendar calendars
macverbs --json calendar list --days 7
macverbs calendar add "Standup" \
  --start "2026-08-01 10:00" --end "2026-08-01 10:30" \
  --calendar Work
```

`--calendar` accepts alias (from `calendars.json`), title, or UID.
All-day `when` strings are ISO dates (`2026-08-09` or `2026-08-09 - 2026-08-11`).
Timed events use `YYYY-MM-DD at HH:MM - …`.

### reminders

```bash
macverbs --json reminders lists
macverbs --json reminders list --list Inbox
macverbs reminders add "Ship notes" --list Work --due "2026-08-01" --priority high
macverbs reminders done "Ship notes" --list Work
macverbs reminders move "Ship notes" --from Work --to Personal
macverbs reminders edit "Ship notes" --list Personal --notes "blocked on review"
macverbs reminders mklist "Sprint"
macverbs reminders delete "Ship notes" --list Personal
```

Empty `--list` on `reminders list` means **all lists**. Mutations match by
**exact title** (optional list). Prefer re-list after write to verify effect.

### mail

```bash
macverbs --json mail accounts
macverbs --json mail unread
macverbs --json mail list --account Work --limit 20
macverbs --json mail read '0100019f…@example.com' --account Work
macverbs --json mail archive --account Work -- 'id-one' 'id-two'
macverbs --json mail delete  --account Work -- 'id-three'
macverbs mail attachments 'msg-id' --dest /tmp/out --account Work
macverbs mail draft 'msg-id' --body-file ./reply.txt --account Work
macverbs mail compose --subject "Hi" --body-file ./body.txt --to a@example.com
```

Use the `id` field from `mail list` **as-is** (no angle brackets unless the
header already includes them). Always pass `--` before IDs that can start with
`-`. Prefer **`--json`** for agents parsing archive/delete results
(`moved` / `requested` / `remaining` / optional `unsupported`).

**Gmail archive is unsupported** (honest refusal). Delete (trash) still works.

### notes

```bash
macverbs --json notes list --folder Notes
macverbs --json notes read "Standup notes"
macverbs notes create "Title" --body-file ./note.txt --folder Work
macverbs --json notes search "meeting"
```

## Agent tips

1. Put `--json` first; never mix JSON success with errors on stdout.
2. After mutations, re-query (list / unread counts) when the verb does not
   already embed verification (mail archive/delete re-count for you).
3. Treat domain exit `1` as user-fixable (missing list, denied access);
   exit `2` as backend/osascript failure.
4. Do not invent account names; discover with `mail accounts` / `calendar calendars`.
