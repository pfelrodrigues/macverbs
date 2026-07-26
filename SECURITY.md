# Security Policy

## Supported versions

Security fixes are applied on the default branch (`main`) and on the latest
tagged release when one exists.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security-sensitive reports.

Email the maintainer at the address listed on the GitHub profile
([@pfelrodrigues](https://github.com/pfelrodrigues)), or use
[GitHub private vulnerability reporting](https://github.com/pfelrodrigues/macverbs/security/advisories/new)
if enabled on this repository.

Include:

- macOS version
- macverbs version (`macverbs --version`)
- Steps to reproduce
- Impact (data access, unexpected network use, privilege escalation, etc.)

You should receive an acknowledgment within a few days when possible.

## Trust model (high level)

macverbs is a **local** CLI. It does not call remote APIs as part of its core
surface:

- **Calendar / Reminders** — EventKit on this Mac (TCC)
- **Mail / Notes** — Apple Events to the local apps (Automation)

Treat any binary you install like other automation tools that can read personal
data already available to those apps under your account.
