param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome
)

$ErrorActionPreference = 'Stop'

$resolvedRootParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $Root))
if ($resolvedRootParent -notlike '*\build\*') {
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

$archivePath = Join-Path $sourceDir 'scriptbundle.dat'
Set-Content -Path $archivePath -Value 'fake 7z payload container' -Encoding Ascii
Set-Content -Path (Join-Path $fakeBin 'payload.exe') -Value 'from fake script 7z' -Encoding Ascii

@(
    '@echo off',
    'echo %* > "%~dp0called.txt"',
    'set "SCO_FAKE_7Z_ARGS=%*"',
    'set "SCO_FAKE_7Z_ROOT=%~dp0"',
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-7z.ps1"',
    'exit /b %ERRORLEVEL%'
) | Set-Content -Path (Join-Path $fakeBin '7z.cmd') -Encoding Ascii

@'
$match = [regex]::Match($env:SCO_FAKE_7Z_ARGS, '-o"?([^"\s]+)"?')
if (!$match.Success) {
    exit 3
}

$destination = $match.Groups[1].Value
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $env:SCO_FAKE_7Z_ROOT 'payload.exe') -Destination (Join-Path $destination 'filetool.exe') -Force
'@ | Set-Content -Path (Join-Path $fakeBin 'fake-7z.ps1') -Encoding Ascii

$manifest = [ordered]@{
    version = '1.0.0'
    description = 'Expand-7zipArchive script test'
    url = ([System.IO.Path]::GetFullPath($archivePath))
    hash = ''
    pre_install = 'Expand-7zipArchive -Path (Join-Path $dir ''scriptbundle.dat'') -DestinationPath $dir'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'sevenzipscripttool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:PATH = "$fakeBin;$env:PATH"

$installOutput = & $ScoExe install sevenzipscripttool --independent --skip-hash-check --no-update-scoop 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "install sevenzipscripttool failed with exit code $LASTEXITCODE`: $installOutput"
}

$installed = Join-Path $Root 'apps\sevenzipscripttool\current\filetool.exe'
if (!(Test-Path $installed)) {
    throw 'Expand-7zipArchive did not create the manifest bin target'
}
if ((Get-Content $installed -Raw).Trim() -ne 'from fake script 7z') {
    throw 'installed file was not produced by the fake 7z helper'
}

$called = Join-Path $fakeBin 'called.txt'
if (!(Test-Path $called)) {
    throw 'fake 7z helper was not invoked'
}
$calledArgs = Get-Content $called -Raw
if ($calledArgs -notmatch '(^|\s)x\s' -or $calledArgs -notmatch 'scriptbundle\.dat' -or $calledArgs -notmatch '-o' -or $calledArgs -notmatch '-xr!\*\.nsis') {
    throw "7z helper was invoked with unexpected arguments: $calledArgs"
}
