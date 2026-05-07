## What this changes

<!-- One-paragraph summary. Why does this PR exist? -->

## Threat model impact

Pick exactly one:

- [ ] This PR does NOT modify any file under `lib/` or `install.ps1`.
- [ ] This PR modifies pinned files AND I have re-run `install.ps1` and
      verified `install.ps1 -Verify` returns "lead-agent gate ACTIVE" with
      all 5 probes green.
- [ ] This PR explicitly changes the threat model. I have updated DESIGN.md
      section 11 (Security Analysis) to reflect the new model.

If any pinned file is modified, the manifest in `lib/lead-extension.sha256`
MUST be re-pinned in the same PR. Otherwise the gate fails closed on next
install.

## Tests

- [ ] `install.ps1 -Verify` passes (5/5 probes).
- [ ] Manual fixture spot-checks pass (or, when v1.1 lands, the C-01..C-13
      fixture matrix is green).
- [ ] The host `windows_shell_safety.py` is restored cleanly by
      `lib/install-hook.ps1 -Uninstall`.

## ASCII policy

- [ ] Every changed file is ASCII-only. No em-dashes, no curly quotes, no
      Unicode bullets. CI's `ASCII-only` step is green.

## Atomic commits

- [ ] This PR is one logical change. If it bundles unrelated changes, I have
      noted why above.

## Related

<!-- Codex review IDs, prior PRs, DESIGN.md sections, issue numbers. -->
