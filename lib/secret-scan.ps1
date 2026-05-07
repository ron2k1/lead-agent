[CmdletBinding()]
param(
    [string] $UpstreamRev   = 'origin/main',
    [string] $WorktreePath  = '',
    [string] $Branch        = ''
)

# secret-scan.ps1 v1.1.0 production implementation.
# Contract: DESIGN.md s6 (regex pin-set) + s7 (manifest format)
#         + s12.2 (git-push-feature preCheck consumer).
#
# Behavior:
#   1. Diff current branch HEAD against UpstreamRev with `git diff --binary
#      --no-textconv --no-renames --no-color` under core.autocrlf=false.
#   2. HALT if diff > 10 MB (regex-DoS guard).
#   3. Run 15-pattern regex pin-set (.NET engine pinned for byte-stable
#      cross-version behavior).
#   4. Second pass: rescan any base64 blob >=200 chars after decode.
#   5. On clean pass, write HMAC-SHA256-signed manifest to
#      $env:LOCALAPPDATA\Temp\lead-scan-passed-<shaPrefix>.json with
#      current-user-only ACL.
#   6. Consumer (git-push-feature precheck) verifies HMAC + 5-minute TTL
#      against staged-diff-sha256 BEFORE allowing the push.
#
# Exit codes:  0 = pass + manifest written
#              2 = any deny / refusal / preflight failure (fail closed)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- preflight -------------------------------------------------------------
if ($env:LEAD_AGENT -ne '1') {
    Write-Error "secret-scan.ps1: not running in a lead-mode session (LEAD_AGENT != 1)"
    exit 2
}
if (-not $env:LEAD_AGENT_ACK_HMAC_KEY) {
    Write-Error "secret-scan.ps1: LEAD_AGENT_ACK_HMAC_KEY not provisioned by runner; cannot sign manifest"
    exit 2
}
# Strict ref-name validation: legitimate refs are [A-Za-z0-9_/.\-+] only.
# Refusing anything else closes the door on shell-metachar injection through
# the Arguments string we hand to ProcessStartInfo below.
if ($UpstreamRev -notmatch '^[A-Za-z0-9_/.\-+]+$') {
    Write-Error "secret-scan.ps1: invalid upstream rev format: $UpstreamRev"
    exit 2
}
if (-not $WorktreePath) {
    $WorktreePath = if ($env:LEAD_AGENT_WORKTREE) { $env:LEAD_AGENT_WORKTREE } else { (Get-Location).Path }
}
if (-not (Test-Path -LiteralPath $WorktreePath -PathType Container)) {
    Write-Error "secret-scan.ps1: worktree path does not exist: $WorktreePath"
    exit 2
}
if (-not (Test-Path -LiteralPath (Join-Path $WorktreePath '.git'))) {
    Write-Error "secret-scan.ps1: $WorktreePath is not a git worktree (.git missing)"
    exit 2
}
$gitBin = Get-Command 'git.exe' -CommandType Application -ErrorAction SilentlyContinue
if (-not $gitBin) { $gitBin = Get-Command 'git' -CommandType Application -ErrorAction Stop }

# --- helper: invoke git via ProcessStartInfo for clean stdout/stderr split -
function Invoke-LeadGit([string]$Cwd, [string]$ArgString) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $gitBin.Path
    $psi.Arguments              = $ArgString
    $psi.WorkingDirectory       = $Cwd
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $proc   = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{ Stdout = $stdout; Stderr = $stderr; ExitCode = $proc.ExitCode }
}

# --- branch resolution -----------------------------------------------------
if (-not $Branch) {
    $r = Invoke-LeadGit $WorktreePath 'rev-parse --abbrev-ref HEAD'
    if ($r.ExitCode -ne 0) {
        Write-Error "secret-scan.ps1: cannot determine branch via git rev-parse: $($r.Stderr)"
        exit 2
    }
    $Branch = $r.Stdout.Trim()
    if (-not $Branch) {
        Write-Error "secret-scan.ps1: empty branch name from rev-parse"
        exit 2
    }
}

# --- canonical diff (DESIGN.md s6) -----------------------------------------
$diffArgs = '-c core.autocrlf=false diff "{0}..HEAD" --no-textconv --no-renames --no-color --binary' -f $UpstreamRev
$d = Invoke-LeadGit $WorktreePath $diffArgs
if ($d.ExitCode -ne 0) {
    Write-Error "secret-scan.ps1: git diff failed (exit $($d.ExitCode)): $($d.Stderr)"
    exit 2
}
$diffText      = $d.Stdout
$diffBytes     = [System.Text.Encoding]::UTF8.GetBytes($diffText)
$diffByteCount = $diffBytes.Length

# --- HALT >10 MB (regex-DoS guard, V6-M2) ----------------------------------
$tenMB = 10 * 1024 * 1024
if ($diffByteCount -gt $tenMB) {
    Write-Error "secret-scan.ps1: diff is $diffByteCount bytes (>10MB); HALT to prevent regex DoS"
    exit 2
}

# --- canonical staged-diff SHA-256 -----------------------------------------
$shaCsp    = [System.Security.Cryptography.SHA256]::Create()
$diffSha   = ([BitConverter]::ToString($shaCsp.ComputeHash($diffBytes))).Replace('-','').ToLowerInvariant()
$shaPrefix = $diffSha.Substring(0, 12)
$shaCsp.Dispose()

# --- regex pin-set (DESIGN.md s6) ------------------------------------------
# Engine pin: System.Text.RegularExpressions with Compiled +
# CultureInvariant + ExplicitCapture for byte-stable behavior across PS5/7.
# We deliberately do NOT use the PowerShell `-match` operator: its case
# semantics differ from .NET defaults and would create version-skew hits.
$regexOpts = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor `
             [System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor `
             [System.Text.RegularExpressions.RegexOptions]::ExplicitCapture

$denyPatterns = @(
    @{ name = 'AWS access key (AKIA)';        pattern = 'AKIA[0-9A-Z]{16}' },
    @{ name = 'OpenAI key (sk-)';             pattern = 'sk-[A-Za-z0-9]{20,}' },
    @{ name = 'GitHub PAT (ghp_)';            pattern = 'ghp_[A-Za-z0-9]{36}' },
    @{ name = 'GitHub OAuth (gho_)';          pattern = 'gho_[A-Za-z0-9]{36}' },
    @{ name = 'GitLab PAT (glpat-)';          pattern = 'glpat-[A-Za-z0-9_-]{20}' },
    @{ name = 'Slack bot token (xoxb-)';      pattern = 'xoxb-[A-Za-z0-9-]{40,}' },
    @{ name = 'Slack user token (xoxp-)';     pattern = 'xoxp-[A-Za-z0-9-]{40,}' },
    @{ name = 'JWT';                          pattern = 'eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}' },
    @{ name = 'Postgres URL with password';   pattern = 'postgres://[^:]+:[^@]+@' },
    @{ name = 'Stripe restricted-key (live)'; pattern = 'rk_live_[a-z0-9]+' },
    @{ name = 'Bearer token';                 pattern = 'Bearer\s+[A-Za-z0-9_=-]{20,}' },
    @{ name = 'MongoDB URL with password';    pattern = 'mongodb(?:\+srv)?://[^:]+:[^@]{4,}@' },
    @{ name = 'MySQL URL with password';      pattern = 'mysql://[^:]+:[^@]{4,}@' },
    @{ name = 'Redis URL with password';      pattern = 'redis(?:s)?://[^:]+:[^@]{4,}@' },
    @{ name = 'AWS STS / OAuth long-form';    pattern = '\b(?:FQoG|FwoG|IQo[a-zA-Z0-9])[A-Za-z0-9_/+=]{200,}' }
)
$compiledRegexes = foreach ($p in $denyPatterns) {
    [pscustomobject]@{
        Name  = $p.name
        Regex = [System.Text.RegularExpressions.Regex]::new($p.pattern, $regexOpts)
    }
}

function Test-DiffForSecrets([string]$Text) {
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($r in $compiledRegexes) {
        if ($r.Regex.IsMatch($Text)) { [void]$hits.Add($r.Name) }
    }
    return ,$hits.ToArray()
}

# --- first-pass scan -------------------------------------------------------
# Refusal output: emit ONLY pattern names, never matched substrings (would
# leak the secret into the chat surface and the launcher's stderr log).
$denyHits = Test-DiffForSecrets $diffText
if ($denyHits.Count -gt 0) {
    $names = ($denyHits | Select-Object -Unique) -join ', '
    Write-Error "secret-scan.ps1 DENY: deny-pattern match: $names. Scrub diff and rerun."
    exit 2
}

# --- base64 second-pass (V7-9b) --------------------------------------------
# Find runs of base64 >=200 chars; decode-attempt; if decoded looks textual
# (>=50% printable ASCII), rescan the decoded payload with the same regex
# pin-set. Catches secrets wrapped in env-var dumps or config blobs.
$base64Re = [System.Text.RegularExpressions.Regex]::new(
    '[A-Za-z0-9+/]{200,}={0,2}',
    [System.Text.RegularExpressions.RegexOptions]::Compiled
)
foreach ($run in $base64Re.Matches($diffText)) {
    try {
        $decoded = [System.Convert]::FromBase64String($run.Value)
    } catch { continue }
    if ($decoded.Length -eq 0) { continue }
    $printable = 0
    for ($i = 0; $i -lt $decoded.Length; $i++) {
        $b = $decoded[$i]
        if (($b -ge 32 -and $b -le 126) -or $b -eq 9 -or $b -eq 10 -or $b -eq 13) { $printable++ }
    }
    if (($printable / $decoded.Length) -lt 0.5) { continue }
    $decodedText = [System.Text.Encoding]::UTF8.GetString($decoded)
    $b64Hits = Test-DiffForSecrets $decodedText
    if ($b64Hits.Count -gt 0) {
        $names = ($b64Hits | Select-Object -Unique) -join ', '
        Write-Error "secret-scan.ps1 DENY: pattern match inside base64 blob ($($run.Length) chars): $names. Scrub and rerun."
        exit 2
    }
}

# --- scanner self-hash -----------------------------------------------------
# Bound into the manifest so a tampered scanner cannot pass off old hashes.
$selfPath  = $MyInvocation.MyCommand.Path
$selfBytes = [System.IO.File]::ReadAllBytes($selfPath)
$shCsp     = [System.Security.Cryptography.SHA256]::Create()
$selfHash  = ([BitConverter]::ToString($shCsp.ComputeHash($selfBytes))).Replace('-','').ToLowerInvariant()
$shCsp.Dispose()

# --- resolve upstream-rev to commit sha ------------------------------------
$rUp = Invoke-LeadGit $WorktreePath ('rev-parse --verify "{0}^{{commit}}"' -f $UpstreamRev)
if ($rUp.ExitCode -ne 0) {
    Write-Error "secret-scan.ps1: cannot resolve upstream rev '$UpstreamRev': $($rUp.Stderr)"
    exit 2
}
$upstreamSha = $rUp.Stdout.Trim()

# --- build manifest body (DESIGN.md s6 manifest schema) --------------------
$manifestPath = Join-Path $env:LOCALAPPDATA "Temp\lead-scan-passed-$shaPrefix.json"
$tsIso        = (Get-Date).ToUniversalTime().ToString('o')
$body = [ordered]@{
    schemaVersion    = 1
    ok               = $true
    stagedDiffSha256 = $diffSha
    diffByteCount    = $diffByteCount
    upstreamRev      = $upstreamSha
    upstreamRefName  = $UpstreamRev
    branch           = $Branch
    worktreePath     = (Resolve-Path -LiteralPath $WorktreePath).Path
    scannerVersion   = '1.1.0'
    scannerSha256    = $selfHash
    scanRegexVersion = 'v1.1.0/15-pattern+base64'
    ts               = $tsIso
}
# Sign-then-store-as-string: HMAC is over THIS exact byte sequence. Consumer
# verifies HMAC over the stored string THEN parses it. This avoids
# ConvertTo-Json key-order skew between PS5.1/7 invalidating signatures.
$bodyJson = $body | ConvertTo-Json -Compress -Depth 10

# --- HMAC-SHA256 sign ------------------------------------------------------
$keyHex = $env:LEAD_AGENT_ACK_HMAC_KEY -replace '[^0-9A-Fa-f]', ''
if ($keyHex.Length -lt 64) {
    Write-Error "secret-scan.ps1: HMAC key shorter than 32 bytes (got $([int]($keyHex.Length / 2)) bytes hex)"
    exit 2
}
$keyBytes = New-Object byte[] ($keyHex.Length / 2)
for ($i = 0; $i -lt $keyBytes.Length; $i++) {
    $keyBytes[$i] = [Convert]::ToByte($keyHex.Substring($i * 2, 2), 16)
}
$hmac   = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
$msgB   = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)
$sigHex = ([BitConverter]::ToString($hmac.ComputeHash($msgB))).Replace('-','').ToLowerInvariant()
$hmac.Dispose()
# Wipe key bytes from memory promptly (V8-10 hygiene).
[Array]::Clear($keyBytes, 0, $keyBytes.Length)

$signed = [ordered]@{
    schemaVersion = 1
    bodyJson      = $bodyJson
    hmacAlg       = 'HMAC-SHA256'
    hmac          = $sigHex
}
$signedJson = $signed | ConvertTo-Json -Compress -Depth 10

# --- atomic write + ACL lockdown -------------------------------------------
$tmpManifest = "$manifestPath.tmp"
[System.IO.File]::WriteAllText($tmpManifest, $signedJson, [System.Text.UTF8Encoding]::new($false))

# Strip inheritance, grant only current user FullControl. Same-user-read
# residual is documented per V8-4 (the manifest is per-user-confidential
# but not cross-process secret-keeping; HMAC binds it to the signing key).
$acl = Get-Acl -LiteralPath $tmpManifest
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
$identity = "$env:USERDOMAIN\$env:USERNAME"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $identity, 'FullControl', 'Allow'
)
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $tmpManifest -AclObject $acl

Move-Item -LiteralPath $tmpManifest -Destination $manifestPath -Force

# --- success output --------------------------------------------------------
Write-Host "secret-scan.ps1 v1.1.0 PASS" -ForegroundColor Green
Write-Host "  branch:    $Branch -> $UpstreamRev ($($upstreamSha.Substring(0,12)))" -ForegroundColor DarkGray
Write-Host "  diff sha:  $diffSha" -ForegroundColor DarkGray
Write-Host "  bytes:     $diffByteCount" -ForegroundColor DarkGray
Write-Host "  manifest:  $manifestPath" -ForegroundColor Green
Write-Host "  TTL:       5 minutes (consumer enforces; expires $((Get-Date).AddMinutes(5).ToUniversalTime().ToString('o')))" -ForegroundColor DarkGray
exit 0
