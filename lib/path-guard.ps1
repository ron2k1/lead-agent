[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $TargetPath
)

# path-guard.ps1 (v0.9-final fail-closed stub).
# Full contract: DESIGN.md s12.3 (path guard).
#
# v1.x implementation contract:
#   - Resolve TargetPath via lib/canonicalize-path.py (subprocess-isolated
#     per SE-N7/SE-N15 v0.5/v0.6 contract).
#   - Load lib/path-guard.json once, cache in memory; respect schemaVersion=2.
#   - Match TargetPath against writeAllowGlobs AND must NOT match
#     writeDenyGlobs via wcmatch.glob.globmatch with GLOBSTAR | BRACE.
#   - On Edit of package.json: parse JSON, deny any add/modify of
#     writeDenyJsonScriptKeys.
#   - Print "ALLOW" + exit 0 on pass; "DENY: <reason>" + exit 2 on fail.
#
# This script is callable by the BUILDER allowlist (rule path-guard-ps1)
# so the lead can pre-flight a path itself before issuing an Edit; the hook
# still re-runs the canonicalization + glob check at PreToolUse fire time.
#
# v0.9-final stub: refuse with exit 2.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host "path-guard.ps1 v0.9-final: fail-closed stub" -ForegroundColor Yellow
Write-Host "  Path: $TargetPath" -ForegroundColor Yellow
Write-Host "  Full contract: DESIGN.md s12.3." -ForegroundColor Yellow
Write-Host "  Until v1.x lands, every path-guard request denies." -ForegroundColor Yellow

exit 2
