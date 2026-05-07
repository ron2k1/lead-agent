[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]   $CallerCwd,
    [string]   $CallerSessionId,
    [string]   $SubdirHint,
    [ValidateSet('OVERWATCH', 'ADVISOR', 'BUILDER', 'TOOLSMITH')]
    [string]   $Mode = 'ADVISOR',
    [switch]   $Standalone,
    [switch]   $Force,
    [switch]   $Dry
)

# lead-agent launch entrypoint (v0.9-final scaffold).
# Full preflight + manifest contract: DESIGN.md sections 3.6, 3.9, 4.1.3.
# This scaffold implements the structural launch path; deep-logic phases are
# marked with explicit DESIGN.md section pointers for the v1.x implementation
# pass. Every gate that is not yet fully implemented fails CLOSED with exit 2.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$LibDir     = Join-Path $ScriptRoot 'lib'
$LockPath   = Join-Path $env:LOCALAPPDATA 'Temp\lead-agent.lock'
# v1.0: install-hook.ps1 chains the gate INTO the existing windows_shell_safety.py
# (rather than dropping a standalone hook file). Preflight verifies the marker
# block is present in the chained file.
$ChainedHookPath = Join-Path $env:USERPROFILE '.claude\hooks\windows_shell_safety.py'
$ChainedMarker   = '# BEGIN lead-agent-extension'

function Write-Refusal($msg, $hint = '') {
    [Console]::Error.WriteLine(("lead-agent refuses: {0}{1}" -f $msg, ($(if ($hint) { "`n  hint: $hint" } else { '' }))))
    exit 2
}

# 1. Self-target refusal (W-09 in DESIGN.md s4.1.4): a lead spawning a lead.
if ($env:LEAD_AGENT_MODE) {
    Write-Refusal "lead-agent cannot spawn itself" "run /lead-agent from main CC on Screen 2."
}

# 2. Lockfile (C4, C4 v0.6 in DESIGN.md s4.1.3.1).
# CreateNew + FileShare.None gives atomic acquisition.
try {
    $lockStream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
} catch [System.IO.IOException] {
    # F-01 (DESIGN.md s4.1.3.1 v1.1): orphan-lock stale detection. A live PID
    # whose Win32_Process.CreationDate matches the lock's startTime (within 2s
    # of WMI clock skew) proves the lock is owned. PID dead OR CreationDate
    # mismatch proves stale -- reclaim under -Force only. Stale reclaims log
    # to logs/lock-recovery.log for forensics.
    if (-not $Force) {
        Write-Refusal "lead-agent already running" "close the prior tab; lockfile at $LockPath. Retry with -Force only after confirming no lead-agent process is running."
    }
    $stale       = $false
    $reason      = ''
    $rawLock     = ''
    $lockedPid   = 0
    $lockedStart = [datetime]::MinValue
    try {
        $rawLock     = Get-Content -LiteralPath $LockPath -Raw -ErrorAction Stop
        $lockJson    = $rawLock | ConvertFrom-Json -ErrorAction Stop
        $lockedPid   = [int]$lockJson.pid
        $lockedStart = [datetime]::Parse($lockJson.startTime).ToUniversalTime()
    } catch {
        $stale  = $true
        $reason = "corrupt or unparsable lockfile: $($_.Exception.Message)"
    }
    if (-not $stale) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$lockedPid" -ErrorAction SilentlyContinue
        if (-not $proc) {
            $stale  = $true
            $reason = "PID $lockedPid is dead"
        } else {
            $procStart = ([datetime]$proc.CreationDate).ToUniversalTime()
            $skew      = [Math]::Abs(($procStart - $lockedStart).TotalSeconds)
            if ($skew -gt 2) {
                $stale  = $true
                $reason = "PID $lockedPid reused (CreationDate skew $([int]$skew)s > 2s slack)"
            }
        }
    }
    if (-not $stale) {
        Write-Refusal "lead-agent is genuinely running (PID $lockedPid, started $($lockedStart.ToString('o')))" "close the prior tab; -Force will not override a live lock."
    }
    $logDir = Join-Path $ScriptRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $rawForLog = ($rawLock -replace '[\r\n]+', ' ')
    $logLine   = "{0}  RECLAIM  {1}  raw={2}" -f (Get-Date).ToUniversalTime().ToString('o'), $reason, $rawForLog
    Add-Content -LiteralPath (Join-Path $logDir 'lock-recovery.log') -Value $logLine -Encoding UTF8
    try {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction Stop
        $lockStream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    } catch {
        Write-Refusal "stale lockfile reclaim failed: $($_.Exception.Message)" "another launcher may have raced; retry once."
    }
    Write-Host "lead-agent reclaimed stale lockfile ($reason)" -ForegroundColor Yellow
}
$lockContent = @{ pid = $PID; startTime = (Get-Date).ToString('o'); ppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId } | ConvertTo-Json -Compress
$lockBytes   = [System.Text.Encoding]::UTF8.GetBytes($lockContent)
$lockStream.Write($lockBytes, 0, $lockBytes.Length)
$lockStream.Flush()
$lockStream.Dispose()

# Lock is intentionally held for the LIFE of the lead tab. The runner
# releases it on exit (DESIGN.md s4.1.3.1). v0.9-final keeps lock
# semantics simple; do NOT release the lock at the end of this script --
# that would defeat the single-lead invariant the .lock file enforces.
# 3. Preflight (DESIGN.md s4.1.3.2). Trust roots per V0.6+CM4.
# TODO v1.x: full enumerate-all-5-scopes ExecutionPolicy check; trust-root
# prefix verification on every persisted absolute path; wt --version regex
# parse; gh auth + repo-scope; hook-installer integrity verify.
$wt     = Get-Command -CommandType Application 'wt.exe'     -ErrorAction Stop
$claude = Get-Command -CommandType Application 'claude.cmd' -ErrorAction SilentlyContinue
if (-not $claude) { $claude = Get-Command -CommandType Application 'claude' -ErrorAction Stop }
$ps     = Get-Command -CommandType Application 'pwsh.exe'   -ErrorAction SilentlyContinue
if (-not $ps)     { $ps     = Get-Command -CommandType Application 'powershell.exe' -ErrorAction Stop }

if (-not (Test-Path -LiteralPath $ChainedHookPath)) {
    Write-Refusal "chained hook host not present at $ChainedHookPath" "windows_shell_safety.py must be installed (it is the system PreToolUse hook the lead-agent extension chains into)."
}
$markerFound = Select-String -LiteralPath $ChainedHookPath -Pattern ([regex]::Escape($ChainedMarker)) -Quiet -ErrorAction SilentlyContinue
if (-not $markerFound) {
    $installCmd = "powershell.exe -ExecutionPolicy Bypass -File '$(Join-Path $LibDir 'install-hook.ps1')'"
    Write-Refusal "lead-agent gate not chained into $ChainedHookPath" "run: $installCmd"
}

# 4. cwd validation (DESIGN.md s4.1.3.3).
# TODO v1.x: full junction/symlink component-walk per W-08 v0.6;
# canonicalize via lib/canonicalize-path.py.
if (-not (Test-Path -LiteralPath $CallerCwd -PathType Container)) {
    Write-Refusal "CallerCwd does not exist or is not a directory: $CallerCwd"
}
$reject = $CallerCwd -match '^(\\\\\?\\|\\\\\.\\|\\\\[^\\]+\\)' -or
          $CallerCwd -match '^/mnt/' -or
          $CallerCwd -match '^\\\\wsl\$\\'
if ($reject) { Write-Refusal "CallerCwd is UNC/WSL/reparse path; lead refuses" "use a plain local-disk path." }

# 5. Resolve worktree root + watch-target (DESIGN.md s4.1.3.4).
# TODO v1.x: monorepo-root detection + SubdirHint disambiguation
# + lead-self-target exclusion in JSONL discovery.
$worktreeRoot = $CallerCwd
if ($SubdirHint -and (Test-Path -LiteralPath (Join-Path $CallerCwd $SubdirHint) -PathType Container)) {
    $worktreeRoot = Join-Path $CallerCwd $SubdirHint
}

# 6. Manifest construction (DESIGN.md s3.6, s3.9; V8-3 fingerprint).
# TODO v1.x: precompute manifestFingerprint via [ordered]@{} +
# ConvertTo-Json -Compress BEFORE inserting ackHmacKey; populate
# manifestMtime + manifestFileId per V8-8 schema/contract grounding;
# apply [Array]::Clear($randomBytes,0,32) post-write per V8-10;
# Set-PSDebug -Trace 0 BEFORE manifest write; refuse if Start-Transcript
# is active.
$diffPrefix = 'PENDING-V1X'   # placeholder - real value comes from secret-scan manifest
$manifestPath = Join-Path $env:LOCALAPPDATA "Temp\lead-launch-manifest-$diffPrefix-$([System.Guid]::NewGuid().ToString('N')).json"
$manifest = [ordered]@{
    version            = '0.9-final'
    mode               = $Mode
    callerCwd          = $CallerCwd
    callerSessionId    = $CallerSessionId
    subdirHint         = $SubdirHint
    worktreeRoot       = $worktreeRoot
    standalone         = [bool]$Standalone
    wtPath             = $wt.Path
    claudePath         = $claude.Path
    psPath             = $ps.Path
    launchedAt         = (Get-Date).ToUniversalTime().ToString('o')
    launchedBy         = $env:USERNAME
    launcherPid        = $PID
    # Fields below are populated by v1.x implementation passes:
    manifestFingerprint = '<TODO V8-3 v1.x: precompute-then-insert>'
    ackHmacKey          = '<TODO V8-4 v1.x: per-launch random 32 bytes; same-user-read residual>'
    manifestMtime       = 0
    manifestFileId      = ''
    createdByImageSha256 = '<TODO v1.x: hash launch.ps1 self-bytes>'
}
$manifestJson = $manifest | ConvertTo-Json -Compress -Depth 10
Set-Content -LiteralPath $manifestPath -Value $manifestJson -Encoding UTF8 -NoNewline

# 7. Spawn the WT tab on Screen 2 (DESIGN.md s4.1.3.5; W-12 --pos).
# TODO v1.x: detect monitor topology and pin to Screen 2 origin;
# currently lets WT pick its default tab placement.
$runnerPath = Join-Path $ScriptRoot 'runner.ps1'
$tabTitle   = "lead [$Mode]"
$wtArgs = @(
    'new-tab',
    '--title', $tabTitle,
    '--',
    $ps.Path, '-NoExit', '-NoProfile',
    '-File', $runnerPath,
    '-ManifestPath', $manifestPath
)
if ($Dry) {
    Write-Host "lead-agent DRY RUN: would have spawned wt tab" -ForegroundColor Cyan
    Write-Host "  Mode:      $Mode" -ForegroundColor Cyan
    Write-Host "  Manifest:  $manifestPath" -ForegroundColor Cyan
    Write-Host "  Worktree:  $worktreeRoot" -ForegroundColor Cyan
    Write-Host "  wt args:   $($wtArgs -join ' ')" -ForegroundColor Cyan
    Write-Host "lead-agent dry run OK" -ForegroundColor Green
    return
}

& $wt.Path @wtArgs
if ($LASTEXITCODE -ne 0) {
    Write-Refusal "wt.exe failed to spawn the lead tab (exit $LASTEXITCODE)" "verify Windows Terminal >= 1.18 is installed."
}

Write-Host "lead-agent spawned: tab '$tabTitle', mode=$Mode, manifest=$manifestPath" -ForegroundColor Green
