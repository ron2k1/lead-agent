[CmdletBinding()]
param(
    [switch] $Repair,
    [switch] $RepinNotify,
    [switch] $Uninstall,
    [string] $HookFileOverride = ''
)

# install-hook.ps1 v1.0 (DESIGN.md s12.6 + s12.8 + B7/SE-R3/SE-R5 v0.4
# + CM2/SE-N5 v0.5 + C7/SE-N6/SE-N16 v0.6).
#
# Atomic, idempotent installer for the lead-agent PreToolUse extension.
# Chains a marker block into ~/.claude/hooks/windows_shell_safety.py that
# delegates to lib/lead-pretool-hook.py whenever LEAD_AGENT=1, and falls
# through to the existing windows_shell_safety logic otherwise.
#
# Contract:
#   1. Detect existing hook; abort if .tmp present (previous crash; -Repair).
#   2. Backup hook to .bak (overwrite any prior .bak).
#   3. Detect marker block:
#        absent          -> insert fresh block after import section.
#        same-version    -> replace block (CM2 v0.5 same-version-tampered).
#        version drift   -> replace block.
#        downgrade        -> refuse with explicit error.
#   4. Write new content to .tmp on the same NTFS volume.
#   5. [System.IO.File]::Replace(.tmp, hook, .bak2) - atomic same-volume
#      NTFS replace (Move-Item -Force is non-atomic across volumes).
#   6. Re-pin lib/notify-sh.sha256 (if notify.sh present) and
#      lib/lead-extension.sha256 (12-file pin chain + self-hash).
#   7. Write trust-anchor file ~/.claude/lead-agent-trust-anchor.txt with
#      SHA256 of install-hook.ps1; deny Everyone:Write best-effort.
#   8. Print the trust-anchor SHA so the user can paste into _ANCHOR_SHA
#      in lib/lead-pretool-hook.py.
#
# Modes:
#   (default)       install or in-place upgrade.
#   -Repair         restore from .bak, remove .tmp, re-pin SHAs.
#   -RepinNotify    re-pin notify-sh.sha256 + lead-extension.sha256 only.
#   -Uninstall      remove the marker block.
#
# Note on hook filename: spec writes "windows-shell-safety" but the live
# hook on disk is windows_shell_safety.py (underscore + .py extension).
# Pass -HookFileOverride to point at a different file (e.g., test fixtures).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# === Mutual-exclusion check ============================================
$switchCount = @($Repair.IsPresent, $RepinNotify.IsPresent, $Uninstall.IsPresent | Where-Object { $_ }).Count
if ($switchCount -gt 1) {
    throw "switches -Repair / -RepinNotify / -Uninstall are mutually exclusive."
}

# === Constants =========================================================
$EXT_VERSION  = '1.0'
$EXT_BEGIN    = "# BEGIN lead-agent-extension v$EXT_VERSION"
$EXT_END      = '# END lead-agent-extension'
$EXT_BEGIN_RE = '^\s*# BEGIN lead-agent-extension v(?<v>\d+\.\d+)\s*$'
$EXT_END_RE   = '^\s*# END lead-agent-extension\s*$'

# === Paths =============================================================
$LibRoot   = $PSScriptRoot
$SkillRoot = Split-Path -Parent $LibRoot

if ($HookFileOverride) {
    $HookPath = $HookFileOverride
} else {
    $HookPath = Join-Path $env:USERPROFILE '.claude\hooks\windows_shell_safety.py'
}
$BakPath        = "$HookPath.bak"
$Bak2Path       = "$HookPath.bak2"
$TmpPath        = "$HookPath.tmp"
$AnchorPath     = Join-Path $env:USERPROFILE '.claude\lead-agent-trust-anchor.txt'
$ExtShaPath     = Join-Path $LibRoot 'lead-extension.sha256'
$NotifySrc      = Join-Path $env:USERPROFILE '.claude\tools\notify.sh'
$NotifyShaPath  = Join-Path $LibRoot 'notify-sh.sha256'
$LeadHookPath   = Join-Path $LibRoot 'lead-pretool-hook.py'
$InstallerPath  = $PSCommandPath

# 12-file pin set (s12.8); order is significant for readability only.
# v1.1.0 walkback additions: secret-scan.ps1 + jsonl-watcher.ps1 + runner.ps1.
# Adding helpers to the pin chain closes the orphan-attack surface where an
# attacker could swap them under a running BUILDER/OVERWATCH session. The
# secret-scan + jsonl-watcher libraries shipped production-grade in v1.1.0
# (hook wiring lands in v1.1.1); runner.ps1 was added after Codex Wave 3c
# REJECT flagged it was live runtime code (3-layer lock release F-02) but
# unpinned, while CHANGELOG/README claimed it was covered. MUST stay in sync
# with lead-pretool-hook.py:_PIN_FILES and tests/run-hook-fixtures.ps1.
$PinFiles = @(
    [pscustomobject]@{ Name='allowlist.json';        Path = (Join-Path $LibRoot   'allowlist.json') }
    [pscustomobject]@{ Name='path-guard.json';       Path = (Join-Path $LibRoot   'path-guard.json') }
    [pscustomobject]@{ Name='mcp-allow.json';        Path = (Join-Path $LibRoot   'mcp-allow.json') }
    [pscustomobject]@{ Name='notify-sh.sha256';      Path = (Join-Path $LibRoot   'notify-sh.sha256') }
    [pscustomobject]@{ Name='canonicalize-path.py';  Path = (Join-Path $LibRoot   'canonicalize-path.py') }
    [pscustomobject]@{ Name='allowlist_parser.py';   Path = (Join-Path $LibRoot   'allowlist_parser.py') }
    [pscustomobject]@{ Name='lead-pretool-hook.py';  Path = (Join-Path $LibRoot   'lead-pretool-hook.py') }
    [pscustomobject]@{ Name='sanitize-jsonl.py';     Path = (Join-Path $LibRoot   'sanitize-jsonl.py') }
    [pscustomobject]@{ Name='secret-scan.ps1';       Path = (Join-Path $LibRoot   'secret-scan.ps1') }
    [pscustomobject]@{ Name='jsonl-watcher.ps1';     Path = (Join-Path $LibRoot   'jsonl-watcher.ps1') }
    [pscustomobject]@{ Name='launch.ps1';            Path = (Join-Path $SkillRoot 'launch.ps1') }
    [pscustomobject]@{ Name='runner.ps1';            Path = (Join-Path $SkillRoot 'runner.ps1') }
)

# === Helpers ===========================================================
function Get-Sha256Hex {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "missing file: $Path"
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower()
    } finally { $sha.Dispose() }
}

function Get-Sha256OfBytes {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLower()
    } finally { $sha.Dispose() }
}

function Write-LfFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Read-LfText {
    param([Parameter(Mandatory)][string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return ($text -replace "`r`n", "`n")
}

function Get-ExtensionBlockText {
    # The lead-pretool-hook.py path is hardcoded into the chained Python
    # block at install time. Backslashes are doubled because the literal
    # ends up inside a Python raw-string that we emit verbatim.
    $hookPathLiteral = $LeadHookPath
    $block = @"
$EXT_BEGIN
# Auto-inserted by ~/.claude/skills/lead-agent/lib/install-hook.ps1.
# When LEAD_AGENT=1 this block delegates the PreToolUse hook to
# lead-pretool-hook.py which fail-closes on any error. When LEAD_AGENT
# is unset, control falls through to the original windows_shell_safety
# logic. Manual edits break the integrity contract; re-run install-hook.ps1
# (or use -Uninstall to remove cleanly).
import os as _lead_os, subprocess as _lead_subprocess, sys as _lead_sys
if _lead_os.environ.get("LEAD_AGENT") == "1":
    _LEAD_HOOK = r"$hookPathLiteral"
    try:
        _proc = _lead_subprocess.run(
            [_lead_sys.executable, _LEAD_HOOK],
            stdin=_lead_sys.stdin,
            stdout=_lead_sys.stdout,
            stderr=_lead_sys.stderr,
            check=False,
        )
        _lead_sys.exit(_proc.returncode)
    except Exception:
        _lead_sys.stderr.write("denied: lead-agent gate failed to invoke\n")
        _lead_sys.exit(2)
$EXT_END
"@
    return $block
}

function Find-InsertionIndex {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $Lines
    )
    $i = 0
    if ($i -lt $Lines.Count -and $Lines[$i] -match '^#!') { $i++ }
    if ($i -lt $Lines.Count) {
        $first = $Lines[$i].TrimStart()
        $tripleQuote = $null
        if ($first.StartsWith('"""'))   { $tripleQuote = '"""' }
        elseif ($first.StartsWith("'''")) { $tripleQuote = "'''" }
        if ($tripleQuote) {
            $occurrences = ([regex]::Matches($Lines[$i], [regex]::Escape($tripleQuote))).Count
            if ($occurrences -ge 2) {
                $i++
            } else {
                $i++
                while ($i -lt $Lines.Count -and -not $Lines[$i].Contains($tripleQuote)) { $i++ }
                if ($i -lt $Lines.Count) { $i++ }
            }
        }
    }
    for (; $i -lt $Lines.Count; $i++) {
        $t = $Lines[$i].TrimStart()
        if ($t -eq '') { continue }
        if ($t.StartsWith('#')) { continue }
        if ($t -match '^(import|from)\s') { continue }
        return $i
    }
    return $Lines.Count
}

function Find-MarkerRange {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $Lines
    )
    $beginIdx = -1
    $endIdx   = -1
    $ver      = $null
    for ($k = 0; $k -lt $Lines.Count; $k++) {
        if ($beginIdx -lt 0) {
            $m = [regex]::Match($Lines[$k], $EXT_BEGIN_RE)
            if ($m.Success) {
                $beginIdx = $k
                $ver = $m.Groups['v'].Value
            }
        } elseif ($Lines[$k] -match $EXT_END_RE) {
            $endIdx = $k
            return [pscustomobject]@{ Begin = $beginIdx; End = $endIdx; Version = $ver }
        }
    }
    if ($beginIdx -ge 0 -and $endIdx -lt 0) {
        throw "lead-agent BEGIN marker found at line $($beginIdx + 1) but no matching END. Manual repair needed."
    }
    return $null
}

function Slice-Range {
    # Safe array slice that returns @() for empty ranges (avoids PS5 quirks
    # where $arr[0..-1] reverses or wraps).
    param(
        [object[]] $Source,
        [int] $Start,
        [int] $EndInclusive
    )
    if ($null -eq $Source -or $Source.Count -eq 0) { return @() }
    if ($Start -gt $EndInclusive) { return @() }
    if ($Start -lt 0) { $Start = 0 }
    if ($EndInclusive -ge $Source.Count) { $EndInclusive = $Source.Count - 1 }
    return @($Source[$Start..$EndInclusive])
}

function Write-NotifyShaIfPresent {
    if (Test-Path -LiteralPath $NotifySrc -PathType Leaf) {
        $sha = Get-Sha256Hex -Path $NotifySrc
        Write-LfFile -Path $NotifyShaPath -Text "$sha  notify.sh`n"
        Write-Host "  Pinned notify.sh -> $NotifyShaPath" -ForegroundColor Green
    } else {
        # Fresh clone: notify.sh missing means the user has not yet installed
        # the trusted notify shim. Without writing a placeholder here, the
        # subsequent Write-PinManifest call iterates $PinFiles, hits index 3
        # (notify-sh.sha256), and Get-Sha256Hex throws "missing file" at the
        # Test-Path guard above -- aborting install on every fresh clone.
        # Mirror tests/run-hook-fixtures.ps1:75-82 stub format byte-for-byte
        # (64-zero hex + 2 spaces + "notify.sh" + LF; UTF8 no-BOM via
        # Write-LfFile; 76 bytes total) so the manifest can enumerate all 12
        # pins deterministically. Re-stamps cleanly via Invoke-RepinNotify
        # once the user creates notify.sh.
        $stubSha = '0' * 64
        Write-LfFile -Path $NotifyShaPath -Text "$stubSha  notify.sh`n"
        Write-Warning "  notify.sh missing at $NotifySrc; wrote placeholder $NotifyShaPath."
        Write-Warning "  After creating notify.sh, run: install-hook.ps1 -RepinNotify"
    }
}

function Write-PinManifest {
    $rows = @(
        '# lead-extension.sha256 v3'
        '# Generated by install-hook.ps1; manually editing breaks the integrity contract.'
        '# Last line is sha256:<hex> over all preceding lines (self-hash chain).'
    )
    foreach ($entry in $PinFiles) {
        $sha = Get-Sha256Hex -Path $entry.Path
        $name = $entry.Name.PadRight(24)
        $rows += "$name $sha"
    }
    $body = ($rows -join "`n") + "`n"
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $selfHash = Get-Sha256OfBytes -Bytes $bodyBytes
    $finalText = $body + "sha256:$selfHash`n"
    Write-LfFile -Path $ExtShaPath -Text $finalText
    Write-Host "  Wrote pin manifest: $ExtShaPath" -ForegroundColor Green
    Write-Host "  Self-hash: $selfHash" -ForegroundColor DarkGray
}

function Write-TrustAnchor {
    $sha = Get-Sha256Hex -Path $InstallerPath
    Write-LfFile -Path $AnchorPath -Text "$sha`n"
    try {
        $acl = Get-Acl -LiteralPath $AnchorPath
        $denyEveryoneWrite = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'Everyone',
            'Write',
            'Deny'
        )
        $acl.AddAccessRule($denyEveryoneWrite)
        Set-Acl -LiteralPath $AnchorPath -AclObject $acl
    } catch {
        Write-Warning "  could not set Deny-Write ACL on trust anchor (non-fatal): $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  TRUST ANCHOR SHA256' -ForegroundColor Cyan
    Write-Host '  Paste this into the _ANCHOR_SHA constant in:' -ForegroundColor Cyan
    Write-Host "  $LeadHookPath" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  $sha" -ForegroundColor White
    Write-Host ''
    Write-Host "  (Anchor file: $AnchorPath)" -ForegroundColor DarkGray
    Write-Host '============================================================' -ForegroundColor Cyan
}

# === Main flows ========================================================
function Invoke-Install {
    if (-not (Test-Path -LiteralPath $HookPath -PathType Leaf)) {
        throw "windows_shell_safety hook not found at $HookPath. Cannot chain into a missing parent. Install windows_shell_safety first or pass -HookFileOverride."
    }
    if (Test-Path -LiteralPath $TmpPath) {
        throw "stale .tmp at $TmpPath -- previous install crashed. Run: install-hook.ps1 -Repair"
    }

    Copy-Item -LiteralPath $HookPath -Destination $BakPath -Force
    Write-Host "  Backed up: $BakPath" -ForegroundColor Green

    $hookText = Read-LfText -Path $HookPath
    $hookLines = @($hookText -split "`n")
    $existing = Find-MarkerRange -Lines $hookLines
    $newBlock = Get-ExtensionBlockText
    $newBlockLines = @($newBlock -split "`n")

    if ($null -ne $existing) {
        $installedVer = [version]$existing.Version
        $targetVer    = [version]$EXT_VERSION
        if ($installedVer -gt $targetVer) {
            throw "downgrade not supported: installed v$($existing.Version), target v$EXT_VERSION. Run -Uninstall first."
        }
        $before = Slice-Range -Source $hookLines -Start 0 -EndInclusive ($existing.Begin - 1)
        $after  = Slice-Range -Source $hookLines -Start ($existing.End + 1) -EndInclusive ($hookLines.Count - 1)
        $newLines = @($before) + @($newBlockLines) + @($after)
        $kind = if ($installedVer -eq $targetVer) { 'tampered/same-version' } else { 'version-drift' }
        Write-Host "  Replacing existing block (v$($existing.Version) -> v$EXT_VERSION; $kind)" -ForegroundColor Yellow
    } else {
        $insertIdx = Find-InsertionIndex -Lines $hookLines
        $before = Slice-Range -Source $hookLines -Start 0 -EndInclusive ($insertIdx - 1)
        $after  = Slice-Range -Source $hookLines -Start $insertIdx -EndInclusive ($hookLines.Count - 1)
        $newLines = @($before) + @('') + @($newBlockLines) + @('') + @($after)
        Write-Host "  Inserting fresh block at line $($insertIdx + 1)" -ForegroundColor Green
    }

    $newText = ($newLines -join "`n")
    if ($hookText.EndsWith("`n") -and -not $newText.EndsWith("`n")) {
        $newText += "`n"
    }
    Write-LfFile -Path $TmpPath -Text $newText
    Write-Host "  Wrote staged: $TmpPath" -ForegroundColor Green

    try {
        [System.IO.File]::Replace($TmpPath, $HookPath, $Bak2Path)
        Write-Host "  Atomic replace OK (.bak2 = $Bak2Path)" -ForegroundColor Green
    } catch [System.IO.IOException] {
        Remove-Item -LiteralPath $TmpPath -ErrorAction SilentlyContinue
        throw "atomic replace failed: $($_.Exception.Message). Tmp must be on the same NTFS volume as the target hook."
    }

    Write-NotifyShaIfPresent
    Write-PinManifest
    Write-TrustAnchor
}

function Invoke-Repair {
    if (Test-Path -LiteralPath $TmpPath) {
        Remove-Item -LiteralPath $TmpPath -Force
        Write-Host "  Removed stale: $TmpPath" -ForegroundColor Yellow
    }
    if (Test-Path -LiteralPath $BakPath) {
        Copy-Item -LiteralPath $BakPath -Destination $HookPath -Force
        Write-Host "  Restored hook from: $BakPath" -ForegroundColor Green
    } else {
        Write-Warning "  no .bak found at $BakPath -- nothing to restore. Re-pinning only."
    }
    Write-NotifyShaIfPresent
    Write-PinManifest
    Write-TrustAnchor
}

function Invoke-RepinNotify {
    if (-not (Test-Path -LiteralPath $NotifySrc -PathType Leaf)) {
        throw "notify.sh not found at $NotifySrc. Create it first or skip -RepinNotify."
    }
    $sha = Get-Sha256Hex -Path $NotifySrc
    Write-LfFile -Path $NotifyShaPath -Text "$sha  notify.sh`n"
    Write-Host "  Updated $NotifyShaPath -> $sha" -ForegroundColor Green
    Write-PinManifest
    Write-TrustAnchor
}

function Invoke-Uninstall {
    if (-not (Test-Path -LiteralPath $HookPath -PathType Leaf)) {
        Write-Warning "  hook file not found at $HookPath -- nothing to uninstall."
        return
    }
    $hookText = Read-LfText -Path $HookPath
    $hookLines = @($hookText -split "`n")
    $existing = Find-MarkerRange -Lines $hookLines
    if ($null -eq $existing) {
        Write-Warning "  no lead-agent-extension block found in $HookPath. Nothing to remove."
        return
    }

    $before = Slice-Range -Source $hookLines -Start 0 -EndInclusive ($existing.Begin - 1)
    $after  = Slice-Range -Source $hookLines -Start ($existing.End + 1) -EndInclusive ($hookLines.Count - 1)

    if ($before.Count -gt 0 -and $before[$before.Count - 1] -eq '') {
        $before = Slice-Range -Source $before -Start 0 -EndInclusive ($before.Count - 2)
    }
    if ($after.Count -gt 0 -and $after[0] -eq '') {
        $after = Slice-Range -Source $after -Start 1 -EndInclusive ($after.Count - 1)
    }

    Copy-Item -LiteralPath $HookPath -Destination $BakPath -Force
    if (Test-Path -LiteralPath $TmpPath) { Remove-Item -LiteralPath $TmpPath -Force }

    $newText = (@($before) + @($after) -join "`n")
    if ($hookText.EndsWith("`n") -and -not $newText.EndsWith("`n")) { $newText += "`n" }
    Write-LfFile -Path $TmpPath -Text $newText
    [System.IO.File]::Replace($TmpPath, $HookPath, $Bak2Path)
    Remove-Item -LiteralPath $BakPath -ErrorAction SilentlyContinue
    Write-Host "  Removed lead-agent-extension v$($existing.Version) from $HookPath" -ForegroundColor Green
    Write-Host "  Pin manifest left in place. To fully clean, also delete:" -ForegroundColor Yellow
    Write-Host "    $ExtShaPath" -ForegroundColor Yellow
    Write-Host "    $AnchorPath" -ForegroundColor Yellow
}

# === Dispatch ==========================================================
Write-Host "lead-agent install-hook.ps1 v$EXT_VERSION" -ForegroundColor Cyan
Write-Host "  HookPath:   $HookPath"
Write-Host "  ExtShaPath: $ExtShaPath"
Write-Host "  AnchorPath: $AnchorPath"
Write-Host ''

if ($Repair)         { Invoke-Repair }
elseif ($RepinNotify) { Invoke-RepinNotify }
elseif ($Uninstall)   { Invoke-Uninstall }
else                  { Invoke-Install }

exit 0
