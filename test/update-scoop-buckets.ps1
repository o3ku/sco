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

$repo = Join-Path $Root '..\update-scoop-source'
if (Test-Path $repo) {
    Remove-Item -LiteralPath $repo -Recurse -Force
}
$repoBucket = Join-Path $repo 'bucket'
New-Item -ItemType Directory -Force -Path $repoBucket | Out-Null

function Write-AppManifest($Name, $Description, [bool]$IncludeBin = $true) {
    $manifest = [ordered]@{
        version = '1.0.0'
        description = $Description
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    }
    if ($IncludeBin) {
        $manifest.bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $repoBucket "$Name.json") -Encoding UTF8
}

Write-AppManifest 'filetool' 'Original app'
git -C $repo init | Out-Null
git -C $repo config user.email sco-test@example.invalid | Out-Null
git -C $repo config user.name sco-test | Out-Null
git -C $repo add bucket/filetool.json | Out-Null
git -C $repo commit -m 'add filetool' | Out-Null

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe bucket add gitlocal $repo
if ($LASTEXITCODE -ne 0) {
    throw "bucket add git failed with exit code $LASTEXITCODE"
}

& $ScoExe config use_sqlite_cache true | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config use_sqlite_cache before bucket update failed with exit code $LASTEXITCODE"
}
$indexPath = Join-Path $Root 'cache\buckets.index.json'

Write-AppManifest 'scoopupdated' 'Added by explicit update scoop'
git -C $repo add bucket/scoopupdated.json | Out-Null
git -C $repo commit -m 'add scoopupdated' | Out-Null

$explicitOutput = & $ScoExe update scoop
if ($LASTEXITCODE -ne 0) {
    throw "update scoop failed with exit code $LASTEXITCODE`: $explicitOutput"
}
$explicitJoined = $explicitOutput -join "`n"
if ($explicitJoined -notmatch "Updated 'gitlocal' bucket" -or $explicitJoined -notmatch 'Scoop buckets were updated successfully') {
    throw "update scoop did not use bucket update path: $explicitJoined"
}
if ($explicitJoined -notmatch 'INFO  Updating cache') {
    throw "update scoop with use_sqlite_cache did not report cache refresh: $explicitJoined"
}
if (!(Test-Path (Join-Path $Root 'buckets\gitlocal\bucket\scoopupdated.json'))) {
    throw 'update scoop did not pull new bucket manifest'
}
$index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
if (-not ($index.entries | Where-Object { $_.bucket -eq 'gitlocal' -and $_.name -eq 'scoopupdated' })) {
    throw "update scoop with use_sqlite_cache did not refresh manifest index: $($index | ConvertTo-Json -Compress)"
}

$repeatExplicitOutput = & $ScoExe update scoop
if ($LASTEXITCODE -ne 0) {
    throw "repeat update scoop without bucket changes failed with exit code $LASTEXITCODE`: $repeatExplicitOutput"
}
$repeatExplicitJoined = $repeatExplicitOutput -join "`n"
if ($repeatExplicitJoined -match 'INFO  Updating cache') {
    throw "repeat update scoop without bucket changes should not report cache refresh like Scoop: $repeatExplicitJoined"
}

$configPath = Join-Path $ConfigHome 'scoop\config.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ([string]$config.last_update -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    throw "update scoop did not write ISO last_update: $($config.last_update)"
}
if ([string]$config.scoop_repo -ne 'https://github.com/ScoopInstaller/Scoop' -or [string]$config.scoop_branch -ne 'master') {
    throw "update scoop did not persist default Scoop update channel config: $($config | ConvertTo-Json -Compress)"
}

& $ScoExe config scoop_repo https://example.invalid/custom-scoop | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config custom scoop_repo failed with exit code $LASTEXITCODE"
}
& $ScoExe config scoop_branch develop | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config custom scoop_branch failed with exit code $LASTEXITCODE"
}
& $ScoExe update scoop | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "update scoop after custom update channel config failed with exit code $LASTEXITCODE"
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ([string]$config.scoop_repo -ne 'https://example.invalid/custom-scoop' -or [string]$config.scoop_branch -ne 'develop') {
    throw "update scoop should not overwrite custom Scoop update channel config: $($config | ConvertTo-Json -Compress)"
}

$staleNoChangeLastUpdate = (Get-Date).AddHours(-4).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
& $ScoExe config last_update $staleNoChangeLastUpdate | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config stale last_update before no-change refresh failed with exit code $LASTEXITCODE"
}
$noChangeRefreshOutput = & $ScoExe download filetool --force
if ($LASTEXITCODE -ne 0) {
    throw "download with stale last_update and no bucket changes failed with exit code $LASTEXITCODE`: $noChangeRefreshOutput"
}
$noChangeRefreshJoined = $noChangeRefreshOutput -join "`n"
if ($noChangeRefreshJoined -notmatch "Updated 'gitlocal' bucket" -or
    $noChangeRefreshJoined -notmatch 'Scoop buckets were updated successfully' -or
    $noChangeRefreshJoined -match 'INFO  Updating cache') {
    throw "stale last_update without bucket changes should sync buckets and skip cache refresh like Scoop: $noChangeRefreshJoined"
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ([string]$config.last_update -eq $staleNoChangeLastUpdate -or [string]$config.last_update -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    throw "stale last_update without bucket changes did not refresh last_update: $($config.last_update)"
}

Write-AppManifest 'bareupdated' 'Added by bare update'
git -C $repo add bucket/bareupdated.json | Out-Null
git -C $repo commit -m 'add bareupdated' | Out-Null

$bareOutput = & $ScoExe update
if ($LASTEXITCODE -ne 0) {
    throw "bare update failed with exit code $LASTEXITCODE`: $bareOutput"
}
if (!(Test-Path (Join-Path $Root 'buckets\gitlocal\bucket\bareupdated.json'))) {
    throw 'bare update did not pull new bucket manifest'
}

Write-AppManifest 'heldcoreupdated' 'Added while Scoop Core is held'
git -C $repo add bucket/heldcoreupdated.json | Out-Null
git -C $repo commit -m 'add heldcoreupdated' | Out-Null
& $ScoExe config hold_update_until (Get-Date).AddDays(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config hold_update_until failed with exit code $LASTEXITCODE"
}

$heldCoreOutput = & $ScoExe update scoop
if ($LASTEXITCODE -ne 0) {
    throw "update scoop while held failed with exit code $LASTEXITCODE`: $heldCoreOutput"
}
$heldCoreJoined = $heldCoreOutput -join "`n"
if ($heldCoreJoined -notmatch 'Skipping self-update of Scoop Core until' -or
    $heldCoreJoined -notmatch "Updated 'gitlocal' bucket" -or
    $heldCoreJoined -notmatch 'Scoop buckets were updated successfully') {
    throw "update scoop while held did not warn and continue bucket update like Scoop: $heldCoreJoined"
}
if (!(Test-Path (Join-Path $Root 'buckets\gitlocal\bucket\heldcoreupdated.json'))) {
    throw 'update scoop while held did not pull bucket manifest'
}

& $ScoExe config rm hold_update_until | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config rm hold_update_until failed with exit code $LASTEXITCODE"
}

& $ScoExe install filetool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install before implicit update failed with exit code $LASTEXITCODE"
}

$oldLastUpdate = (Get-Date).AddHours(-4).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

Write-AppManifest 'implicitupdated' 'Added by implicit app update'
git -C $repo add bucket/implicitupdated.json | Out-Null
git -C $repo commit -m 'add implicitupdated' | Out-Null
& $ScoExe config last_update $oldLastUpdate | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config last_update failed with exit code $LASTEXITCODE"
}

$implicitOutput = & $ScoExe update filetool --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "implicit stale update before app update failed with exit code $LASTEXITCODE`: $implicitOutput"
}
$implicitJoined = $implicitOutput -join "`n"
if ($implicitJoined -notmatch "Updated 'gitlocal' bucket" -or
    $implicitJoined -notmatch 'Scoop buckets were updated successfully' -or
    $implicitJoined -notmatch 'filetool: 1\.0\.0 \(latest version\)') {
    throw "update app did not refresh stale Scoop buckets before app status: $implicitJoined"
}
if (!(Test-Path (Join-Path $Root 'buckets\gitlocal\bucket\implicitupdated.json'))) {
    throw 'implicit update before app update did not pull new bucket manifest'
}

Write-AppManifest 'downloadupdated' 'Added before download'
git -C $repo add bucket/downloadupdated.json | Out-Null
git -C $repo commit -m 'add downloadupdated' | Out-Null
& $ScoExe config last_update $oldLastUpdate | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config last_update before download failed with exit code $LASTEXITCODE"
}

$downloadOutput = & $ScoExe download filetool --force
if ($LASTEXITCODE -ne 0) {
    throw "download with implicit stale update failed with exit code $LASTEXITCODE`: $downloadOutput"
}
$downloadJoined = $downloadOutput -join "`n"
if ($downloadJoined -notmatch "Updated 'gitlocal' bucket" -or
    $downloadJoined -notmatch 'Scoop buckets were updated successfully' -or
    $downloadJoined -notmatch 'WARN  Cache is being ignored\.' -or
    $downloadJoined -notmatch "'filetool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download did not refresh stale Scoop buckets before downloading: $downloadJoined"
}
if (!(Test-Path (Join-Path $Root 'buckets\gitlocal\bucket\downloadupdated.json'))) {
    throw 'implicit update before download did not pull new bucket manifest'
}

Write-AppManifest 'skippedupdated' 'Added while no-update-scoop is set'
git -C $repo add bucket/skippedupdated.json | Out-Null
git -C $repo commit -m 'add skippedupdated' | Out-Null
& $ScoExe config last_update $oldLastUpdate | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config last_update before no-update-scoop failed with exit code $LASTEXITCODE"
}

$skipOutput = & $ScoExe download filetool --force --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "download --no-update-scoop failed with exit code $LASTEXITCODE`: $skipOutput"
}
$skipJoined = $skipOutput -join "`n"
if ($skipJoined -notmatch 'WARN  Scoop is out of date\.' -or $skipJoined -match "Updated 'gitlocal' bucket") {
    throw "download --no-update-scoop did not warn and skip stale bucket refresh: $skipJoined"
}
if (Test-Path (Join-Path $Root 'buckets\gitlocal\bucket\skippedupdated.json')) {
    throw 'download --no-update-scoop unexpectedly pulled stale bucket changes'
}

Write-AppManifest 'installupdated' 'Added before install' $false
git -C $repo add bucket/installupdated.json | Out-Null
git -C $repo commit -m 'add installupdated' | Out-Null
& $ScoExe config last_update $oldLastUpdate | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config last_update before install failed with exit code $LASTEXITCODE"
}

$installOutput = & $ScoExe install installupdated
if ($LASTEXITCODE -ne 0) {
    throw "install with implicit stale update failed with exit code $LASTEXITCODE`: $installOutput"
}
$installJoined = $installOutput -join "`n"
if ($installJoined -notmatch "Updated 'gitlocal' bucket" -or
    $installJoined -notmatch 'Scoop buckets were updated successfully' -or
    $installJoined -notmatch "Installing 'installupdated' \(1\.0\.0\) \[64bit\] from 'gitlocal' bucket" -or
    $installJoined -notmatch "'installupdated' \(1\.0\.0\) was installed successfully!") {
    throw "install did not refresh stale Scoop buckets before resolving manifest: $installJoined"
}
if (!(Test-Path (Join-Path $Root 'apps\installupdated\current\filetool.exe'))) {
    throw 'install after implicit bucket update did not install the newly pulled app'
}

Write-AppManifest 'skippedinstall' 'Added while install no-update-scoop is set' $false
git -C $repo add bucket/skippedinstall.json | Out-Null
git -C $repo commit -m 'add skippedinstall' | Out-Null
& $ScoExe config last_update $oldLastUpdate | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config last_update before install no-update-scoop failed with exit code $LASTEXITCODE"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$skipInstallOutput = & $ScoExe install skippedinstall --no-update-scoop 2>&1
$skipInstallExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($skipInstallExit -ne 1) {
    throw "install --no-update-scoop for a stale manifest returned $skipInstallExit instead of 1: $skipInstallOutput"
}
$skipInstallJoined = $skipInstallOutput -join "`n"
if ($skipInstallJoined -notmatch 'WARN  Scoop is out of date\.' -or
    $skipInstallJoined -match "Updated 'gitlocal' bucket" -or
    $skipInstallJoined -notmatch "sco install: couldn't find manifest for 'skippedinstall'") {
    throw "install --no-update-scoop did not warn and skip stale bucket refresh: $skipInstallJoined"
}
if (Test-Path (Join-Path $Root 'apps\skippedinstall')) {
    throw 'install --no-update-scoop unexpectedly installed an app from an unpulled stale bucket change'
}

$localBucketDir = Join-Path $Root 'buckets\local\bucket'
New-Item -ItemType Directory -Force -Path $localBucketDir | Out-Null
Write-AppManifest 'nongitupdated' 'Non-git bucket skip check'
git -C $repo add bucket/nongitupdated.json | Out-Null
git -C $repo commit -m 'add nongitupdated' | Out-Null
& $ScoExe config last_update $oldLastUpdate | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config last_update before non-git skip failed with exit code $LASTEXITCODE"
}

$nonGitOutput = & $ScoExe update
if ($LASTEXITCODE -ne 0) {
    throw "bare update with non-git bucket failed with exit code $LASTEXITCODE`: $nonGitOutput"
}
$nonGitJoined = $nonGitOutput -join "`n"
if ($nonGitJoined -notmatch "'local' is not a git repository\. Skipped\." -or
    $nonGitJoined -notmatch "Updated 'gitlocal' bucket" -or
    $nonGitJoined -notmatch 'Scoop buckets were updated successfully') {
    throw "bare update did not skip non-git bucket like Scoop: $nonGitJoined"
}
if (!(Test-Path (Join-Path $Root 'buckets\gitlocal\bucket\nongitupdated.json'))) {
    throw 'bare update with non-git bucket present did not update git bucket'
}

Write-AppManifest 'nocacheupdated' 'Added by update scoop no-cache'
git -C $repo add bucket/nocacheupdated.json | Out-Null
git -C $repo commit -m 'add nocacheupdated' | Out-Null

$noCacheScoopOutput = & $ScoExe update scoop --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "update scoop --no-cache should be accepted like Scoop, got exit code $LASTEXITCODE`: $noCacheScoopOutput"
}
$noCacheScoopJoined = $noCacheScoopOutput -join "`n"
if ($noCacheScoopJoined -notmatch "Updated 'gitlocal' bucket" -or
    $noCacheScoopJoined -notmatch 'Scoop buckets were updated successfully') {
    throw "update scoop --no-cache did not use the bucket update path: $noCacheScoopJoined"
}
if (!(Test-Path (Join-Path $Root 'buckets\gitlocal\bucket\nocacheupdated.json'))) {
    throw 'update scoop --no-cache did not pull new bucket manifest'
}
