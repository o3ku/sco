param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome,
    [Parameter(Mandatory = $true)][string]$Artifact
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

$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'filetool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe bucket list
if ($LASTEXITCODE -ne 0) {
    throw "bucket list failed with exit code $LASTEXITCODE"
}

& $ScoExe install filetool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install by app name failed with exit code $LASTEXITCODE"
}

foreach ($path in @(
    (Join-Path $Root 'apps\filetool\1.0.0\filetool.exe'),
    (Join-Path $Root 'apps\filetool\current\filetool.exe'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "Missing expected install output: $path"
    }
}

$install = Get-Content (Join-Path $Root 'apps\filetool\1.0.0\install.json') -Raw | ConvertFrom-Json
if ($install.manifest -notlike '*buckets/main/bucket/filetool.json') {
    throw "install.json did not record bucket manifest: $($install.manifest)"
}
if ($install.bucket -ne 'main') {
    throw "install.json did not record Scoop-compatible bucket source: $($install | ConvertTo-Json -Compress)"
}
if ($install.PSObject.Properties.Name -contains 'url') {
    throw "bucket install should not record a standalone url source: $($install | ConvertTo-Json -Compress)"
}

$nestedBucketDir = Join-Path $bucketDir 'nested'
New-Item -ItemType Directory -Force -Path $nestedBucketDir | Out-Null
$nestedManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$nestedManifest | ConvertTo-Json | Set-Content -Path (Join-Path $nestedBucketDir 'nestedtool.json') -Encoding UTF8

& $ScoExe install nestedtool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install by nested bucket manifest failed with exit code $LASTEXITCODE"
}

if (!(Test-Path (Join-Path $Root 'apps\nestedtool\current\filetool.exe'))) {
    throw 'nested bucket manifest install did not create current filetool.exe'
}

$nestedInstall = Get-Content (Join-Path $Root 'apps\nestedtool\1.0.0\install.json') -Raw | ConvertFrom-Json
if ($nestedInstall.bucket -ne 'main') {
    throw "nested bucket install did not record bucket source: $($nestedInstall | ConvertTo-Json -Compress)"
}
if ($nestedInstall.manifest -notlike '*buckets/main/bucket/nested/nestedtool.json') {
    throw "nested bucket install did not record nested manifest path: $($nestedInstall.manifest)"
}

$caseManifest = [ordered]@{
    Version = '1.0.0'
    URL = ([System.IO.Path]::GetFullPath($Artifact))
    Hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    Bin = 'filetool.exe'
}
$caseManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'casetool.JSON') -Encoding UTF8

& $ScoExe install MAIN/CASETOOL --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install by differently-cased bucket and manifest name failed with exit code $LASTEXITCODE"
}

if (!(Test-Path (Join-Path $Root 'apps\casetool\current\filetool.exe'))) {
    throw 'case-insensitive bucket manifest install did not create current filetool.exe'
}

$caseInstall = Get-Content (Join-Path $Root 'apps\casetool\1.0.0\install.json') -Raw | ConvertFrom-Json
if ($caseInstall.bucket -ne 'main') {
    throw "case-insensitive bucket install did not record actual bucket source: $($caseInstall | ConvertTo-Json -Compress)"
}
if ($caseInstall.manifest -notlike '*buckets/main/bucket/casetool.JSON') {
    throw "case-insensitive bucket install did not record actual manifest path: $($caseInstall.manifest)"
}

$multiInstallOutput = & $ScoExe install filetool nestedtool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with already installed multiple apps failed with exit code $LASTEXITCODE`: $multiInstallOutput"
}
$multiInstallJoined = $multiInstallOutput -join "`n"
if ($multiInstallJoined -notmatch "WARN  'filetool' \(1\.0\.0\) is already installed\. Skipping\." -or
    $multiInstallJoined -notmatch "WARN  'nestedtool' \(1\.0\.0\) is already installed\. Skipping\.") {
    throw "install with multiple already installed explicit apps did not match Scoop skip warnings: $multiInstallJoined"
}
if ($multiInstallJoined -match "Use 'sco update") {
    throw "install with multiple already installed apps should use Scoop's Skipping warning, not the single-app update hint: $multiInstallJoined"
}
