---
name: lead-agent
description: Use when the user types `/lead-agent` (optionally with a subdirectory hint) to spawn a long-lived "lieutenant" Claude Code instance in its own Windows Terminal tab on Screen 2. The lieutenant runs alongside the main CC and operates in one of four modes (OVERWATCH / ADVISOR / BUILDER / TOOLSMITH) determined by the system prompt and runtime allowlist. The slash command must be invoked from main CC (not from inside the lead itself); SKILL.md will detect lead-self-target and refuse. See DESIGN.md for the full contract; v1.0 shipped 2026-05-06 with the runtime gate ACTIVE. ADVISOR + TOOLSMITH modes are READY for daily use; BUILDER + OVERWATCH are PARTIAL (secret-scan + jsonl-watcher remain v1.1 work).
---

# lead-agent

Spawn a lieutenant Claude Code in a Windows Terminal tab on Screen 2.

## When to use

The user types `/lead-agent` (or `/lead-agent <subdir-hint>`) in main CC. Hand
control to `launch.ps1`; do not attempt to do its work in-line.

## When NOT to use

- The current process is itself running under lead-mode (`$env:LEAD_AGENT_MODE`
  is set). Refuse with: "lead-agent cannot spawn itself; run /lead-agent from
  the main CC tab on Screen 2." This closes the recursion / fork-bomb surface
  (W-09 in DESIGN.md section 4.1.4).
- The user asks for a "second Claude" but is not on Windows or does not have
  Windows Terminal installed. Refuse explicitly; do not silently pivot to a
  different launcher (W-03).
- A prior lieutenant is still running and the lockfile at
  `%LOCALAPPDATA%\Temp\lead-agent.lock` is held by a live process tree. Refuse
  with the lockfile's PID and suggest closing the prior tab. If the lockfile
  is orphaned (lieutenant tab closed without runner cleanup, parent process
  killed, mid-session reboot), point the user at README.md `## Recovery` for
  the manual cleanup one-liner. `-Force` is a documented v1.x stub
  (`launch.ps1:46-52`); do NOT offer it as a workaround.

## How to invoke

The slash command runs in main CC. Pass through the caller's cwd and session id
directly; do NOT use the latest-modified-JSONL heuristic to discover them
(W-09: it can pick the lead's own session or a peer-CLI session).

```powershell
& "$PSScriptRoot\launch.ps1" `
    -CallerCwd $PWD `
    -CallerSessionId $env:CLAUDE_SESSION_ID `
    -SubdirHint $args[0]
```

Standalone double-click path: `launch.cmd` does the same with no
`-CallerSessionId` (runner derives it from the lead's own JSONL on first
write).

### Contract

When the user types `/lead-agent` with no arguments:

- Pass `-CallerCwd $PWD` to `launch.ps1`.
- Default to ADVISOR mode (the documented `-Mode` default in `launch.ps1`).
- Do NOT prompt the user for mode, cwd, or subdir.
- Do NOT inline-replicate `launch.ps1`'s lockfile, preflight, or
  PID-correlation logic. Hand control over and let `launch.ps1` own those
  checks. The skill is intentionally a thin shell.

When `launch.ps1` refuses:

- Surface its `lead-agent refuses: <reason>` message verbatim, including
  the `hint:` line.
- Do NOT offer to bypass via `-Force` -- that flag is a documented v1.x
  stub (`launch.ps1:46-52` still refuses with
  `-Force not yet implemented`).
- For the stale-lockfile case specifically, point the user at README.md
  `## Recovery` for the manual cleanup one-liner.

Closes F-03 + F-04; see DESIGN.md section 15.10.

## Files

| File | Purpose | Status (v1.0) |
|---|---|---|
| `install.ps1` | User-facing bootstrap (preflight + anchor stamp + delegate to install-hook.ps1) | Active |
| `launch.ps1` | Entrypoint: lockfile + preflight + manifest + WT spawn | Active (launch + lock + manifest with HMAC key wired) |
| `launch.cmd` | Double-click wrapper | Active |
| `runner.ps1` | Runs INSIDE the WT tab; reads manifest; env scrub; calls `claude` with the full LEAD_* env-var contract | Active |
| `system-prompt.md` | Role + DENY hints; ASCII-only | Authored |
| `lib/path-guard.json` | Single source of truth for write-deny globs (V8-6) | Active |
| `lib/mcp-allow.json` | Positive MCP allowlist; deny-by-default | Active |
| `lib/allowlist.json` | argv-shape rules for BUILDER + TOOLSMITH (V8-1 valid JSON; uses `${LEAD_TOOLS_DIR}` env-var expansion) | Active |
| `lib/notify-sh.sha256` | Pin for `~/.claude/tools/notify.sh` (rotated by `install-hook.ps1 -RepinNotify`) | Active |
| `lib/lead-extension.sha256` | 12-file pin manifest with self-hash chain | Active |
| `lib/canonicalize-path.py` | 8.3 / casing / slash / symlink normalizer | Active |
| `lib/allowlist_parser.py` | argv-shape parser with env-var expansion | Active |
| `lib/sanitize-jsonl.py` | JSONL sanitizer (used by OVERWATCH watcher; library is ready, watcher is stub) | Active |
| `lib/lead-pretool-hook.py` | The runtime gate (PreToolUse hook); trust-anchor SHA stamped at install time | Active |
| `lib/install-hook.ps1` | Idempotent hook chain installer (`-Repair`, `-RepinNotify`, `-Uninstall`, `-Force`) | Active |
| `lib/secret-scan.ps1` | Pre-push secret scanner with manifest writer | Stub (fail-closed) - blocks BUILDER mode autonomous-push, v1.1 |
| `lib/jsonl-watcher.ps1` | Sanitizing JSONL tail; brake/break writer for OVERWATCH | Stub (fail-closed) - blocks OVERWATCH mode tailing, v1.1 |
| `README.md` | User-facing install/use/uninstall doc | Active (v1.0) |

## Mode readiness

| Mode | Status | Notes |
|---|---|---|
| ADVISOR | READY | Full read/search/web on a deny-by-default tool surface. Recommended default. |
| TOOLSMITH | READY | Skill writes go through path-guard with `lib/` excluded. Safe for skill-creator workflows. |
| BUILDER | PARTIAL | Worktree edits + draft PRs work; pre-push secret scanner is fail-closed stub. Treat as "code-review buddy" until v1.1. |
| OVERWATCH | PARTIAL | Hook denies tool calls correctly; the JSONL tail/brake-list writer is fail-closed stub. v1.1. |

## v1.0 changelog vs v0.9-final

- All 9 pinned runtime-gate components are ACTIVE (canonicalizer, allowlist parser, hook, JSONL sanitizer, install-hook + 4 JSON pins).
- Trust anchor pattern (C7 v0.6) wired: `_ANCHOR_SHA` constant in `lead-pretool-hook.py` is stamped by `install.ps1` from the local `lib/install-hook.ps1` SHA256 BEFORE the pin manifest is written, so distribution-time line-ending drift cannot break the running gate.
- Bootstrap installer `install.ps1` provides preflight + idempotent install + `-Verify` 5-probe end-to-end check + `-Force`.
- `lib/secret-scan.ps1` and `lib/jsonl-watcher.ps1` remain fail-closed stubs - the hook still denies dangerous calls, so the deny-by-default invariant holds. BUILDER's autonomous push and OVERWATCH's live tail are both deferred to v1.1.
- See DESIGN.md section 15.8 for the original v0.9 residuals list and which entries are now closed.
