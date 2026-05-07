# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog (https://keepachangelog.com/en/1.1.0/),
and this project adheres to Semantic Versioning (https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-05-06

First public release. Runtime gate is live and trust-chain end-to-end verified.
ADVISOR and TOOLSMITH modes are ready for daily use. BUILDER and OVERWATCH
modes are partial -- see "Known limitations" below.

### Added

- Runtime gate at `lib/lead-pretool-hook.py` -- deny-by-default PreToolUse
  hook that re-verifies the 9-file pin manifest on every tool call, not just
  at launch. Closes the v0.4 swap-after-startup window.
- 9-file pin manifest with self-hash chain at `lib/lead-extension.sha256`.
  Covers `allowlist.json`, `path-guard.json`, `mcp-allow.json`,
  `notify-sh.sha256`, `canonicalize-path.py`, `allowlist_parser.py`,
  `lead-pretool-hook.py`, `sanitize-jsonl.py`, `launch.ps1`, plus a self-hash.
- Trust anchor pattern: `_ANCHOR_SHA` constant in `lead-pretool-hook.py` is
  stamped at install time from the local `lib/install-hook.ps1` SHA256, then
  cross-checked against `~/.claude/lead-agent-trust-anchor.txt` on every
  hook invocation. Distribution-time line-ending drift cannot break the
  running gate.
- Path canonicalizer at `lib/canonicalize-path.py` -- handles 8.3 short
  names, casing, slash style, symlinks, junctions, UNC paths, and long-path
  prefixes before path-guard checks.
- Argv-shape allowlist parser at `lib/allowlist_parser.py` with
  `${LEAD_TOOLS_DIR}` env-var expansion.
- JSONL transcript sanitizer at `lib/sanitize-jsonl.py` (library is ready;
  the watcher that uses it is a v1.1 stub).
- Idempotent hook chain installer at `lib/install-hook.ps1` with `-Repair`,
  `-RepinNotify`, `-Uninstall`, and `-Force` flags.
- Bootstrap installer at `install.ps1` with 5-probe `-Verify` mode and
  `-Force` flag.
- Four launch modes: OVERWATCH, ADVISOR, BUILDER, TOOLSMITH.
- ASCII-only policy enforcement on shipped runtime files (W-07).
- Self-spawn refusal (W-09): the skill refuses to spawn a lieutenant from
  inside a lieutenant.
- Lockfile at `%LOCALAPPDATA%\Temp\lead-agent.lock` to prevent concurrent
  lieutenant spawns.

### Known limitations

- BUILDER mode autonomous push is BLOCKED. The pre-push secret scanner at
  `lib/secret-scan.ps1` is a fail-closed stub. BUILDER currently works as
  a code-review buddy that can open feature branches and draft PRs but
  cannot push. Scheduled for v1.1.
- OVERWATCH mode live JSONL tail is BLOCKED. The watcher at
  `lib/jsonl-watcher.ps1` is a fail-closed stub. The brake-file write path
  works; sibling-transcript ingestion does not. Scheduled for v1.1.
- C-01..C-13 fixture test matrix not yet authored. Scheduled for v1.1.
- The `lib/path-guard.ps1` standalone CLI is a fail-closed stub. The
  path-guard logic itself runs inside the hook and is not affected.

### Security

- Hook chains INTO the host `windows_shell_safety.py` via marker block
  insertion rather than dropping a parallel hook. Existing secret-leak
  protections in the host hook are preserved.
- `LEAD_AGENT=1` and `LEAD_HOOK_SCHEMA=3` environment variables gate
  activation. Without both set, the hook delegates to the host hook
  unchanged. The lead gate is dormant in non-lead Claude Code sessions.
- Generic deny messages (`denied: <generic-reason>`) prevent rule
  enumeration by a probing lieutenant. Specific reasons are written to
  `~/.claude/hooks/lead-pretool-hook.log` for owner debugging only.

[1.0.0]: https://github.com/ron2k1/lead-agent/releases/tag/v1.0.0
