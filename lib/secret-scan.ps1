[CmdletBinding()]
param()

# secret-scan.ps1 (v0.9-final fail-closed stub).
# Full contract: DESIGN.md s6 + s7.
#
# v1.x implementation contract:
#   - Read git diff --staged of current worktree.
#   - HALT before hashing if `wc -c` of diff > 10 MB (V6-M2 v0.8).
#   - Run regex pin-set (V7-9 v0.8): JWT IQo collision rule, AWS STS FwoG,
#     postgres://user:pass@host, mongodb://user:pass@host, GH PAT, OpenAI key,
#     Anthropic key, Stripe live, GCP service-account JSON shape.
#   - Compute staged-diff-sha256 (sha256 of `git diff --staged --no-color
#     --no-textconv` bytes, after canonicalizing line endings to LF).
#   - Write scan-pass-manifest with timestamp + branch + worktreePath +
#     upstreamRev + diffSha + diffByteCount + scanRegexVersion to
#     ~/.claude/lead-state/scan-pass/<sha-prefix>.json.
#   - Manifest TTL: 5 minutes; rules with stale or missing manifest are
#     denied at git-push-feature preCheck (DESIGN.md s12.2).
#   - HMAC-sign manifest with LEAD_AGENT_ACK_HMAC_KEY (V7-4 v0.8) so peers
#     cannot pre-plant a forged manifest.
#
# v0.9-final stub: refuse with exit 2 + log a clear pointer to DESIGN.md s6
# for v1.x implementation.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:LEAD_AGENT -ne '1') {
    Write-Error "secret-scan.ps1: not running in a lead-mode session (LEAD_AGENT != 1)"
    exit 2
}

Write-Host "secret-scan.ps1 v0.9-final: fail-closed stub" -ForegroundColor Yellow
Write-Host "  This stub refuses every scan request until the v1.x implementation lands." -ForegroundColor Yellow
Write-Host "  Full contract: DESIGN.md s6 (regex pin-set) + s7 (manifest format) + s12.2 git-push-feature preCheck." -ForegroundColor Yellow
Write-Host "  Until then, every git push -u origin lead/* is denied by the hook because the scan-pass" -ForegroundColor Yellow
Write-Host "  manifest cannot be produced. This is the intended fail-closed posture for v0.9-final." -ForegroundColor Yellow

exit 2
