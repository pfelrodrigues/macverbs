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
| add | `title`, `--list` `--due` `--notes` `--priority high\|medium\|low` | planned |
| done | `title`, `--list` | planned |
| move | `title`, `--from` (required) `--to` (required) | planned |
| edit | `title`, `--list` `--due` `--priority high\|medium\|low\|none` `--notes` | planned |
| mklist | `name` (idempotent: ensure list exists) | planned |
| delete | `title`, `--list` (delete without completing) | planned |

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

### calendar

| Verb | Args | Status |
|------|------|--------|
| list | `--days` (default `7`) | **done** (T07) |
| add | `title`, `--start` (required) `--end` (required) `--calendar` | planned |

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
| list | `--account` (empty = all) `--limit` (default `20`) `--mailbox inbox\|archive` (default `inbox`) | planned |
| read | `message-id`, `--account` | planned |
| archive | `ids…`, `--account` (required); **Gmail → unsupported** (honest refuse) | planned |
| delete | `ids…`, `--account` (required) | planned |
| attachments | `message-id`, `--dest` (required), `--account` | planned |
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
