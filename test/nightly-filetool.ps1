param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome,
    [Parameter(Mandatory = $true)][string]$ArtifactV1,
    [Parameter(Mandatory = $true)][string]$ArtifactV2
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
$source = Join-Path $Root 'sources\filetool.exe'
$manifestPath = Join-Path $bucketDir 'nightlytool.json'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $source) | Out-Null
Copy-Item -LiteralPath $ArtifactV1 -Destination $source -Force

function Write-NightlyManifest($Hash) {
    $manifest = [ordered]@{
        version = 'nightly'
        url = ([System.IO.Path]::GetFullPath($source))
        hash = $Hash
        pre_install = "Set-Content -Path (Join-Path `$dir 'pre-version.txt') -Value `$version -NoNewline -Encoding Ascii"
        post_install = "Set-Content -Path (Join-Path `$dir 'post-version.txt') -Value `$version -NoNewline -Encoding Ascii"
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$today = Get-Date -Format 'yyyyMMdd'
$todayVersion = "nightly-$today"

Write-NightlyManifest '0000000000000000000000000000000000000000000000000000000000000000'
$nightlyInstallOutput = & $ScoExe install nightlytool --no-update-scoop --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "nightly install should skip hash checks, got exit code $LASTEXITCODE`: $nightlyInstallOutput"
}
if (($nightlyInstallOutput -join "`n") -notmatch "WARN  This is a nightly version\. Downloaded files won't be verified\." -or
    ($nightlyInstallOutput -join "`n") -notmatch "'nightlytool' \($todayVersion\) was installed successfully!") {
    throw "nightly install did not warn and report dated version: $nightlyInstallOutput"
}

$currentDir = Join-Path $Root 'apps\nightlytool\current'
$todayDir = Join-Path $Root "apps\nightlytool\$todayVersion"
foreach ($path in @(
    (Join-Path $todayDir 'filetool.exe'),
    (Join-Path $currentDir 'filetool.exe'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "Missing nightly install output: $path"
    }
}
if (Test-Path (Join-Path $Root 'apps\nightlytool\nightly')) {
    throw 'nightly install used literal nightly directory instead of dated nightly version'
}

$currentManifest = Get-Content (Join-Path $currentDir 'manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne 'nightly') {
    throw "nightly manifest version was not preserved: $($currentManifest.version)"
}
$install = Get-Content (Join-Path $todayDir 'install.json') -Raw | ConvertFrom-Json
if ($install.check_hash -ne $false) {
    throw "nightly install did not record disabled hash checking: $($install | ConvertTo-Json -Compress)"
}
foreach ($hookMarker in @('pre-version.txt', 'post-version.txt')) {
    $hookVersion = Get-Content (Join-Path $todayDir $hookMarker) -Raw
    if ($hookVersion -ne $todayVersion) {
        throw "nightly hook $hookMarker did not expose dated version: $hookVersion"
    }
}
$cacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter "nightlytool#$todayVersion#*.exe")
if ($cacheFiles.Count -ne 0) {
    throw "nightly install --no-cache left cache entries: $($cacheFiles.Name -join ', ')"
}

$downloadOutput = & $ScoExe download nightlytool --force
if ($LASTEXITCODE -ne 0) {
    throw "nightly download should skip hash checks, got exit code $LASTEXITCODE`: $downloadOutput"
}
if (($downloadOutput -join "`n") -notmatch "'nightlytool' \($todayVersion\) was downloaded successfully!" -or ($downloadOutput -join "`n") -notmatch 'INFO  Skipping hash verification\.') {
    throw "nightly download did not report dated nightly version: $downloadOutput"
}

$infoOutput = & $ScoExe info nightlytool --verbose
if ($LASTEXITCODE -ne 0) {
    throw "nightly info failed with exit code $LASTEXITCODE`: $infoOutput"
}
$infoJoined = $infoOutput -join "`n"
$todayDirForOutput = $todayDir.Replace('\', '/')
if ($infoJoined -notmatch 'Version\s+:\s+nightly' -or $infoJoined -notmatch [regex]::Escape($todayDirForOutput) -or $infoJoined -notmatch 'Cached downloads:') {
    throw "nightly info did not use dated current/cache version: $infoJoined"
}

$statusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "nightly status failed with exit code $LASTEXITCODE`: $statusOutput"
}
$statusJoined = $statusOutput -join "`n"
if ($statusJoined -match 'nightlytool\s+') {
    throw "nightly status should not list the app when update_nightly is unset: $statusJoined"
}
if ($statusJoined -notmatch "WARN  Scoop bucket\(s\) out of date\. Run 'scoop update' to get the latest changes\.") {
    throw "nightly status should still report bucket update state: $statusJoined"
}

$oldVersion = 'nightly-20000101'
$oldDir = Join-Path $Root "apps\nightlytool\$oldVersion"
Copy-Item -LiteralPath $todayDir -Destination $oldDir -Recurse -Force
[System.IO.Directory]::Delete($currentDir)
New-Item -ItemType Junction -Path $currentDir -Target $oldDir | Out-Null

$oldStatusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "nightly old status failed with exit code $LASTEXITCODE`: $oldStatusOutput"
}
$oldStatusJoined = $oldStatusOutput -join "`n"
if ($oldStatusJoined -match 'nightlytool\s+') {
    throw "nightly old install should not be listed without update_nightly: $oldStatusJoined"
}
if ($oldStatusJoined -notmatch "WARN  Scoop bucket\(s\) out of date\. Run 'scoop update' to get the latest changes\.") {
    throw "nightly old install should still report bucket update state: $oldStatusJoined"
}

& $ScoExe config update_nightly true
if ($LASTEXITCODE -ne 0) {
    throw "config update_nightly failed with exit code $LASTEXITCODE"
}
$updateNightlyStatus = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status with update_nightly failed with exit code $LASTEXITCODE`: $updateNightlyStatus"
}
$joined = $updateNightlyStatus -join "`n"
if ($joined -notmatch 'nightlytool' -or $joined -notmatch $oldVersion -or $joined -notmatch $todayVersion) {
    throw "status did not honor update_nightly: $joined"
}
if ($joined -match 'Update available') {
    throw "status should not add an Update available info field for nightly updates: $joined"
}

Copy-Item -LiteralPath $ArtifactV2 -Destination $source -Force
Write-NightlyManifest '1111111111111111111111111111111111111111111111111111111111111111'
$updateOutput = & $ScoExe update nightlytool --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "nightly update failed with exit code $LASTEXITCODE`: $updateOutput"
}
if (($updateOutput -join "`n") -notmatch "WARN  This is a nightly version\. Downloaded files won't be verified\." -or
    ($updateOutput -join "`n") -notmatch "Updated 'nightlytool' from $oldVersion to $todayVersion") {
    throw "nightly update output was unexpected: $updateOutput"
}
$updatedContent = Get-Content (Join-Path $Root "apps\nightlytool\current\filetool.exe") -Raw
if ($updatedContent -notmatch 'filetool-v2') {
    throw "nightly update did not install refreshed artifact: $updatedContent"
}
$updatedCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter "nightlytool#$todayVersion#*.exe")
if ($updatedCacheFiles.Count -ne 0) {
    throw "nightly update --no-cache left cache entries: $($updatedCacheFiles.Name -join ', ')"
}
