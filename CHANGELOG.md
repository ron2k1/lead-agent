# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog (https://keepachangelog.com/en/1.1.0/),
and this project adheres to Semantic Versioning (https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-05-07

Distribution-first patch release. v1.1.0 shipped with a doc claim that
`~/.claude/hooks/windows_shell_safety.py` was an "Anthropic Windows
safety baseline" -- it is not. Anthropic does not ship that file. It is
the user's own custom PreToolUse hook, which fresh cloners do not have.
The v1.1.0 install therefore refused for any stranger trying to clone
the repo and use the skill. v1.1.1 closes that distribution gap, plus
two runtime fixes that surfaced once the install path actually worked
end-to-end on a fresh machine.

No security model changes. No allowlist or path-guard changes. No pin
manifest schema changes (manifest contents re-pinned because launch.ps1
and runner.ps1 changed). The deny-by-default invariant is identical to
v1.1.0; this release only fixes user-facing distribution friction and
two latent runtime bugs.

### Added

- `lib/windows_shell_safety_stub.py` (50-line ASCII no-op host hook).
  Drains stdin, exits 0 -- a chain anchor for the lead-agent gate, not
  a security feature on its own. NOT pinned in
  `lib/lead-extension.sha256` by design (users are expected to replace
  or harden their own host hook). Provides a positive answer to "what
  do strangers without an existing PreToolUse hook do?".
- `install.ps1 -Bootstrap` flag. Idempotently copies the stub to
  `~/.claude/hooks/windows_shell_safety.py` if no host hook is present;
  refuses to overwrite an existing host hook (custom hooks are sacred).
  Dispatch happens BEFORE `Test-Prereq` so the preflight check sees the
  just-installed stub. Updated the host-hook preflight hint to point
  fresh cloners at `-Bootstrap` instead of the false "install
  Anthropic's baseline" path.

### Fixed

- `runner.ps1` env-scrub no longer breaks lieutenant MCP children.
  v1.1.0's scrub destroyed `PATH` before child processes could resolve
  `node` / `npx` / `npm` / `pnpm` / `yarn` / `python` / `python3` /
  `pythonw` / `uv` / `uvx` / `git`, breaking 14+ MCP servers on
  lieutenant launch. Fixed by resolving each tool via `Get-Command`
  BEFORE the scrub loop runs, deduping case-insensitively (Windows
  PATH semantics), and appending the resolved directories to `$minPath`.
  Missing tools are silently skipped (additive, not validating). The
  scrub still removes everything else, preserving the v1.1.0
  attack-surface reduction.
- `launch.ps1 -Dry` no longer leaks the lockfile + manifest temp file.
  v1.1.0's `-Dry` branch acquired both resources at lines 44 and 179
  but returned at line 201 without spawning the runner that would
  release them. `install.ps1 -Verify` probe 5 invokes `-Dry`, so every
  verify run was poisoning the lead-agent state and accumulating stale
  GUID-named blobs in `%LOCALAPPDATA%\Temp\`. Fixed by
  `Remove-Item -LiteralPath ... -Force -ErrorAction SilentlyContinue`
  on both paths immediately before the `-Dry` `return`. Real-spawn
  path unchanged (deletes are inside the `if ($Dry)` branch).

### Changed

- `README.md` rewritten to lead with the actual product pitch
  ("deny-by-default gate for a SECOND CC instance") instead of a
  technical preamble. Three doc fixes: (1) fear-first opener after the
  badges; (2) `windows_shell_safety.py` reclassified from HARD to SOFT
  requirement with three install paths (own hook / `-Bootstrap` stub /
  `-HookFileOverride <path>`); (3) FAQ "macOS or Linux?" answer no
  longer claims the host hook is an Anthropic baseline. Install
  procedure step #2 gained a one-line `-Bootstrap` callout for fresh
  cloners.
- `SECURITY.md` "out of scope" entry for the host hook now states
  provenance positively: the host hook is USER-PROVIDED, not
  vendor-supplied. Adds a positive carve-out that bugs in the bundled
  stub which break the chain anchor (preventing lead-agent from
  extending) ARE in scope, even though the stub itself is allow-all.
  Also makes explicit that the stub does not provide additional
  security on its own -- the lead-agent gate runs ON TOP when
  `LEAD_AGENT=1`.
- `lib/lead-extension.sha256` re-pinned twice during v1.1.1: once for
  `runner.ps1` (PATH expansion edit) and once for `launch.ps1` (-Dry
  leak fix). Final values:
  - `runner.ps1`: `8820d65e782f5873dc5899997b6cf22ea449d37d34da221318f8cbd253f85382`
  - `launch.ps1`: `d7f0668773686d5927c7eac51105ab903e87ed6e9744d28119565d26b1e43ff4`
  - self-hash: `2a92cab63b39f447f5a6ef3a0d84f7c48dda62fa9f6d43ecf60536afce8294b6`
- `.commitmsg` and `.tagmsg-*` workflow files added to `.gitignore`.
  These are per-commit `git commit -F <file>` / `git tag -F <file>`
  workflow artifacts that should never have been tracked in the first
  place. Same category as the already-ignored `.codex-review-prompt.txt`.

### Known limitations carried forward from v1.1.0

- BUILDER pre-push hook wiring still deferred (lib is production-grade,
  caller is missing). Tracked for v1.2 along with the v1.2 task-board
  work.
- OVERWATCH ingest loop wiring still deferred (lib is production-grade,
  driver is missing). Tracked for v1.2.
- W3-NEW3 MINOR (mid-string role tokens slipping through after
  `ConvertTo-Json -Compress` flattens nested payloads) still
  outstanding. The `lib/jsonl-watcher.ps1` library is the affected
  surface; fix lands when the OVERWATCH driver wiring goes in.

## [1.1.0] - 2026-05-06

Walkback release. v1.0.x shipped runtime gate + ADVISOR/TOOLSMITH; v1.1.0
hardens the gate and promotes the secret-scan + jsonl-watcher libraries
from fail-closed stubs to production-grade implementations. The 4-mode
matrix is now: ADVISOR + TOOLSMITH READY, BUILDER + OVERWATCH library-ready
with runtime wiring deferred to v1.1.1.

> **Note (added at v1.1.1 tag):** the wiring promised here was re-deferred
> to **v1.2** when v1.1.1 became a distribution-first patch (host-hook
> bootstrap gap + 2 latent runtime fixes). See the v1.1.1 entry's
> "Known limitations carried forward" section. The library code shipped
> in v1.1.0 is unchanged; only the consumer-side hook + ingest-loop wiring
> moved to v1.2.

Driven by codex Wave 3b adversarial re-review (3 BLOCKERs + 4 MAJORs +
1 MINOR), then closed by codex Wave 3c convergence pass which independently
flagged a 4th BLOCKER (runner.ps1 was promised in walkback CHANGELOG/README
but not actually pinned). Walkback executed across 13 atomic commits.
See `git log v1.0.0..v1.1.0 --oneline` for the per-commit walkback story.

### Added

- 12-file pin manifest (was 9 in v1.0.0). Now covers `secret-scan.ps1`,
  `jsonl-watcher.ps1`, and `runner.ps1` in addition to v1.0.0's nine
  files. Closes W3-NEW2 BLOCKER (codex Wave 3b flagged the v1.0.0 set
  as incomplete -- three live runtime files were unsanctioned) and the
  Wave 3c convergence BLOCKER (the original walkback added secret-scan
  + jsonl-watcher to the tuple but missed runner.ps1, which holds the
  launch lock and runs F-02's three-layer lock-release handlers in the
  trust boundary).
- Trust anchor `_ANCHOR_SHA` constant in `lead-pretool-hook.py:45`
  re-stamped twice during the v1.1.0 walkback (Wave 3b expanded the
  pin set from 9 to 11 files; Wave 3c added `runner.ps1`; Wave 3d
  added the fresh-clone `notify.sh` placeholder stub which mutated
  `install-hook.ps1` once more). Final value:
  `a8329a1b08d024b6fde74fd095873d9bd7f941fe3fdde54d5973c109cc2d8c2e`.
  This is the SHA256 of `lib/install-hook.ps1` as shipped at v1.1.0
  tag and is the trust-cascade root that the runtime gate verifies
  on every PreToolUse fire (DESIGN.md s12.6 step 1).
- Production-grade `lib/secret-scan.ps1`: 15-pattern HMAC-signed scan-pass
  manifest replaces the v1.0.0 fail-closed stub. Library is ready; the
  BUILDER pre-push hook that calls it remains stubbed in v1.1.0 (see
  "Known limitations" below).
- Production-grade `lib/jsonl-watcher.ps1`: tail + sanitizer (secret
  redact + role-prefix neutralize + truncate) + brake-list writer
  replaces the v1.0.0 fail-closed stub. Library is ready; the OVERWATCH
  ingest loop that calls it remains stubbed in v1.1.0.
- C-01..C-15 fixture test matrix at `tests/fixtures/hook/*.json` plus
  driver at `tests/run-hook-fixtures.ps1`. 5 allow-cases + 10 deny-cases.
  15/15 PASS as of `v1.1.0`. Closes #33 from v1.0.0 known-limitations.
- Lock-recovery preflight in `launch.ps1`: `-Force` mode re-claims a
  stale lockfile only when the recorded PID is dead OR the recorded
  CreationDate predates the current process. The (PID, CreationDate)
  tuple is collision-resistant per the Win32_Process docs and prevents
  the v1.0.x "PID-recycled-into-different-program" false-reclaim window.
- Three-layer lock release in `runner.ps1`: try/finally + the
  `Register-EngineEvent PowerShell.Exiting` event + a P/Invoke
  `SetConsoleCtrlHandler` callback. The lock now releases on any of:
  normal exit, unhandled exception, Ctrl-C, console-window-close.

### Changed

- Bash command-chain parser in `lib/allowlist_parser.py` now denies on
  detection of any shell control token. The `tokenize()` function uses
  `shlex(punctuation_chars=True, whitespace_split=True)` so operators
  emit as standalone tokens regardless of surrounding whitespace
  (`cmd1;cmd2` -> `['cmd1', ';', 'cmd2']`), then a frozenset membership
  check (`_SHELL_CONTROL_TOKENS`: `;`, `&&`, `||`, `|`, `&`, `>`, `>>`,
  `<`, `<<`, `<<<`, `(`, `)`) raises `AllowlistError("denied: shell
  metacharacter disallowed")` on the first hit. Command-substitution
  sigils (`$(`, backtick) and statement separators (`\n`, `\r`) are
  scanned in the raw input before tokenization since shlex does not
  treat `$` as punctuation and bash expands command substitution even
  inside double quotes. Closes W3-NEW3 BLOCKER (v1.0.x parsed only the
  first segment via `shlex.split`, which let `git status && rm -rf /`
  slip through).

  Note: this is deny-on-detect, not split-and-validate-each-segment.
  The implementation is *strictly more restrictive* than per-segment
  allowlist matching -- a single shell metacharacter anywhere in the
  argv stream denies the whole input, even if every segment in
  isolation would have been allowlisted. The split-validate variant
  is documented in DESIGN.md s12.2 as a v1.x backlog refinement; it
  would relax this gate to allow legitimate compound commands
  (`git fetch && git rebase`) by validating each segment against
  the allowlist independently. Until that lands, callers needing
  pipelines must split into separate Bash invocations.
- Secret-pattern set unified across the three places it was duplicated
  (Python `re` in the parser, .NET `Regex` in `secret-scan.ps1`, .NET
  `Regex` in `jsonl-watcher.ps1`). All three now consume the canonical
  15-pattern set documented in `DESIGN.md` s6. Closes W3-1 MAJOR.
- 24 sites across 5 .ps1 files rewritten from `Write-Error <msg>` +
  `exit 2` to `[Console]::Error.WriteLine(<msg>)` + `exit 2`. Under
  `$ErrorActionPreference='Stop'` (set by every shipped .ps1 at line
  ~12-32 for fail-fast hygiene), `Write-Error` raises a terminating
  WriteErrorException that beats `exit 2` -- the host's exit code
  defaults to 1 (unhandled error), not the intended 2. The harness
  reads exit codes with strict equality (0=allow, 2=deny, other=crash);
  pre-fix every preflight refusal landed in the third bucket.
  Closes W3-11 MAJOR.
- C-06..C-15 deny-fixtures tightened to assert per-route generic
  strings (`"not in mcp-allow.json"` for the 8 mcp routes,
  `"not in allowlist"` for the 2 catch-all routes) plus negative
  guards against `"integrity"` and `"mcp-allow"` substrings. v1.0.x
  asserted only `stdoutContains: "block"` -- a 4-into-1 conflation
  that let any deny path satisfy any deny fixture. Closes W3-3 MAJOR.
- The v1.0.x `imperative-strip` label on the watcher sanitizer was
  inaccurate -- the regex only neutralizes leading role-impersonation
  prefixes (`^system:`, `^assistant:`, etc.), not generic imperative
  verbs. Renamed to `role-prefix neutralizer`. Variable, marker
  string `[NEUTRALIZED-ROLE-PREFIX]` (was `[STRIPPED-IMPERATIVE]`),
  and four comment lines updated in lockstep. New docblock spells out
  the W3-NEW3 known-limitation explicitly: mid-string role tokens
  pass through after `ConvertTo-Json -Compress` flattens nested
  payloads to a single line. Closes W3-9 TRIVIAL + W3-NEW3 MINOR.
- `launch.ps1` empty `try { ... } finally { /*comments-only*/ }`
  wrapper dropped. The 100-line body is now top-level; the
  lock-hold-for-life rationale is relocated to the lock-acquire site
  where it constrains the right code. Closes W3-10 TRIVIAL.

### Security

- The `lib/lead-extension.sha256` self-hash terminator now covers 12
  files instead of 9, increasing the integrity gate's coverage of the
  runtime path.
- The expanded pin set means a tampered `secret-scan.ps1` or
  `jsonl-watcher.ps1` is now caught at hook-invocation time
  (`_GENERIC_INTEGRITY` deny), where v1.0.x would have allowed it
  through unchecked.
- Bash `&&` / `||` / `;` chain bypass closed (W3-NEW3 BLOCKER). v1.0.x
  was advisory-only on multi-command bash inputs.

### Known limitations

- BUILDER mode autonomous push is STILL BLOCKED. The
  `lib/secret-scan.ps1` library is now production-grade (15-pattern
  scan + HMAC-signed scan-pass manifest), but the BUILDER pre-push
  hook that would call it is still a stub. Scheduled for v1.1.1.
  v1.0.x called this "scheduled for v1.1"; v1.1.0 is honest that the
  library shipped but the wiring did not.
- OVERWATCH mode live JSONL tail is STILL BLOCKED. The
  `lib/jsonl-watcher.ps1` library is now production-grade (tail +
  sanitizer + brake-list writer), but the OVERWATCH ingest loop that
  would call it is still a stub. Scheduled for v1.1.1. Same
  honesty-update note as BUILDER.
- Trust-anchor file-write race (W3-NEW1 BLOCKER, deferred per
  Critical Filter): the external fallback at
  `~/.claude/lead-agent-trust-anchor.txt` is ACL-locked with
  `Everyone:(DENY)`, but a sufficiently-privileged adversary could
  in principle race the file-write during install. Acceptable in
  v1.1.0 because the inline `_ANCHOR_SHA` constant takes precedence
  over the fallback file in every code path -- the fallback only
  matters if a packager strips the constant, which the integrity
  manifest catches. v1.1.1 will harden the file write itself.
- Spec residuals deferred to v1.1.1: V8-10 (Set-PSDebug -Trace 0 +
  Start-Transcript refusal preflight), V8-11 (regex-engine pin
  promote to spec-global), V8-12 (rewrite DESIGN.md s12.3 + s12.4
  hook-deny prose to "internally classify; emit generic; log specific").

[1.1.0]: https://github.com/ron2k1/lead-agent/releases/tag/v1.1.0

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
