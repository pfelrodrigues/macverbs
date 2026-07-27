# Behavior contract

**Public contract** of the `macverbs` CLI: UX, JSON shapes, and exit codes for
humans and agents. Recipes live in [`usage.md`](usage.md).

Do not paste proprietary account names into examples. Use `Work`, `Personal`, `Acme`.

## Global

| Item | Contract |
|------|----------|
| Binary | `macverbs` |
| Global flags | `--json` **before** the subcommand (e.g. `macverbs --json calendar list`) |
| stdout (text) | Human lines via formatters |
| stdout (`--json`) | One JSON value (object or array); pretty-printed, sorted keys |
| stderr | Errors and diagnostics only (`error: <message>` for domain/system) |
| Exit 0 | Success |
| Exit 1 | Domain / user error (not found, unsupported, denied) |
| Exit 2 | System / backend failure |
| Exit 64 | Usage / parse error (`EX_USAGE`) |

Errors always go to **stderr** as `error: …` (never mixed into JSON stdout).

Help (`-h` / `--help`) and `--version` write to stdout and exit 0. Usage failures
(unknown option, missing required arg) write to stderr and exit 64.

## Backends (hybrid)

| Domain | Backend | Notes |
|--------|---------|-------|
| reminders | EventKit | No icalBuddy |
| calendar | EventKit | No icalBuddy |
| notes | Apple Events | osascript / NSAppleScript |
| mail | Apple Events | osascript / NSAppleScript |
| meta (`doctor`) | local checks | Must run without TCC prompts |

## Domains and verbs

### reminders

| Verb | Args (summary) |
|------|----------------|
| lists | |
| list | `--list` (optional; empty = all lists) |
| add | `title`, `--list` `--due` `--notes` `--priority high\|medium\|low` |
| done | `title`, `--list` |
| move | `title`, `--from` (required) `--to` (required) |
| edit | `title`, `--list` `--due` `--priority high\|medium\|low\|none` `--notes` |
| mklist | `name` (idempotent: ensure list exists) |
| delete | `title`, `--list` (delete without completing) |

#### reminders lists / list

EventKit (no AppleScript). `reminders lists` returns each list with its
incomplete count. `reminders list` returns incomplete items; `--list` filters
by exact list title (empty = all lists). Priority mapping matches the contract:
0 none (empty string), 1–4 `high`, 5 `medium`, 6–9 `low`. Due dates use
`YYYY-MM-DD` or `YYYY-MM-DD HH:MM` (stable; not locale AppleScript text).

JSON lists: array of `{ "name", "pending" }`. Text: `- Name (N pending)`.

JSON items: array of `{ "due", "list", "notes", "priority", "title" }` (sorted
keys). Text: `- title | list: … | due: … | priority: … | notes: …`.

```json
[
  {
    "name": "Work",
    "pending": 2
  }
]
```

```json
[
  {
    "due": "2026-07-06 14:30",
    "list": "Work",
    "notes": "bring laptop",
    "priority": "high",
    "title": "Standup prep"
  }
]
```


#### reminders add / done / delete

EventKit mutations. Match for `done` / `delete` is **exact title** within the
resolved list (incomplete only). Empty `--list` uses the default list for new
reminders (default list). Write priority map: high→1, medium→5,
low→9. Due: `YYYY-MM-DD` or `YYYY-MM-DD HH:MM` (date-only defaults to 09:00).

JSON add: `{ "created", "list" }` where `list` is the flag value, or `"(first)"`
when `--list` was empty. Text: `created: <title>`.

JSON done: `{ "done" }`. Text: `done: <title>`.

JSON delete: `{ "deleted" }`. Text: `deleted: <title>`.

Exit 1 when list or reminder is missing, or due/priority is invalid.

```json
{
  "created": "Standup prep",
  "list": "Work"
}
```

```json
{
  "done": "Standup prep"
}
```

```json
{
  "deleted": "Temp task"
}
```

#### reminders move / edit / mklist

EventKit mutations. `move` requires `--from` and `--to` (exact list titles);
matches the first incomplete reminder with exact title in the source list and
reassigns its calendar. `edit` requires at least one of `--due`, `--priority`,
or `--notes`; empty `--list` uses the default list. Priority accepts
`high|medium|low|none` (`none` clears). `mklist` creates the list when missing
and is a no-op when it already exists.

JSON move: `{ "moved", "from", "to" }`. Text: `moved: <title> (<from> → <to>)`.

JSON edit: `{ "edited" }`. Text: `edited: <title>`.

JSON mklist: `{ "list" }`. Text: `list ensured: <name>`.

Exit 1 when list/reminder is missing, due/priority is invalid, or edit has no
fields to change.

```json
{
  "from": "Work",
  "moved": "Standup prep",
  "to": "Personal"
}
```

```json
{
  "edited": "Standup prep"
}
```

```json
{
  "list": "Acme"
}
```

### calendar

| Verb | Args |
|------|------|
| list | `--days` (default `7`) |
| add | `title`, `--start` (required) `--end` (required) `--calendar` (optional) |

Date/time forms: `YYYY-MM-DD HH:MM` (stable form).

#### calendar list

All-day `when` values are ISO dates. If EventKit reports end on the same
day as start, the range is not inverted (inclusive last day is clamped).


EventKit (no icalBuddy). Range: start of today through the end of day
`today + --days` (contract `eventsToday+N`). Recurring series are expanded into
individual occurrences by EventKit. Calendar label: UID → `calendars.json`
alias when present, else EventKit calendar title.

JSON: array of objects (pretty-printed, sorted keys):

```json
[
  {
    "calendar": "Work",
    "title": "Standup",
    "when": "2026-07-26 at 10:00 - 10:30"
  }
]
```

- `when` timed same-day: `YYYY-MM-DD at HH:MM - HH:MM`
- `when` timed multi-day: `YYYY-MM-DD at HH:MM - YYYY-MM-DD at HH:MM`
- `when` all-day single: `YYYY-MM-DD`
- `when` all-day multi: `YYYY-MM-DD - YYYY-MM-DD`

Text: one line per event `- title | when | calendar`, or `no events.` when empty.

Exit 1 when Calendar access is denied / restricted / write-only / not granted
(after a request). Exit 2 on EventKit system failure.

#### calendar add

EventKit (no AppleScript). Creates a timed event with required `--start` and
`--end` (`YYYY-MM-DD HH:MM`). Optional `--calendar` resolves in order: config
alias label (`calendars.json`), EventKit calendar title, then raw UID. Empty
`--calendar` uses the store default for new events. Fails with exit 1 when the
named calendar does not exist, dates are invalid, or `--end` is not after
`--start`.

JSON:

```json
{
  "created": "Standup",
  "end": "2026-07-05 11:00",
  "start": "2026-07-05 10:00"
}
```

Text: `created: Standup`.


### notes

| Verb | Args |
|------|------|
| list | `--folder` (default `Notes`) |
| read | `title` |
| create | `title`, `body`, `--folder` (default `Notes`) |
| search | `query` |

#### notes list / read / create / search

Apple Events via Notes.app (`ScriptRunner`). `--folder` defaults to `Notes`
(the default Notes folder name). List is scoped to that folder; search scans
every note (name or plaintext contains query). Read matches the first note
whose name is exactly `title`. Create makes a new note in `--folder`.

JSON list / search: array of `{ "title", "modified" }` (`modified` is the
AppleScript `modification date as text` string). Text: `- title | modified`,
or `no notes.` when empty.

JSON read: `{ "title", "body" }`. Text: the body string (or `(empty)` when
blank) — contract `fmt.body` prints body only.

JSON create: `{ "created", "folder" }`. Text: `created: <title>`.

Missing note / folder failures surface as AppleScript errors (exit 2 via
ScriptRunner), matching the contract (no special not-found sentinel).

```json
[
  {
    "modified": "Saturday, July 5, 2026 at 10:00:00 AM",
    "title": "Standup notes"
  }
]
```

```json
{
  "body": "Hello from the meeting",
  "title": "Standup notes"
}
```

```json
{
  "created": "Standup notes",
  "folder": "Notes"
}
```

### mail

| Verb | Args |
|------|------|
| accounts | |
| unread | |
| list | `--account` (empty = all) `--limit` (default `20`) `--mailbox inbox\|archive` (default `inbox`) |
| read | `message-id`, `--account` |
| archive | `ids…`, `--account` (required); **Gmail → unsupported** (honest refuse) |
| delete | `ids…`, `--account` (required) |
| attachments | `message-id`, `--dest` (required), `--account` |
| draft | `message-id`, `--body-file` (required), `--attach`… (repeatable), `--account`; **never send** |
| compose | `--subject` `--body-file` (required) `--to`… `--cc`… `--account`; **never send** |


#### mail accounts

Lists Mail.app accounts via Apple Events (`ScriptRunner`). No flags.

JSON: array of `{ "name", "type", "email" }` (stable keys). Text:
`- name | type | email` (or `no accounts.`).

```json
[
  {
    "email": "user@example.com",
    "name": "Work",
    "type": "imap"
  }
]
```

#### mail unread

Per-account unread totals (sum of mailbox `unread count`). Accounts with zero
unread are omitted by the script (documented parity).

JSON: array of `{ "account", "unread" }` with `unread` as integer. Text:
`- account: N unread` (or `no unread.`).

```json
[
  {
    "account": "Work",
    "unread": 5
  }
]
```

#### mail list

Recent messages via Apple Events. Empty `--account` scans all accounts.
`--mailbox inbox` (default) or `archive`. Resolves the box by ordered name
candidates (inbox: `INBOX`, `Caixa de Entrada`, `Inbox`, `Bandeja de entrada`;
archive: Gmail All Mail forms, then `Archive` / `Arquivo Morto` / `Arquivo`).
`--limit` caps messages **per account** (default 20). Negative limit → exit 1.

JSON: array of `{ "account", "date", "id", "read", "sender", "subject" }`
(`read` is the string `"read"` or `"unread"`, not a boolean). Text:
`[read|unread] (account) subject | sender | date | id:…`, or `no messages.`

```json
[
  {
    "account": "Work",
    "date": "Saturday, July 5, 2026 at 10:00:00 AM",
    "id": "msg1@example.com",
    "read": "unread",
    "sender": "Alice <alice@example.com>",
    "subject": "Standup notes"
  }
]
```

#### mail read

Fetch one message by Message-ID (value from `mail list`, as returned — do not wrap in `<>` unless present). Optional
`--account` narrows the search. Searches inbox **and** archive candidates
(treated/replied mail is often already archived). Returns a multi-line body
with From/Subject/Date lines plus content (contract header labels kept for
parity). Missing message → exit 1 (`message <id> not found`).

JSON: `{ "body": "…" }`. Text: the body string (or `(empty)` when blank).

```json
{
  "body": "De: Alice <alice@example.com>\nAssunto: Standup notes\nData: …\n\nHello"
}
```

#### mail archive / delete

Move messages from the account inbox to archive (`archive`) or trash
(`delete`), then **re-count** how many of the requested message-ids remain in
the inbox (embedded verification; never trust a silent no-op). `--account` is
**required**. At least one message-id argument is required.

JSON: `{ "account", "action", "moved", "requested", "remaining" }` plus optional
`"unsupported"` when archive is refused. Text: `account: moved/requested
archived|deleted` and, when `remaining > 0`, `; N remaining in inbox`.

Gmail archive is **unsupported**: resolving the destination to All Mail
(`[Gmail]/All Mail` / `Todos os e-mails`) would only hide the message locally;
sync brings it back. Refuse with `moved: 0`, `remaining == requested`, and an
`unsupported` explanation (exit 0). Delete (trash) still works on Gmail.

```json
{
  "account": "Work",
  "action": "archive",
  "moved": 2,
  "remaining": 0,
  "requested": 2
}
```

```json
{
  "account": "Personal",
  "action": "delete",
  "moved": 1,
  "remaining": 1,
  "requested": 2
}
```

```json
{
  "account": "Acme",
  "action": "archive",
  "moved": 0,
  "remaining": 1,
  "requested": 1,
  "unsupported": "archive is not supported on this account (Gmail): moving to '[Gmail]/All Mail' does not remove the message from the inbox. Use delete or archive manually in Mail."
}
```

#### mail attachments

Save every attachment of a message into `--dest` (required directory path).
Optional `--account` narrows the search. Looks in inbox **and** archive
candidates (same as `mail read`). Apple Events `save` each mail attachment to
`dest/name`. Missing message → exit 1 (`message <id> not found`). Message found
with zero attachments is success with empty `saved`.

JSON: `{ "message_id", "dest_dir", "saved" }` where `saved` is an array of base
file names. Text: `saved to <dest>:` plus `- name` lines, or `no attachments.`

```json
{
  "dest_dir": "/tmp/dest",
  "message_id": "msg1@example.com",
  "saved": [
    "foto.jpg",
    "doc.pdf"
  ]
}
```

#### mail draft / compose

Draft creates a **reply** draft for an existing message (Message-ID from
`mail list`). Compose creates a **new** outgoing message draft (not a reply).
Both **never send** — only `save` (drafts land in Drafts).

`draft`:
- Required `--body-file` (UTF-8 body). Optional `--account` narrows search.
- Optional `--attach` (repeatable): each path is tilde-expanded and made
  absolute; missing files → exit 1 before scripting.
- Searches inbox **and** archive (same candidates as `mail read`).
- AppleScript: `reply msg without opening window`, then `set content`, then
  attachments on `content of newMsg` with `delay 1` after each
  `make new attachment` so Mail materializes them before `save`. Opening a
  composition window would make `set content` a silent no-op and drop
  attachments.
- Missing message → exit 1 (`message <id> not found`).

JSON draft: `{ "message_id", "status", "attachments" }` (`attachments` are the
absolute paths requested; `status` is typically `"OK"`). Text:
`draft created (reply to <id>), not sent.`

`compose`:
- Required `--subject` and `--body-file`. Optional `--to` / `--cc` (repeatable;
  empty allowed so you can fill later in Mail). Optional `--account` selects
  the sender by account name (empty = Mail default).
- Never calls `send`; only `save`.

JSON compose: `{ "subject", "to", "cc" }`. Text:
`new draft created, not sent. Subject: … | To: …[, cc: …]`.

```json
{
  "attachments": [
    "/tmp/a.pdf"
  ],
  "message_id": "msg1@example.com",
  "status": "OK"
}
```

```json
{
  "cc": [
    "c@example.com"
  ],
  "subject": "Standup notes",
  "to": [
    "a@example.com"
  ]
}
```

#### Mail behavioral constraints (contract)

- Multi-account: resolve inbox by name candidates (`INBOX` vs localized Exchange names). Prefer scanning all accounts when `--account` is empty.
- `archive` / `delete`: **verify** effect (re-count IDs remaining in inbox). Never report success on silent no-ops. Return `moved` / `requested` (and `remaining` when applicable).
- Gmail `archive` is unsupported (label semantics; no honest AppleScript path). Refuse with `unsupported`, `moved: 0`.
- `draft` and `compose` create Mail drafts only; they must never send.

### meta

| Verb |
|------|
| doctor |
| --version / --help |
| shell completions |

#### Shell completions

ArgumentParser generates scripts via:

```text
macverbs --generate-completion-script fish
macverbs --generate-completion-script zsh
macverbs --generate-completion-script bash
```

Checked-in copies (regenerate with `mise run generate-completions`):

| Shell | Path | Install (example) |
|-------|------|-------------------|
| fish | `completions/macverbs.fish` | copy/symlink into `~/.config/fish/completions/` |
| zsh | `completions/_macverbs` | put on `$fpath` (e.g. site-functions) |
| bash | `completions/macverbs.bash` | `source` from bashrc, or install under bash-completion |

Covers every domain verb (`calendar`, `reminders`, `mail`, `notes`, `doctor`),
global `--json`, and constrained values such as `--mailbox`, `--priority`,
path/directory options for mail draft/compose/attachments.

#### doctor

Runs **without** permission prompts. Reports backend wiring and authorization
from injectable seams:

| Seam | What it reports |
|------|-----------------|
| `EventStoreClient` | Calendar + Reminders EventKit status (`authorizationStatus` only; never `requestAccess`) |
| `ScriptRunner` | Apple Events runner wired (`osascript`) or stub |
| `AutomationPermissionClient` | Mail + Notes **Automation** TCC via `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false` |

Default production wiring: real EventKit , real osascript , real AE
Automation probe . Tests inject mocks so unit checks never require live TCC.

**EventKit gaps** (`missing` when not fully usable): denied, restricted,
write-only, not determined. Messages point at
`System Settings → Privacy & Security → Calendars|Reminders`.

**Automation gaps** (`missing`): denied, not determined. Messages point at
`System Settings → Privacy & Security → Automation` (enable Mail / Notes for
this process). Status `notRunning` means the target app is not running so AE
cannot resolve permission — reported under `backends` only (not a proven gap;
open the app and re-run doctor to verify).

JSON shape (production defaults; statuses depend on host TCC):

```json
{
  "backends": {
    "appleEvents": {
      "kind": "osascript",
      "mail": "authorized",
      "notes": "authorized",
      "wired": true
    },
    "eventKit": {
      "calendar": "fullAccess",
      "kind": "eventkit",
      "reminders": "fullAccess"
    }
  },
  "missing": [],
  "ok": true,
  "version": "0.1.0"
}
```

Automation status strings: `authorized`, `denied`, `notDetermined`,
`notRunning`, `unavailable` (stub / unwired runner).

When access is not yet granted, `ok` is false and `missing` lists actionable
System Settings hints (e.g. Calendar access denied; Mail Automation denied).

Exit 0 when the report is produced successfully (gaps go in `missing`, not exit
code).

Text mode includes EventKit and Apple Events lines plus `missing:` bullets.
#### EventStoreClient 

- Protocol `EventStoreClient`: `authorizationStatus(for:)` (no prompt) and
  `requestAccess(for:)` (may prompt once when not determined).
- `ensureAccess(for:)` (protocol extension): request if needed, then throw
  `MacverbsError.domain` with a clear System Settings path when access is
  denied, restricted, write-only, or still not granted.
- Calendar data : `eventCalendars()` and `events(from:to:)` (half-open
  range; recurring instances expanded by EventKit). DTOs:
  `EventKitCalendarInfo`, `EventKitEventInfo`.
- Calendar create : `saveEvent(title:start:end:calendarUID:)` (`nil` UID →
  store default calendar for new events).
- Reminders mutations: `reminderLists`, `incompleteReminders`,
  `addReminder`, `completeReminder`, `deleteReminder`, `moveReminder`,
  `editReminder`, `ensureReminderList` (mklist).
- Production: `EKEventStoreClient` (`kind: eventkit`) wraps `EKEventStore` via
  injectable `EventKitBacking` (live store or test double).
- Unit tests use `MockEventStoreClient` / fake backing; never require live TCC.

#### ScriptRunner

- Protocol `ScriptRunner.run(script:timeout:)` returns osascript stdout.
- Production: `OSAScriptRunner` → `/usr/bin/osascript -e …` (process launch is
  injectable via `OsascriptProcessLaunching` for unit tests).
- Non-zero exit → `MacverbsError.system` with stderr (or `"AppleScript failed"`).
- `AppleScript.escape` for safe double-quoted string interpolation (contract `esc`).
- `AppleScript.parseRecords` for US/RS-delimited structured output (contract
  `parse_records`; field sep U+001F, record sep U+001E).

## JSON field notes (fill as verbs land)

Document concrete examples under each verb when implemented. Prefer additive keys;
never rename without a major version bump.

Oracle return shapes (reference while porting; exact macverbs keys may gain fields):

| Area | Typical keys |
|------|----------------|
| reminder lists | `name`, `pending` |
| reminder items | `title`, `due`, `priority`, `notes` |
| reminder mutations | `created` / `done` / `moved`+`from`+`to` / `edited` / `deleted` / `list` |
| calendar events | `title`, `when`, `calendar` |
| calendar add | `created`, `start`, `end` |
| notes list | `title`, `modified` |
| notes read | `title`, `body` |
| notes create | `created`, `folder` |
| mail accounts | `name`, `type`, `email` |
| mail unread | `account`, `unread` |
| mail list | `read`, `account`, `subject`, `sender`, `date`, `id` |
| mail move | `account`, `action`, `moved`, `requested`, `remaining`; optional `unsupported` |
| mail attachments | `message_id`, `dest_dir`, `saved` |
| mail draft | `message_id`, `status`, `attachments` |
| mail compose | `subject`, `to`, `cc` |

## History (optional reading)

Early design aimed for behavioral parity with a personal Python CLI used by the
maintainer. **macverbs is the public contract** now: do not require that tool
to understand or contribute. Exit codes, English text defaults, and absolute
ISO-style calendar `when` strings are deliberate product choices.
