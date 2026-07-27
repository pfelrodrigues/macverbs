# Contributing to macverbs

Thanks for helping. This project uses **[GitHub Flow](https://docs.github.com/en/get-started/using-github/github-flow)** and **[Conventional Commits](https://www.conventionalcommits.org/)**.

## GitHub Flow

1. **`main` is always shippable.** Do not commit product work directly to `main`.
2. **Create a branch** from an up-to-date `main`:
   - `feat/<short-topic>` — new capability
   - `fix/<short-topic>` — bug fix
   - `docs/<short-topic>` — documentation only
   - `test/<short-topic>` — tests / coverage
   - `chore/<short-topic>` — tooling, repo hygiene
   - `ci/<short-topic>` — CI only
   - `refactor/<short-topic>` — no behavior change
3. **Make focused commits** (Conventional Commits; see below).
4. **Open a pull request** into `main`. Fill the PR template.
5. **Keep CI green.** Local gate before you push:

   ```bash
   mise run setup           # once per clone: git hooks
   mise run check           # format-check + build + test
   mise run check-coverage  # optional: line coverage gate (default min 97%)
   ```

6. **Merge** via PR (squash or merge commit is fine; message must stay conventional).
7. **Delete the branch** after merge.

For **macOS CI on a PR**, add the label **`ci-macos`** (weekly schedule and manual
`workflow_dispatch` also run [macOS check](.github/workflows/macos-check.yml)).

Releases and Homebrew tap updates: [`docs/RELEASE.md`](docs/RELEASE.md).
Do not publish tags or push to the tap without maintainer approval.

## Conventional Commits

Every commit subject:

```text
<type>[optional scope]: <description>
```

Examples:

```text
feat(calendar): add calendars discovery verb
fix(mail): refuse Gmail archive no-ops honestly
test: raise EventKit live coverage
docs: document config calendars init
chore: install conventional commit-msg hook
```

### Types we use

| Type | When |
|------|------|
| `feat` | User-visible capability |
| `fix` | Bug fix |
| `docs` | Docs only |
| `test` | Tests only |
| `refactor` | Internal change, same behavior |
| `perf` | Performance |
| `build` | Package / SPM / formula build |
| `ci` | GitHub Actions |
| `chore` | Tooling, hooks, cleanup |
| `style` | Formatting only (rare; hooks usually handle this) |
| `revert` | Revert a previous commit |

Rules:

- Subject in **English**, imperative mood, **no period** at the end.
- Keep the first line ≤ ~72 characters.
- Body optional; use it for *why*, not *what*.
- **No AI co-author trailers** (`Co-Authored-By`, etc.).
- Breaking changes: `feat!:` or a `BREAKING CHANGE:` footer.

The `commit-msg` git hook rejects non-conforming subjects (merge commits are allowed).

## Code expectations

- **English** for code, comments, CLI help, and public docs.
- Match the CLI contract in [`docs/behavior.md`](docs/behavior.md). Usage recipes: [`docs/usage.md`](docs/usage.md).
- Injectable seams for EventKit / Apple Events; unit tests must not require live TCC when mocks suffice.
- No secrets, no real personal account names in tests (use `Work`, `Personal`, `Acme`).
- Format with Apple **`swift format`** (see `mise run format`).

### Coverage

- Prefer keeping **Sources/macverbs** line coverage high (`mise run coverage` / `check-coverage`).
- Default gate: **97%** lines (see `scripts/coverage.sh`, `COVERAGE_MIN`).
- Residual ~2–3% is expected: live EventKit/osascript failure branches and process
  entry (`Main.main`). Do not chase 100% with brittle live-only tests on CI.

### Live / dogfood tests

- Default unit suite is mock-first and safe for agents and CI.
- Optional live EventKit paths in the suite no-op or skip when access is missing.
- Do **not** commit credentials or personal mailbox names. Dogfood on your machine;
  automated GitHub runners will not have your TCC grants.

Agent-oriented notes: [`AGENTS.md`](AGENTS.md).
