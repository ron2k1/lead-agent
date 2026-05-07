#!/usr/bin/env python3
# lib/sanitize-jsonl.py v1.0 (DESIGN.md s4.1 + s5 OVERWATCH placeholder).
#
# v1.x role: post-tool JSONL sanitizer for the lead's session transcript.
# Reads the lead's session JSONL (sibling of main CC's JSONL, sharing parent
# dir per s4.1.3.4), redacts secret-shaped substrings using the same pin-set
# as lib/allowlist_parser.py _SECRET_PATTERNS, and writes the redacted form
# back atomically. Runs as a sidecar invoked by lib/jsonl-watcher.ps1.
#
# v1.0 PLACEHOLDER STATUS:
#   This file is in the 9-file pin set (s12.8) so that lib/install-hook.ps1
#   can compute a stable SHA256 over the OVERWATCH path. The runtime gate
#   (lib/lead-pretool-hook.py) NEVER executes this file - it only verifies
#   the pinned hash matches on every fire. Until v1.1 wires the watcher,
#   the only contract this file must honor is byte-stability: any edit
#   forces a re-pin via `install-hook.ps1`.
#
# v1.1 contract sketch (do NOT implement now; reserved):
#   def sanitize_event(event: dict) -> dict
#   def redact_text(text: str, patterns: list[re.Pattern]) -> tuple[str, int]
#   CLI: sanitize-jsonl.py <jsonl-path> --in-place --redact-set=secret-v6

import sys


def main() -> int:
    sys.stderr.write(
        "sanitize-jsonl.py v1.0: OVERWATCH placeholder. Functionality lands in v1.1.\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
