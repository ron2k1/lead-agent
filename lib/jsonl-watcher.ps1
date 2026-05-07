[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $WatchTarget
)

# jsonl-watcher.ps1 (v0.9-final fail-closed stub).
# Full contract: DESIGN.md s4.1 (OVERWATCH mode) + s5 (brake list).
#
# v1.x implementation contract:
#   - Discover sibling JSONL transcripts under ~/.claude/projects/<encoded-cwd>/
#     with monorepo-root detection + SubdirHint disambiguation.
#   - Skip own session JSONL (lead-self-target exclusion per W-09).
#   - Tail each sibling transcript with a tail-only watcher; emit one line
#     per JSONL event to stdout in a stable shape so the lead can ingest it
#     as untrusted data (NEVER parse imperatives from inside transcripts).
#   - On brake/break-list trigger (DESIGN.md s5): write a brake file under
#     ~/.claude/lead-state/brakes/<session-id>.brake with the reason; brake
#     files are the lead's only write surface in OVERWATCH mode (path-guard
#     enforces this: the worktreeRoot in OVERWATCH points at the brake dir
#     rather than a project tree).
#   - On EOF / file rotation: re-open and resume from new file.
#
# v0.9-final stub: refuse with exit 2.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:LEAD_AGENT -ne '1') {
    Write-Error "jsonl-watcher.ps1: not running in a lead-mode session (LEAD_AGENT != 1)"
    exit 2
}
if ($env:LEAD_AGENT_MODE -ne 'OVERWATCH') {
    Write-Error "jsonl-watcher.ps1: only valid in OVERWATCH mode (got LEAD_AGENT_MODE=$env:LEAD_AGENT_MODE)"
    exit 2
}

Write-Host "jsonl-watcher.ps1 v0.9-final: fail-closed stub" -ForegroundColor Yellow
Write-Host "  This stub refuses to tail until the v1.x implementation lands." -ForegroundColor Yellow
Write-Host "  Full contract: DESIGN.md s4.1 + s5 brake-list semantics." -ForegroundColor Yellow

exit 2
