# Security Policy

## Supported versions

Only v1.0 and later are supported. Pre-1.0 tags exist as design-cycle
artifacts and should not be deployed.

| Version | Supported |
|---|---|
| v1.0+ | yes |
| < v1.0 | no |

## Reporting a vulnerability

Email: ronilbasu@gmail.com with subject prefix `[lead-agent security]`.
Please do NOT open a public GitHub issue for security findings.

This is a side project, not a paid product. Response is best-effort,
not contractual. Realistic expectations:

- Acknowledgement: within 5 business days.
- Initial assessment (triage + scope confirmation): within 14 days.
- Fix or "wontfix with documented reason": within 60 days for High /
  Critical findings, longer for Medium / Low.

If your finding is time-sensitive (active exploitation, public PoC
imminent), say so in the subject line and mention the disclosure
deadline you are working to.

## Encrypted communication

The author does not currently publish a PGP / GPG key. If your report
contains exploit code or sensitive details and you need encrypted
transport, ask in the initial email and we can arrange Signal or
Keybase. Plain email is acceptable for most findings -- the threat
model below makes most "leak" scenarios obvious before disclosure.

## Disclosure policy

Default: 90-day coordinated disclosure from acknowledgement. Negotiable
in either direction:

- Shorter if active exploitation is observed.
- Longer if a fix requires upstream changes (e.g., to Anthropic's
  Claude Code hook protocol) that you and I cannot complete alone.

After the embargo expires, you may disclose publicly. Credit will be
given in the release notes unless you prefer to remain anonymous.

## Scope

The following ARE in scope and qualify as a vulnerability:

- Bypass of the runtime gate's deny-by-default invariant. Any path
  that lets a Bash, Edit, Write, NotebookEdit, Read, Grep, Glob, or
  MCP call execute when `LEAD_AGENT=1` without matching an allowlist
  rule is in scope.
- Trust-chain compromise. Any path that lets a tampered
  `install-hook.ps1`, `lead-extension.sha256`, or pinned config
  survive an `install.ps1 -Verify` probe is in scope.
- Argv-shape parser injection. Any input that causes
  `allowlist_parser.tokenize` to produce an argv that matches an
  allowlist rule but executes a different command on the shell is in
  scope. Also any input that bypasses the bypass-token regex.
- Path canonicalizer bypass. Any Windows path encoding (8.3 short
  name, junction chain, NTFS alternate stream, UNC variant, casing,
  Unicode normalization) that makes `canonicalize-path.py` return a
  string that the path-guard accepts but resolves to a different file
  on disk.
- Lifecycle-script execution. Any way to trigger npm / pip / cargo /
  pytest / gem / composer / poetry / uv / bundler / mix / cabal /
  swift-package / dotnet / pdm / hatch lifecycle hooks from inside
  BUILDER mode without explicit owner approval.
- ACK-marker forgery. Any same-user-OR-LOWER attacker who forges a
  valid HMAC ACK without reading the manifest (the manifest read is
  the documented same-user-residual; forgery without it is in scope).

The following are OUT of scope:

- Same-user-RCE attacker. An attacker who already has code execution
  under your Windows account is explicitly out of scope. v3 (TPM +
  user-presence) addresses this; v1 does not. See the README's
  "What this is NOT" block.
- Issues in upstream Claude Code itself. Report those to Anthropic.
- Issues in the host `windows_shell_safety.py` hook. lead-agent is an
  *extension* of that file, not a replacement; bugs in the host hook
  are out of scope here.
- Resource exhaustion / DoS by an adversarial system prompt. The
  lieutenant is trusted to not loop forever; if it does, you can
  close the tab. Token-burn is not a vulnerability.
- Findings that require physical access to the unlocked machine,
  domain-admin privileges, or kernel-level process injection.
- Findings that require modifying the user's `$env:USERPROFILE` ACL
  to allow Everyone:Write. The user-only ACL is part of the
  threat-model assumption set.
- Cross-platform issues. v1 is Windows-only by design.

## What "Critical / High / Medium / Low" means here

- **Critical**: deny-by-default broken. Any user running v1.0 has
  their threat-model assumption violated.
- **High**: trust-chain or canonicalizer bypass that requires only
  out-of-process capabilities (no same-user-write).
- **Medium**: scope violation that requires out-of-band conditions
  (specific Windows version, specific filesystem, etc.).
- **Low**: documentation drift, sub-optimal defaults, hardening that
  would be nice but is not load-bearing.

Findings of any severity are welcome. Low findings still get fixed --
they just queue behind Critical / High.
