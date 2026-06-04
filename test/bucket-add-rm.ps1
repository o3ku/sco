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

$sourceBucket = Join-Path $Root '..\bucket-source'
if (Test-Path $sourceBucket) {
    Remove-Item -LiteralPath $sourceBucket -Recurse -Force
}
$sourceManifestDir = Join-Path $sourceBucket 'bucket'
New-Item -ItemType Directory -Force -Path $sourceManifestDir | Out-Null

$manifest = [ordered]@{
    version = '1.0.0'
    description = 'Local bucket test app'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $sourceManifestDir 'filetool.json') -Encoding UTF8
$nestedSourceManifestDir = Join-Path $sourceManifestDir 'nested'
New-Item -ItemType Directory -Force -Path $nestedSourceManifestDir | Out-Null
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $nestedSourceManifestDir 'nestedfiletool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingCommandOutput = & $ScoExe bucket 2>&1
$missingCommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingCommandExitCode -ne 1) {
    throw "bucket without a command returned $missingCommandExitCode instead of 1: $missingCommandOutput"
}
if (($missingCommandOutput -join "`n") -notmatch "scoop bucket: cmd '' not supported" -or ($missingCommandOutput -join "`n") -notmatch 'Usage: sco bucket add\|list\|known\|rm \[<args>\]') {
    throw "bucket without a command did not print Scoop-style usage: $missingCommandOutput"
}

$bucketHelp = (& $ScoExe bucket --help) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "bucket --help failed with exit code $LASTEXITCODE`: $bucketHelp"
}
if ($bucketHelp -notmatch 'Usage: sco bucket add\|list\|known\|rm \[<args>\]' -or $bucketHelp -match 'sco bucket update \[<name>\]') {
    throw "bucket help did not advertise update support: $bucketHelp"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidCommandOutput = & $ScoExe bucket nope 2>&1
$invalidCommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidCommandExitCode -ne 1) {
    throw "bucket with an invalid command returned $invalidCommandExitCode instead of 1: $invalidCommandOutput"
}
if (($invalidCommandOutput -join "`n") -notmatch "scoop bucket: cmd 'nope' not supported" -or ($invalidCommandOutput -join "`n") -notmatch 'Usage: sco bucket add\|list\|known\|rm \[<args>\]') {
    throw "bucket invalid command did not print Scoop-style usage: $invalidCommandOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAddOutput = & $ScoExe bucket add 2>&1
$missingAddExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAddExitCode -ne 1) {
    throw "bucket add without a name returned $missingAddExitCode instead of 1: $missingAddOutput"
}
if (($missingAddOutput -join "`n") -notmatch '<name> missing' -or ($missingAddOutput -join "`n") -notmatch 'usage: scoop bucket add <name> \[<repo>\]') {
    throw "bucket add without a name did not match Scoop usage: $missingAddOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$unknownAddOutput = & $ScoExe bucket add definitely-missing-bucket-name 2>&1
$unknownAddExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($unknownAddExitCode -ne 1) {
    throw "bucket add unknown bucket returned $unknownAddExitCode instead of 1: $unknownAddOutput"
}
if (($unknownAddOutput -join "`n") -notmatch "Unknown bucket 'definitely-missing-bucket-name'\. Try specifying <repo>\." -or ($unknownAddOutput -join "`n") -notmatch 'usage: scoop bucket add <name> \[<repo>\]') {
    throw "bucket add unknown bucket did not match Scoop output: $unknownAddOutput"
}

$invalidRepo = Join-Path $Root '..\definitely-missing-bucket-repo'
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidRepoOutput = & $ScoExe bucket add badrepo $invalidRepo 2>&1
$invalidRepoExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidRepoExitCode -ne 1) {
    throw "bucket add invalid git repo returned $invalidRepoExitCode instead of 1: $invalidRepoOutput"
}
if (($invalidRepoOutput -join "`n") -notmatch "'$([regex]::Escape($invalidRepo))' doesn't look like a valid git repository") {
    throw "bucket add invalid git repo did not match Scoop-style validation: $invalidRepoOutput"
}
if (Test-Path (Join-Path $Root 'buckets\badrepo')) {
    throw 'bucket add invalid git repo created the target bucket directory'
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingRmOutput = & $ScoExe bucket rm 2>&1
$missingRmExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingRmExitCode -ne 1) {
    throw "bucket rm without a name returned $missingRmExitCode instead of 1: $missingRmOutput"
}
if (($missingRmOutput -join "`n") -notmatch '<name> missing' -or ($missingRmOutput -join "`n") -notmatch 'usage: scoop bucket rm <name>') {
    throw "bucket rm without a name did not match Scoop usage: $missingRmOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingBucketRmOutput = & $ScoExe bucket rm missinglocal 2>&1
$missingBucketRmExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingBucketRmExitCode -ne 0) {
    throw "bucket rm missing bucket returned $missingBucketRmExitCode instead of 0 like Scoop: $missingBucketRmOutput"
}
if (($missingBucketRmOutput -join "`n") -notmatch "ERROR 'missinglocal' bucket not found\.") {
    throw "bucket rm missing bucket did not match Scoop error: $missingBucketRmOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$emptyListOutput = & $ScoExe bucket list 2>&1
$emptyListExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($emptyListExitCode -ne 2) {
    throw "bucket list without buckets returned $emptyListExitCode instead of 2: $emptyListOutput"
}
if (($emptyListOutput -join "`n") -notmatch "No bucket found\. Please run 'sco bucket add main'") {
    throw "bucket list without buckets did not match Scoop warning: $emptyListOutput"
}

New-Item -ItemType Directory -Force -Path (Join-Path $Root 'buckets\brokenlocal') | Out-Null
$brokenListOutput = @(& $ScoExe bucket list | Where-Object { $_ -match '^brokenlocal\s' })
if ($LASTEXITCODE -ne 0) {
    throw "bucket list with a bucket missing its manifest directory failed with exit code $LASTEXITCODE`: $brokenListOutput"
}
if ($brokenListOutput.Count -ne 1 -or $brokenListOutput[0] -notmatch '^brokenlocal\s+\S+\s+0$') {
    throw "bucket list should include malformed local buckets with zero manifests like Scoop: $($brokenListOutput -join '; ')"
}

Remove-Item -LiteralPath (Join-Path $Root 'buckets') -Recurse -Force

[ordered]@{
    MiXeDLocal = ([System.IO.Path]::GetFullPath($sourceBucket))
} | ConvertTo-Json | Set-Content -Path (Join-Path (New-Item -ItemType Directory -Force -Path $Root) 'buckets.json') -Encoding UTF8

& $ScoExe bucket add mixedlocal
if ($LASTEXITCODE -ne 0) {
    throw "bucket add should resolve known bucket names case-insensitively like Scoop, got exit code $LASTEXITCODE"
}
if (!(Test-Path (Join-Path $Root 'buckets\mixedlocal\bucket\filetool.json'))) {
    throw 'bucket add did not add the case-insensitive known bucket source'
}

[ordered]@{
    main = 'https://example.invalid/main'
    extras = 'https://example.invalid/extras'
} | ConvertTo-Json | Set-Content -Path (Join-Path (New-Item -ItemType Directory -Force -Path $Root) 'buckets.json') -Encoding UTF8

foreach ($bucketName in @('zzzcustom', 'extras', 'main')) {
    $bucketPath = Join-Path $Root "buckets\$bucketName\bucket"
    New-Item -ItemType Directory -Force -Path $bucketPath | Out-Null
}

$orderedListOutput = @(& $ScoExe bucket list | Where-Object { $_ -match '^(main|extras|zzzcustom)\s' })
if ($LASTEXITCODE -ne 0) {
    throw "bucket list ordering setup failed with exit code $LASTEXITCODE`: $orderedListOutput"
}
$orderedListNames = @($orderedListOutput | ForEach-Object { ($_ -split '\s+')[0] })
if ($orderedListNames.Count -lt 3 -or $orderedListNames[0] -ne 'main' -or $orderedListNames[1] -ne 'extras' -or $orderedListNames[2] -ne 'zzzcustom') {
    throw "bucket list did not order known buckets first using buckets.json order: $($orderedListOutput -join '; ')"
}
foreach ($line in $orderedListOutput) {
    if ($line -notmatch '^(main|extras|zzzcustom)\s+\S.+' -or $line -notmatch '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' -or $line -notmatch '\s0$') {
        throw "bucket list row did not include Scoop-style metadata: $line"
    }
}

Remove-Item -LiteralPath (Join-Path $Root 'buckets') -Recurse -Force

& $ScoExe bucket add local $sourceBucket
if ($LASTEXITCODE -ne 0) {
    throw "bucket add failed with exit code $LASTEXITCODE"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$duplicateAddOutput = & $ScoExe bucket add local $sourceBucket 2>&1
$duplicateAddExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($duplicateAddExitCode -ne 2) {
    throw "duplicate bucket add returned $duplicateAddExitCode instead of 2: $duplicateAddOutput"
}
if (($duplicateAddOutput -join "`n") -notmatch "WARN  The 'local' bucket already exists\. To add this bucket again, first remove it by running 'scoop bucket rm local'\.") {
    throw "duplicate bucket add did not match Scoop warning: $duplicateAddOutput"
}

$listOutput = & $ScoExe bucket list
if ($LASTEXITCODE -ne 0 -or ($listOutput -join "`n") -notmatch 'local') {
    throw "bucket list did not include local bucket: $listOutput"
}
$listJoined = $listOutput -join "`n"
if ($listJoined -notmatch 'Name\s+Source\s+Updated\s+Manifests' -or
    $listJoined -notmatch 'local\s+\S.+\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s+3') {
    throw "bucket list local bucket did not include source, updated time, and manifest count: $listJoined"
}

$searchOutput = & $ScoExe search filetool
if ($LASTEXITCODE -ne 0 -or ($searchOutput -join "`n") -notmatch 'filetool') {
    throw "search did not find filetool from local bucket: $searchOutput"
}

& $ScoExe config use_sqlite_cache true | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config use_sqlite_cache before bucket cache verification failed with exit code $LASTEXITCODE"
}

$sqliteSourceBucket = Join-Path $Root '..\bucket-sqlite-source'
if (Test-Path $sqliteSourceBucket) {
    Remove-Item -LiteralPath $sqliteSourceBucket -Recurse -Force
}
$sqliteSourceManifestDir = Join-Path $sqliteSourceBucket 'bucket'
New-Item -ItemType Directory -Force -Path $sqliteSourceManifestDir | Out-Null
$sqliteManifest = [ordered]@{
    version = '1.0.0'
    description = 'Added bucket cache test app'
    bin = 'sqlitecache.exe'
}
$sqliteManifest | ConvertTo-Json | Set-Content -Path (Join-Path $sqliteSourceManifestDir 'sqlitecache.json') -Encoding UTF8

$sqliteAddOutput = (& $ScoExe bucket add sqlitecache $sqliteSourceBucket) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "bucket add sqlitecache failed with exit code $LASTEXITCODE`: $sqliteAddOutput"
}
if ($sqliteAddOutput -notmatch 'INFO  Updating cache') {
    throw "bucket add with use_sqlite_cache did not report cache refresh like Scoop: $sqliteAddOutput"
}

$indexPath = Join-Path $Root 'cache\buckets.index.json'
$cache = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
$entry = @($cache.entries | Where-Object { $_.name -eq 'sqlitecache' })[0]
if ($null -eq $entry -or $entry.bucket -ne 'sqlitecache') {
    throw "bucket add with use_sqlite_cache did not refresh manifest index: $($cache | ConvertTo-Json -Compress)"
}

$sqliteRmOutput = (& $ScoExe bucket rm sqlitecache) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "bucket rm sqlitecache failed with exit code $LASTEXITCODE`: $sqliteRmOutput"
}
if ($sqliteRmOutput -notmatch 'INFO  Updating cache') {
    throw "bucket rm with use_sqlite_cache did not report cache refresh like Scoop: $sqliteRmOutput"
}

$cache = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
if (@($cache.entries | Where-Object { $_.name -eq 'sqlitecache' }).Count -ne 0) {
    throw "bucket rm with use_sqlite_cache did not refresh manifest index: $($cache | ConvertTo-Json -Compress)"
}

& $ScoExe install local/filetool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install from added bucket failed with exit code $LASTEXITCODE"
}

if (!(Test-Path (Join-Path $Root 'apps\filetool\current\filetool.exe'))) {
    throw 'install from added bucket did not produce current filetool.exe'
}

& $ScoExe bucket rm local
if ($LASTEXITCODE -ne 0) {
    throw "bucket rm failed with exit code $LASTEXITCODE"
}

if (Test-Path (Join-Path $Root 'buckets\local')) {
    throw 'bucket rm left local bucket directory'
}
