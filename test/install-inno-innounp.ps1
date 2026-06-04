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

$installerPath = Join-Path $sourceDir 'innotool.exe'
Set-Content -Path $installerPath -Value 'fake inno setup payload container' -Encoding Ascii
Set-Content -Path (Join-Path $fakeBin 'payload.exe') -Value 'from fake innounp' -Encoding Ascii

@(
    '@echo off',
    'echo %* > "%~dp0called.txt"',
    'set "SCO_FAKE_INNOUNP_ARGS=%*"',
    'set "SCO_FAKE_INNOUNP_ROOT=%~dp0"',
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-innounp.ps1"',
    'exit /b %ERRORLEVEL%'
) | Set-Content -Path (Join-Path $fakeBin 'innounp.cmd') -Encoding Ascii

@'
$match = [regex]::Match($env:SCO_FAKE_INNOUNP_ARGS, '-d"([^"]+)"')
if (!$match.Success) {
    exit 3
}

$destination = $match.Groups[1].Value
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $env:SCO_FAKE_INNOUNP_ROOT 'payload.exe') -Destination (Join-Path $destination 'filetool.exe') -Force
'@ | Set-Content -Path (Join-Path $fakeBin 'fake-innounp.ps1') -Encoding Ascii

$manifest = [ordered]@{
    version = '1.0.0'
    description = 'Inno Setup extraction test'
    url = ([System.IO.Path]::GetFullPath($installerPath))
    hash = ''
    innosetup = 'true'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'innotool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:PATH = "$fakeBin;$env:PATH"

$installOutput = & $ScoExe install innotool --independent --skip-hash-check --no-update-scoop 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "install innotool failed with exit code $LASTEXITCODE`: $installOutput"
}

$installed = Join-Path $Root 'apps\innotool\current\filetool.exe'
if (!(Test-Path $installed)) {
    throw 'Inno extraction did not create the manifest bin target'
}
if ((Get-Content $installed -Raw).Trim() -ne 'from fake innounp') {
    throw 'installed file was not produced by the fake innounp'
}

$called = Join-Path $fakeBin 'called.txt'
if (!(Test-Path $called)) {
    throw 'fake innounp was not invoked'
}
$calledArgs = Get-Content $called -Raw
if ($calledArgs -notmatch '(^|\s)-x\s' -or $calledArgs -notmatch '-d"' -or $calledArgs -notmatch 'innotool\.exe' -or $calledArgs -notmatch '-c\{app\}') {
    throw "innounp was invoked with unexpected arguments: $calledArgs"
}
