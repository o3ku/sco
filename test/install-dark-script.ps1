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

$sourceDir = Join-Path $Root 'sources'
$bucketDir = Join-Path $Root 'buckets\main\bucket'
$fakeBin = Join-Path $Root 'fake-bin'
New-Item -ItemType Directory -Force -Path $sourceDir, $bucketDir, $fakeBin | Out-Null

$bundlePath = Join-Path $sourceDir 'bundle.exe'
Set-Content -Path $bundlePath -Value 'fake wix bundle' -Encoding Ascii
Set-Content -Path (Join-Path $fakeBin 'payload.exe') -Value 'from fake dark' -Encoding Ascii

@(
    '@echo off',
    'echo dark %* > "%~dp0called.txt"',
    'set "SCO_FAKE_DARK_ARGS=%*"',
    'set "SCO_FAKE_DARK_ROOT=%~dp0"',
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-dark.ps1"',
    'exit /b %ERRORLEVEL%'
) | Set-Content -Path (Join-Path $fakeBin 'dark.cmd') -Encoding Ascii

@(
    '@echo off',
    'echo wix %* > "%~dp0called.txt"',
    'set "SCO_FAKE_DARK_ARGS=%*"',
    'set "SCO_FAKE_DARK_ROOT=%~dp0"',
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-dark.ps1"',
    'exit /b %ERRORLEVEL%'
) | Set-Content -Path (Join-Path $fakeBin 'wix.cmd') -Encoding Ascii

@'
$arguments = $env:SCO_FAKE_DARK_ARGS
$destination = $null

$darkMatch = [regex]::Match($arguments, '-x\s+"?([^"\s]+)"?')
if ($darkMatch.Success) {
    $destination = $darkMatch.Groups[1].Value
}

if (!$destination) {
    $wixMatch = [regex]::Match($arguments, '-out\s+"?([^"\s]+)"?')
    if ($wixMatch.Success) {
        $destination = $wixMatch.Groups[1].Value
    }
}

if (!$destination) {
    exit 3
}

New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $env:SCO_FAKE_DARK_ROOT 'payload.exe') -Destination (Join-Path $destination 'filetool.exe') -Force
'@ | Set-Content -Path (Join-Path $fakeBin 'fake-dark.ps1') -Encoding Ascii

$manifest = [ordered]@{
    version = '1.0.0'
    description = 'Expand-DarkArchive script test'
    url = ([System.IO.Path]::GetFullPath($bundlePath))
    hash = ''
    pre_install = 'Expand-DarkArchive -Path (Join-Path $dir ''bundle.exe'') -DestinationPath $dir'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'darkscripttool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:PATH = "$fakeBin;$env:PATH"

$installOutput = & $ScoExe install darkscripttool --independent --skip-hash-check --no-update-scoop 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "install darkscripttool failed with exit code $LASTEXITCODE`: $installOutput"
}

$installed = Join-Path $Root 'apps\darkscripttool\current\filetool.exe'
if (!(Test-Path $installed)) {
    throw 'Expand-DarkArchive did not create the manifest bin target'
}
if ((Get-Content $installed -Raw).Trim() -ne 'from fake dark') {
    throw 'installed file was not produced by the fake dark helper'
}

$called = Join-Path $fakeBin 'called.txt'
if (!(Test-Path $called)) {
    throw 'fake dark/wix helper was not invoked'
}
$calledArgs = Get-Content $called -Raw
if ($calledArgs -notmatch 'bundle\.exe' -or ($calledArgs -notmatch '\s-x\s' -and $calledArgs -notmatch '\sburn\s+extract\s')) {
    throw "dark/wix helper was invoked with unexpected arguments: $calledArgs"
}
