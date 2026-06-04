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
$manifestPath = Join-Path $bucketDir 'filetool.json'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

function Write-Manifest($Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = [System.IO.Path]::GetFileName($Artifact)
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$globalNoAppOutput = & $ScoExe update --global 2>&1
$globalNoAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($globalNoAppExitCode -ne 1) {
    throw "update --global without an app returned $globalNoAppExitCode instead of 1: $globalNoAppOutput"
}
if (($globalNoAppOutput -join "`n") -notmatch 'ERROR scoop update: --global is invalid when <app> is not specified\.') {
    throw "update --global without an app did not match Scoop error: $globalNoAppOutput"
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $globalNonAdminOutput = & $ScoExe update --global definitely-missing-global-tool 2>&1
    $globalNonAdminExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($globalNonAdminExitCode -ne 1) {
        throw "non-admin update --global returned $globalNonAdminExitCode instead of 1: $globalNonAdminOutput"
    }
    if (($globalNonAdminOutput -join "`n") -notmatch 'ERROR: You need admin rights to update global apps\.') {
        throw "non-admin update --global did not match Scoop admin error: $globalNonAdminOutput"
    }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$noCacheNoAppOutput = & $ScoExe update --no-cache 2>&1
$noCacheNoAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($noCacheNoAppExitCode -ne 1) {
    throw "update --no-cache without an app returned $noCacheNoAppExitCode instead of 1: $noCacheNoAppOutput"
}
if (($noCacheNoAppOutput -join "`n") -notmatch 'ERROR scoop update: --no-cache is invalid when <app> is not specified\.') {
    throw "update --no-cache without an app did not match Scoop error: $noCacheNoAppOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$archOutput = & $ScoExe update --arch 64bit filetool 2>&1
$archExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($archExitCode -ne 1) {
    throw "update --arch returned $archExitCode instead of 1: $archOutput"
}
if (($archOutput -join "`n") -notmatch 'sco update: Option --arch not recognized\.') {
    throw "update --arch did not match Scoop getopt error: $archOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$archEqualsOutput = & $ScoExe update --arch=64bit filetool 2>&1
$archEqualsExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($archEqualsExitCode -ne 1) {
    throw "update --arch=64bit returned $archEqualsExitCode instead of 1: $archEqualsOutput"
}
if (($archEqualsOutput -join "`n") -notmatch 'sco update: Option --arch=64bit not recognized\.') {
    throw "update --arch=64bit did not match Scoop getopt error: $archEqualsOutput"
}

Write-Manifest '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
& $ScoExe install filetool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$v2Source = Join-Path $Root 'sources\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $v2Source) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $v2Source -Force

$updateHookMarkerDir = Join-Path $Root 'update-hook-markers'
$updateHookManifestPath = Join-Path $bucketDir 'updatehooktool.json'
$updateHookMarker = $updateHookMarkerDir.Replace('\', '\\')
@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
    pre_uninstall = @(
        "New-Item -ItemType Directory -Force -Path '$updateHookMarker' | Out-Null",
        "Set-Content -Path (Join-Path '$updateHookMarker' 'pre_uninstall.txt') -Value `$version -NoNewline -Encoding Ascii"
    )
    uninstaller = [ordered]@{
        script = "Set-Content -Path (Join-Path '$updateHookMarker' 'uninstaller.txt') -Value `$app -NoNewline -Encoding Ascii"
    }
    post_uninstall = @(
        "Set-Content -Path (Join-Path '$updateHookMarker' 'post_uninstall.txt') -Value `$architecture -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path '$updateHookMarker' 'post_uninstall_dir_exists.txt') -Value (Test-Path -LiteralPath `$dir) -NoNewline -Encoding Ascii"
    )
} | ConvertTo-Json -Depth 5 | Set-Content -Path $updateHookManifestPath -Encoding UTF8
& $ScoExe install updatehooktool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "update hook fixture install failed with exit code $LASTEXITCODE"
}
@{
    version = '1.1.0'
    url = ([System.IO.Path]::GetFullPath($v2Source))
    hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
    bin = 'filetool.exe'
} | ConvertTo-Json -Depth 5 | Set-Content -Path $updateHookManifestPath -Encoding UTF8
$updateHookOutput = (& $ScoExe update updatehooktool --no-cache) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "update hook fixture update failed with exit code $LASTEXITCODE`: $updateHookOutput"
}
foreach ($item in @{
    'pre_uninstall.txt' = '1.0.0'
    'uninstaller.txt' = 'updatehooktool'
    'post_uninstall.txt' = '64bit'
    'post_uninstall_dir_exists.txt' = 'True'
}.GetEnumerator()) {
    $path = Join-Path $updateHookMarkerDir $item.Key
    if (!(Test-Path $path)) {
        throw "update did not run old manifest hook: $($item.Key). Output: $updateHookOutput"
    }
    $content = Get-Content $path -Raw
    if ($content -ne $item.Value) {
        throw "update old manifest hook $($item.Key) wrote '$content', expected '$($item.Value)'"
    }
}
$updateHookCurrentManifest = Get-Content (Join-Path $Root 'apps\updatehooktool\current\manifest.json') -Raw | ConvertFrom-Json
if ($updateHookCurrentManifest.version -ne '1.1.0') {
    throw "update hook fixture did not switch current manifest to 1.1.0"
}

Write-Manifest '1.1.0' $v2Source '0000000000000000000000000000000000000000000000000000000000000000'
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$badHashUpdateOutput = & $ScoExe update filetool --no-cache 2>&1
$badHashUpdateExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badHashUpdateExitCode -ne 1) {
    throw "bad-hash update returned $badHashUpdateExitCode instead of 1: $badHashUpdateOutput"
}
$badHashUpdateJoined = $badHashUpdateOutput -join "`n"
if ($badHashUpdateJoined -notmatch 'Downloading new version' -or
    $badHashUpdateJoined -match "Uninstalling 'filetool'") {
    throw "bad-hash update did not abort before uninstalling the old app: $badHashUpdateJoined"
}
if (Test-Path (Join-Path $Root 'apps\filetool\1.1.0')) {
    throw 'bad-hash update left a failed new version directory behind'
}
foreach ($path in @(
    (Join-Path $Root 'apps\filetool\current\filetool.exe'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "bad-hash update removed existing installation integration: $path"
    }
}
$currentAfterBadHash = Get-Content (Join-Path $Root 'apps\filetool\current\filetool.exe') -Raw
if ($currentAfterBadHash -notmatch 'fixture') {
    throw "bad-hash update changed current artifact: $currentAfterBadHash"
}

Write-Manifest '1.1.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
$installAgainOutput = & $ScoExe install filetool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install of already installed app failed with exit code $LASTEXITCODE`: $installAgainOutput"
}
if (($installAgainOutput -join "`n") -notmatch "'filetool' \(1\.0\.0\) is already installed" -or ($installAgainOutput -join "`n") -notmatch "Use 'sco update filetool' to install a new version") {
    throw "install of already installed app did not match Scoop warning: $installAgainOutput"
}
if (Test-Path (Join-Path $Root 'apps\filetool\1.1.0')) {
    throw 'install upgraded an already installed app instead of leaving update to scoop update'
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$mixedUpdateOutput = & $ScoExe update missing-update-tool filetool 2>&1
$mixedUpdateExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($mixedUpdateExitCode -ne 0) {
    throw "update with one missing app returned $mixedUpdateExitCode instead of 0 like Scoop: $mixedUpdateOutput"
}
$mixedUpdateJoined = $mixedUpdateOutput -join "`n"
if ($mixedUpdateJoined -notmatch "'missing-update-tool' isn't installed\." -or
    $mixedUpdateJoined -notmatch "Updating 'filetool' \(1\.0\.0 -> 1\.1\.0\)" -or
    $mixedUpdateJoined -notmatch 'Downloading new version' -or
    $mixedUpdateJoined -notmatch "Uninstalling 'filetool' \(1\.0\.0\)" -or
    $mixedUpdateJoined -notmatch "Updated 'filetool' from 1\.0\.0 to 1\.1\.0") {
    throw "update with one missing app did not report both failure and successful update: $mixedUpdateJoined"
}
$currentManifest = Get-Content (Join-Path $Root 'apps\filetool\current\manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne '1.1.0') {
    throw 'update stopped before processing the installed app after a missing app'
}

$terminatorOutput = & $ScoExe update -- filetool
if ($LASTEXITCODE -ne 0) {
    throw "update -- terminator failed with exit code $LASTEXITCODE`: $terminatorOutput"
}
if (($terminatorOutput -join "`n") -notmatch 'filetool: 1\.1\.0 \(latest version\)') {
    throw "update -- terminator output was unexpected: $terminatorOutput"
}

$duplicateLatestOutput = & $ScoExe update filetool filetool
if ($LASTEXITCODE -ne 0) {
    throw "update with a duplicate app failed with exit code $LASTEXITCODE`: $duplicateLatestOutput"
}
$duplicateLatestJoined = $duplicateLatestOutput -join "`n"
$duplicateLatestCount = [regex]::Matches($duplicateLatestJoined, 'filetool: 1\.1\.0 \(latest version\)').Count
if ($duplicateLatestCount -ne 1) {
    throw "update with a duplicate app reported latest version $duplicateLatestCount times instead of once: $duplicateLatestJoined"
}

$quietLatestOutput = & $ScoExe update filetool --quiet
if ($LASTEXITCODE -ne 0) {
    throw "update filetool --quiet failed with exit code $LASTEXITCODE`: $quietLatestOutput"
}
$quietLatestJoined = $quietLatestOutput -join "`n"
if ($quietLatestJoined -notmatch 'filetool: 1\.1\.0 \(latest version\)') {
    throw "explicit update --quiet should still report current app like Scoop: $quietLatestJoined"
}

$currentPath = Join-Path $Root 'apps\filetool\current'
[System.IO.Directory]::Delete($currentPath)
$repairLatestOutput = & $ScoExe update filetool --quiet
if ($LASTEXITCODE -ne 0) {
    throw "update repair for missing current link failed with exit code $LASTEXITCODE`: $repairLatestOutput"
}
$repairLatestJoined = $repairLatestOutput -join "`n"
if ($repairLatestJoined -notmatch 'INFO  Repair previous failed installation of filetool\.' -or
    $repairLatestJoined -notmatch "ERROR 'filetool' isn't installed correctly\." -or
    $repairLatestJoined -notmatch 'Resetting filetool \(1\.1\.0\)\.' -or
    $repairLatestJoined -notmatch 'filetool: 1\.1\.0 \(latest version\)' -or
    !(Test-Path (Join-Path $currentPath 'filetool.exe'))) {
    throw "explicit update should repair a failed installed layout before reporting latest version: $repairLatestJoined"
}

foreach ($path in @(
    (Join-Path $Root 'apps\filetool\1.0.0\filetool.exe'),
    (Join-Path $Root 'apps\filetool\1.1.0\filetool.exe'),
    (Join-Path $Root 'apps\filetool\current\filetool.exe'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "Missing expected update output: $path"
    }
}

$currentContent = Get-Content (Join-Path $Root 'apps\filetool\current\filetool.exe') -Raw
if ($currentContent -ne '@echo filetool-v2') {
    throw "current did not switch to updated artifact: $currentContent"
}

$currentManifest = Get-Content (Join-Path $Root 'apps\filetool\current\manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne '1.1.0') {
    throw "current manifest did not switch to 1.1.0"
}

$oldVersionInstallOutput = (& $ScoExe install filetool@1.0.0 --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install filetool@1.0.0 after update failed with exit code $LASTEXITCODE`: $oldVersionInstallOutput"
}
if ($oldVersionInstallOutput -notmatch "WARN  'filetool' \(1\.0\.0\) is already installed\." -or
    $oldVersionInstallOutput -notmatch "WARN  Use 'sco update filetool' to install a new version\." -or
    $oldVersionInstallOutput -match "Installing 'filetool'") {
    throw "specific-version install should report already installed even when that version is not current: $oldVersionInstallOutput"
}

$directManifestDir = Join-Path $Root 'direct-manifests'
$directManifestPath = Join-Path $directManifestDir 'directtool.json'
$directSource = Join-Path $Root 'sources\directtool\filetool.exe'
New-Item -ItemType Directory -Force -Path $directManifestDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $directSource) | Out-Null

function Write-DirectManifest($Version, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($directSource))
        hash = $Hash
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path $directManifestPath -Encoding UTF8
}

Copy-Item -LiteralPath $ArtifactV1 -Destination $directSource -Force
Write-DirectManifest '1.0.0' '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$directInstallOutput = & $ScoExe install $directManifestPath --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "direct manifest install failed with exit code $LASTEXITCODE`: $directInstallOutput"
}

Copy-Item -LiteralPath $ArtifactV2 -Destination $directSource -Force
Write-DirectManifest '1.1.0' 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
$directUpdateOutput = & $ScoExe update directtool --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "direct manifest update failed with exit code $LASTEXITCODE`: $directUpdateOutput"
}
$directUpdateJoined = $directUpdateOutput -join "`n"
if ($directUpdateJoined -notmatch "Updating 'directtool' \(1\.0\.0 -> 1\.1\.0\)" -or
    $directUpdateJoined -notmatch "Updated 'directtool' from 1\.0\.0 to 1\.1\.0") {
    throw "direct manifest update did not use installed manifest source: $directUpdateJoined"
}
$directContent = Get-Content (Join-Path $Root 'apps\directtool\current\filetool.exe') -Raw
if ($directContent -ne '@echo filetool-v2') {
    throw "direct manifest update did not switch artifact: $directContent"
}

$sourceBucketDir = Join-Path $Root 'buckets\zzsource\bucket'
New-Item -ItemType Directory -Force -Path $sourceBucketDir | Out-Null

function Write-SourcePickManifest($Directory, $Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = [System.IO.Path]::GetFileName($Artifact)
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $Directory 'sourcepick.json') -Encoding UTF8
}

Write-SourcePickManifest $sourceBucketDir '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$sourceInstallOutput = & $ScoExe install zzsource/sourcepick --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "source bucket install failed with exit code $LASTEXITCODE`: $sourceInstallOutput"
}

$sourcePickV2 = Join-Path $Root 'sources\sourcepick\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourcePickV2) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $sourcePickV2 -Force
Write-SourcePickManifest $bucketDir '9.9.9' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
Write-SourcePickManifest $sourceBucketDir '1.1.0' $sourcePickV2 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
$sourceUpdateOutput = & $ScoExe update sourcepick --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "source bucket update failed with exit code $LASTEXITCODE`: $sourceUpdateOutput"
}
$sourceUpdateJoined = $sourceUpdateOutput -join "`n"
if ($sourceUpdateJoined -notmatch "Updating 'sourcepick' \(1\.0\.0 -> 1\.1\.0\)" -or
    $sourceUpdateJoined -match "9\.9\.9" -or
    $sourceUpdateJoined -notmatch "Updated 'sourcepick' from 1\.0\.0 to 1\.1\.0") {
    throw "update did not reuse installed bucket source when another bucket had the same app: $sourceUpdateJoined"
}
$sourcePickManifest = Get-Content (Join-Path $Root 'apps\sourcepick\current\manifest.json') -Raw | ConvertFrom-Json
if ($sourcePickManifest.version -ne '1.1.0') {
    throw "source bucket update installed $($sourcePickManifest.version) instead of 1.1.0"
}

function Write-DependencyUpdateManifest($Name, $Version, $Artifact, $Hash, $Depends = $null) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = [System.IO.Path]::GetFileName($Artifact)
    }
    if ($Depends) {
        $manifest.depends = $Depends
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir "$Name.json") -Encoding UTF8
}

Write-DependencyUpdateManifest 'depupdate' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$depUpdateInstallOutput = & $ScoExe install depupdate --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "depupdate install failed with exit code $LASTEXITCODE`: $depUpdateInstallOutput"
}

Write-DependencyUpdateManifest 'newdep' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
Write-DependencyUpdateManifest 'depupdate' '1.1.0' $ArtifactV2 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824' 'newdep'
$depUpdateOutput = & $ScoExe update depupdate --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "depupdate update failed with exit code $LASTEXITCODE`: $depUpdateOutput"
}
$depUpdateJoined = $depUpdateOutput -join "`n"
if ($depUpdateJoined -notmatch "Installing 'newdep' \(1\.0\.0\) \[64bit\] from 'main' bucket" -or
    $depUpdateJoined -notmatch "'newdep' \(1\.0\.0\) was installed successfully!" -or
    $depUpdateJoined -notmatch "Updated 'depupdate' from 1\.0\.0 to 1\.1\.0") {
    throw "update did not install a newly introduced dependency before completing app update: $depUpdateJoined"
}
if (!(Test-Path (Join-Path $Root 'apps\newdep\current\filetool.exe'))) {
    throw 'update did not install missing dependency newdep'
}

Write-DependencyUpdateManifest 'installeddep' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$installedDepOutput = & $ScoExe install installeddep --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "installeddep install failed with exit code $LASTEXITCODE`: $installedDepOutput"
}
Write-DependencyUpdateManifest 'transitiveupdate' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$transitiveUpdateInstallOutput = & $ScoExe install transitiveupdate --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "transitiveupdate install failed with exit code $LASTEXITCODE`: $transitiveUpdateInstallOutput"
}

Write-DependencyUpdateManifest 'transitivedep' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
Write-DependencyUpdateManifest 'installeddep' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b' 'transitivedep'
Write-DependencyUpdateManifest 'transitiveupdate' '1.1.0' $ArtifactV2 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824' 'installeddep'
$transitiveUpdateOutput = & $ScoExe update transitiveupdate --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "transitiveupdate update failed with exit code $LASTEXITCODE`: $transitiveUpdateOutput"
}
$transitiveUpdateJoined = $transitiveUpdateOutput -join "`n"
if ($transitiveUpdateJoined -match "Installing 'installeddep'" -or
    $transitiveUpdateJoined -notmatch "Installing 'transitivedep' \(1\.0\.0\) \[64bit\] from 'main' bucket" -or
    $transitiveUpdateJoined -notmatch "Updated 'transitiveupdate' from 1\.0\.0 to 1\.1\.0") {
    throw "update should install missing transitive dependencies without reinstalling already-installed direct dependencies: $transitiveUpdateJoined"
}
if (!(Test-Path (Join-Path $Root 'apps\transitivedep\current\filetool.exe'))) {
    throw 'update did not install missing transitive dependency transitivedep'
}

Write-DependencyUpdateManifest 'indepupdate' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$indepUpdateInstallOutput = & $ScoExe install indepupdate --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "indepupdate install failed with exit code $LASTEXITCODE`: $indepUpdateInstallOutput"
}

Write-DependencyUpdateManifest 'newindepdep' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
Write-DependencyUpdateManifest 'indepupdate' '1.1.0' $ArtifactV2 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824' 'newindepdep'
$indepUpdateOutput = & $ScoExe update indepupdate --independent --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "indepupdate update failed with exit code $LASTEXITCODE`: $indepUpdateOutput"
}
$indepUpdateJoined = $indepUpdateOutput -join "`n"
if ($indepUpdateJoined -match "Installing 'newindepdep'" -or $indepUpdateJoined -notmatch "Updated 'indepupdate' from 1\.0\.0 to 1\.1\.0") {
    throw "update --independent should update the app without installing new dependencies: $indepUpdateJoined"
}
if (Test-Path (Join-Path $Root 'apps\newindepdep')) {
    throw 'update --independent installed dependency newindepdep'
}

$remoteManifestFile = Join-Path $Root 'sources\remoteurl\remoteurl.json'
$remoteArtifact = Join-Path $Root 'sources\remoteurl\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $remoteManifestFile) | Out-Null

function Write-RemoteUrlManifest($Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path $remoteManifestFile -Encoding UTF8
}

Copy-Item -LiteralPath $ArtifactV1 -Destination $remoteArtifact -Force
Write-RemoteUrlManifest '1.0.0' $remoteArtifact '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'

$remotePrefix = 'http://127.0.0.1:18214/'
$remoteManifestUrl = $remotePrefix + 'remoteurl.json'
$remoteJob = Start-Job -ScriptBlock {
    param($Prefix, $ManifestFile)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        for ($i = 0; $i -lt 3; $i++) {
            $context = $listener.GetContext()
            if ($context.Request.Url.AbsolutePath -ne '/remoteurl.json') {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('missing')
                $context.Response.StatusCode = 404
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                continue
            }
            $body = Get-Content -LiteralPath $ManifestFile -Raw
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'application/json'
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList $remotePrefix, $remoteManifestFile

Start-Sleep -Milliseconds 300
try {
    $remoteInstallOutput = & $ScoExe install $remoteManifestUrl --no-update-scoop
    if ($LASTEXITCODE -ne 0) {
        throw "remote URL manifest install failed with exit code $LASTEXITCODE`: $remoteInstallOutput"
    }
    $remoteInstallInfo = Get-Content (Join-Path $Root 'apps\remoteurl\current\install.json') -Raw | ConvertFrom-Json
    if ($remoteInstallInfo.url -ne $remoteManifestUrl) {
        throw "remote URL manifest install did not preserve original URL: $($remoteInstallInfo | ConvertTo-Json -Compress)"
    }

    Copy-Item -LiteralPath $ArtifactV2 -Destination $remoteArtifact -Force
    Write-RemoteUrlManifest '1.1.0' $remoteArtifact 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
    $remoteUpdateOutput = & $ScoExe update remoteurl --no-cache
    if ($LASTEXITCODE -ne 0) {
        throw "remote URL manifest update failed with exit code $LASTEXITCODE`: $remoteUpdateOutput"
    }
    $remoteUpdateJoined = $remoteUpdateOutput -join "`n"
    if ($remoteUpdateJoined -notmatch "Updating 'remoteurl' \(1\.0\.0 -> 1\.1\.0\)" -or
        $remoteUpdateJoined -notmatch "Updated 'remoteurl' from 1\.0\.0 to 1\.1\.0") {
        throw "remote URL manifest update did not reuse original URL: $remoteUpdateJoined"
    }
    $remoteUpdatedInfo = Get-Content (Join-Path $Root 'apps\remoteurl\current\install.json') -Raw | ConvertFrom-Json
    if ($remoteUpdatedInfo.url -ne $remoteManifestUrl) {
        throw "remote URL manifest update did not preserve original URL for future updates: $($remoteUpdatedInfo | ConvertTo-Json -Compress)"
    }

    Copy-Item -LiteralPath $ArtifactV1 -Destination $remoteArtifact -Force
    Write-RemoteUrlManifest '1.2.0' $remoteArtifact '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    $remoteSecondUpdateOutput = & $ScoExe update remoteurl --no-cache
    if ($LASTEXITCODE -ne 0) {
        throw "second remote URL manifest update failed with exit code $LASTEXITCODE`: $remoteSecondUpdateOutput"
    }
    $remoteSecondUpdateJoined = $remoteSecondUpdateOutput -join "`n"
    if ($remoteSecondUpdateJoined -notmatch "Updating 'remoteurl' \(1\.1\.0 -> 1\.2\.0\)" -or
        $remoteSecondUpdateJoined -notmatch "Updated 'remoteurl' from 1\.1\.0 to 1\.2\.0") {
        throw "second remote URL manifest update did not fetch the original URL again: $remoteSecondUpdateJoined"
    }
} finally {
    Wait-Job $remoteJob -Timeout 5 | Out-Null
    Receive-Job $remoteJob | Out-Null
    Remove-Job $remoteJob -Force
}
