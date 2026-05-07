[CmdletBinding()]
param(
    [string] $JsonlPath      = '',
    [int]    $MaxLines       = 100,
    [int]    $MaxFieldChars  = 200
)

# jsonl-watcher.ps1 (v1.1.0 production).
# Full contract: DESIGN.md s4.1 (OVERWATCH mode) + s5 (brake list).
#
# Tails a sibling JSONL transcript as untrusted input. Sanitizes every
# string field (secret-redact + imperative-strip + truncate) before
# emitting a structured summary so the OVERWATCH lead can reason about
# the lieutenant's progress without ingesting injection payloads.
#
# Hardening:
#   - Path allowlist: target MUST be inside LEAD_WATCH_ROOT or the
#     default ~/.claude/projects tree (StartsWith with trailing-sep
#     normalization to defeat C:\foo vs C:\foo-evil prefix-overlap).
#   - Self-target refusal: refuses if path contains the caller session
#     id (W-09 lead-self-target exclusion).
#   - 15-pattern secret pin-set MIRROR of lib/secret-scan.ps1 -- the
#     two scanners must redact the same alphabet (rotate together).
#   - Imperative-strip: narrow regex anchored at start-of-line targeting
#     role-impersonation only (system:/assistant:/lead-agent:/"ignore
#     previous" etc). Generic imperative verbs like "create" are NOT
#     stripped because legitimate transcript content contains them.
#   - Brake list: if >5% of parsed lines fail JSON parse, the watcher
#     fail-closes (DESIGN.md s5). Garbage stream defaults to refuse.
#   - HMAC envelope: same sign-then-store pattern as secret-scan.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# .NET regex engine pin (V8-11 carry, byte-stable PS5/7).
$RegexOpts = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor `
             [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

# Preflight 1: lead-mode env.
if ($env:LEAD_AGENT -ne '1') {
    Write-Error "jsonl-watcher.ps1: not running in a lead-mode session (LEAD_AGENT != 1)"
    exit 2
}
if ($env:LEAD_AGENT_MODE -ne 'OVERWATCH') {
    Write-Error "jsonl-watcher.ps1: only valid in OVERWATCH mode (got LEAD_AGENT_MODE=$env:LEAD_AGENT_MODE)"
    exit 2
}

# Preflight 2: target path. Accept -JsonlPath or env fallback.
if (-not $JsonlPath -and $env:LEAD_AGENT_WATCH_TARGET) {
    $JsonlPath = $env:LEAD_AGENT_WATCH_TARGET
}
if (-not $JsonlPath) {
    Write-Error "jsonl-watcher.ps1: no target (-JsonlPath or LEAD_AGENT_WATCH_TARGET required)"
    exit 2
}

# Preflight 3: bounds.
if ($MaxLines -lt 1 -or $MaxLines -gt 5000) {
    Write-Error "jsonl-watcher.ps1: MaxLines $MaxLines out of range [1,5000]"
    exit 2
}
if ($MaxFieldChars -lt 1 -or $MaxFieldChars -gt 4096) {
    Write-Error "jsonl-watcher.ps1: MaxFieldChars $MaxFieldChars out of range [1,4096]"
    exit 2
}

# Soft-refusal helper: emits a structured ok=false JSON to stdout and
# exits 0. Reserved for refusals the lead consumes as data (path-allow,
# self-target, brake). Hard preflight failures use exit 2 above.
function Emit-Refusal {
    param([string] $Reason, [hashtable] $Extra = @{})
    $obj = [ordered]@{
        ok            = $false
        reason        = $Reason
        watchTarget   = $JsonlPath
        schemaVersion = '1.1.0-jsonl-watcher'
    }
    foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] }
    Write-Output ($obj | ConvertTo-Json -Compress -Depth 10)
    exit 0
}

# Resolve path. If the file doesn't exist yet, refuse softly so the
# lead can decide to retry (lieutenant may not have written its first
# line yet during the launch race).
try {
    $resolved = (Resolve-Path -LiteralPath $JsonlPath -ErrorAction Stop).ProviderPath
} catch {
    Emit-Refusal -Reason 'target-not-found' -Extra @{ error = $_.Exception.Message }
}

# Path allowlist. Default watchRoot is ~/.claude/projects (the canonical
# CC transcript tree on Windows). LEAD_WATCH_ROOT can override for tests.
$watchRoot = if ($env:LEAD_WATCH_ROOT) {
    $env:LEAD_WATCH_ROOT
} else {
    Join-Path $env:USERPROFILE '.claude\projects'
}
try {
    $watchRootResolved = (Resolve-Path -LiteralPath $watchRoot -ErrorAction Stop).ProviderPath
} catch {
    Emit-Refusal -Reason 'watch-root-missing' -Extra @{ watchRoot = $watchRoot }
}

# Trailing-separator normalization. Without this, "C:\Users\foo" allows
# "C:\Users\foo-evil\..." through StartsWith. Always anchor with the
# directory separator so prefix-overlap attacks fail.
$sep = [System.IO.Path]::DirectorySeparatorChar
$rootPrefix = if ($watchRootResolved.EndsWith($sep)) {
    $watchRootResolved
} else {
    $watchRootResolved + $sep
}
if (-not $resolved.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    Emit-Refusal -Reason 'path-outside-watch-root' -Extra @{
        watchRoot = $watchRootResolved
        resolved  = $resolved
    }
}

# Self-target refusal. The lead must never tail its own transcript or
# we get a feedback loop where the lead's tool calls re-enter via JSONL
# and trigger more tool calls. Substring match on caller session id
# because the JSONL filename embeds it.
if ($env:LEAD_AGENT_CALLER_SESSION_ID) {
    $sid = $env:LEAD_AGENT_CALLER_SESSION_ID
    if ($resolved -like "*$sid*") {
        Emit-Refusal -Reason 'self-target-refused' -Extra @{
            callerSessionId = $sid
        }
    }
}

# 15-pattern secret pin-set (MIRROR of lib/secret-scan.ps1 -- keep in
# sync; the two scanners must redact the same alphabet so OVERWATCH
# never bleeds a secret that BUILDER's diff-scan would have caught).
$secretPatterns = @(
    @{ Name = 'aws-access-key';     Pattern = 'AKIA[0-9A-Z]{16}' }
    @{ Name = 'aws-session-token';  Pattern = '(?:FQoG|FwoG|IQo)[A-Za-z0-9+/=]{200,}' }
    @{ Name = 'openai-key';         Pattern = 'sk-(?:proj-)?[A-Za-z0-9_\-]{20,}' }
    @{ Name = 'github-pat';         Pattern = 'ghp_[A-Za-z0-9]{36,}' }
    @{ Name = 'github-oauth';       Pattern = 'gho_[A-Za-z0-9]{36,}' }
    @{ Name = 'gitlab-pat';         Pattern = 'glpat-[A-Za-z0-9_\-]{20,}' }
    @{ Name = 'slack-bot';          Pattern = 'xoxb-[0-9]+-[0-9]+-[A-Za-z0-9]+' }
    @{ Name = 'slack-user';         Pattern = 'xoxp-[0-9]+-[0-9]+-[0-9]+-[A-Za-z0-9]+' }
    @{ Name = 'jwt';                Pattern = 'eyJ[A-Za-z0-9_\-]{30,}\.[A-Za-z0-9_\-]{30,}\.[A-Za-z0-9_\-]{30,}' }
    @{ Name = 'postgres-url';       Pattern = 'postgres(?:ql)?://[^\s''"<>]{8,}' }
    @{ Name = 'mongodb-url';        Pattern = 'mongodb(?:\+srv)?://[^\s''"<>]{8,}' }
    @{ Name = 'mysql-url';          Pattern = 'mysql://[^\s''"<>]{8,}' }
    @{ Name = 'redis-url';          Pattern = 'rediss?://[^\s''"<>]{8,}' }
    @{ Name = 'stripe-live';        Pattern = 'rk_live_[A-Za-z0-9]{24,}' }
    @{ Name = 'bearer-token';       Pattern = '(?i)bearer\s+[A-Za-z0-9_\-\.=]{20,}' }
)
$compiledSecrets = foreach ($p in $secretPatterns) {
    [System.Text.RegularExpressions.Regex]::new($p.Pattern, $RegexOpts)
}

# Imperative-strip targets role-impersonation prompt-injection only.
# Anchored at start-of-line, IgnoreCase, multiline. NOT a generic
# verb-stripper -- that would gut legit transcript content.
$imperativeRe = [System.Text.RegularExpressions.Regex]::new(
    '^\s*(?:lead[-\s]?agent[,:]|claude(?:\s+code)?\s*[,:]|system\s*:|assistant\s*:|<\s*system\s*>|you\s+are\s+now\s+|ignore\s+(?:all\s+)?(?:previous|prior)\s+instructions)',
    ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor `
     [System.Text.RegularExpressions.RegexOptions]::Multiline -bor `
     $RegexOpts)
)

function Sanitize-Field {
    param([string] $Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }

    # 1. Secret redaction.
    $redacted = $Value
    foreach ($re in $compiledSecrets) {
        $redacted = $re.Replace($redacted, '[REDACTED-SECRET]')
    }

    # 2. Imperative strip (replaces role-prefix with marker).
    $stripped = $imperativeRe.Replace($redacted, '[STRIPPED-IMPERATIVE]')

    # 3. Truncate to MaxFieldChars.
    if ($stripped.Length -gt $MaxFieldChars) {
        return $stripped.Substring(0, $MaxFieldChars) + '...[truncated]'
    }
    return $stripped
}

function Sanitize-Object {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [string]) { return Sanitize-Field $Obj }

    # Non-string scalar: leave as-is (numbers/bools are not injection
    # vectors). Compound: stringify via ConvertTo-Json then sanitize.
    if ($Obj.GetType().IsPrimitive -or $Obj -is [bool]) { return $Obj }

    try {
        $serialized = $Obj | ConvertTo-Json -Compress -Depth 5
        return Sanitize-Field $serialized
    } catch {
        return '[unserializable]'
    }
}

# Tail read with FileShare.ReadWrite so the lieutenant's still-running
# write handle doesn't collide. Seek back MaxLines*4096 bytes (heuristic
# average line length 4KB) if the file is bigger; discard the partial
# first line; take the last MaxLines.
$lines = New-Object 'System.Collections.Generic.List[string]'
try {
    $fs = [System.IO.File]::Open(
        $resolved,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    try {
        $tailBytes = [int64]($MaxLines * 4096)
        if ($fs.Length -gt $tailBytes) {
            $null = $fs.Seek(-$tailBytes, [System.IO.SeekOrigin]::End)
        }
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        try {
            # If we seeked, the first line is partial -- discard it.
            if ($fs.Length -gt $tailBytes) { $null = $sr.ReadLine() }
            while (-not $sr.EndOfStream) {
                $lines.Add($sr.ReadLine())
            }
        } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
} catch {
    Emit-Refusal -Reason 'tail-read-failed' -Extra @{ error = $_.Exception.Message }
}

# Window to the last MaxLines (StreamReader gave us everything from
# the seek point; the partial-line discard above may have left us with
# slightly more or less than MaxLines).
if ($lines.Count -gt $MaxLines) {
    $lines = $lines.GetRange($lines.Count - $MaxLines, $MaxLines)
}

# Per-line: parse JSON, walk top-level properties, sanitize. Track
# parse failures for the brake-list trigger.
$summary = New-Object 'System.Collections.Generic.List[object]'
$parseFails = 0
$secretHits = 0
$lineNum = 0

foreach ($line in $lines) {
    $lineNum++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $parseFails++
        continue
    }

    # Quick secret-hit count (pre-sanitize, so we can report).
    foreach ($re in $compiledSecrets) {
        if ($re.IsMatch($line)) { $secretHits++; break }
    }

    $sanitized = [ordered]@{ line = $lineNum }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $obj.PSObject.Properties) {
            $sanitized[$prop.Name] = Sanitize-Object $prop.Value
        }
    } else {
        $sanitized['_raw'] = Sanitize-Object $obj
    }
    $summary.Add($sanitized)
}

# Brake-list: >5% parse failures = stream is garbage, fail-closed.
$totalNonEmpty = ($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
if ($totalNonEmpty -gt 0) {
    $failPct = [double]($parseFails / $totalNonEmpty)
    if ($failPct -gt 0.05) {
        Emit-Refusal -Reason 'brake-parse-failure-rate' -Extra @{
            parseFails        = $parseFails
            totalNonEmpty     = $totalNonEmpty
            parseFailureRatio = [math]::Round($failPct, 4)
        }
    }
}

# Build the success body. Same sign-then-store-as-string envelope as
# secret-scan: serialize body as a string, HMAC over those bytes,
# emit envelope wrapping the string. Keeps consumer HMAC verification
# byte-stable across PS5/PS7 ConvertTo-Json key-order drift.
$body = [ordered]@{
    ok            = $true
    schemaVersion = '1.1.0-jsonl-watcher'
    watchTarget   = $resolved
    linesScanned  = $lines.Count
    parseFails    = $parseFails
    secretHits    = $secretHits
    summary       = $summary.ToArray()
}
$bodyJson = $body | ConvertTo-Json -Compress -Depth 10

# HMAC sign if key present. Otherwise emit body alone (caller decides
# whether unsigned is acceptable -- pin manifest will reject it).
$envelope = [ordered]@{
    schemaVersion = '1.1.0-jsonl-watcher-envelope'
    bodyJson      = $bodyJson
}

if ($env:LEAD_AGENT_ACK_HMAC_KEY) {
    $hexKey = $env:LEAD_AGENT_ACK_HMAC_KEY
    if ($hexKey.Length -lt 64) {
        Emit-Refusal -Reason 'hmac-key-too-short' -Extra @{ keyLen = $hexKey.Length }
    }
    try {
        $keyBytes = New-Object byte[] ($hexKey.Length / 2)
        for ($i = 0; $i -lt $keyBytes.Length; $i++) {
            $keyBytes[$i] = [Convert]::ToByte($hexKey.Substring($i * 2, 2), 16)
        }
    } catch {
        Emit-Refusal -Reason 'hmac-key-not-hex' -Extra @{ error = $_.Exception.Message }
    }
    try {
        $hmac = New-Object System.Security.Cryptography.HMACSHA256(,$keyBytes)
        try {
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)
            $sigBytes = $hmac.ComputeHash($bodyBytes)
            $envelope['hmacAlg'] = 'HMAC-SHA256'
            $envelope['hmac']    = ([BitConverter]::ToString($sigBytes)).Replace('-', '').ToLowerInvariant()
        } finally { $hmac.Dispose() }
    } finally {
        # Best-effort scrub of key bytes.
        if ($keyBytes) { [Array]::Clear($keyBytes, 0, $keyBytes.Length) }
    }
}

Write-Output ($envelope | ConvertTo-Json -Compress -Depth 10)
exit 0
