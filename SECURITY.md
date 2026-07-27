# Security Policy

## Supported versions

Security fixes land on the default branch (`main`) and on the latest tagged
release when practical.

| Version | Supported |
|---------|-----------|
| latest `0.1.x` / `main` | yes |
| older tags | best-effort only |

## Reporting a vulnerability

**Do not** open a public GitHub issue for security-sensitive reports.

Preferred:

1. [GitHub private vulnerability reporting](https://github.com/pfelrodrigues/macverbs/security/advisories/new)
   — maintainer: enable under **Settings → Code security → Private vulnerability
   reporting** if the link is unavailable.
2. Or contact the maintainer via the email listed on
   [GitHub profile @pfelrodrigues](https://github.com/pfelrodrigues)

Include:

- macOS version
- macverbs version (`macverbs --version`)
- Install path (Homebrew / source)
- Steps to reproduce
- Impact (local data access, unexpected network use, privilege issues)

You should receive an acknowledgment within a few days when possible.

## Trust model

macverbs is a **local** CLI. Core features do **not** call remote HTTP APIs:

| Domain | Mechanism | OS permission |
|--------|-----------|----------------|
| Calendar / Reminders | EventKit | TCC Calendars / Reminders |
| Mail / Notes | Apple Events → local apps | Automation (Terminal/agent host → Mail/Notes) |

```text
  you / agent
       │
       ▼
   macverbs (unsigned CLI in Terminal)
       │
       ├── EventKit ──────────► Calendar.app data (TCC)
       ├── EventKit ──────────► Reminders data (TCC)
       ├── Apple Events ──────► Mail.app (Automation)
       └── Apple Events ──────► Notes.app (Automation)
```

It is **not** App Sandbox–restricted like a Mac App Store app. Treat the binary
like other automation tools that can read personal data already available to
those apps under your account.

### Supply chain

- **Homebrew formula** builds from the tagged source tarball on *your* Mac with
  the system Swift toolchain (no opaque prebuilt bottle by default).
- Review `Formula/macverbs.rb` and the tag contents before upgrading.
- SPM dependency: [swift-argument-parser](https://github.com/apple/swift-argument-parser)
  (see `Package.swift` / `Package.resolved`).

### Out of scope for “security bugs”

- Features that intentionally read mail/calendar/reminders/notes you granted
- Agent scripts that misuse JSON output
- Issues in Apple Mail / EventKit themselves

Those may still be valid product bugs — file a normal issue when appropriate.
