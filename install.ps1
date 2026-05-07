[CmdletBinding()]
param(
    [switch] $Verify,
    [switch] $Force
)

# install.ps1 - lead-agent bootstrap installer (v1.0).
#
# Orchestrates:
#   1. Preflight sanity checks (OS, PS, Python, wt.exe, claude, host hook).
#   2. Trust-anchor stamping: rewrites _ANCHOR_SHA in lib/lead-pretool-hook.py
#      to match the SHA256 of THIS clone's lib/install-hook.ps1 BEFORE the
#      pin manifest is written. Critical ordering: install-hook.ps1 pins the
#      hook file's bytes; if the constant inside hook.py is stale, the
#      running gate fail-closes on every call because the anchor file does
#      not match the constant.
#   3. Delegates to lib/install-hook.ps1 for the actual hook chain + manifest
#      pin + trust-anchor file write.
#   4. With -Verify: probes the installed gate end-to-end and reports state.
#
# Idempotent: safe to re-run on an already-installed skill. Re-stamps the
# anchor only if it drifted, re-pins the manifest, exits clean.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptRoot   = $PSScriptRoot
$LibDir       = Join-Path $ScriptRoot 'lib'
$InstallHook  = Join-Path $LibDir     'install-hook.ps1'
$HookPy       = Join-Path $LibDir     'lead-pretool-hook.py'
$HostHookPath = Join-Path $env:USERPROFILE '.claude\hooks\windows_shell_safety.py'
$AnchorPath   = Join-Path $env:USERPROFILE '.claude\lead-agent-trust-anchor.txt'

function Write-Step($msg) { Write-Host "  [.] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Write-Bad($msg)  { Write-Host "  [X] $msg" -ForegroundColor Red }

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower()
    } finally { $sha.Dispose() }
}

function Test-Prereq {
    Write-Host ''
    Write-Host '== Preflight ==' -ForegroundColor Cyan

    $checks = @(
        @{ Name = 'Windows OS';         Test = { $env:OS -eq 'Windows_NT' };       Hint = 'lead-agent is Windows-only in v1.x.' }
        @{ Name = 'PowerShell >= 5.1';  Test = { $PSVersionTable.PSVersion.Major -ge 5 -and $PSVersionTable.PSVersion.Minor -ge 1 -or $PSVersionTable.PSVersion.Major -ge 6 }; Hint = 'install Windows PowerShell 5.1 (built into Win10/11) or pwsh 7+.' }
        @{ Name = 'python on PATH';     Test = { [bool](Get-Command python -ErrorAction SilentlyContinue) }; Hint = 'install Python 3.10+ from python.org or winget install Python.Python.3.13.' }
        @{ Name = 'wt.exe present';     Test = { [bool](Get-Command wt.exe -ErrorAction SilentlyContinue) }; Hint = 'install Windows Terminal from Microsoft Store (>= 1.18).' }
        @{ Name = 'claude CLI present'; Test = { [bool]((Get-Command claude.cmd -ErrorAction SilentlyContinue) -or (Get-Command claude -ErrorAction SilentlyContinue)) }; Hint = 'install Claude Code CLI (npm i -g @anthropic-ai/claude-code).' }
        @{ Name = 'lib/install-hook.ps1';   Test = { Test-Path -LiteralPath $InstallHook -PathType Leaf };  Hint = "expected at $InstallHook" }
        @{ Name = 'lib/lead-pretool-hook.py'; Test = { Test-Path -LiteralPath $HookPy -PathType Leaf };    Hint = "expected at $HookPy" }
        @{ Name = 'host hook present';   Test = { Test-Path -LiteralPath $HostHookPath -PathType Leaf };   Hint = "windows_shell_safety.py is the chained host. Install Anthropic's Windows safety baseline at $HostHookPath, or pass -HookFileOverride to lib/install-hook.ps1." }
    )

    $allOk = $true
    foreach ($c in $checks) {
        $ok = & $c.Test
        if ($ok) {
            Write-Ok $c.Name
        } else {
            Write-Bad $c.Name
            Write-Host "      hint: $($c.Hint)" -ForegroundColor DarkGray
            $allOk = $false
        }
    }

    if (-not $allOk) {
        Write-Host ''
        if ($Force) {
            Write-Warn2 'preflight failed but -Force was passed; continuing anyway.'
        } else {
            throw 'preflight failed. Fix the [X] items above (or pass -Force to bypass).'
        }
    }

    # Soft warning: skill should be under ~/.claude/skills/ for CC to discover it.
    $expectedRoot = Join-Path $env:USERPROFILE '.claude\skills\lead-agent'
    $resolvedRoot = (Resolve-Path -LiteralPath $ScriptRoot).Path
    if ($resolvedRoot -ne $expectedRoot) {
        Write-Warn2 "skill is at $resolvedRoot but Claude Code auto-discovers skills only under $expectedRoot."
        Write-Warn2 "the install will succeed, but /lead-agent will not appear in CC until you move or symlink the skill into the expected directory."
    }
}

function Update-AnchorConstant {
    Write-Host ''
    Write-Host '== Trust-anchor stamp ==' -ForegroundColor Cyan

    $localSha = Get-FileSha256 -Path $InstallHook
    Write-Step "local install-hook.ps1 SHA256: $localSha"

    $bytes = [System.IO.File]::ReadAllBytes($HookPy)
    $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
    $rx    = [regex]'_ANCHOR_SHA\s*=\s*"([0-9a-f]{64})"'
    $match = $rx.Match($text)
    if (-not $match.Success) {
        throw "could not locate _ANCHOR_SHA constant in $HookPy. Has the hook been hand-edited?"
    }
    $currentSha = $match.Groups[1].Value

    if ($currentSha -eq $localSha) {
        Write-Ok '_ANCHOR_SHA already matches local install-hook.ps1 (no stamp needed).'
        return
    }

    Write-Step "stamping: $currentSha -> $localSha"
    $newText  = $rx.Replace($text, "_ANCHOR_SHA = `"$localSha`"", 1)
    $newBytes = [System.Text.Encoding]::UTF8.GetBytes($newText)
    [System.IO.File]::WriteAllBytes($HookPy, $newBytes)
    Write-Ok 'stamped lead-pretool-hook.py with local install-hook.ps1 SHA.'
    Write-Step 'pin manifest will be regenerated on the next step (install-hook.ps1).'
}

function Invoke-InstallHook {
    Write-Host ''
    Write-Host '== Hook chain + pin manifest ==' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallHook
    if ($LASTEXITCODE -ne 0) {
        throw "lib/install-hook.ps1 exited with $LASTEXITCODE; see output above."
    }
}

function Test-Verify {
    Write-Host ''
    Write-Host '== Post-install verification ==' -ForegroundColor Cyan

    # 1. Marker block present in host hook?
    if (-not (Test-Path -LiteralPath $HostHookPath -PathType Leaf)) {
        Write-Bad "host hook missing at $HostHookPath"
        return $false
    }
    $hostHookText = [System.IO.File]::ReadAllText($HostHookPath)
    if ($hostHookText -notmatch '# BEGIN lead-agent-extension v') {
        Write-Bad 'lead-agent-extension marker NOT found in host hook.'
        return $false
    }
    Write-Ok 'lead-agent-extension marker present in host hook.'

    # 2. Trust anchor file present + matches install-hook.ps1?
    if (-not (Test-Path -LiteralPath $AnchorPath -PathType Leaf)) {
        Write-Bad "trust anchor missing at $AnchorPath"
        return $false
    }
    $anchorContent = (Get-Content -LiteralPath $AnchorPath -Raw).Trim()
    $localSha      = Get-FileSha256 -Path $InstallHook
    if ($anchorContent -ne $localSha) {
        Write-Bad "trust anchor SHA mismatch: file=$anchorContent local=$localSha"
        return $false
    }
    Write-Ok "trust anchor matches local install-hook.ps1 ($localSha)."

    # 3. _ANCHOR_SHA constant in hook.py matches?
    $hookText = [System.IO.File]::ReadAllText($HookPy)
    $rx       = [regex]'_ANCHOR_SHA\s*=\s*"([0-9a-f]{64})"'
    $match    = $rx.Match($hookText)
    if (-not $match.Success -or $match.Groups[1].Value -ne $localSha) {
        Write-Bad "_ANCHOR_SHA constant mismatch in lead-pretool-hook.py."
        return $false
    }
    Write-Ok '_ANCHOR_SHA constant matches install-hook.ps1.'

    # 4. Pin manifest exists + self-hash valid?
    $extShaPath = Join-Path $LibDir 'lead-extension.sha256'
    if (-not (Test-Path -LiteralPath $extShaPath -PathType Leaf)) {
        Write-Bad "pin manifest missing at $extShaPath"
        return $false
    }
    $manifestText  = [System.IO.File]::ReadAllText($extShaPath)
    $manifestLines = $manifestText -split "`n"
    $selfHashLine  = $manifestLines | Where-Object { $_ -match '^sha256:[0-9a-f]{64}$' } | Select-Object -Last 1
    if (-not $selfHashLine) {
        Write-Bad 'pin manifest has no sha256: self-hash line.'
        return $false
    }
    $claimedSelfHash = ($selfHashLine -split ':')[1]
    $bodyEnd         = $manifestText.LastIndexOf("sha256:")
    $bodyText        = $manifestText.Substring(0, $bodyEnd)
    $bodyBytes       = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
    $sha             = [System.Security.Cryptography.SHA256]::Create()
    try {
        $computed = ([System.BitConverter]::ToString($sha.ComputeHash($bodyBytes)) -replace '-', '').ToLower()
    } finally { $sha.Dispose() }
    if ($computed -ne $claimedSelfHash) {
        Write-Bad "pin manifest self-hash mismatch: claimed=$claimedSelfHash computed=$computed"
        return $false
    }
    Write-Ok 'pin manifest self-hash valid.'

    # 5. launch.ps1 dry-run.
    Write-Step 'invoking launch.ps1 -Dry to confirm preflight wiring...'
    $launchPath = Join-Path $ScriptRoot 'launch.ps1'
    $tmpCwd     = $env:USERPROFILE
    $output     = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launchPath -CallerCwd $tmpCwd -Mode ADVISOR -Standalone -Dry 2>&1
    $exitCode   = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Bad "launch.ps1 -Dry failed with exit $exitCode"
        $output | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        return $false
    }
    Write-Ok 'launch.ps1 -Dry preflight clean.'

    # 6. Drift detector (F-05): warn when shipped features advertised in
    # docs are still v1.x stubs in code. Non-fatal -- the gate is ACTIVE;
    # we just want adopters to learn about gaps at install time, not when
    # they hit them. The regex disappears once v1.1 implements -Force,
    # so the warning auto-silences.
    $launchText = [System.IO.File]::ReadAllText($launchPath)
    $driftWarnings = @()
    if ($launchText -match '(?s)catch \[System\.IO\.IOException\].*?-Force.*?not yet implemented') {
        $driftWarnings += '-Force flag for orphan lockfiles is a v1.x stub (launch.ps1 still refuses).'
        $driftWarnings += '   Manual recovery: Remove-Item -LiteralPath "$env:LOCALAPPDATA\Temp\lead-agent.lock" -Force'
        $driftWarnings += '   See README.md ## Recovery; auto-recovery lands in v1.1 (DESIGN.md s15.10 F-01).'
    }
    if ($driftWarnings.Count -gt 0) {
        Write-Host ''
        Write-Warn2 'documentation drift detected (non-fatal):'
        foreach ($w in $driftWarnings) { Write-Host "      $w" -ForegroundColor DarkYellow }
    } else {
        Write-Ok 'no documentation drift detected.'
    }

    Write-Host ''
    Write-Host 'lead-agent gate ACTIVE' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor Cyan
    Write-Host '    - Restart any open Claude Code session so the hook is picked up.'
    Write-Host '    - Type /lead-agent in main CC to spawn a lieutenant.'
    Write-Host '    - Or double-click launch.cmd in this skill directory.'
    Write-Host ''
    return $true
}

# === Dispatch ==========================================================
Write-Host ''
Write-Host 'lead-agent install.ps1' -ForegroundColor Cyan
Write-Host "  SkillRoot:  $ScriptRoot"
Write-Host "  HostHook:   $HostHookPath"
Write-Host "  Anchor:     $AnchorPath"

if ($Verify) {
    $ok = Test-Verify
    if ($ok) { exit 0 } else { exit 2 }
}

Test-Prereq
Update-AnchorConstant
Invoke-InstallHook

Write-Host ''
Write-Host 'install complete' -ForegroundColor Green
Write-Host '  Run with -Verify to confirm the gate is wired end-to-end:' -ForegroundColor Cyan
Write-Host "    & '$($MyInvocation.MyCommand.Path)' -Verify" -ForegroundColor White
Write-Host ''
exit 0
