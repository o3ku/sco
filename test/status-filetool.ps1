param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$GlobalRoot,
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
if (Test-Path $GlobalRoot) {
    Remove-Item -LiteralPath $GlobalRoot -Recurse -Force
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
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome

function Install-GlobalStatusFixture($Name) {
    $previousScoop = $env:SCOOP
    $previousGlobal = $env:SCOOP_GLOBAL
    try {
        $env:SCOOP = $GlobalRoot
        Remove-Item Env:SCOOP_GLOBAL -ErrorAction SilentlyContinue
        $globalBucketDir = Join-Path $GlobalRoot 'buckets\main\bucket'
        New-Item -ItemType Directory -Force -Path $globalBucketDir | Out-Null
        Copy-Item -LiteralPath (Join-Path $bucketDir "$Name.json") -Destination (Join-Path $globalBucketDir "$Name.json") -Force
        & $ScoExe install $Name --no-update-scoop
    } finally {
        $env:SCOOP = $previousScoop
        $env:SCOOP_GLOBAL = $previousGlobal
    }
}

Write-Manifest '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
& $ScoExe install filetool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$statusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status failed with exit code $LASTEXITCODE"
}
$statusJoined = $statusOutput -join "`n"
if ($statusJoined -notmatch "WARN  Scoop bucket\(s\) out of date\. Run 'scoop update' to get the latest changes\.") {
    throw "status should report non-git local bucket as out of date like Scoop: $statusJoined"
}
if ($statusJoined -match 'Everything is ok!') {
    throw "status should not report everything ok when a bucket needs update: $statusJoined"
}

$scoopStatusSource = Join-Path (Split-Path -Parent $Root) 'test-status-scoop-source'
$scoopStatusRemote = Join-Path (Split-Path -Parent $Root) 'test-status-scoop-remote.git'
if (Test-Path $scoopStatusSource) {
    Remove-Item -LiteralPath $scoopStatusSource -Recurse -Force
}
if (Test-Path $scoopStatusRemote) {
    Remove-Item -LiteralPath $scoopStatusRemote -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $scoopStatusSource | Out-Null
Set-Content -Path (Join-Path $scoopStatusSource 'scoop.ps1') -Value 'initial' -Encoding Ascii
git -C $scoopStatusSource init | Out-Null
git -C $scoopStatusSource config user.email sco-test@example.invalid | Out-Null
git -C $scoopStatusSource config user.name sco-test | Out-Null
git -C $scoopStatusSource add scoop.ps1 | Out-Null
git -C $scoopStatusSource commit -m 'initial scoop core' | Out-Null
git -C $scoopStatusSource branch -M master | Out-Null
git init --bare $scoopStatusRemote | Out-Null
git -C $scoopStatusSource remote add origin $scoopStatusRemote | Out-Null
git -C $scoopStatusSource push -u origin master | Out-Null

$scoopCurrent = Join-Path $Root 'apps\scoop\current'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $scoopCurrent) | Out-Null
git clone -q $scoopStatusRemote $scoopCurrent | Out-Null
Set-Content -Path (Join-Path $scoopStatusSource 'scoop.ps1') -Value 'updated' -Encoding Ascii
git -C $scoopStatusSource add scoop.ps1 | Out-Null
git -C $scoopStatusSource commit -m 'update scoop core' | Out-Null
git -C $scoopStatusSource push | Out-Null

$scoopOutdatedStatus = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status failed for outdated Scoop core fixture with exit code $LASTEXITCODE`: $scoopOutdatedStatus"
}
$scoopOutdatedJoined = $scoopOutdatedStatus -join "`n"
if ($scoopOutdatedJoined -notmatch "WARN  Scoop out of date\. Run 'scoop update' to get the latest changes\." -or
    $scoopOutdatedJoined -match "WARN  Scoop bucket\(s\) out of date\.") {
    throw "status should prefer Scoop core out-of-date warning over bucket warning: $scoopOutdatedJoined"
}
Remove-Item -LiteralPath (Join-Path $Root 'apps\scoop') -Recurse -Force

$localStatusOutput = & $ScoExe status --local
if ($LASTEXITCODE -ne 0) {
    throw "status --local failed with exit code $LASTEXITCODE`: $localStatusOutput"
}
if (($localStatusOutput -join "`n") -notmatch 'Everything is ok!') {
    throw "status --local should skip bucket update checks: $localStatusOutput"
}

$currentPath = Join-Path $Root 'apps\filetool\current'
[System.IO.Directory]::Delete($currentPath)
$failedStatusOutput = & $ScoExe status --local
if ($LASTEXITCODE -ne 0) {
    throw "status --local failed for broken install layout with exit code $LASTEXITCODE`: $failedStatusOutput"
}
$failedStatusJoined = $failedStatusOutput -join "`n"
if ($failedStatusJoined -notmatch 'filetool' -or
    $failedStatusJoined -notmatch 'Name\s+Installed Version\s+Latest Version\s+Missing Dependencies\s+Info' -or
    $failedStatusJoined -notmatch '1\.0\.0' -or
    $failedStatusJoined -notmatch 'Install failed') {
    throw "status --local did not report a missing current link as a failed install: $failedStatusJoined"
}

$resetOutput = & $ScoExe reset filetool
if ($LASTEXITCODE -ne 0) {
    throw "reset after failed status fixture failed with exit code $LASTEXITCODE`: $resetOutput"
}

$extraArgStatusOutput = & $ScoExe status ignored-extra
if ($LASTEXITCODE -ne 0) {
    throw "status with an extra positional argument failed with exit code $LASTEXITCODE`: $extraArgStatusOutput"
}
$extraArgStatusJoined = $extraArgStatusOutput -join "`n"
if ($extraArgStatusJoined -notmatch "WARN  Scoop bucket\(s\) out of date\. Run 'scoop update' to get the latest changes\.") {
    throw "status did not ignore extra positional arguments while keeping normal bucket checks: $extraArgStatusJoined"
}

$v2Source = Join-Path $Root 'sources\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $v2Source) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $v2Source -Force

Write-Manifest '1.1.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
$statusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status failed after manifest update with exit code $LASTEXITCODE"
}

$joined = $statusOutput -join "`n"
if ($joined -notmatch 'filetool') {
    throw "status did not include filetool: $joined"
}
if ($joined -notmatch '1\.0\.0') {
    throw "status did not include installed version: $joined"
}
if ($joined -notmatch '1\.1\.0') {
    throw "status did not include latest version: $joined"
}
if ($joined -notmatch 'Name\s+Installed Version\s+Latest Version\s+Missing Dependencies\s+Info') {
    throw "status did not use Scoop-style status table: $joined"
}
if ($joined -match 'Update available') {
    throw "status should not add an Update available info field; Scoop uses the Latest Version column: $joined"
}

$directManifestDir = Join-Path $Root 'direct-manifests'
$directManifestPath = Join-Path $directManifestDir 'directstatus.json'
$directSource = Join-Path $Root 'sources\directstatus\filetool.exe'
New-Item -ItemType Directory -Force -Path $directManifestDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $directSource) | Out-Null

function Write-DirectStatusManifest($Version, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($directSource))
        hash = $Hash
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path $directManifestPath -Encoding UTF8
}

Copy-Item -LiteralPath $ArtifactV1 -Destination $directSource -Force
Write-DirectStatusManifest '1.0.0' '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$directInstallOutput = & $ScoExe install $directManifestPath --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "direct status manifest install failed with exit code $LASTEXITCODE`: $directInstallOutput"
}

Copy-Item -LiteralPath $ArtifactV2 -Destination $directSource -Force
Write-DirectStatusManifest '1.1.0' 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
$directStatusOutput = & $ScoExe status --local
if ($LASTEXITCODE -ne 0) {
    throw "status --local failed for direct manifest app with exit code $LASTEXITCODE`: $directStatusOutput"
}
$directStatusJoined = $directStatusOutput -join "`n"
if ($directStatusJoined -notmatch 'directstatus' -or
    $directStatusJoined -notmatch '1\.0\.0' -or
    $directStatusJoined -notmatch '1\.1\.0' -or
    $directStatusJoined -match 'directstatus.*Manifest removed') {
    throw "status did not use direct manifest source for installed app: $directStatusJoined"
}

$statusBucketDir = Join-Path $Root 'buckets\zzstatus\bucket'
New-Item -ItemType Directory -Force -Path $statusBucketDir | Out-Null

function Write-StatusPickManifest($Directory, $Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $Directory 'statuspick.json') -Encoding UTF8
}

Write-StatusPickManifest $statusBucketDir '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$statusPickInstall = & $ScoExe install zzstatus/statuspick --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "status source bucket install failed with exit code $LASTEXITCODE`: $statusPickInstall"
}
Write-StatusPickManifest $bucketDir '9.9.9' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
Write-StatusPickManifest $statusBucketDir '1.1.0' $ArtifactV2 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
$statusPickOutput = & $ScoExe status --local
if ($LASTEXITCODE -ne 0) {
    throw "status --local failed for source bucket app with exit code $LASTEXITCODE`: $statusPickOutput"
}
$statusPickJoined = $statusPickOutput -join "`n"
if ($statusPickJoined -notmatch 'statuspick' -or
    $statusPickJoined -notmatch '1\.0\.0' -or
    $statusPickJoined -notmatch '1\.1\.0' -or
    $statusPickJoined -match '9\.9\.9') {
    throw "status did not reuse installed bucket source when another bucket had the same app: $statusPickJoined"
}

$remoteStatusManifest = Join-Path $Root 'sources\remotestatus\remotestatus.json'
$remoteStatusArtifact = Join-Path $Root 'sources\remotestatus\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $remoteStatusManifest) | Out-Null

function Write-RemoteStatusManifest($Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path $remoteStatusManifest -Encoding UTF8
}

Copy-Item -LiteralPath $ArtifactV1 -Destination $remoteStatusArtifact -Force
Write-RemoteStatusManifest '1.0.0' $remoteStatusArtifact '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'

$remoteStatusPrefix = 'http://127.0.0.1:18215/'
$remoteStatusUrl = $remoteStatusPrefix + 'remotestatus.json'
$remoteStatusJob = Start-Job -ScriptBlock {
    param($Prefix, $ManifestFile)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        for ($i = 0; $i -lt 2; $i++) {
            $context = $listener.GetContext()
            $body = if ($context.Request.Url.AbsolutePath -eq '/remotestatus.json') {
                Get-Content -LiteralPath $ManifestFile -Raw
            } else {
                'missing'
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $context.Response.StatusCode = if ($context.Request.Url.AbsolutePath -eq '/remotestatus.json') { 200 } else { 404 }
            $context.Response.ContentType = 'application/json'
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList $remoteStatusPrefix, $remoteStatusManifest

Start-Sleep -Milliseconds 300
try {
    $remoteStatusInstall = & $ScoExe install $remoteStatusUrl --no-update-scoop
    if ($LASTEXITCODE -ne 0) {
        throw "remote status manifest install failed with exit code $LASTEXITCODE`: $remoteStatusInstall"
    }
    Copy-Item -LiteralPath $ArtifactV2 -Destination $remoteStatusArtifact -Force
    Write-RemoteStatusManifest '1.1.0' $remoteStatusArtifact 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
    $remoteStatusOutput = & $ScoExe status --local
    if ($LASTEXITCODE -ne 0) {
        throw "status --local failed for remote URL manifest app with exit code $LASTEXITCODE`: $remoteStatusOutput"
    }
    $remoteStatusJoined = $remoteStatusOutput -join "`n"
    if ($remoteStatusJoined -notmatch 'remotestatus' -or
        $remoteStatusJoined -notmatch '1\.0\.0' -or
        $remoteStatusJoined -notmatch '1\.1\.0' -or
        $remoteStatusJoined -match 'remotestatus.*Manifest removed') {
        throw "status did not rematerialize remote URL manifest source: $remoteStatusJoined"
    }
} finally {
    Wait-Job $remoteStatusJob -Timeout 5 | Out-Null
    Receive-Job $remoteStatusJob | Out-Null
    Remove-Job $remoteStatusJob -Force
}

Write-Manifest '1.10.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
& $ScoExe update filetool --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "update to newer numeric version failed with exit code $LASTEXITCODE"
}

Write-Manifest '1.9.9' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$downgradeStatusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status failed for newer installed version with exit code $LASTEXITCODE"
}
$downgradeStatusJoined = $downgradeStatusOutput -join "`n"
if ($downgradeStatusJoined -notmatch "WARN  Scoop bucket\(s\) out of date\. Run 'scoop update' to get the latest changes\.") {
    throw "status should keep reporting the bucket update warning: $downgradeStatusJoined"
}
if ($downgradeStatusJoined -match 'filetool\s+1\.10\.0\s+1\.9\.9') {
    throw "status treated older bucket version as an app update: $downgradeStatusJoined"
}

& $ScoExe config force_update true
if ($LASTEXITCODE -ne 0) {
    throw "config force_update failed with exit code $LASTEXITCODE"
}
$forceUpdateStatusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status with force_update failed with exit code $LASTEXITCODE"
}
$forceUpdateJoined = $forceUpdateStatusOutput -join "`n"
if ($forceUpdateJoined -notmatch 'filetool' -or $forceUpdateJoined -notmatch '1\.10\.0' -or $forceUpdateJoined -notmatch '1\.9\.9') {
    throw "status did not honor force_update mismatch reporting: $forceUpdateJoined"
}
if ($forceUpdateJoined -match 'Update available') {
    throw "status should not add an Update available info field for force_update mismatches: $forceUpdateJoined"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $GlobalRoot) {
    Remove-Item -LiteralPath $GlobalRoot -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
Write-Manifest '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
Install-GlobalStatusFixture 'filetool'
if ($LASTEXITCODE -ne 0) {
    throw "global fixture install failed with exit code $LASTEXITCODE"
}
Write-Manifest '1.1.0' $ArtifactV2 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'

$globalStatusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status failed for global app with exit code $LASTEXITCODE`: $globalStatusOutput"
}
$globalStatusJoined = $globalStatusOutput -join "`n"
if ($globalStatusJoined -notmatch 'filetool' -or $globalStatusJoined -notmatch '1\.0\.0' -or $globalStatusJoined -notmatch '1\.1\.0') {
    throw "status did not include outdated global app: $globalStatusJoined"
}
if ($globalStatusJoined -match 'filetool\s+1\.0\.0\s+1\.1\.0\s+\s*global(\s|$)') {
    throw "status should not append a bare global marker; Scoop status has no global column: $globalStatusJoined"
}

function Write-NamedStatusManifest($Name, $Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir "$Name.json") -Encoding UTF8
}

Write-NamedStatusManifest 'aalocalstatus' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
& $ScoExe install aalocalstatus --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "local status ordering fixture install failed with exit code $LASTEXITCODE"
}
Write-NamedStatusManifest 'zzglobalstatus' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
Install-GlobalStatusFixture 'zzglobalstatus'
if ($LASTEXITCODE -ne 0) {
    throw "global status ordering fixture install failed with exit code $LASTEXITCODE"
}
Write-NamedStatusManifest 'aalocalstatus' '1.1.0' $ArtifactV2 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
Write-NamedStatusManifest 'zzglobalstatus' '1.1.0' $ArtifactV2 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'

$scopeOrderStatus = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status scope-order check failed with exit code $LASTEXITCODE`: $scopeOrderStatus"
}
$scopeOrderStatusJoined = $scopeOrderStatus -join "`n"
$globalStatusIndex = $scopeOrderStatusJoined.IndexOf('zzglobalstatus')
$localStatusIndex = $scopeOrderStatusJoined.IndexOf('aalocalstatus')
if ($globalStatusIndex -lt 0 -or $localStatusIndex -lt 0 -or $globalStatusIndex -gt $localStatusIndex) {
    throw "status should output global app statuses before local app statuses like Scoop: $scopeOrderStatusJoined"
}

$localOnlyGlobalStatus = & $ScoExe status --local
if ($LASTEXITCODE -ne 0) {
    throw "status --local failed with global-only app, exit $LASTEXITCODE`: $localOnlyGlobalStatus"
}
$localOnlyGlobalJoined = $localOnlyGlobalStatus -join "`n"
if ($localOnlyGlobalJoined -match 'filetool' -or $localOnlyGlobalJoined -match 'zzglobalstatus') {
    throw "status --local should not include global-only apps: $localOnlyGlobalJoined"
}
if ($localOnlyGlobalJoined -notmatch 'aalocalstatus' -or $localOnlyGlobalJoined -match 'Everything is ok!') {
    throw "status --local should report local-only app status while excluding global apps: $localOnlyGlobalJoined"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $GlobalRoot) {
    Remove-Item -LiteralPath $GlobalRoot -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}
$cleanStatusSource = Join-Path (Split-Path -Parent $Root) 'test-status-clean-source'
$cleanStatusRemote = Join-Path (Split-Path -Parent $Root) 'test-status-clean-remote.git'
if (Test-Path $cleanStatusSource) {
    Remove-Item -LiteralPath $cleanStatusSource -Recurse -Force
}
if (Test-Path $cleanStatusRemote) {
    Remove-Item -LiteralPath $cleanStatusRemote -Recurse -Force
}
$cleanStatusBucket = Join-Path $cleanStatusSource 'bucket'
New-Item -ItemType Directory -Force -Path $cleanStatusBucket | Out-Null
@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
} | ConvertTo-Json | Set-Content -Path (Join-Path $cleanStatusBucket 'cleanstatus.json') -Encoding UTF8
git -C $cleanStatusSource init | Out-Null
git -C $cleanStatusSource config user.email sco-test@example.invalid | Out-Null
git -C $cleanStatusSource config user.name sco-test | Out-Null
git -C $cleanStatusSource add bucket/cleanstatus.json | Out-Null
git -C $cleanStatusSource commit -m 'add cleanstatus' | Out-Null
git -C $cleanStatusSource branch -M master | Out-Null
git init --bare $cleanStatusRemote | Out-Null
git -C $cleanStatusSource remote add origin $cleanStatusRemote | Out-Null
git -C $cleanStatusSource push -u origin master | Out-Null

New-Item -ItemType Directory -Force -Path (Join-Path $Root 'buckets') | Out-Null
git clone -q $cleanStatusRemote (Join-Path $Root 'buckets\main') | Out-Null

$cleanStatusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "clean status failed with exit code $LASTEXITCODE`: $cleanStatusOutput"
}
$cleanStatusJoined = $cleanStatusOutput -join "`n"
if ($cleanStatusJoined -notmatch 'Scoop is up to date\.' -or $cleanStatusJoined -notmatch 'Everything is ok!') {
    throw "clean remote status should report Scoop and app state as ok like Scoop: $cleanStatusJoined"
}

$cleanLocalStatusOutput = & $ScoExe status --local
if ($LASTEXITCODE -ne 0) {
    throw "clean status --local failed with exit code $LASTEXITCODE`: $cleanLocalStatusOutput"
}
$cleanLocalStatusJoined = $cleanLocalStatusOutput -join "`n"
if ($cleanLocalStatusJoined -match 'Scoop is up to date\.' -or $cleanLocalStatusJoined -notmatch 'Everything is ok!') {
    throw "status --local should skip remote Scoop status while still reporting app state: $cleanLocalStatusJoined"
}
