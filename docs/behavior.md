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
| stdout (`--json`) | One JSON value (object or array); stable keys |
| stderr | Errors and diagnostics only |
| Exit 0 | Success |
| Exit 1 | Domain / user error (not found, unsupported, denied) |
| Exit 2 | System / backend failure |
| Exit 64 | Usage / parse error |

## Domains and verbs (parity with `apple`)

### reminders

| Verb | Args (summary) | Status |
|------|----------------|--------|
| lists | | planned |
| list | `--list` | planned |
| add | title, `--list` `--due` `--notes` `--priority` | planned |
| done | title, `--list` | planned |
| move | title, `--from` `--to` | planned |
| edit | title, `--list` `--due` `--priority` `--notes` | planned |
| mklist | name | planned |
| delete | title, `--list` | planned |

### calendar

| Verb | Args | Status |
|------|------|--------|
| list | `--days` (default 7) | planned |
| add | title, `--start` `--end` `--calendar` | planned |

### notes

| Verb | Args | Status |
|------|------|--------|
| list | `--folder` (default `Notes`) | planned |
| read | title | planned |
| create | title, body, `--folder` | planned |
| search | query | planned |

### mail

| Verb | Args | Status |
|------|------|--------|
| accounts | | planned |
| unread | | planned |
| list | `--account` `--limit` `--mailbox inbox\|archive` | planned |
| read | message-id, `--account` | planned |
| archive | ids…, `--account` (required); Gmail → unsupported | planned |
| delete | ids…, `--account` (required) | planned |
| attachments | message-id, `--dest`, `--account` | planned |
| draft | message-id, `--body-file`, `--attach`… | planned (never send) |
| compose | `--subject` `--body-file` `--to` `--cc` `--account` | planned (never send) |

### meta

| Verb | Status |
|------|--------|
| doctor | planned |
| --version / --help | planned (T01) |

## JSON field notes (fill as verbs land)

Document concrete examples under each verb when implemented. Prefer additive keys;
never rename without a major version bump.
