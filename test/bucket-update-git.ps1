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

$repo = Join-Path $Root '..\bucket-update-source'
if (Test-Path $repo) {
    Remove-Item -LiteralPath $repo -Recurse -Force
}
$repoBucket = Join-Path $repo 'bucket'
New-Item -ItemType Directory -Force -Path $repoBucket | Out-Null

function Write-AppManifest($Name, $Description) {
    $manifest = [ordered]@{
        version = '1.0.0'
        description = $Description
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $repoBucket "$Name.json") -Encoding UTF8
}

Write-AppManifest 'filetool' 'Original git bucket app'
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

Write-AppManifest 'newtool' 'New app after bucket update'
git -C $repo add bucket/newtool.json | Out-Null
git -C $repo commit -m 'add newtool' | Out-Null

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$bucketUpdateOutput = & $ScoExe bucket update gitlocal 2>&1
$bucketUpdateExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference

if ($bucketUpdateExitCode -ne 0) {
    throw "bucket update failed with exit code $bucketUpdateExitCode`: $bucketUpdateOutput"
}
if (($bucketUpdateOutput -join "`n") -notmatch "Updated 'gitlocal' bucket\.") {
    throw "bucket update did not report the updated bucket: $bucketUpdateOutput"
}
if (!(Test-Path (Join-Path $Root 'buckets\gitlocal\bucket\newtool.json'))) {
    throw 'bucket update did not pull the new manifest'
}

$searchOutput = & $ScoExe search newtool
if ($LASTEXITCODE -ne 0 -or ($searchOutput -join "`n") -notmatch 'newtool') {
    throw "search did not find the app added by bucket update: $searchOutput"
}

$localSource = Join-Path $Root '..\bucket-update-local-source'
if (Test-Path $localSource) {
    Remove-Item -LiteralPath $localSource -Recurse -Force
}
$localBucket = Join-Path $localSource 'bucket'
New-Item -ItemType Directory -Force -Path $localBucket | Out-Null
[ordered]@{
    version = '1.0.0'
    description = 'Local non-git bucket app'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
} | ConvertTo-Json | Set-Content -Path (Join-Path $localBucket 'localonly.json') -Encoding UTF8

& $ScoExe bucket add localbucket $localSource
if ($LASTEXITCODE -ne 0) {
    throw "bucket add localbucket failed with exit code $LASTEXITCODE"
}

& $ScoExe config use_sqlite_cache true | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config use_sqlite_cache before bucket update failed with exit code $LASTEXITCODE"
}

Write-AppManifest 'cachetool' 'App added before all-bucket update'
git -C $repo add bucket/cachetool.json | Out-Null
git -C $repo commit -m 'add cachetool' | Out-Null

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$allUpdateOutput = & $ScoExe bucket update 2>&1
$allUpdateExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
$allUpdateOutput = $allUpdateOutput -join "`n"
if ($allUpdateExitCode -ne 0) {
    throw "bucket update all failed with exit code $allUpdateExitCode`: $allUpdateOutput"
}
if ($allUpdateOutput -notmatch "Updated 'gitlocal' bucket\." -or
    $allUpdateOutput -notmatch "'localbucket' is not a git repository\. Skipped\." -or
    $allUpdateOutput -notmatch 'INFO  Updating cache') {
    throw "bucket update all did not report git update, local skip, and cache refresh: $allUpdateOutput"
}
if (!(Test-Path (Join-Path $Root 'buckets\gitlocal\bucket\cachetool.json'))) {
    throw 'bucket update all did not pull the cachetool manifest'
}

$indexPath = Join-Path $Root 'cache\buckets.index.json'
$cache = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
$cacheEntry = @($cache.entries | Where-Object { $_.name -eq 'cachetool' })[0]
if ($null -eq $cacheEntry -or $cacheEntry.bucket -ne 'gitlocal') {
    throw "bucket update all did not refresh the manifest index: $($cache | ConvertTo-Json -Compress)"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingUpdateOutput = & $ScoExe bucket update missingbucket 2>&1
$missingUpdateExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingUpdateExitCode -ne 1) {
    throw "bucket update missingbucket returned $missingUpdateExitCode instead of 1: $missingUpdateOutput"
}
if (($missingUpdateOutput -join "`n") -notmatch "Could not update 'missingbucket' bucket: bucket not found") {
    throw "bucket update missingbucket did not report a missing bucket: $missingUpdateOutput"
}
