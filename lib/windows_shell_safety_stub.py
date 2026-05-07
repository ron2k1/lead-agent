"""
windows_shell_safety_stub.py - minimal no-op host hook for Claude Code.

Shipped by lead-agent's `install.ps1 -Bootstrap` for users who do not
yet have their own `~/.claude/hooks/windows_shell_safety.py`.

This stub allows every PreToolUse invocation. Its only job is to be the
chain anchor that `lib/install-hook.ps1` extends with the lead-agent
gate. When lead-agent injects its marker block ABOVE the fallthrough
below, the gate handles enforcement for the lieutenant tab via the
LEAD_AGENT=1 env var dispatch. The fallthrough here is reached only
when LEAD_AGENT is unset (i.e. main Claude Code session, not the
lieutenant tab) and it allows the tool call.

Why this is correct deny-by-default:
  - Inside the lieutenant tab (LEAD_AGENT=1), the injected marker block
    delegates to `lib/lead-pretool-hook.py` which fail-closes on every
    error and enforces the positive allowlist + path guard. The stub
    fallthrough is never reached there.
  - In the main CC session (LEAD_AGENT unset), no lead-agent rules
    apply because no lead-agent context exists. This stub allows tool
    calls just as if no host hook were present at all.
  - If you want defense-in-depth in your main CC session too (e.g.
    blocking secret-leaking commands like `railway variables`), replace
    this file with a richer PreToolUse hook. lead-agent will continue
    to chain into whatever you put here as long as it is valid Python
    with the PreToolUse-shaped contract:
        reads JSON tool-input from stdin, exit 0 = allow, exit 2 = deny
        (with reason on stderr).

This file is intentionally NOT pinned in `lib/lead-extension.sha256`.
Users are expected to replace or extend it. The lead-agent gate's
integrity comes from its own pin chain, the trust-anchor cascade, and
the marker block inserted into this file by install-hook.ps1.

To upgrade later:
  - Replace the body of this file with your own hardening, OR
  - Run `install.ps1 -Uninstall` to remove the marker block, drop in
    your own `windows_shell_safety.py`, and re-run `install.ps1`.
"""
from __future__ import annotations

import sys


def main() -> None:
    """Drain stdin (so the producer pipe does not block) and allow."""
    try:
        _ = sys.stdin.read()
    except Exception:
        pass
    sys.exit(0)


if __name__ == "__main__":
    main()
