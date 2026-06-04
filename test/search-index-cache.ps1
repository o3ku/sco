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

$bucketDir = Join-Path $Root 'buckets\main\bucket'
$manifestPath = Join-Path $bucketDir 'cachetool.json'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
[ordered]@{} | ConvertTo-Json | Set-Content -Path (Join-Path $Root 'buckets.json') -Encoding UTF8

function Write-Manifest($Description) {
    $manifest = [ordered]@{
        version = '1.0.0'
        description = $Description
        bin = @(, @('cachetool.exe', 'cache-alias'))
        shortcuts = @(, @('cachetool.exe', 'Cache Tool'))
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

Write-Manifest 'Alpha cached description'

$emojiName = "emoji-$([char]::ConvertFromUtf32(0x1F9EA))-ff.json"
$emojiManifest = [ordered]@{
    version = '1.0.0'
    description = 'Unicode filename manifest'
    bin = 'ffunicode.exe'
}
$emojiManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $bucketDir $emojiName) -Encoding UTF8

$allSearchOutput = & $ScoExe search
if ($LASTEXITCODE -ne 0 -or (($allSearchOutput -join "`n") -notmatch 'cachetool')) {
    throw "search without query did not list available apps: $allSearchOutput"
}
if (($allSearchOutput -join "`n") -match 'Alpha cached description') {
    throw "search without query should not print manifest descriptions like Scoop: $allSearchOutput"
}

$searchOutput = & $ScoExe search cachetool
if ($LASTEXITCODE -ne 0) {
    throw "initial search failed with exit code $LASTEXITCODE"
}
$joined = $searchOutput -join "`n"
if ($joined -notmatch 'Results from local buckets\.\.\.') {
    throw "initial search did not print Scoop-style local bucket header: $joined"
}
if ($joined -notmatch 'cachetool') {
    throw "initial search did not list manifest by name: $joined"
}
if ($joined -match 'Alpha cached description') {
    throw "search should not print manifest description like Scoop: $joined"
}

$unicodeSearchOutput = & $ScoExe search ffunicode
$unicodeJoined = $unicodeSearchOutput -join "`n"
if ($LASTEXITCODE -ne 0 -or $unicodeJoined -notmatch 'ffunicode\.exe') {
    throw "search should handle manifest filenames with Unicode outside the active ANSI code page: $unicodeJoined"
}

$extraArgSearchOutput = & $ScoExe search cachetool ignored-extra
if ($LASTEXITCODE -ne 0) {
    throw "search with an extra positional argument failed with exit code $LASTEXITCODE`: $extraArgSearchOutput"
}
if (($extraArgSearchOutput -join "`n") -notmatch 'cachetool') {
    throw "search did not ignore extra positional arguments like Scoop: $extraArgSearchOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$descriptionOnlyOutput = & $ScoExe search alpha 2>&1
$descriptionOnlyExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($descriptionOnlyExitCode -ne 1) {
    throw "description-only search returned $descriptionOnlyExitCode instead of 1 like Scoop: $descriptionOnlyOutput"
}
if (($descriptionOnlyOutput -join "`n") -notmatch 'WARN  No matches found\.') {
    throw "description-only search should not match manifest descriptions: $descriptionOnlyOutput"
}

$searchOutput = & $ScoExe search cache-alias
$joined = $searchOutput -join "`n"
if ($LASTEXITCODE -ne 0 -or $joined -notmatch 'cachetool') {
    throw "search did not match indexed bin alias: $searchOutput"
}
if ($joined -notmatch 'Name\s+Version\s+Source\s+Binaries' -or $joined -notmatch 'cachetool\s+1\.0\.0\s+main\s+cache-alias') {
    throw "search did not display Scoop-style binary table: $joined"
}

$searchOutput = & $ScoExe search cachetool
$joined = $searchOutput -join "`n"
if ($LASTEXITCODE -ne 0 -or $joined -notmatch 'cachetool') {
    throw "search did not match manifest name: $searchOutput"
}
if ($joined -match 'cachetool\s+1\.0\.0\s+main\s+\S') {
    throw "search should not display binary matches when manifest name matches like Scoop: $joined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$searchOutput = & $ScoExe search 'Cache Tool'
$shortcutExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
$joined = $searchOutput -join "`n"
if ($shortcutExitCode -ne 1 -or $joined -notmatch 'WARN  No matches found\.') {
    throw "non-SQLite search should not match shortcuts like Scoop: $joined"
}

$configDir = Join-Path $ConfigHome 'scoop'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
@{ use_sqlite_cache = $true } | ConvertTo-Json | Set-Content -Path (Join-Path $configDir 'config.json') -Encoding UTF8

$literalLikeManifest = [ordered]@{
    version = '1.0.0'
    description = 'SQLite literal match manifest'
    bin = 'literalbracket.exe'
}
$literalLikeManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $bucketDir 'literal[tool].json') -Encoding UTF8

$sqliteBinManifest = [ordered]@{
    version = '1.0.0'
    description = 'SQLite string bin manifest'
    bin = 'tools/sqlitebin.exe'
}
$sqliteBinManifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $bucketDir 'sqlitebinapp.json') -Encoding UTF8

$literalLikeOutput = & $ScoExe search '[' 2>&1
$literalLikeJoined = $literalLikeOutput -join "`n"
if ($LASTEXITCODE -ne 0 -or $literalLikeJoined -notmatch 'literal\[tool\]') {
    throw "SQLite-style search should treat '[' as a LIKE pattern character, not an invalid regex: $literalLikeJoined"
}
if ($literalLikeJoined -match 'Invalid regular expression') {
    throw "SQLite-style search incorrectly parsed '[' as a regular expression: $literalLikeJoined"
}

$searchOutput = & $ScoExe search 'Cache Tool'
$joined = $searchOutput -join "`n"
if ($LASTEXITCODE -ne 0 -or $joined -notmatch 'cachetool') {
    throw "SQLite-style search did not match shortcut name: $searchOutput"
}
if ($joined -notmatch 'cachetool\s+1\.0\.0\s+main\s+cache-alias') {
    throw "SQLite-style shortcut match should display binary column like Scoop: $joined"
}

$sqliteBinOutput = & $ScoExe search sqlitebin
$sqliteBinJoined = $sqliteBinOutput -join "`n"
if ($LASTEXITCODE -ne 0 -or $sqliteBinJoined -notmatch 'sqlitebinapp') {
    throw "SQLite-style search did not match string bin basename: $sqliteBinOutput"
}
if ($sqliteBinJoined -notmatch 'sqlitebinapp\s+1\.0\.0\s+main\s+sqlitebin(\s|$)') {
    throw "SQLite-style search should display known executable bin names without extension like Scoop: $sqliteBinJoined"
}
if ($sqliteBinJoined -match 'sqlitebin\.exe') {
    throw "SQLite-style search displayed a string bin extension unlike Scoop: $sqliteBinJoined"
}
@{} | ConvertTo-Json | Set-Content -Path (Join-Path $configDir 'config.json') -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidRegexOutput = & $ScoExe search '[' 2>&1
$invalidRegexExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidRegexExitCode -ne 1) {
    throw "invalid regex search returned $invalidRegexExitCode instead of 1: $invalidRegexOutput"
}
if (($invalidRegexOutput -join "`n") -notmatch 'Invalid regular expression') {
    throw "invalid regex search did not report regex parse error: $invalidRegexOutput"
}

$indexPath = Join-Path $Root 'cache\buckets.index.json'
if (!(Test-Path $indexPath)) {
    throw "search did not create bucket manifest index: $indexPath"
}

Write-Manifest 'Beta refreshed description with changed size'
$searchOutput = & $ScoExe search cachetool
if ($LASTEXITCODE -ne 0) {
    throw "refreshed search failed with exit code $LASTEXITCODE"
}
$joined = $searchOutput -join "`n"
if ($joined -notmatch 'cachetool') {
    throw "search did not refresh bucket manifest index: $joined"
}
if ($joined -match 'Beta refreshed description') {
    throw "search should not display refreshed manifest description like Scoop: $joined"
}

$cache = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
$entry = @($cache.entries | Where-Object { $_.name -eq 'cachetool' })[0]
if ($null -eq $entry -or $entry.description -notmatch 'Beta refreshed description') {
    throw 'bucket manifest index cache did not persist refreshed summary'
}
if (($entry.bins -join ',') -notmatch 'cache-alias') {
    throw 'bucket manifest index cache did not persist bin aliases'
}
if (($entry.shortcuts -join ',') -notmatch 'Cache Tool') {
    throw 'bucket manifest index cache did not persist shortcut names'
}

$binOnlyManifest = [ordered]@{
    version = '1.0.0'
    description = 'Target bin manifest'
    bin = 'tools/targetbin.exe'
}
$binOnlyManifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $bucketDir 'binmatchapp.json') -Encoding UTF8

$targetSearchOutput = & $ScoExe search targetbin
if ($LASTEXITCODE -ne 0) {
    throw "search target bin failed with exit code $LASTEXITCODE"
}
$targetJoined = $targetSearchOutput -join "`n"
if ($targetJoined -notmatch 'binmatchapp') {
    throw "search did not match bin target basename: $targetJoined"
}
if ($targetJoined -notmatch 'binmatchapp\s+1\.0\.0\s+main\s+targetbin\.exe') {
    throw "search did not display matched target filename with extension like Scoop: $targetJoined"
}
if ($targetJoined -match 'Target bin manifest') {
    throw "search should not display bin-matched manifest description like Scoop: $targetJoined"
}
if ($targetJoined -match 'binmatchapp\s+1\.0\.0\s+main\s+targetbin(\s|\||$)') {
    throw "search displayed stripped target filename instead of filename with extension: $targetJoined"
}

$upperExtensionManifest = [ordered]@{
    version = '1.0.0'
    description = 'Upper extension manifest'
    bin = 'uppertool.exe'
}
$upperExtensionManifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $bucketDir 'uppertool.JSON') -Encoding UTF8

$upperSearchOutput = & $ScoExe search uppertool
if ($LASTEXITCODE -ne 0) {
    throw "search upper-extension manifest failed with exit code $LASTEXITCODE"
}
$upperJoined = $upperSearchOutput -join "`n"
if ($upperJoined -notmatch 'uppertool') {
    throw "search did not index manifest with uppercase .JSON extension: $upperJoined"
}

$nestedBucketDir = Join-Path $bucketDir 'nested'
New-Item -ItemType Directory -Force -Path $nestedBucketDir | Out-Null
$nestedManifest = [ordered]@{
    version = '1.0.0'
    description = 'Nested manifest description'
    bin = 'nestedtool.exe'
}
$nestedManifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $nestedBucketDir 'nestedtool.json') -Encoding UTF8

$nestedSearchOutput = & $ScoExe search nestedtool
if ($LASTEXITCODE -ne 0) {
    throw "search nested manifest failed with exit code $LASTEXITCODE"
}
$nestedJoined = $nestedSearchOutput -join "`n"
if ($nestedJoined -notmatch 'nestedtool') {
    throw "search did not find recursively nested bucket manifest: $nestedJoined"
}
if ($nestedJoined -match 'Nested manifest description') {
    throw "search should not print recursively nested manifest description like Scoop: $nestedJoined"
}

$rootOnlyBucket = Join-Path $Root 'buckets\rootonly'
New-Item -ItemType Directory -Force -Path $rootOnlyBucket | Out-Null
$rootOnlyManifest = [ordered]@{
    version = '1.0.0'
    description = 'Root-only bucket manifest'
    bin = 'rootonlytool.exe'
}
$rootOnlyManifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $rootOnlyBucket 'rootonlytool.json') -Encoding UTF8

$rootOnlySearchOutput = & $ScoExe search rootonlytool
if ($LASTEXITCODE -ne 0) {
    throw "search root-only bucket manifest failed with exit code $LASTEXITCODE`: $rootOnlySearchOutput"
}
$rootOnlyJoined = $rootOnlySearchOutput -join "`n"
if ($rootOnlyJoined -notmatch 'rootonlytool\s+1\.0\.0\s+rootonly') {
    throw "search did not fall back to bucket root when a local bucket has no bucket subdirectory like Scoop: $rootOnlyJoined"
}
if ($rootOnlyJoined -match 'Root-only bucket manifest') {
    throw "search should not print root-only manifest description like Scoop: $rootOnlyJoined"
}
