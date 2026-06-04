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
$manifestPath = Join-Path $bucketDir 'forcetool.json'
$source = Join-Path $Root 'sources\filetool.exe'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $source) | Out-Null
Copy-Item -LiteralPath $ArtifactV1 -Destination $source -Force

function Write-Manifest($Hash) {
    $manifest = [ordered]@{
        version = '1.0.0'
        url = ([System.IO.Path]::GetFullPath($source))
        hash = $Hash
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

Write-Manifest '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
& $ScoExe install forcetool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

Copy-Item -LiteralPath $ArtifactV2 -Destination $source -Force
Write-Manifest 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'

$updateOutput = & $ScoExe update forcetool --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "same-version update failed with exit code $LASTEXITCODE`: $updateOutput"
}
if (($updateOutput -join "`n") -notmatch 'forcetool: 1\.0\.0 \(latest version\)') {
    throw "same-version update did not report up-to-date: $updateOutput"
}

$currentContent = Get-Content (Join-Path $Root 'apps\forcetool\current\filetool.exe') -Raw
if ($currentContent -notmatch 'fixture') {
    throw "same-version update without force changed installed artifact: $currentContent"
}

$forceOutput = & $ScoExe update forcetool --force --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "update --force failed with exit code $LASTEXITCODE`: $forceOutput"
}
$forceJoined = $forceOutput -join "`n"
if ($forceJoined -notmatch 'Downloading new version' -or
    $forceJoined -notmatch "Uninstalling 'forcetool' \(1\.0\.0\)" -or
    $forceJoined -notmatch "Reinstalled 'forcetool' \(1\.0\.0\)") {
    throw "update --force output was unexpected: $forceJoined"
}

$currentContent = Get-Content (Join-Path $Root 'apps\forcetool\current\filetool.exe') -Raw
if ($currentContent -notmatch 'filetool-v2') {
    throw "update --force did not reinstall same-version artifact: $currentContent"
}

$oldDirs = @(Get-ChildItem (Join-Path $Root 'apps\forcetool') -Directory -Filter '_1.0.0.old*')
if ($oldDirs.Count -ne 1) {
    throw "update --force did not preserve one old version directory: $($oldDirs.Name -join ', ')"
}
if (!(Test-Path (Join-Path $oldDirs[0].FullName 'filetool.exe'))) {
    throw 'old version backup does not contain previous artifact'
}

function Write-VersionedManifest($Version, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($source))
        hash = $Hash
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}

Copy-Item -LiteralPath $ArtifactV2 -Destination $source -Force
Write-VersionedManifest '1.10.0' 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
& $ScoExe update forcetool --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "update to newer numeric version failed with exit code $LASTEXITCODE"
}

Copy-Item -LiteralPath $ArtifactV1 -Destination $source -Force
Write-VersionedManifest '1.9.9' '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$downgradeOutput = & $ScoExe update forcetool --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "update with older bucket version failed with exit code $LASTEXITCODE`: $downgradeOutput"
}
if (($downgradeOutput -join "`n") -notmatch 'forcetool: 1\.10\.0 \(latest version\)') {
    throw "update treated older bucket version as an update: $downgradeOutput"
}
$currentManifest = Get-Content (Join-Path $Root 'apps\forcetool\current\manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne '1.10.0') {
    throw "update downgraded newer installed version: $($currentManifest.version)"
}

& $ScoExe config force_update true
if ($LASTEXITCODE -ne 0) {
    throw "config force_update failed with exit code $LASTEXITCODE"
}
$forceConfigOutput = & $ScoExe update forcetool --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "update with force_update config failed with exit code $LASTEXITCODE`: $forceConfigOutput"
}
$forceConfigJoined = $forceConfigOutput -join "`n"
if ($forceConfigJoined -notmatch 'Downloading new version' -or
    $forceConfigJoined -notmatch "Uninstalling 'forcetool' \(1\.10\.0\)" -or
    $forceConfigJoined -notmatch "Updated 'forcetool' from 1\.10\.0 to 1\.9\.9") {
    throw "update did not honor force_update config mismatch: $forceConfigJoined"
}
$currentManifest = Get-Content (Join-Path $Root 'apps\forcetool\current\manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne '1.9.9') {
    throw "force_update config did not install mismatched manifest version: $($currentManifest.version)"
}

& $ScoExe cleanup forcetool
if ($LASTEXITCODE -ne 0) {
    throw "cleanup after force update failed with exit code $LASTEXITCODE"
}
if (Test-Path $oldDirs[0].FullName) {
    throw 'cleanup did not remove forced update backup directory'
}
