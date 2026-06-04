param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome
)

$ErrorActionPreference = 'Stop'

$resolvedRootParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $Root))
if ($resolvedRootParent -notlike '*\build\msvc-release*') {
    throw "Refusing to clean test root outside build tree: $Root"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $Root | Out-Null

$listenerPrefix = 'http://127.0.0.1:18198/'
@{
    remote = ($listenerPrefix + 'repos/local/remote/git/trees/HEAD?recursive=1')
} | ConvertTo-Json | Set-Content -Path (Join-Path $Root 'buckets.json') -Encoding UTF8

$treeJson = @{
    tree = @(
        @{ path = 'bucket/remotetool.json'; type = 'blob' },
        @{ path = 'bucket/nested/remote-extra.json'; type = 'blob' },
        @{ path = 'Bucket/remote-upper.JSON'; type = 'blob' },
        @{ path = 'README.md'; type = 'blob' }
    )
} | ConvertTo-Json -Depth 5

$job = Start-Job -ScriptBlock {
    param($Prefix, $Body)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        $context = $listener.GetContext()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'application/json'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList $listenerPrefix, $treeJson

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

Start-Sleep -Milliseconds 300
try {
    $output = & $ScoExe search remote
    if ($LASTEXITCODE -ne 0) {
        throw "remote search failed with exit code $LASTEXITCODE`: $output"
    }
} finally {
    Wait-Job $job -Timeout 5 | Out-Null
    Receive-Job $job | Out-Null
    Remove-Job $job -Force
}

$joined = $output -join "`n"
if ($joined -notmatch 'Results from other known buckets') {
    throw "remote search did not print known-bucket header: $joined"
}
if ($joined -notmatch "add them using 'sco bucket add <bucket name>'") {
    throw "remote search did not print add-bucket hint: $joined"
}
if ($joined -notmatch 'Name\s+Source' -or
    $joined -notmatch 'remotetool\s+remote' -or
    $joined -notmatch 'remote-extra\s+remote' -or
    $joined -notmatch 'remote-upper\s+remote') {
    throw "remote search did not list matching remote manifests: $joined"
}

$localUpperBucket = Join-Path $Root 'buckets\REMOTE\bucket'
New-Item -ItemType Directory -Force -Path $localUpperBucket | Out-Null

$skipListenerPrefix = 'http://127.0.0.1:18199/'
@{
    remote = ($skipListenerPrefix + 'repos/local/remote/git/trees/HEAD?recursive=1')
} | ConvertTo-Json | Set-Content -Path (Join-Path $Root 'buckets.json') -Encoding UTF8

$skipTreeJson = @{
    tree = @(
        @{ path = 'bucket/remoteshouldbeskipped.json'; type = 'blob' }
    )
} | ConvertTo-Json -Depth 5

$skipServerScript = Join-Path $Root 'skip-remote-server.ps1'
$skipBodyPath = Join-Path $Root 'skip-remote-body.json'
$skipMarkerPath = Join-Path $Root 'skip-remote-requested.txt'
$skipTreeJson | Set-Content -LiteralPath $skipBodyPath -Encoding UTF8
@'
param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][string]$BodyPath,
    [Parameter(Mandatory = $true)][string]$MarkerPath
)

$ErrorActionPreference = 'Stop'
$Body = Get-Content -LiteralPath $BodyPath -Raw
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Prefix)
$listener.Start()
try {
    $context = $listener.GetContext()
    Set-Content -LiteralPath $MarkerPath -Value 'requested' -Encoding Ascii
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $context.Response.StatusCode = 200
    $context.Response.ContentType = 'application/json'
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.OutputStream.Close()
} finally {
    $listener.Stop()
    $listener.Close()
}
'@ | Set-Content -LiteralPath $skipServerScript -Encoding UTF8

$skipServer = Start-Process -FilePath powershell -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $skipServerScript,
    $skipListenerPrefix,
    $skipBodyPath,
    $skipMarkerPath
) -WindowStyle Hidden -PassThru

try {
    Start-Sleep -Milliseconds 300
    $caseOutput = & $ScoExe search remote 2>&1
    $caseExitCode = $LASTEXITCODE
} finally {
    if ($skipServer -and -not $skipServer.HasExited) {
        Stop-Process -Id $skipServer.Id -Force -ErrorAction SilentlyContinue
        $skipServer.WaitForExit()
    }
}

if (Test-Path $skipMarkerPath) {
    throw "search queried a known remote bucket even though differently-cased local bucket REMOTE exists"
}

if ($caseExitCode -ne 1) {
    throw "search should skip known remote bucket when a differently-cased local bucket exists, got ${caseExitCode}: $caseOutput"
}
$caseJoined = $caseOutput -join "`n"
if ($caseJoined -match 'remoteshouldbeskipped' -or $caseJoined -notmatch 'WARN  No matches found\.') {
    throw "search did not treat local bucket names case-insensitively when skipping known remotes: $caseJoined"
}

$missingOutput = & $ScoExe search nomatch 2>&1
if ($LASTEXITCODE -ne 1) {
    throw "search with no local or remote matches returned $LASTEXITCODE instead of 1: $missingOutput"
}
if (($missingOutput -join "`n") -notmatch 'WARN  No matches found\.') {
    throw "search with no matches did not print Scoop-style warning: $missingOutput"
}
