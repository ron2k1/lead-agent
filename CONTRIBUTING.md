# Contributing to lead-agent

Thanks for your interest. This project guards a security-relevant trust chain,
so contributions follow a slightly stricter discipline than typical OSS.

## Before you change anything in `lib/`

The 10 files under `lib/` plus `launch.ps1` and `runner.ps1` (12 in total)
are covered by a pinned SHA256 manifest at `lib/lead-extension.sha256`.
After ANY edit to a pinned file, you must re-run the installer so the
manifest is re-pinned:

    & "$env:USERPROFILE\.claude\skills\lead-agent\install.ps1"

If you do not re-pin, the runtime gate fails closed on next launch and refuses
to spawn a lieutenant. This is intentional.

## ASCII-only policy

Every shipped file MUST be ASCII. No em-dashes, no curly quotes, no Unicode
bullets, no zero-width characters. This applies to README.md, DESIGN.md,
CHANGELOG.md, and every file under `lib/`. The pin manifest covers
byte-for-byte content, so a Unicode normalization pass on a fork will silently
break the trust chain.

If you need docs in another language, put them in a separate file (for
example `README.ja.md`) and exclude it from the pin set.

CI enforces this. The `ASCII-only` step in `.github/workflows/ci.yml` fails
on any non-ASCII byte in shipped runtime files.

## Atomic commits

Stage and commit ONE logical change per commit. Subject line: imperative mood,
under 70 characters, conventional-commit prefix when sensible (`feat:`,
`fix:`, `refactor:`, `chore:`, `docs:`, `test:`).

Body: explain WHY, not what. The diff shows what.

Reverting one tiny commit is trivial. Carving a fix out of a 500-line blob is
painful.

If torn whether to split: split.

## Testing changes locally

Before opening a PR:

1. Run `install.ps1 -Verify`. All 5 probes must be green.
2. Confirm the hook still denies obvious bad inputs (path traversal, denied
   argv shapes, manifest drift).
3. Confirm the hook still allows the documented happy-path cases.
4. Run `lib/install-hook.ps1 -Uninstall` then re-run install. Both directions
   must complete cleanly with the host `windows_shell_safety.py` restored
   from `.bak`.

The C-01..C-13 fixture matrix is scheduled for v1.1. Until then, manual
verification per the steps above is the bar.

## PR template

PRs without the threat-model-impact checkbox checked will not be reviewed.
The template is at `.github/PULL_REQUEST_TEMPLATE.md`.

## Reporting security issues

Do NOT open a public GitHub issue for security findings. See `SECURITY.md`
for the disclosure process.

## Style

- Functions and variables: `snake_case` in Python, `PascalCase` for
  PowerShell cmdlets, `camelCase` for PowerShell parameters.
- No magic strings in `lib/`. Add a constant.
- No new dependencies without an issue first. The trust chain depends on
  the surface area being small.

## License

By contributing you agree your contributions are licensed under MIT (see
`LICENSE`).
