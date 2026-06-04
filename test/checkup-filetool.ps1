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

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$fakePath = Join-Path $Root 'fake-path'
New-Item -ItemType Directory -Force -Path $fakePath | Out-Null
foreach ($helper in @('7z.exe', 'innounp.exe', 'dark.exe')) {
    Set-Content -Path (Join-Path $fakePath $helper) -Value 'fake helper' -Encoding Ascii
}
$originalPath = $env:PATH
$env:PATH = "$fakePath;$originalPath"

$output = & $ScoExe checkup
if ($LASTEXITCODE -ne 0) {
    throw "checkup failed with exit code $LASTEXITCODE`: $output"
}

$joined = $output -join "`n"
foreach ($pattern in @(
    'Main bucket is not added',
    "run 'sco bucket add main'",
    'You may read more about the symlinks support here:',
    "'7-Zip' is not installed",
    "'Inno Setup Unpacker' is not installed",
    "'dark' is not installed",
    'WARN  Found \d+ potential problem'
)) {
    if ($joined -notmatch $pattern) {
        throw "checkup output missing pattern '$pattern': $joined"
    }
}

$extraArgOutput = & $ScoExe checkup ignored-extra
if ($LASTEXITCODE -ne 0) {
    throw "checkup with an extra positional argument failed with exit code $LASTEXITCODE`: $extraArgOutput"
}
if (($extraArgOutput -join "`n") -notmatch 'WARN  Found \d+ potential problem') {
    throw "checkup did not ignore extra positional arguments like Scoop: $extraArgOutput"
}

New-Item -ItemType Directory -Force -Path (Join-Path $Root 'buckets\Main') | Out-Null
$caseBucketOutput = & $ScoExe checkup
if ($LASTEXITCODE -ne 0) {
    throw "checkup with mixed-case main bucket failed with exit code $LASTEXITCODE`: $caseBucketOutput"
}
$caseBucketJoined = $caseBucketOutput -join "`n"
if ($caseBucketJoined -match 'Main bucket is not added') {
    throw "checkup should treat the main bucket name case-insensitively like Scoop: $caseBucketJoined"
}
