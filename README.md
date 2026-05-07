# lead-agent

> A second Claude Code instance -- a "lieutenant" -- that runs in its own
> Windows Terminal tab on Screen 2, gated by a deny-by-default PreToolUse
> runtime hook.

[![CI](https://img.shields.io/github/actions/workflow/status/ron2k1/lead-agent/ci.yml?branch=main&label=CI)](https://github.com/ron2k1/lead-agent/actions)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.1.1-informational)](CHANGELOG.md)
[![Status](https://img.shields.io/badge/status-v1.1.1%20partial-yellow)](#status)

---

**Worried about giving Claude Code shell access?** lead-agent runs a
SECOND Claude Code instance -- "the lieutenant" -- with a deny-by-default
PreToolUse gate sitting in front of every tool call. Same toolkit
(plugins, MCPs, skills), but only what an explicit allowlist plus
path-guard say it can do. The lieutenant cannot talk its way past the
gate; the gate is the source of truth.

The 30-second pitch: open `/lead-agent` in your main CC, get a fresh
Claude Code tab on your second monitor with a different system prompt
and a tighter tool surface. Use it as a code-review buddy (ADVISOR),
to refine your skills (TOOLSMITH), or to prepare branches with no push
authority (BUILDER, library-grade in v1.1.0; pre-push hook wiring lands
in v1.2). The runtime gate is identical across all four modes; only
the allowlist differs.

---

## Status

v1.1.0 shipped 2026-05-06 as a walkback over v1.0.x. v1.1.1 shipped
2026-05-07 as a distribution-first patch (closes the host-hook bootstrap
gap with `install.ps1 -Bootstrap` and a bundled stub; fixes runner.ps1
PATH scrub for MCP children; fixes launch.ps1 -Dry temp-resource leak).
The runtime gate is live and the 12-file pin chain (was 9 in v1.0) plus
trust anchor are end-to-end verified. ADVISOR and TOOLSMITH modes are
READY for daily use. BUILDER's pre-push secret scanner
(`lib/secret-scan.ps1`) and OVERWATCH's JSONL watcher
(`lib/jsonl-watcher.ps1`) shipped as production-grade libraries in
v1.1.0 -- but the BUILDER pre-push hook and OVERWATCH ingest loop that
call them are still stubs. Wiring lands in v1.2 alongside the task-board
work. The gate still denies-by-default in those modes; the stubs only
block the autonomous sub-flows, not the gate itself.

If you want a "send a second Claude to advise me / refine skills" pattern
today, install. If you specifically need autonomous push or live transcript
overwatch, wait for v1.2 (the libraries ship in v1.1.0; the wiring does
not).

See `## Mode readiness` below for the full split.

---

## What it is

You type `/lead-agent` in your main Claude Code session. A new Windows
Terminal tab opens on your second monitor. Inside that tab is a fresh
`claude` process with your full toolkit (plugins, MCP servers, skills) and
a role-specific system prompt. Every tool call that lieutenant tries is
intercepted by a PreToolUse hook that checks a positive allowlist plus a
canonicalized path-guard before the tool ever runs. The lieutenant cannot
talk its way past the gate -- the hook is the source of truth.

Demo flow:

- You type `/lead-agent web` in main CC.
- A new WT tab titled `LEAD` appears on Screen 2 in ADVISOR mode by default.
- You ask the lieutenant to read your codebase and propose a refactor.
- It reads, searches, fetches docs, writes analysis to chat.
- Any write attempt outside its mode-specific allowed paths is denied
  before the tool fires. The lieutenant sees a generic "denied" string
  with no rule details.

<!-- TODO(owner): drop a real screenshot at docs/screenshot-screen2.png. -->
<!-- ![Screen 2 layout with main CC, codex, and LEAD tabs](docs/screenshot-screen2.png) -->

---

## Requirements

Hard requirements (skill refuses to launch without these):

- Windows 10/11 with NTFS on the disk holding `%USERPROFILE%`.
- Windows PowerShell 5.1 or PowerShell 7+ (`pwsh.exe`). Both work.
- Python 3.10+ on `PATH`. The hook is a Python subprocess.
- Windows Terminal (`wt.exe`) 1.18 or later.
- Claude Code CLI (`claude` or `claude.cmd`) on `PATH`.

Soft requirements (recommended):

- A PreToolUse hook at `~/.claude/hooks/windows_shell_safety.py`. The
  lead-agent gate chains INTO this file rather than dropping a parallel
  hook. Three install paths:
    1. You already have your own custom hook (shell-safety, secret-scan,
       project-specific deny rules) -- lead-agent extends it without
       replacing.
    2. You don't have one. Run `install.ps1 -Bootstrap` to drop the
       bundled `lib/windows_shell_safety_stub.py` (a 50-line ASCII no-op
       that drains stdin and exits 0) at the host path. This is a chain
       anchor only -- the stub is allow-all on its own; lead-agent's
       deny-by-default gate runs ON TOP of it when `LEAD_AGENT=1`. The
       stub never touches main CC's behavior.
    3. You have a hook at a different path. Invoke
       `lib/install-hook.ps1 -HookFileOverride <path>` directly (the
       top-level `install.ps1` does not forward this flag in v1.1.1
       -- end-to-end plumbing tracked for v1.2).
  Without one of the above, `install.ps1` refuses. The stub is NOT
  pinned in `lib/lead-extension.sha256` by design -- you are expected
  to replace or harden it yourself.
- `gh` CLI logged into your GitHub account. BUILDER mode opens draft PRs
  via `gh pr create --draft`.
- A `~/.claude/tools/notify.sh` script for one-way Telegram or Discord
  notifications. The hook's allowlist only permits invocations of this
  exact file when `lib/notify-sh.sha256` matches. Missing notify.sh is
  fine. BUILDER cannot ping you on blocking events without it.

---

## Install (five commands)

```powershell
# 1. Clone into your skills directory.
git clone https://github.com/ron2k1/lead-agent "$env:USERPROFILE\.claude\skills\lead-agent"

# 2. Run the bootstrap. Stamps the trust anchor, chains the hook,
#    pins the integrity manifest.
#    First install with no host hook? Add -Bootstrap to drop the
#    bundled no-op stub at ~/.claude/hooks/windows_shell_safety.py
#    so the lead-agent gate has a chain anchor.
& "$env:USERPROFILE\.claude\skills\lead-agent\install.ps1"
# OR for fresh machines:
# & "$env:USERPROFILE\.claude\skills\lead-agent\install.ps1" -Bootstrap

# 3. Verify the gate is wired (should print "lead-agent gate ACTIVE").
& "$env:USERPROFILE\.claude\skills\lead-agent\install.ps1" -Verify

# 4. Restart any open Claude Code session so the hook is picked up.

# 5. From main CC, type /lead-agent to spawn a lieutenant. Or
#    double-click launch.cmd for the standalone path.
```

`install.ps1` is idempotent. Re-running it on an already-installed skill
re-pins the manifests, re-stamps the trust anchor, and exits clean. It
does NOT modify any project files outside the skill directory and
`~/.claude/hooks/windows_shell_safety.py`.

---

## Use

**From main CC (recommended):** type `/lead-agent` (optionally with a
subdirectory hint: `/lead-agent web`). The slash command refuses if
invoked from inside a lieutenant (W-09 self-spawn guard) and refuses if
a prior lieutenant is still holding the lockfile at
`%LOCALAPPDATA%\Temp\lead-agent.lock`.

**Standalone:** double-click `launch.cmd` in the skill root, or run

```powershell
& "$env:USERPROFILE\.claude\skills\lead-agent\launch.cmd" [subdir-hint]
```

The lieutenant inherits your full toolkit (plugins, MCP servers, skills)
and a role-specific system prompt selected by mode.

---

## Modes

Pick the mode at launch via `-Mode`:

```powershell
& "$env:USERPROFILE\.claude\skills\lead-agent\launch.ps1" `
    -CallerCwd $PWD `
    -Mode ADVISOR
```

| Mode | What it does | Writes? |
|---|---|---|
| OVERWATCH | Tails sibling JSONL transcripts, surfaces anomalies, writes brake/break files only. | `~/.claude/lead-state/` only |
| ADVISOR | Reads project files, searches the codebase, fetches web docs, writes analysis to chat. | None |
| BUILDER | Opens feature branches `lead/*`, runs tests with `--ignore-scripts`, opens DRAFT PRs only. | Branch + draft PR only |
| TOOLSMITH | Refines skills under `~/.claude/skills/`. Cannot modify `lib/` or hook configs. | `~/.claude/skills/` only (excluding lead-agent itself) |

The default is `ADVISOR`. Together with TOOLSMITH it is one of the two
modes fully implemented in v1.1.0.

### Mode readiness

| Mode | v1.1.1 readiness |
|---|---|
| ADVISOR | READY. Full read/search/web on a deny-by-default tool surface. |
| TOOLSMITH | READY. Skill writes go through path-guard with `lib/` excluded. |
| BUILDER | PARTIAL. The secret scanner library (`lib/secret-scan.ps1`) is production-grade since v1.1.0: 15-pattern HMAC-signed scan-pass manifest. But the BUILDER pre-push hook that would call it is still stubbed, so `git push` remains gated. Use BUILDER for branch + draft PR work that does NOT require pushing yet. Wiring lands in v1.2 alongside the task-board work. |
| OVERWATCH | PARTIAL. The watcher library (`lib/jsonl-watcher.ps1`) is production-grade since v1.1.0: tail + sanitizer (secret-redact + role-prefix neutralizer + truncate) + brake-list writer. But the OVERWATCH ingest loop that would call it is still stubbed, so sibling JSONL ingestion is not live. The brake-file write path works. Wiring lands in v1.2. |

---

## Security model

### What this is NOT

- **NOT a sandbox in the chroot, container, or process-isolation sense.**
  lead-agent is a tool-call gate that runs in the same Windows user session
  as the lieutenant. It mediates which Bash commands, file writes, and MCP
  calls fire -- it does not isolate process memory, network, or filesystem
  at the kernel level.

- **NOT defense against malicious code already running as your Windows
  user.** A same-user-RCE attacker can read your ACL'd manifest, edit any
  pinned file before the hook reads it, or replace `python.exe` on PATH.
  v1 raises the bar (ancestor-walk, pin chain, anchor) but does not defeat
  this class. TPM-backed signing with user-presence is the v3 answer.

- **NOT multi-tenant.** lead-agent assumes one Windows user account that
  owns `%USERPROFILE%`, the skill directory, and the spawned `claude`
  process. It has not been threat-modeled for shared-machine,
  RDP-multi-session, or cross-user scenarios. If your machine is shared,
  do not deploy.

### How the gate works

The runtime gate (`lib/lead-pretool-hook.py`) is the source of truth for
what the lieutenant can do. The system prompt only carries hints so the
lieutenant can refuse politely BEFORE invoking a doomed tool call. Every
PreToolUse fires:

1. Verifies `LEAD_AGENT=1`. If unset, the hook delegates to the host
   `windows_shell_safety.py` (the gate is dormant in non-lead sessions).
   If set, the lead gate takes over.
2. Re-verifies the 12-file pin manifest at `lib/lead-extension.sha256` on
   every call (not just at launch). Closes the v0.4 SE-S2
   swap-after-startup window. Any drift fails closed. v1.1.0 expanded
   the manifest from 9 files to 12 to cover `secret-scan.ps1`,
   `jsonl-watcher.ps1`, and `runner.ps1` (W3-NEW2 plus Codex Wave 3c
   convergence on runner.ps1, which holds the launch lock and runs
   F-02's three-layer release handlers).
3. Re-verifies the trust anchor at
   `~/.claude/lead-agent-trust-anchor.txt` matches the SHA constant
   `_ANCHOR_SHA` in `lib/lead-pretool-hook.py`, which `install.ps1`
   stamps with the SHA-256 of `lib/install-hook.ps1` on first run. The
   published source ships with the author's dev-machine value already
   in place. `install.ps1` re-stamps it for your install.
4. Canonicalizes every path argument (8.3 short names, casing, slash
   style, symlinks, junctions) before checking the path-guard. Closes
   the path-traversal-via-encoding surface.
5. Argv-shape matches against `lib/allowlist.json`. The allowlist is
   positive (deny-by-default). There is no "allow anything that does not
   match a deny rule".

If any step fails, the hook prints `denied: <generic-reason>` and exits
with code 2. Specific reasons go to
`~/.claude/hooks/lead-pretool-hook.log` for debugging. The lieutenant
sees only the generic message so a probing lieutenant cannot enumerate
the rules.

### Threat model boundaries (read this before forking)

- The same-user-RCE adversary -- an attacker with code execution under
  your Windows account -- is **explicitly out of scope for v1**. v1
  raises the bar with user-only ACLs, ancestor-walk authentication, and
  pin-chain integrity, but cannot defeat a same-user attacker who can
  read your manifest and forge an HMAC. The right primitive is
  TPM-backed signing with user-presence (v3). BitLocker is unrelated --
  it protects offline disks, not running sessions.
- The lieutenant itself is treated as untrusted. The hook does not trust
  the lieutenant's claim about what tool it is calling, what arguments
  it is passing, or what mode it is in. The lieutenant cannot bypass
  the hook by claiming a comment-suffix bypass token. The hook
  substring-matches and rejects the suffix evasion. Untrusted means the
  hook will not act on the lieutenant's claims -- it does not mean the
  lieutenant cannot mislead a human reading its output. Treat lieutenant
  text the same as any LLM output.
- Sibling JSONL transcripts are treated as attacker-controlled (W-13
  prompt-injection vector). The v1.1.0 watcher library
  (`lib/jsonl-watcher.ps1`) sanitizes content via secret-redact +
  role-prefix neutralizer + truncate before any consumer reads it. The
  library is production-grade since v1.1.0; the OVERWATCH ingest loop that
  would call it is still stubbed, so sibling-JSONL ingestion is not yet
  live as of v1.1.1. This is a forward-looking guarantee that lands fully
  when v1.2 wires the loop. Known limitation: mid-string role tokens
  pass through after `ConvertTo-Json -Compress` flattens nested
  payloads to a single line (W3-NEW3 MINOR, scheduled for v1.2).

---

## FAQ

**Why a separate "lieutenant" instead of just running two `claude` tabs?**

Two unrelated `claude` tabs share the same hook chain and tool surface.
The lieutenant has a different env-var profile (`LEAD_AGENT=1`,
`LEAD_HOOK_SCHEMA=3`, plus 9 other `LEAD_*` vars set by `runner.ps1`)
that activates the deny-by-default gate INSIDE the existing PreToolUse
hook. Main CC stays unchanged.

**Will this slow main CC down?**

No. The lead-agent extension is dormant when `LEAD_AGENT` is unset --
the chained hook block returns immediately and falls through to the
existing `windows_shell_safety.py`. Only the lieutenant tab pays the
canonicalization + allowlist + path-guard cost.

**Is BUILDER mode safe to use right now?**

Yes, as a code-review buddy. Branch creation, worktree edits, and draft
PRs are fully wired. Autonomous `git push` is fail-closed because the
BUILDER pre-push hook that would call `lib/secret-scan.ps1` is still
stubbed as of v1.1.1 -- the gate denies the push tool call and nothing
leaks. The scanner library itself shipped production-grade in v1.1.0
(15-pattern HMAC-signed scan-pass manifest); only the wiring is
deferred. If you specifically need autonomous push, wait for v1.2.

**Does this work on macOS or Linux?**

No. v1 is Windows-only. The launcher uses `wt.exe` (Windows Terminal)
and chains into a Python PreToolUse hook at
`~/.claude/hooks/windows_shell_safety.py` -- either your own custom
hook, or the bundled `-Bootstrap` no-op stub. A Linux port would
replace both layers; see `## Distribution / forking notes` for the
boundaries.

**My fork edits a file under `lib/`. Why does the gate now refuse
everything?**

The pin manifest at `lib/lead-extension.sha256` covers twelve files
plus a self-hash (was nine in v1.0; v1.1.0 added `secret-scan.ps1`,
`jsonl-watcher.ps1`, and `runner.ps1` per W3-NEW2 + Codex Wave 3c
convergence). Editing any of
them invalidates the chain and the hook fail-closes on every call.
Re-pin with `install.ps1` to regenerate the manifest, or
`lib/install-hook.ps1 -RepinNotify` for the notify-only path.

**Can the lieutenant spawn another lieutenant?**

No. `launch.ps1` checks `$env:LEAD_AGENT_MODE` at startup and refuses
self-spawn (W-09 recursion guard). This closes the fork-bomb surface.
The lieutenant inherits the env var from the runner manifest, which is
HMAC-pinned, so editing the env var post-launch does not bypass the
check.

**Where do hook decisions get logged?**

`~/.claude/hooks/lead-pretool-hook.log`. The lieutenant only sees the
generic `denied: <reason>` string in chat; specific reasons stay in the
log. This prevents a probing lieutenant from enumerating the rules by
trial and error.

**`/lead-agent` keeps refusing with "stale lockfile detected" -- now
what?**

See `## Recovery` above for the one-liner cleanup. v1.1.0 added
`launch.ps1 -Force` lock-recovery preflight (PID + Win32_Process
CreationDate stale-detection per F-01) plus a 3-layer release in
`runner.ps1` (try/finally + Register-EngineEvent +
SetConsoleCtrlHandler per F-02). Most stale locks now self-clear; the
manual `Remove-Item` path is the fallback for cases where both layers
fail. Run the `Remove-Item` line, then retry.

---

## Uninstall

```powershell
# Remove the chained block from windows_shell_safety.py and clean up
# the pin manifest plus trust anchor.
& "$env:USERPROFILE\.claude\skills\lead-agent\lib\install-hook.ps1" -Uninstall
Remove-Item "$env:USERPROFILE\.claude\lead-agent-trust-anchor.txt"
Remove-Item "$env:USERPROFILE\.claude\skills\lead-agent\lib\lead-extension.sha256"

# Optional: remove the skill directory entirely.
Remove-Item -Recurse "$env:USERPROFILE\.claude\skills\lead-agent"
```

The uninstall preserves the host `windows_shell_safety.py` (only the
marker block between `# BEGIN lead-agent-extension` and
`# END lead-agent-extension` is removed) and creates a `.bak` for
recovery.

---

## Repair / re-pin

If you edit any file under `lib/` or change `notify.sh`, you must re-pin
so the hook does not fail-closed on integrity check:

```powershell
# Re-pin the manifest and trust anchor.
& "$env:USERPROFILE\.claude\skills\lead-agent\install.ps1"

# Re-pin notify.sh only (faster).
& "$env:USERPROFILE\.claude\skills\lead-agent\lib\install-hook.ps1" -RepinNotify

# Repair after a crashed install (restores .bak).
& "$env:USERPROFILE\.claude\skills\lead-agent\lib\install-hook.ps1" -Repair
```

---

## Recovery

If `/lead-agent` refuses with `stale lockfile detected`, the previous
lieutenant tab was closed without the runner releasing its lockfile --
typical causes: X-button tab close, parent process killed, mid-session
reboot. v1.1.0 added auto-recovery via `launch.ps1 -Force` (PID +
Win32_Process CreationDate stale-detection per F-01) plus a 3-layer
release in `runner.ps1` (try/finally + Register-EngineEvent +
SetConsoleCtrlHandler per F-02; `DESIGN.md` section 15.10). Most
double-failure cases that v1.0.x left stuck now self-clear; the manual
cleanup below is the fallback.

Manual cleanup:

```powershell
Remove-Item -LiteralPath "$env:LOCALAPPDATA\Temp\lead-agent.lock" -Force
```

Then re-run `/lead-agent`. If the lockfile reappears immediately, a real
lieutenant is still running -- find the WT tab and close it
(`launch.ps1` holds the lock for the LIFE of the spawned tab by design,
so a live tab will re-acquire the lock the moment you delete it).

v1.1.0 ships proper PID + Win32_Process CreationDate stale-detection
under `launch.ps1 -Force`, plus the runner.ps1 3-layer release that
clears the lock on normal exit, unhandled exception, Ctrl-C, or
console-window-close. The v1.0.x yellow drift warning is gone; the
recovery path documented above is now the fallback for the rare
double-failure case, not the default.

---

## Disclosure

This skill ships a PreToolUse hook that gates code execution. If you find
a vulnerability, do NOT file a public issue. See [`SECURITY.md`](SECURITY.md)
for the disclosure process and contact address. Reports are acknowledged
within 5 business days.

---

## Distribution / forking notes

- Every file under this skill is ASCII-only by policy (W-07). No
  em-dashes, no curly quotes, no Unicode bullets. The hook bytes are
  pinned. A Unicode normalization pass on a fork will break the trust
  chain. If you need to add docs in another language, put them in a
  separate file and exclude it from the pin set.
- The pin manifest at `lib/lead-extension.sha256` covers twelve files
  (allowlist.json, path-guard.json, mcp-allow.json, notify-sh.sha256,
  canonicalize-path.py, allowlist_parser.py, lead-pretool-hook.py,
  sanitize-jsonl.py, launch.ps1, secret-scan.ps1, jsonl-watcher.ps1,
  runner.ps1) plus a self-hash. v1.1.0 added the last three after
  W3-NEW2 flagged them as live runtime files that v1.0 left
  unsanctioned. (Codex Wave 3c then caught that the original walkback
  added two of the three but missed runner.ps1 -- the file that holds
  the launch lock and runs F-02's three-layer release handlers.) If
  you fork and change any of these, run `install.ps1` to re-pin.
- The published `_ANCHOR_SHA` constant in `lib/lead-pretool-hook.py`
  reflects the author's install. `install.ps1` overwrites it with YOUR
  `install-hook.ps1` SHA on first run. Do not commit your local anchor
  back upstream -- the published constant is a placeholder for fresh
  installs.
- DESIGN.md is the source of truth. If runtime behavior contradicts
  DESIGN.md, runtime is wrong. Fix runtime, not the spec. Nine codex
  review cycles plus Security Engineer companion across six of those
  cycles produced this design. The rationale for every quirk is
  documented in `DESIGN.md` section 15 changelog tables.
- This skill assumes Windows. Cross-platform is out of scope for v1. A
  Linux port would replace `wt.exe` with `tmux` or `kitty`, replace
  PowerShell with `bash`, and replace the chained-hook pattern with
  whatever the user's `claude` install uses for PreToolUse hooks.

---

## File map

| File | Purpose |
|---|---|
| `SKILL.md` | Skill metadata. CC reads this on startup. |
| `DESIGN.md` | Full design contract. 9 review cycles documented in section 15. |
| `README.md` | This file. |
| `SECURITY.md` | Vulnerability disclosure policy. |
| `CHANGELOG.md` | Per-version changelog (Keep a Changelog format). |
| `CONTRIBUTING.md` | How to land changes safely given the pin chain. |
| `LICENSE` | MIT. |
| `install.ps1` | Bootstrap installer. Stamps anchor and runs install-hook. |
| `launch.ps1` | Entrypoint: lockfile, preflight, manifest, WT spawn. |
| `launch.cmd` | Standalone double-click wrapper. Forwards to launch.ps1. |
| `runner.ps1` | Runs INSIDE the WT tab. Env scrub and claude exec. v1.1.0 adds 3-layer lock release (try/finally + Register-EngineEvent + SetConsoleCtrlHandler) per F-02. |
| `system-prompt.md` | Role plus DENY hints. ASCII-only. |
| `lib/install-hook.ps1` | Atomic chained-hook installer. Idempotent. |
| `lib/lead-pretool-hook.py` | The runtime gate. |
| `lib/allowlist_parser.py` | Argv-shape parser with env-var expansion. |
| `lib/canonicalize-path.py` | 8.3 / casing / slash / symlink normalizer. |
| `lib/sanitize-jsonl.py` | JSONL transcript sanitizer for OVERWATCH. |
| `lib/allowlist.json` | Argv-shape rules. Deny-by-default. |
| `lib/path-guard.json` | Single source of truth for write-deny globs. |
| `lib/mcp-allow.json` | Positive MCP allowlist. |
| `lib/notify-sh.sha256` | Pinned hash of `~/.claude/tools/notify.sh`. |
| `lib/lead-extension.sha256` | 12-file pin manifest plus self-hash. |
| `lib/secret-scan.ps1` | BUILDER pre-push secret scanner. PRODUCTION-GRADE LIBRARY since v1.1.0; BUILDER pre-push hook wiring lands in v1.2. |
| `lib/jsonl-watcher.ps1` | OVERWATCH transcript tailer. PRODUCTION-GRADE LIBRARY since v1.1.0; OVERWATCH ingest loop wiring lands in v1.2. |
| `lib/windows_shell_safety_stub.py` | Bundled 50-line ASCII no-op host hook copied to `~/.claude/hooks/windows_shell_safety.py` by `install.ps1 -Bootstrap` for fresh cloners with no existing host hook. Allow-all on its own; the lead-agent gate runs ON TOP when `LEAD_AGENT=1`. NOT pinned in `lib/lead-extension.sha256` by design. v1.1.1. |
| `lib/path-guard.ps1` | Standalone path-guard CLI. STUB. The path-guard logic itself runs inside the hook and is unaffected. |

---

## Pointers

- Full design and threat model: `DESIGN.md`.
- Per-version notes: `CHANGELOG.md`.
- Vulnerability disclosure: `SECURITY.md`.
- Contributing safely without breaking the pin chain: `CONTRIBUTING.md`.
