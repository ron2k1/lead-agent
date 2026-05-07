---
name: lead-agent
description: Use when the user types `/lead-agent` (optionally with a subdirectory hint) to spawn a long-lived "lieutenant" Claude Code instance in its own Windows Terminal tab on Screen 2. The lieutenant runs alongside the main CC and operates in one of four modes (OVERWATCH / ADVISOR / BUILDER / TOOLSMITH) determined by the system prompt and runtime allowlist. The slash command must be invoked from main CC (not from inside the lead itself); SKILL.md will detect lead-self-target and refuse. See DESIGN.md for the full contract; v1.0 shipped 2026-05-06 with the runtime gate ACTIVE; v1.1.0 expanded the pin set to 12 files, shipped F-01/F-02 stale-lock auto-recovery, and ships secret-scan + jsonl-watcher as production-grade libraries (BUILDER push + OVERWATCH ingest wiring lands in v1.1.1). ADVISOR + TOOLSMITH modes are READY for daily use; BUILDER + OVERWATCH are PARTIAL (libraries production-grade in v1.1.0; consumer wiring lands in v1.1.1).
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
  killed, mid-session reboot), `-Force` reclaims it after PID +
  Win32_Process.CreationDate stale-detection (F-01, `launch.ps1` lockfile
  block). For the rare double-failure case where -Force itself fails (lock
  raced by a peer launcher mid-reclaim), point the user at README.md
  `## Recovery` for the manual cleanup one-liner.

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
- For stale-lockfile refusals: `-Force` reclaims after PID +
  Win32_Process.CreationDate stale-detection (F-01 went live in v1.1.0).
  The hint line in the refusal message tells the user when -Force is
  the right call. Do NOT offer -Force for live-PID refusals (the lock
  is held by an actual running lieutenant; -Force will not override
  that, by design).
- For the rare double-failure case (lock raced by a peer launcher
  mid-reclaim), point the user at README.md `## Recovery` for the
  manual cleanup one-liner.

Closes F-01 + F-03 + F-04; see DESIGN.md section 15.10.

## Files

| File | Purpose | Status (v1.1.0) |
|---|---|---|
| `install.ps1` | User-facing bootstrap (preflight + anchor stamp + delegate to install-hook.ps1) | Active |
| `launch.ps1` | Entrypoint: lockfile + preflight + manifest + WT spawn; F-01 stale-lock reclaim live | Active (launch + lock + manifest with HMAC key wired; -Force reclaims via PID + Win32_Process.CreationDate) |
| `launch.cmd` | Double-click wrapper | Active |
| `runner.ps1` | Runs INSIDE the WT tab; reads manifest; env scrub; calls `claude` with the full LEAD_* env-var contract; F-02 3-layer lock-release on exit (try/finally + Register-EngineEvent + SetConsoleCtrlHandler) | Active (pinned in v1.1.0 manifest after Codex Wave 3c convergence flagged the unpinned-runtime-code BLOCKER) |
| `system-prompt.md` | Role + DENY hints; ASCII-only | Authored |
| `lib/path-guard.json` | Single source of truth for write-deny globs (V8-6) | Active |
| `lib/mcp-allow.json` | Positive MCP allowlist; deny-by-default | Active |
| `lib/allowlist.json` | argv-shape rules for BUILDER + TOOLSMITH (V8-1 valid JSON; uses `${LEAD_TOOLS_DIR}` env-var expansion) | Active |
| `lib/notify-sh.sha256` | Pin for `~/.claude/tools/notify.sh` (rotated by `install-hook.ps1 -RepinNotify`) | Active |
| `lib/lead-extension.sha256` | 12-file pin manifest with self-hash chain | Active |
| `lib/canonicalize-path.py` | 8.3 / casing / slash / symlink normalizer | Active |
| `lib/allowlist_parser.py` | argv-shape parser with env-var expansion + 15-pattern secret regex (mirror of `secret-scan.ps1`) | Active |
| `lib/sanitize-jsonl.py` | JSONL sanitizer (consumed by `jsonl-watcher.ps1` OVERWATCH ingest loop) | Active |
| `lib/lead-pretool-hook.py` | The runtime gate (PreToolUse hook); trust-anchor SHA stamped at install time | Active |
| `lib/install-hook.ps1` | Idempotent hook chain installer (`-Repair`, `-RepinNotify`, `-Uninstall`, `-Force`) | Active |
| `lib/secret-scan.ps1` | Pre-push secret scanner: 15-pattern canonical regex set + base64 second-pass + HMAC-SHA256-signed manifest writer | Library production-grade in v1.1.0; BUILDER pre-push **hook wiring** lands in v1.1.1 |
| `lib/jsonl-watcher.ps1` | Sanitizing JSONL tail (role-prefix neutralizer + 15-pattern secret scrub) + brake-list writer for OVERWATCH | Library production-grade in v1.1.0; OVERWATCH **ingest-loop wiring** lands in v1.1.1 |
| `README.md` | User-facing install/use/uninstall doc | Active (v1.1.0) |

## Mode readiness

| Mode | Status (v1.1.0) | Notes |
|---|---|---|
| ADVISOR | READY | Full read/search/web on a deny-by-default tool surface. Recommended default. |
| TOOLSMITH | READY | Skill writes go through path-guard with `lib/` excluded. Safe for skill-creator workflows. |
| BUILDER | PARTIAL | Worktree edits + draft PRs work. Secret-scan **library** is production-grade in v1.1.0 (15-pattern canonical set + HMAC-signed manifest); the BUILDER pre-push **hook wiring** that calls it is still stubbed and lands in v1.1.1. Treat as "code-review buddy" until v1.1.1; the lieutenant cannot autonomously push to a remote yet. |
| OVERWATCH | PARTIAL | Hook denies tool calls correctly. JSONL **library** (sanitizer + brake-list writer) is production-grade in v1.1.0; the OVERWATCH **ingest-loop wiring** that tails the lieutenant's JSONL is still stubbed and lands in v1.1.1. |

## Runtime gate status (v1.1.0)

- All 12 pinned runtime-gate components are ACTIVE (canonicalizer, allowlist parser, hook, JSONL sanitizer, install-hook, secret-scan library, jsonl-watcher library, launch.ps1, runner.ps1 + 3 JSON pins). v1.0.0 shipped 9; v1.1.0 walkback added secret-scan.ps1 + jsonl-watcher.ps1 (library production-grade) and runner.ps1 (Codex Wave 3c convergence on the unpinned-runtime-code BLOCKER).
- Trust anchor pattern (C7 v0.6) wired: `_ANCHOR_SHA` constant in `lead-pretool-hook.py` is stamped by `install.ps1` from the local `lib/install-hook.ps1` SHA256 BEFORE the pin manifest is written, so distribution-time line-ending drift cannot break the running gate.
- Bootstrap installer `install.ps1` provides preflight + idempotent install + `-Verify` 6-probe end-to-end check (marker block, trust-anchor file, `_ANCHOR_SHA` constant, pin-manifest self-hash, `launch.ps1 -Dry`, drift detector) + `-Force`.
- `lib/secret-scan.ps1` and `lib/jsonl-watcher.ps1` ship as production-grade libraries in v1.1.0; the BUILDER pre-push hook + OVERWATCH ingest-loop **wiring** that consumes them is still stubbed and lands in v1.1.1. The deny-by-default invariant holds in both modes (the hook still denies dangerous calls); the only thing missing is the autonomous-flow plumbing that would actually invoke these libraries.
- `launch.ps1 -Force` reclaims orphaned lockfiles (F-01 live in v1.1.0) after PID + Win32_Process.CreationDate stale-detection. `runner.ps1` 3-layer lock-release (try/finally + Register-EngineEvent + SetConsoleCtrlHandler P/Invoke; F-02 live in v1.1.0) means orphan locks are now rare to begin with.
- See DESIGN.md section 15.8 for the residuals list and CHANGELOG.md for v1.0 → v1.1.0 detail.
