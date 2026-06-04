param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome,
    [Parameter(Mandatory = $true)][string]$ArtifactV1,
    [Parameter(Mandatory = $true)][string]$ArtifactV2
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

$bucketDir = Join-Path $Root 'buckets\main\bucket'
$manifestPath = Join-Path $bucketDir 'filetool.json'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

function Write-Manifest($Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        persist = 'data'
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAppOutput = & $ScoExe cleanup 2>&1
$missingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppExitCode -ne 1) {
    throw "cleanup without an app returned $missingAppExitCode instead of 1: $missingAppOutput"
}
if (($missingAppOutput -join "`n") -notmatch 'ERROR: <app> missing' -or ($missingAppOutput -join "`n") -notmatch 'Usage: sco cleanup <app> \[options\]') {
    throw "cleanup without an app did not match Scoop usage: $missingAppOutput"
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $globalNonAdminOutput = & $ScoExe cleanup --global definitely-missing-global-tool 2>&1
    $globalNonAdminExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($globalNonAdminExitCode -ne 1) {
        throw "non-admin cleanup --global returned $globalNonAdminExitCode instead of 1: $globalNonAdminOutput"
    }
    if (($globalNonAdminOutput -join "`n") -notmatch 'ERROR: you need admin rights to cleanup global apps') {
        throw "non-admin cleanup --global did not match Scoop admin error: $globalNonAdminOutput"
    }
}

$emptyAllOutput = (& $ScoExe cleanup --all) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "cleanup --all on empty install set returned $LASTEXITCODE`: $emptyAllOutput"
}
if ($emptyAllOutput -notmatch 'Everything is shiny now!') {
    throw "cleanup --all on empty install set did not report success: $emptyAllOutput"
}

$emptyCacheDir = Join-Path $Root 'cache'
New-Item -ItemType Directory -Force -Path $emptyCacheDir | Out-Null
$emptyTemporaryDownload = Join-Path $emptyCacheDir 'empty.partial.download'
Set-Content -Path $emptyTemporaryDownload -Value 'partial download' -Encoding Ascii

$emptyAllCacheOutput = (& $ScoExe cleanup --all --cache) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "cleanup --all --cache on empty install set returned $LASTEXITCODE`: $emptyAllCacheOutput"
}
if ($emptyAllCacheOutput -notmatch 'Everything is shiny now!') {
    throw "cleanup --all --cache on empty install set did not report success: $emptyAllCacheOutput"
}
if (Test-Path $emptyTemporaryDownload) {
    throw 'cleanup --all --cache did not remove stale .download entry when no apps were installed'
}

$failedCleanRoot = Join-Path $Root 'apps\failedclean'
$failedCleanOldVersion = Join-Path $failedCleanRoot 'stale'
New-Item -ItemType Directory -Force -Path $failedCleanOldVersion | Out-Null
Set-Content -Path (Join-Path $failedCleanOldVersion 'leftover.txt') -Value 'failed install leftover' -Encoding Ascii
$failedCleanCache = Join-Path $Root 'cache\failedclean#0.1.0#leftover.exe'
Set-Content -Path $failedCleanCache -Value 'failed install cache' -Encoding Ascii

$failedCleanOutput = (& $ScoExe cleanup failedclean --cache) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "cleanup failed install layout returned $LASTEXITCODE`: $failedCleanOutput"
}
if ($failedCleanOutput -notmatch "ERROR 'failedclean' isn't installed correctly\." -or
    $failedCleanOutput -notmatch 'Removing failedclean: stale' -or
    $failedCleanOutput -match "ERROR 'failedclean' isn't installed\.") {
    throw "cleanup failed install layout did not match Scoop behavior: $failedCleanOutput"
}
if (Test-Path $failedCleanRoot) {
    throw 'cleanup failed install layout left stale app directory behind'
}
if (Test-Path $failedCleanCache) {
    throw 'cleanup failed install layout did not remove stale cache'
}

Write-Manifest '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
& $ScoExe install filetool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$currentData = Join-Path $Root 'apps\filetool\current\data'
$persistData = Join-Path $Root 'persist\filetool\data'
if (!(Test-Path $currentData)) {
    throw 'install did not create current persist data path'
}
Set-Content -Path (Join-Path $currentData 'settings.json') -Value '{"cleanup":true}' -NoNewline -Encoding Ascii
if (!(Test-Path (Join-Path $persistData 'settings.json'))) {
    throw 'writing through current persist path did not reach persist store'
}

$v2Source = Join-Path $Root 'sources\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $v2Source) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $v2Source -Force
Write-Manifest '1.1.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
& $ScoExe update filetool
if ($LASTEXITCODE -ne 0) {
    throw "update failed with exit code $LASTEXITCODE"
}

$oldVersionDir = Join-Path $Root 'apps\filetool\1.0.0'
$readOnlyDir = Join-Path $oldVersionDir 'readonly-dir'
New-Item -ItemType Directory -Force -Path $readOnlyDir | Out-Null
$readOnlyFile = Join-Path $readOnlyDir 'readonly.txt'
Set-Content -Path $readOnlyFile -Value 'readonly cleanup fixture' -Encoding Ascii
(Get-Item $readOnlyFile).Attributes = (Get-Item $readOnlyFile).Attributes -bor [System.IO.FileAttributes]::ReadOnly
(Get-Item $readOnlyDir).Attributes = (Get-Item $readOnlyDir).Attributes -bor [System.IO.FileAttributes]::ReadOnly

$cleanupOutput = (& $ScoExe cleanup filetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "cleanup failed with exit code $LASTEXITCODE`: $cleanupOutput"
}
if ($cleanupOutput -notmatch 'Removing filetool: 1\.0\.0') {
    throw "cleanup did not print Scoop-style removal output: $cleanupOutput"
}

if (Test-Path (Join-Path $Root 'apps\filetool\1.0.0')) {
    throw 'cleanup did not remove old 1.0.0 version'
}
if (!(Test-Path (Join-Path $persistData 'settings.json'))) {
    throw 'cleanup removed persisted data while deleting old version'
}
$currentSettings = Join-Path $Root 'apps\filetool\current\data\settings.json'
if (!(Test-Path $currentSettings)) {
    throw 'cleanup broke current persist data path'
}
if ((Get-Content $currentSettings -Raw) -ne '{"cleanup":true}') {
    throw 'cleanup changed persisted content'
}

foreach ($path in @(
    (Join-Path $Root 'apps\filetool\1.1.0\filetool.exe'),
    (Join-Path $Root 'apps\filetool\current\filetool.exe'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "cleanup removed expected current output: $path"
    }
}

$cacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'filetool#*.exe')
if ($cacheFiles.Count -lt 2) {
    throw "Expected cache files to remain after cleanup, found $($cacheFiles.Count)"
}

$temporaryDownload = Join-Path $Root 'cache\stale.partial.download'
Set-Content -Path $temporaryDownload -Value 'partial download' -Encoding Ascii

& $ScoExe cleanup -ak
if ($LASTEXITCODE -ne 0) {
    throw "cleanup -ak failed with exit code $LASTEXITCODE"
}

$cacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'filetool#*.exe')
if ($cacheFiles.Count -ne 1 -or $cacheFiles[0].Name -notmatch '^filetool#1\.1\.0#') {
    throw "cleanup --cache did not keep only current cache entry: $($cacheFiles.Name -join ', ')"
}
if (Test-Path $temporaryDownload) {
    throw 'cleanup --cache did not remove stale .download cache entry'
}

$regexNameRoot = Join-Path $Root 'apps\dot.name'
$regexNameCurrent = Join-Path $regexNameRoot 'current'
New-Item -ItemType Directory -Force -Path $regexNameCurrent | Out-Null
'{"version":"1.0.0"}' | Set-Content -Path (Join-Path $regexNameCurrent 'manifest.json') -Encoding Ascii

$regexNameOldCache = Join-Path $Root 'cache\dot.name#0.9.0#old.exe'
$regexNameCurrentCache = Join-Path $Root 'cache\dot.name#1.0.0#current.exe'
$regexNeighborCache = Join-Path $Root 'cache\dotXname#0.9.0#old.exe'
Set-Content -Path $regexNameOldCache -Value 'old cache' -Encoding Ascii
Set-Content -Path $regexNameCurrentCache -Value 'current cache' -Encoding Ascii
Set-Content -Path $regexNeighborCache -Value 'neighbor cache' -Encoding Ascii

$regexNameCleanupOutput = (& $ScoExe cleanup dot.name --cache) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "cleanup --cache for app name with regex metacharacter failed with exit code $LASTEXITCODE`: $regexNameCleanupOutput"
}
if (Test-Path $regexNameOldCache) {
    throw 'cleanup --cache did not remove outdated cache for literal dot app name'
}
if (!(Test-Path $regexNameCurrentCache)) {
    throw 'cleanup --cache removed current cache for literal dot app name'
}
if (!(Test-Path $regexNeighborCache)) {
    throw 'cleanup --cache treated dot in app name as a regex wildcard'
}

foreach ($path in @(
    (Join-Path $Root 'apps\filetool\1.1.0\filetool.exe'),
    (Join-Path $Root 'apps\filetool\current\filetool.exe'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "cleanup -ak removed expected current output: $path"
    }
}

$terminatorOutput = (& $ScoExe cleanup -- filetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "cleanup -- terminator failed with exit code $LASTEXITCODE`: $terminatorOutput"
}
if ($terminatorOutput -notmatch 'filetool is already clean') {
    throw "cleanup -- terminator did not treat filetool as positional: $terminatorOutput"
}

$qualifiedOutput = (& $ScoExe cleanup main/filetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "bucket-qualified cleanup failed with exit code $LASTEXITCODE`: $qualifiedOutput"
}
if ($qualifiedOutput -notmatch 'filetool is already clean') {
    throw "bucket-qualified cleanup did not normalize app name: $qualifiedOutput"
}

$duplicateOutput = (& $ScoExe cleanup filetool filetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "duplicate cleanup failed with exit code $LASTEXITCODE`: $duplicateOutput"
}
$duplicateCleanMatches = [regex]::Matches($duplicateOutput, 'filetool is already clean').Count
if ($duplicateCleanMatches -ne 1) {
    throw "duplicate cleanup should process repeated app arguments once like Scoop: $duplicateOutput"
}

$missingOutput = (& $ScoExe cleanup missingtool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "cleanup missing app should skip with exit 0, got $LASTEXITCODE`: $missingOutput"
}
if ($missingOutput -notmatch "ERROR 'missingtool' isn't installed\.") {
    throw "cleanup missing app did not print Scoop-style error: $missingOutput"
}

$scoopOutput = (& $ScoExe cleanup scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "cleanup scoop should be skipped with exit 0 like Scoop, got $LASTEXITCODE`: $scoopOutput"
}
if ($scoopOutput -match "'scoop' isn't installed" -or $scoopOutput.Trim()) {
    throw "cleanup scoop should be a quiet no-op like Scoop: $scoopOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$wrongScopeOutput = (& $ScoExe cleanup filetool --global 2>&1) -join "`n"
$wrongScopeExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($wrongScopeExitCode -ne 0) {
        throw "wrong-scope cleanup should skip with exit 0, got $wrongScopeExitCode`: $wrongScopeOutput"
    }
    if ($wrongScopeOutput -notmatch "ERROR 'filetool' isn't installed globally, but it may be installed locally\.") {
        throw "wrong-scope cleanup did not print global/local hint: $wrongScopeOutput"
    }
    if ($wrongScopeOutput -notmatch 'WARN  Try again without the --global \(or -g\) flag instead\.') {
        throw "wrong-scope cleanup did not print retry hint: $wrongScopeOutput"
    }
} else {
    if ($wrongScopeExitCode -ne 1) {
        throw "non-admin wrong-scope cleanup --global returned $wrongScopeExitCode instead of 1: $wrongScopeOutput"
    }
    if ($wrongScopeOutput -notmatch 'ERROR: you need admin rights to cleanup global apps') {
        throw "non-admin wrong-scope cleanup --global did not match Scoop admin error: $wrongScopeOutput"
    }
}
