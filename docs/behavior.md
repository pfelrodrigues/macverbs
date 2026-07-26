# Behavior contract

Target UX and JSON shapes for agents. While porting, the **oracle** is the
Python CLI:

`~/nix/clis/apple` (env `MACVERBS_APPLE_SPEC`)

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

Help (`-h` / `--help`) and `--version` write to stdout and exit 0. Usage failures
(unknown option, missing required arg) write to stderr and exit 64.

## Backends (hybrid)

| Domain | Backend | Notes |
|--------|---------|-------|
| reminders | EventKit | No icalBuddy |
| calendar | EventKit | No icalBuddy |
| notes | Apple Events | osascript / NSAppleScript |
| mail | Apple Events | osascript / NSAppleScript |
| meta (`doctor`) | local checks | Must run without TCC where possible |

## Domains and verbs (parity with `apple`)

### reminders

| Verb | Args (summary) | Status |
|------|----------------|--------|
| lists | | **done** (T09) |
| list | `--list` (optional; empty = all lists) | **done** (T09) |
| add | `title`, `--list` `--due` `--notes` `--priority high\|medium\|low` | **done** (T10) |
| done | `title`, `--list` | **done** (T10) |
| move | `title`, `--from` (required) `--to` (required) | **done** (T11) |
| edit | `title`, `--list` `--due` `--priority high\|medium\|low\|none` `--notes` | **done** (T11) |
| mklist | `name` (idempotent: ensure list exists) | **done** (T11) |
| delete | `title`, `--list` (delete without completing) | **done** (T10) |

#### reminders lists / list (T09)

EventKit (no AppleScript). `reminders lists` returns each list with its
incomplete count. `reminders list` returns incomplete items; `--list` filters
by exact list title (empty = all lists). Priority mapping matches the oracle:
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


#### reminders add / done / delete (T10)

EventKit mutations. Match for `done` / `delete` is **exact title** within the
resolved list (incomplete only). Empty `--list` uses the default list for new
reminders (oracle first/default list). Write priority map: high→1, medium→5,
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

#### reminders move / edit / mklist (T11)

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

| Verb | Args | Status |
|------|------|--------|
| list | `--days` (default `7`) | **done** (T07) |
| add | `title`, `--start` (required) `--end` (required) `--calendar` (optional) | **done** (T08) |

Date/time forms: `YYYY-MM-DD HH:MM` (oracle-compatible).

#### calendar list (T07)

EventKit (no icalBuddy). Range: start of today through the end of day
`today + --days` (oracle `eventsToday+N`). Recurring series are expanded into
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

#### calendar add (T08)

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

| Verb | Args | Status |
|------|------|--------|
| list | `--folder` (default `Notes`) | planned |
| read | `title` | planned |
| create | `title`, `body`, `--folder` (default `Notes`) | planned |
| search | `query` | planned |

### mail

| Verb | Args | Status |
|------|------|--------|
| accounts | | **done** (T14) |
| unread | | **done** (T14) |
| list | `--account` (empty = all) `--limit` (default `20`) `--mailbox inbox\|archive` (default `inbox`) | **done** (T15) |
| read | `message-id`, `--account` | **done** (T15) |
| archive | `ids…`, `--account` (required); **Gmail → unsupported** (honest refuse) | **done** (T16) |
| delete | `ids…`, `--account` (required) | **done** (T16) |
| attachments | `message-id`, `--dest` (required), `--account` | **done** (T17) |
| draft | `message-id`, `--body-file` (required), `--attach`… (repeatable), `--account`; **never send** | planned |
| compose | `--subject` `--body-file` (required) `--to`… `--cc`… `--account`; **never send** | planned |


#### mail accounts (T14)

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

#### mail unread (T14)

Per-account unread totals (sum of mailbox `unread count`). Accounts with zero
unread are omitted by the script (oracle parity).

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

#### mail list (T15)

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
    "id": "<msg1@example.com>",
    "read": "unread",
    "sender": "Alice <alice@example.com>",
    "subject": "Standup notes"
  }
]
```

#### mail read (T15)

Fetch one message by Message-ID (value from `mail list`). Optional
`--account` narrows the search. Searches inbox **and** archive candidates
(treated/replied mail is often already archived). Returns a multi-line body
with From/Subject/Date lines plus content (oracle header labels kept for
parity). Missing message → exit 1 (`message <id> not found`).

JSON: `{ "body": "…" }`. Text: the body string (or `(empty)` when blank).

```json
{
  "body": "De: Alice <alice@example.com>\nAssunto: Standup notes\nData: …\n\nHello"
}
```

#### mail archive / delete (T16)

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

#### mail attachments (T17)

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
  "message_id": "<msg1@example.com>",
  "saved": [
    "foto.jpg",
    "doc.pdf"
  ]
}
```

#### Mail behavioral constraints (oracle)

- Multi-account: resolve inbox by name candidates (`INBOX` vs localized Exchange names). Prefer scanning all accounts when `--account` is empty.
- `archive` / `delete`: **verify** effect (re-count IDs remaining in inbox). Never report success on silent no-ops. Return `moved` / `requested` (and `remaining` when applicable).
- Gmail `archive` is unsupported (label semantics; no honest AppleScript path). Refuse with `unsupported`, `moved: 0`.
- `draft` and `compose` create Mail drafts only; they must never send.

### meta

| Verb | Status |
|------|--------|
| doctor | **stub** (T03; full TCC report in T21) |
| --version / --help | **done** (T01) |

#### doctor (stub)

Runs without EventKit permission prompts. Reports backend wiring and
authorization status from injectable seams (`EventStoreClient`, `ScriptRunner`).
Default production wiring: `EventStoreClient` is real EventKit (T06) and
`ScriptRunner` is real osascript (T13). Doctor only reads authorization status
(never calls `requestAccess`). When Calendar/Reminders are denied, restricted,
or not determined, those gaps appear under `missing`. Tests may inject
`StubEventStoreClient` / `StubScriptRunner` to report backends as unwired.

JSON shape (production defaults; statuses depend on host TCC):

```json
{
  "backends": {
    "appleEvents": { "kind": "osascript", "wired": true },
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

When access is not yet granted, `ok` is false and `missing` lists actionable
System Settings hints (e.g. Calendar access not determined / denied).

Exit 0 when the report is produced successfully (gaps go in `missing`, not exit
code).

#### EventStoreClient (T06 / T07)

- Protocol `EventStoreClient`: `authorizationStatus(for:)` (no prompt) and
  `requestAccess(for:)` (may prompt once when not determined).
- `ensureAccess(for:)` (protocol extension): request if needed, then throw
  `MacverbsError.domain` with a clear System Settings path when access is
  denied, restricted, write-only, or still not granted.
- Calendar data (T07): `eventCalendars()` and `events(from:to:)` (half-open
  range; recurring instances expanded by EventKit). DTOs:
  `EventKitCalendarInfo`, `EventKitEventInfo`.
- Calendar create (T08): `saveEvent(title:start:end:calendarUID:)` (`nil` UID →
  store default calendar for new events).
- Reminders mutations (T09–T11): `reminderLists`, `incompleteReminders`,
  `addReminder`, `completeReminder`, `deleteReminder`, `moveReminder`,
  `editReminder`, `ensureReminderList` (mklist).
- Production: `EKEventStoreClient` (`kind: eventkit`) wraps `EKEventStore` via
  injectable `EventKitBacking` (live store or test double).
- Unit tests use `MockEventStoreClient` / fake backing; never require live TCC.

#### ScriptRunner (T13)

- Protocol `ScriptRunner.run(script:timeout:)` returns osascript stdout.
- Production: `OSAScriptRunner` → `/usr/bin/osascript -e …` (process launch is
  injectable via `OsascriptProcessLaunching` for unit tests).
- Non-zero exit → `MacverbsError.system` with stderr (or `"AppleScript failed"`).
- `AppleScript.escape` for safe double-quoted string interpolation (oracle `esc`).
- `AppleScript.parseRecords` for US/RS-delimited structured output (oracle
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
