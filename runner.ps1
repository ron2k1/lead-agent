[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ManifestPath,
    [switch] $Dry
)

# lead-agent runner (v0.9-final scaffold).
# Runs INSIDE the wt tab; reads the launcher manifest, scrubs env, sets
# lead-mode env vars, calls `claude` via the call-operator splat.
# Full ACK + HMAC contract: DESIGN.md sections 3.6, 3.9.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Resolve skill-root + lib-dir BEFORE the env scrub so we keep the values in
# PowerShell variables (PS variables survive the scrub; $env:* does not).
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$LibDir     = Join-Path $ScriptRoot 'lib'

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    [Console]::Error.WriteLine("lead-agent runner: manifest not found at $ManifestPath")
    exit 2
}

# F-02 (DESIGN.md s4.1.3.1 v1.1): runner takes ownership of the lockfile that
# the launcher created, then arms three release mechanisms so the lock is
# always cleaned up regardless of how this tab dies.
#   1. graceful exit  -> finally{} (existing, lines below)
#   2. Ctrl+C / engine shutdown -> Register-EngineEvent PowerShell.Exiting
#   3. WT X-button / taskkill /f / parent-kill -> P/Invoke SetConsoleCtrlHandler
# Layers 1+2 are idempotent with layer 3; whichever fires first wins. The
# P/Invoke layer is mandatory: PowerShell.Exiting does NOT fire on Windows
# CTRL_CLOSE_EVENT because the OS terminates the host before the engine
# reaches managed shutdown.
$LockPath        = Join-Path $env:LOCALAPPDATA 'Temp\lead-agent.lock'
$runnerProc      = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
$runnerStartIso  = ([datetime]$runnerProc.CreationDate).ToUniversalTime().ToString('o')
$runnerPpid      = $runnerProc.ParentProcessId
$lockContent     = @{ pid = $PID; startTime = $runnerStartIso; ppid = $runnerPpid; role = 'runner' } | ConvertTo-Json -Compress
Set-Content -LiteralPath $LockPath -Value $lockContent -Encoding UTF8 -NoNewline -Force

# Layer 3: P/Invoke console-control handler. The static delegate field keeps
# the GC from collecting the unmanaged callback pointer mid-tab-life.
if (-not ([System.Management.Automation.PSTypeName]'LeadAgentLockReleaser').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class LeadAgentLockReleaser {
    public delegate bool ConsoleCtrlDelegate(uint ctrlType);
    [DllImport("kernel32.dll")]
    public static extern bool SetConsoleCtrlHandler(ConsoleCtrlDelegate handler, bool add);
    public static string LockPath = "";
    public static ConsoleCtrlDelegate Handler;
    public static bool OnCtrl(uint ctrlType) {
        try {
            if (!string.IsNullOrEmpty(LockPath) && File.Exists(LockPath)) {
                File.Delete(LockPath);
            }
        } catch {}
        return false;  // let the OS continue normal shutdown
    }
    public static void Arm(string path) {
        LockPath = path;
        Handler  = new ConsoleCtrlDelegate(OnCtrl);
        SetConsoleCtrlHandler(Handler, true);
    }
}
"@
}
[LeadAgentLockReleaser]::Arm($LockPath)

# Layer 2: PowerShell.Exiting -- the action runs in its own scope, so we
# stash the path in a global so the scriptblock can reach it.
$global:LeadAgentLockPath = $LockPath
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    try {
        if ($global:LeadAgentLockPath) {
            Remove-Item -LiteralPath $global:LeadAgentLockPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# 1. Read manifest (DESIGN.md s3.9 launcher-runner handshake).
# TODO v1.x: verify manifestFingerprint (V8-3) + ackHmacKey (V8-4) +
# manifestMtime/manifestFileId stability (V8-8) + createdByImageSha256
# matches the running launch.ps1 PID-tree ancestor. Refuse if any check
# fails. v0.9-final reads structurally only.
try {
    $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
    $manifest = $raw | ConvertFrom-Json
} catch {
    [Console]::Error.WriteLine("lead-agent runner: manifest unreadable: $_")
    exit 2
}

if ($manifest.version -ne '0.9-final') {
    [Console]::Error.WriteLine(("lead-agent runner: unexpected manifest version '{0}'" -f $manifest.version))
    exit 2
}

$mode = $manifest.mode
if ($mode -notin 'OVERWATCH', 'ADVISOR', 'BUILDER', 'TOOLSMITH') {
    [Console]::Error.WriteLine("lead-agent runner: invalid mode '$mode'")
    exit 2
}

# 2. Env scrub (DESIGN.md s4.1.3.6).
# Strip every env var that could leak into the lead's tool invocations.
# Keep only the minimum needed for `claude` to start.
# TODO v1.x: complete the keep-set audit per DESIGN.md s4.1.3.6 + S-09.
$keep = @(
    'SystemRoot', 'SystemDrive', 'OS', 'COMPUTERNAME', 'USERNAME', 'USERPROFILE',
    'USERDOMAIN', 'HOMEDRIVE', 'HOMEPATH', 'TEMP', 'TMP', 'LOCALAPPDATA',
    'APPDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)', 'PROGRAMW6432',
    'COMMONPROGRAMFILES', 'COMMONPROGRAMFILES(X86)', 'COMSPEC',
    'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER',
    'PROCESSOR_LEVEL', 'PROCESSOR_REVISION', 'PSModulePath', 'WINDIR',
    'PATHEXT', 'DRIVERDATA',
    # Claude itself needs these:
    'ANTHROPIC_API_KEY', 'CLAUDE_CONFIG_DIR', 'CLAUDE_PROJECT_DIR'
)
$minPath = "$env:SYSTEMROOT;$env:SYSTEMROOT\System32;$env:SYSTEMROOT\System32\WindowsPowerShell\v1.0;" +
           (Split-Path -Parent $manifest.claudePath) + ';' +
           (Split-Path -Parent $manifest.psPath)

Get-ChildItem env: | ForEach-Object {
    if ($_.Name -notin $keep) {
        Remove-Item "env:\$($_.Name)" -ErrorAction SilentlyContinue
    }
}
$env:PATH = $minPath

# 3. Lead-mode env vars (DESIGN.md s4.1.3.7).
$env:LEAD_AGENT_MODE       = $mode
$env:LEAD_AGENT_MANIFEST   = $ManifestPath
$env:LEAD_AGENT_VERSION    = '0.9-final'
$env:LEAD_AGENT_WORKTREE   = $manifest.worktreeRoot
$env:LEAD_AGENT_CALLER_CWD = $manifest.callerCwd
if ($manifest.callerSessionId) {
    $env:LEAD_AGENT_CALLER_SESSION_ID = $manifest.callerSessionId
}

# 3b. Runtime-gate env vars (DESIGN.md s12.1).
# The PreToolUse hook reads these to locate the pin manifest, allowlist,
# canonicalizer, and path-guard. Without them set, the hook fail-closes on
# every tool call (the gate refuses by default -- that is the invariant).
$env:LEAD_AGENT             = '1'
$env:LEAD_HOOK_SCHEMA       = '3'
$env:LEAD_WORKTREE_PARENT   = $manifest.worktreeRoot
$env:LEAD_ALLOWLIST         = (Join-Path $LibDir 'allowlist.json')
$env:LEAD_PATH_GUARD        = (Join-Path $LibDir 'path-guard.json')
$env:LEAD_MCP_ALLOW         = (Join-Path $LibDir 'mcp-allow.json')
$env:LEAD_NOTIFY_SHA256     = (Join-Path $LibDir 'notify-sh.sha256')
$env:LEAD_EXTENSION_SHA256  = (Join-Path $LibDir 'lead-extension.sha256')
$env:LEAD_CANONICALIZER     = (Join-Path $LibDir 'canonicalize-path.py')
$env:LEAD_TOOLS_DIR         = (Join-Path $env:USERPROFILE '.claude\tools')

# 4. Compose the claude invocation (DESIGN.md s4.1.3.8).
# Use call-operator splat to avoid PowerShell argument-mangling on long
# system prompts. The system prompt is in the skill directory; we pass it
# via --append-system-prompt with content piped in via temp file (safest
# under PS5.1 + PS7 quoting drift). $ScriptRoot was resolved at the top.
$systemPrompt = Get-Content -LiteralPath (Join-Path $ScriptRoot 'system-prompt.md') -Raw -Encoding UTF8
$tmpPrompt    = Join-Path $env:LOCALAPPDATA "Temp\lead-system-prompt-$([System.Guid]::NewGuid().ToString('N')).md"
Set-Content -LiteralPath $tmpPrompt -Value $systemPrompt -Encoding UTF8 -NoNewline

Set-Location -LiteralPath $manifest.worktreeRoot

try {
    Write-Host "lead-agent runner: mode=$mode, worktree=$($manifest.worktreeRoot)" -ForegroundColor Cyan
    Write-Host "lead-agent runner: handing control to claude. Hook is the runtime gate." -ForegroundColor Cyan

    if ($Dry) {
        Write-Host "" -ForegroundColor Cyan
        Write-Host "=== runner.ps1 -Dry: env-var verification ===" -ForegroundColor Cyan
        $expected = @(
            'LEAD_AGENT', 'LEAD_HOOK_SCHEMA', 'LEAD_AGENT_MODE',
            'LEAD_WORKTREE_PARENT', 'LEAD_ALLOWLIST', 'LEAD_PATH_GUARD',
            'LEAD_MCP_ALLOW', 'LEAD_NOTIFY_SHA256', 'LEAD_EXTENSION_SHA256',
            'LEAD_CANONICALIZER', 'LEAD_TOOLS_DIR'
        )
        foreach ($name in $expected) {
            $val = [Environment]::GetEnvironmentVariable($name)
            if ($val) { Write-Host ("  {0,-24} = {1}" -f $name, $val) -ForegroundColor Green }
            else      { Write-Host ("  {0,-24} = <UNSET>" -f $name) -ForegroundColor Red }
        }
        Write-Host "  claudePath               = $($manifest.claudePath)" -ForegroundColor Cyan
        Write-Host "  systemPromptTemp         = $tmpPrompt" -ForegroundColor Cyan
        Write-Host "lead-agent runner dry-run OK" -ForegroundColor Green
        $exit = 0
    }
    else {
        & $manifest.claudePath '--append-system-prompt' "@$tmpPrompt"
        $exit = $LASTEXITCODE
    }
} finally {
    # Cleanup temp prompt file. The launch manifest is left in place for
    # post-mortem; v1.x adds an explicit cleanup contract per s4.1.3.9.
    Remove-Item -LiteralPath $tmpPrompt -ErrorAction SilentlyContinue

    # F-02 layer 1: graceful exit lock release. Idempotent with layer 2
    # (PowerShell.Exiting) and layer 3 (SetConsoleCtrlHandler P/Invoke).
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
}

exit $exit
