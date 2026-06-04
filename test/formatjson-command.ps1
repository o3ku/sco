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

$formatPath = Join-Path $bucketDir 'formatme.json'
$skipPath = Join-Path $bucketDir 'skipme.json'
$filePath = Join-Path $bucketDir 'fileonly.json'
$badPath = Join-Path $bucketDir 'badtool.json'

Set-Content -Path $formatPath -Value '{"version":"1.0.0","url":"https://example.test/format.exe","hash":"","architecture":{"64bit":{"url":"https://example.test/format-x64.exe","hash":""}}}' -Encoding UTF8
Set-Content -Path $skipPath -Value '{"version":"1.0.0","url":"https://example.test/skip.exe","hash":""}' -Encoding UTF8
Set-Content -Path $filePath -Value '{"version":"1.0.0","url":"https://example.test/file.exe","hash":""}' -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingDirOutput = & $ScoExe formatjson formatme 2>&1
$missingDirExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingDirExitCode -eq 0 -or ($missingDirOutput -join "`n") -notmatch 'missing mandatory parameters: Dir') {
    throw "formatjson without -Dir did not match PowerShell mandatory parameter behavior: $missingDirOutput"
}

$output = & $ScoExe formatjson 'format*' -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "formatjson failed with exit code $LASTEXITCODE`: $output"
}

$formatted = Get-Content -LiteralPath $formatPath -Raw
if ($formatted -notmatch '    "version": "1\.0\.0"' -or
    $formatted -notmatch '    "architecture": \{' -or
    $formatted -notmatch '        "64bit": \{') {
    throw "formatjson did not pretty-print selected manifest: $formatted"
}
if ($formatted -match "`t") {
    throw "formatjson should use spaces rather than tabs: $formatted"
}

$skipped = Get-Content -LiteralPath $skipPath -Raw
if ($skipped -notmatch '^\{"version":"1\.0\.0"') {
    throw "formatjson wildcard should not rewrite non-matching manifests: $skipped"
}

$output = & $ScoExe formatjson skipme $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "formatjson positional App Dir failed with exit code $LASTEXITCODE`: $output"
}
$skippedFormatted = Get-Content -LiteralPath $skipPath -Raw
if ($skippedFormatted -notmatch '    "url": "https://example\.test/skip\.exe"') {
    throw "formatjson positional App Dir did not format the requested manifest: $skippedFormatted"
}

$output = & $ScoExe formatjson -App skipme -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "formatjson -App failed with exit code $LASTEXITCODE`: $output"
}

$fileOutput = & $ScoExe formatjson $filePath -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "formatjson filepath failed with exit code $LASTEXITCODE`: $fileOutput"
}
$fileFormatted = Get-Content -LiteralPath $filePath -Raw
if ($fileFormatted -notmatch '    "url": "https://example\.test/file\.exe"') {
    throw "formatjson filepath did not format target file: $fileFormatted"
}

$helpOutput = & $ScoExe formatjson --help
if ($LASTEXITCODE -ne 0 -or ($helpOutput -join "`n") -notmatch 'Usage: sco formatjson') {
    throw "formatjson --help failed: $helpOutput"
}

$helpCommandOutput = & $ScoExe help formatjson
if ($LASTEXITCODE -ne 0 -or ($helpCommandOutput -join "`n") -notmatch 'Usage: sco formatjson') {
    throw "help formatjson failed: $helpCommandOutput"
}

Set-Content -Path $badPath -Value '{bad json' -Encoding UTF8
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$badOutput = & $ScoExe formatjson badtool -Dir $bucketDir 2>&1
$badExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badExitCode -eq 0 -or ($badOutput -join "`n") -notmatch 'invalid manifest JSON') {
    throw "formatjson did not reject invalid JSON: $badOutput"
}
