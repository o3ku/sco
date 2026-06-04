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

$msiPath = Join-Path $sourceDir 'scriptmsi.dat'
Set-Content -Path $msiPath -Value 'fake msi payload container' -Encoding Ascii
Set-Content -Path (Join-Path $fakeBin 'payload.exe') -Value 'from fake script msiexec' -Encoding Ascii

@(
    '@echo off',
    'echo %* > "%~dp0called.txt"',
    'set "SCO_FAKE_MSIEXEC_ARGS=%*"',
    'set "SCO_FAKE_MSIEXEC_ROOT=%~dp0"',
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-msiexec.ps1"',
    'exit /b %ERRORLEVEL%'
) | Set-Content -Path (Join-Path $fakeBin 'msiexec.cmd') -Encoding Ascii

@'
$match = [regex]::Match($env:SCO_FAKE_MSIEXEC_ARGS, 'TARGETDIR="?([^"]+)"?')
if (!$match.Success) {
    exit 3
}

$destination = $match.Groups[1].Value
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $env:SCO_FAKE_MSIEXEC_ROOT 'payload.exe') -Destination (Join-Path $destination 'filetool.exe') -Force
'@ | Set-Content -Path (Join-Path $fakeBin 'fake-msiexec.ps1') -Encoding Ascii

$manifest = [ordered]@{
    version = '1.0.0'
    description = 'Expand-MsiArchive script test'
    url = ([System.IO.Path]::GetFullPath($msiPath))
    hash = ''
    pre_install = 'Expand-MsiArchive -Path (Join-Path $dir ''scriptmsi.dat'') -DestinationPath $dir'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'msiscripttool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:PATH = "$fakeBin;$env:PATH"

$installOutput = & $ScoExe install msiscripttool --independent --skip-hash-check --no-update-scoop 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "install msiscripttool failed with exit code $LASTEXITCODE`: $installOutput"
}

$installed = Join-Path $Root 'apps\msiscripttool\current\filetool.exe'
if (!(Test-Path $installed)) {
    throw 'Expand-MsiArchive did not create the manifest bin target'
}
if ((Get-Content $installed -Raw).Trim() -ne 'from fake script msiexec') {
    throw 'installed file was not produced by the fake msiexec helper'
}
if (Test-Path (Join-Path $Root 'apps\msiscripttool\current\SourceDir')) {
    throw 'Expand-MsiArchive did not flatten SourceDir'
}

$called = Join-Path $fakeBin 'called.txt'
if (!(Test-Path $called)) {
    throw 'fake msiexec helper was not invoked'
}
$calledArgs = Get-Content $called -Raw
if ($calledArgs -notmatch '(^|\s)/a\s' -or $calledArgs -notmatch 'scriptmsi\.dat' -or $calledArgs -notmatch 'TARGETDIR=') {
    throw "msiexec helper was invoked with unexpected arguments: $calledArgs"
}
