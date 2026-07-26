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
| lists | | planned |
| list | `--list` (optional; empty = all / first) | planned |
| add | `title`, `--list` `--due` `--notes` `--priority high\|medium\|low` | planned |
| done | `title`, `--list` | planned |
| move | `title`, `--from` (required) `--to` (required) | planned |
| edit | `title`, `--list` `--due` `--priority high\|medium\|low\|none` `--notes` | planned |
| mklist | `name` (idempotent: ensure list exists) | planned |
| delete | `title`, `--list` (delete without completing) | planned |

### calendar

| Verb | Args | Status |
|------|------|--------|
| list | `--days` (default `7`) | planned |
| add | `title`, `--start` (required) `--end` (required) `--calendar` | planned |

Date/time forms: `YYYY-MM-DD HH:MM` (oracle-compatible).

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
| accounts | | planned |
| unread | | planned |
| list | `--account` (empty = all) `--limit` (default `20`) `--mailbox inbox\|archive` (default `inbox`) | planned |
| read | `message-id`, `--account` | planned |
| archive | `ids…`, `--account` (required); **Gmail → unsupported** (honest refuse) | planned |
| delete | `ids…`, `--account` (required) | planned |
| attachments | `message-id`, `--dest` (required), `--account` | planned |
| draft | `message-id`, `--body-file` (required), `--attach`… (repeatable), `--account`; **never send** | planned |
| compose | `--subject` `--body-file` (required) `--to`… `--cc`… `--account`; **never send** | planned |

#### Mail behavioral constraints (oracle)

- Multi-account: resolve inbox by name candidates (`INBOX` vs localized Exchange names). Prefer scanning all accounts when `--account` is empty.
- `archive` / `delete`: **verify** effect (re-count IDs remaining in inbox). Never report success on silent no-ops. Return `moved` / `requested` (and `remaining` when applicable).
- Gmail `archive` is unsupported (label semantics; no honest AppleScript path). Refuse with `unsupported`, `moved: 0`.
- `draft` and `compose` create Mail drafts only; they must never send.

### meta

| Verb | Status |
|------|--------|
| doctor | planned |
| --version / --help | **done** (T01) |

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
