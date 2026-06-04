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

$bucketDir = Join-Path $Root 'buckets\main\bucket'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

$baseUrl = 'http://127.0.0.1:18213'

function Write-Manifest($Name, $Homepage) {
    $manifest = [ordered]@{
        version = '1.0.0'
        url = 'https://example.test/tool.exe'
        hash = ''
    }
    if ($Homepage) {
        $manifest.homepage = $Homepage
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir "$Name.json") -Encoding UTF8
}

Write-Manifest 'emptytool' "$baseUrl/empty"
Write-Manifest 'metatool' "$baseUrl/meta"
Write-Manifest 'missinghome' $null
Write-Manifest 'ogtool' "$baseUrl/og"
Write-Manifest 'paratool' "$baseUrl/para"
Write-Manifest 'refreshtool' "$baseUrl/refresh"
Write-Manifest 'texttool' "$baseUrl/text"
Set-Content -Path (Join-Path $bucketDir 'badtool.json') -Value '{bad json' -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingDirOutput = & $ScoExe describe metatool 2>&1
$missingDirExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingDirExitCode -eq 0 -or ($missingDirOutput -join "`n") -notmatch 'missing mandatory parameters: Dir') {
    throw "describe without -Dir did not match PowerShell mandatory parameter behavior: $missingDirOutput"
}

$serverJob = Start-Job -ScriptBlock {
    param($Prefix)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        for ($i = 0; $i -lt 10; $i++) {
            $context = $listener.GetContext()
            $path = $context.Request.Url.AbsolutePath
            $body = switch ($path) {
                '/og' { '<html><head><meta property="og:description" content="Open graph &amp; description"></head><body></body></html>' }
                '/meta' { '<html><head><meta name="description" content="Meta description"></head><body></body></html>' }
                '/refresh' { '<html><head><meta http-equiv="refresh" content="0; url=/redirected"></head><body></body></html>' }
                '/redirected' { '<html><head><meta name="description" content="Redirected description"></head><body></body></html>' }
                '/text' { '<html><body><div>Intro.</div><div>Text Tool is a focused utility!</div></body></html>' }
                '/para' { '<html><body><p>Paragraph description.</p></body></html>' }
                '/empty' { '<html><body><h1>No useful description</h1></body></html>' }
                default { 'not found' }
            }
            if ($path -eq '/missing') {
                $context.Response.StatusCode = 404
            } else {
                $context.Response.StatusCode = 200
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $context.Response.ContentType = 'text/html; charset=utf-8'
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList 'http://127.0.0.1:18213/'

Start-Sleep -Milliseconds 300
try {
    $output = & $ScoExe describe -Dir $bucketDir
    if ($LASTEXITCODE -ne 0) {
        throw "describe failed with exit code $LASTEXITCODE`: $output"
    }

    $patternOutput = & $ScoExe describe 'meta*' -Dir $bucketDir
    if ($LASTEXITCODE -ne 0) {
        throw "describe app pattern failed with exit code $LASTEXITCODE`: $patternOutput"
    }

    $positionalDirOutput = & $ScoExe describe 'meta*' $bucketDir
    if ($LASTEXITCODE -ne 0) {
        throw "describe positional App Dir failed with exit code $LASTEXITCODE`: $positionalDirOutput"
    }

    $namedAppOutput = & $ScoExe describe -App 'meta*' -Dir $bucketDir
    if ($LASTEXITCODE -ne 0) {
        throw "describe -App failed with exit code $LASTEXITCODE`: $namedAppOutput"
    }
} finally {
    Wait-Job $serverJob -Timeout 5 | Out-Null
    Receive-Job $serverJob | Out-Null
    Remove-Job $serverJob -Force
}

$joined = $output -join "`n"
if ($joined -notmatch 'ogtool: \(found by <meta property="og:description">\)\s+"Open graph & description"') {
    throw "describe did not report Open Graph description: $joined"
}
if ($joined -notmatch 'metatool: \(found by <meta name="description">\)\s+"Meta description"') {
    throw "describe did not report meta description: $joined"
}
if ($joined -notmatch 'refreshtool: \(found by <meta name="description">\)\s+"Redirected description"') {
    throw "describe did not follow meta refresh once: $joined"
}
if ($joined -notmatch 'texttool: \(found by text\)\s+"Text Tool is a focused utility!"') {
    throw "describe did not report text description: $joined"
}
if ($joined -notmatch 'paratool: \(found by first <p>\)\s+"Paragraph description\."') {
    throw "describe did not report first paragraph description: $joined"
}
if ($joined -notmatch 'missinghome:\s+No homepage set\.') {
    throw "describe did not report missing homepage: $joined"
}
if ($joined -notmatch 'badtool:\s+No homepage set\.') {
    throw "describe should treat invalid JSON manifests as missing homepage like Scoop: $joined"
}
if ($joined -notmatch 'emptytool:\s+Description not found \(http://127\.0\.0\.1:18213/empty\)') {
    throw "describe did not report missing description: $joined"
}

$patternJoined = $patternOutput -join "`n"
if ($patternJoined -notmatch 'metatool' -or $patternJoined -match 'ogtool|paratool|texttool|missinghome') {
    throw "describe app pattern did not filter expected manifests: $patternJoined"
}

$positionalDirJoined = $positionalDirOutput -join "`n"
if ($positionalDirJoined -notmatch 'metatool' -or $positionalDirJoined -match 'ogtool|paratool|texttool|missinghome') {
    throw "describe positional App Dir did not match PowerShell parameter binding: $positionalDirJoined"
}

$namedAppJoined = $namedAppOutput -join "`n"
if ($namedAppJoined -notmatch 'metatool' -or $namedAppJoined -match 'ogtool|paratool|texttool|missinghome') {
    throw "describe -App did not select the requested manifest: $namedAppJoined"
}

$helpOutput = & $ScoExe describe --help
if ($LASTEXITCODE -ne 0 -or ($helpOutput -join "`n") -notmatch 'Usage: sco describe') {
    throw "describe --help failed: $helpOutput"
}

$helpCommandOutput = & $ScoExe help describe
if ($LASTEXITCODE -ne 0 -or ($helpCommandOutput -join "`n") -notmatch 'Usage: sco describe') {
    throw "help describe failed: $helpCommandOutput"
}
