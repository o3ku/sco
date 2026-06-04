param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Manifest,
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

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$showOutput = & $ScoExe CACHE SHOW filetool
if ($LASTEXITCODE -ne 0 -or ($showOutput -join "`n") -notmatch 'filetool\s+1\.0\.0\s+\d+') {
    throw "CACHE SHOW did not include filetool entry: $showOutput"
}
$showJoined = $showOutput -join "`n"
if ($showJoined -notmatch 'Total: 1 file, \d+ B') {
    throw "cache show did not include Scoop-style total summary: $showOutput"
}
if ($showJoined.IndexOf('Name') -lt 0 -or $showJoined.IndexOf('Total:') -lt 0 -or $showJoined.IndexOf('Total:') -gt $showJoined.IndexOf('Name')) {
    throw "cache show should print Scoop-style total summary before the cache table: $showJoined"
}
if ($showJoined -notmatch 'Name\s+Version\s+Length' -or $showJoined -notmatch 'filetool\s+1\.0\.0\s+\d+') {
    throw "cache show did not include Scoop-style table: $showOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingRmOutput = & $ScoExe CACHE RM 2>&1
$missingRmExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingRmExitCode -ne 1) {
    throw "CACHE RM without apps returned $missingRmExitCode instead of 1: $missingRmOutput"
}
$missingRmJoined = $missingRmOutput -join "`n"
if ($missingRmJoined -notmatch 'ERROR: <app\(s\)> missing' -or $missingRmJoined -notmatch 'Usage: sco cache show\|rm \[app\(s\)\]') {
    throw "cache rm without apps did not match Scoop usage: $missingRmJoined"
}

$defaultShowOutput = & $ScoExe cache
if ($LASTEXITCODE -ne 0 -or ($defaultShowOutput -join "`n") -notmatch 'filetool\s+1\.0\.0\s+\d+') {
    throw "cache without subcommand did not default to show: $defaultShowOutput"
}

$defaultFilteredOutput = & $ScoExe cache filetool
if ($LASTEXITCODE -ne 0 -or ($defaultFilteredOutput -join "`n") -notmatch 'filetool\s+1\.0\.0\s+\d+') {
    throw "cache <app> did not default to filtered show: $defaultFilteredOutput"
}

$listFilterOutput = & $ScoExe cache list
if ($LASTEXITCODE -ne 0) {
    throw "cache list returned $LASTEXITCODE instead of defaulting to filtered show: $listFilterOutput"
}
if (($listFilterOutput -join "`n") -notmatch 'Total: 0 files, 0 B' -or ($listFilterOutput -join "`n") -match 'filetool\s+1\.0\.0\s+\d+') {
    throw "cache list should be treated as an app filter like Scoop, not as a show alias: $listFilterOutput"
}

$cacheDir = Join-Path $Root 'cache'
$otherCache = Join-Path $cacheDir 'othertool#2.0.0#manual.exe'
$skipCache = Join-Path $cacheDir 'skiptool#3.0.0#manual.exe'
$textCache = Join-Path $cacheDir 'texttool#1.0.0#readme.txt'
$partialCache = Join-Path $cacheDir 'filetool#0.9.0#partial.exe.download'
$twoPartCache = Join-Path $cacheDir 'twoparttool#4.0.0'
$orphanCache = Join-Path $cacheDir 'orphan-cache.bin'
Set-Content -Path $otherCache -Value 'other cache' -Encoding Ascii
Set-Content -Path $skipCache -Value 'skip cache' -Encoding Ascii
Set-Content -Path $textCache -Value 'text cache' -Encoding Ascii
Set-Content -Path $partialCache -Value 'partial cache' -Encoding Ascii
Set-Content -Path $twoPartCache -Value 'two-part cache' -Encoding Ascii
Set-Content -Path $orphanCache -Value 'orphan cache' -Encoding Ascii
Set-Content -Path (Join-Path $cacheDir 'filetool.txt') -Value 'filetool metadata' -Encoding Ascii
Set-Content -Path (Join-Path $cacheDir 'othertool.txt') -Value 'othertool metadata' -Encoding Ascii
Set-Content -Path (Join-Path $cacheDir 'texttool.txt') -Value 'texttool metadata' -Encoding Ascii

$multiShowOutput = & $ScoExe cache show filetool othertool
if ($LASTEXITCODE -ne 0) {
    throw "cache show multiple failed with exit code $LASTEXITCODE`: $multiShowOutput"
}
$multiJoined = $multiShowOutput -join "`n"
if ($multiJoined -notmatch 'filetool\s+1\.0\.0\s+\d+' -or $multiJoined -notmatch 'filetool\s+0\.9\.0\s+\d+' -or $multiJoined -notmatch 'othertool\s+2\.0\.0\s+\d+') {
    throw "cache show multiple did not include both requested apps: $multiJoined"
}
if ($multiJoined -match 'skiptool\s+3\.0\.0\s+\d+') {
    throw "cache show multiple included an unrequested app: $multiJoined"
}

$wildcardShowOutput = & $ScoExe cache show '*'
if ($LASTEXITCODE -ne 0 -or ($wildcardShowOutput -join "`n") -notmatch 'skiptool\s+3\.0\.0\s+\d+') {
    throw "cache show * did not include all cache entries: $wildcardShowOutput"
}
if (($wildcardShowOutput -join "`n") -match 'orphan-cache\.bin') {
    throw "cache show * included an orphan file without a Scoop cache name: $wildcardShowOutput"
}

$dashFilterShowOutput = & $ScoExe cache show -z
if ($LASTEXITCODE -ne 0) {
    throw "cache show -z returned $LASTEXITCODE instead of 0: $dashFilterShowOutput"
}
if (($dashFilterShowOutput -join "`n") -notmatch 'Total: 0 files, 0 B') {
    throw "cache show -z should treat -z as an app filter like Scoop: $dashFilterShowOutput"
}

$dashFilterRemoveOutput = & $ScoExe cache rm -z
if ($LASTEXITCODE -ne 0) {
    throw "cache rm -z returned $LASTEXITCODE instead of 0: $dashFilterRemoveOutput"
}
if (($dashFilterRemoveOutput -join "`n") -notmatch 'Deleted: 0 files, 0 B') {
    throw "cache rm -z should treat -z as an app filter like Scoop: $dashFilterRemoveOutput"
}

$regexShowOutput = & $ScoExe cache show 'file.*'
if ($LASTEXITCODE -ne 0) {
    throw "cache show regex filter failed with exit code $LASTEXITCODE`: $regexShowOutput"
}
if (($regexShowOutput -join "`n") -notmatch 'filetool\s+1\.0\.0\s+\d+') {
    throw "cache show regex filter did not match app names like Scoop: $regexShowOutput"
}

$caseInsensitiveShowOutput = & $ScoExe cache show 'FILE.*'
if ($LASTEXITCODE -ne 0) {
    throw "cache show uppercase regex filter failed with exit code $LASTEXITCODE`: $caseInsensitiveShowOutput"
}
if (($caseInsensitiveShowOutput -join "`n") -notmatch 'filetool\s+1\.0\.0\s+\d+') {
    throw "cache show regex filter should be case-insensitive like Scoop: $caseInsensitiveShowOutput"
}

$textShowOutput = & $ScoExe cache show texttool
if ($LASTEXITCODE -ne 0) {
    throw "cache show text artifact failed with exit code $LASTEXITCODE`: $textShowOutput"
}
if (($textShowOutput -join "`n") -notmatch 'texttool\s+1\.0\.0\s+\d+') {
    throw "cache show skipped a .txt artifact even though Scoop treats app#version#*.txt as cache: $textShowOutput"
}

$twoPartShowOutput = & $ScoExe cache show twoparttool
if ($LASTEXITCODE -ne 0) {
    throw "cache show two-part artifact failed with exit code $LASTEXITCODE`: $twoPartShowOutput"
}
if (($twoPartShowOutput -join "`n") -notmatch 'twoparttool\s+4\.0\.0\s+\d+') {
    throw "cache show should use the second # segment as version even without a URL segment like Scoop: $twoPartShowOutput"
}

$textRemoveOutput = & $ScoExe cache rm texttool
if ($LASTEXITCODE -ne 0) {
    throw "cache rm text artifact failed with exit code $LASTEXITCODE`: $textRemoveOutput"
}
if (($textRemoveOutput -join "`n") -notmatch 'Removing texttool#1\.0\.0#readme\.txt\.\.\.' -or (Test-Path $textCache)) {
    throw "cache rm skipped a .txt artifact even though Scoop removes app#version#*.txt cache: $textRemoveOutput"
}
if (Test-Path (Join-Path $cacheDir 'texttool.txt')) {
    throw "cache rm text artifact did not remove texttool sidecar metadata"
}

$regexRemoveOutput = & $ScoExe cache rm 'skip.*'
if ($LASTEXITCODE -ne 0) {
    throw "cache rm regex filter failed with exit code $LASTEXITCODE`: $regexRemoveOutput"
}
if (($regexRemoveOutput -join "`n") -notmatch 'Removing skiptool#3\.0\.0#manual\.exe\.\.\.' -or (Test-Path $skipCache)) {
    throw "cache rm regex filter did not remove matching app cache like Scoop: $regexRemoveOutput"
}
Set-Content -Path $skipCache -Value 'skip cache' -Encoding Ascii

$caseInsensitiveRemoveOutput = & $ScoExe cache rm 'SKIP.*'
if ($LASTEXITCODE -ne 0) {
    throw "cache rm uppercase regex filter failed with exit code $LASTEXITCODE`: $caseInsensitiveRemoveOutput"
}
if (($caseInsensitiveRemoveOutput -join "`n") -notmatch 'Removing skiptool#3\.0\.0#manual\.exe\.\.\.' -or (Test-Path $skipCache)) {
    throw "cache rm regex filter should be case-insensitive like Scoop: $caseInsensitiveRemoveOutput"
}
Set-Content -Path $skipCache -Value 'skip cache' -Encoding Ascii

$removeOutput = & $ScoExe cache rm filetool othertool
if ($LASTEXITCODE -ne 0) {
    throw "cache rm multiple failed with exit code $LASTEXITCODE"
}
$removeJoined = $removeOutput -join "`n"
if ($removeJoined -notmatch 'Removing filetool#1\.0\.0#.*\.exe\.\.\.' -or
    $removeJoined -notmatch 'Removing filetool#0\.9\.0#partial\.exe\.download\.\.\.' -or
    $removeJoined -notmatch 'Removing othertool#2\.0\.0#manual\.exe\.\.\.') {
    throw "cache rm did not print Scoop-style removing lines: $removeJoined"
}
if ($removeJoined -notmatch 'Deleted: 3 files, \d+ B') {
    throw "cache rm did not include Scoop-style deleted summary: $removeOutput"
}

$cacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'filetool#*.exe')
if ($cacheFiles.Count -ne 0) {
    throw "cache rm left $($cacheFiles.Count) filetool cache entries"
}
if (Test-Path $otherCache) {
    throw "cache rm multiple left othertool cache entry"
}
if (Test-Path $partialCache) {
    throw "cache rm multiple left filetool partial download entry"
}
if (Test-Path (Join-Path $cacheDir 'filetool.txt')) {
    throw "cache rm did not remove filetool sidecar metadata"
}
if (Test-Path (Join-Path $cacheDir 'othertool.txt')) {
    throw "cache rm multiple did not remove othertool sidecar metadata"
}
if (!(Test-Path $skipCache)) {
    throw "cache rm multiple removed an unrequested app cache entry"
}
if (!(Test-Path $orphanCache)) {
    throw "cache rm multiple removed an orphan cache file"
}

foreach ($path in @(
    (Join-Path $Root 'apps\filetool\current\filetool.exe'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "cache rm removed installed output: $path"
    }
}

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "reinstall failed with exit code $LASTEXITCODE"
}

Set-Content -Path (Join-Path $cacheDir 'orphan.txt') -Value 'orphan sidecar' -Encoding Ascii
Set-Content -Path (Join-Path $cacheDir 'stale.partial.download') -Value 'partial download' -Encoding Ascii
$nestedCacheDir = Join-Path $cacheDir 'generated-manifests\orphan\1.0.0'
New-Item -ItemType Directory -Force -Path $nestedCacheDir | Out-Null
Set-Content -Path (Join-Path $nestedCacheDir 'orphan.json') -Value '{}' -Encoding Ascii

& $ScoExe cache rm --all
if ($LASTEXITCODE -ne 0) {
    throw "cache rm --all failed with exit code $LASTEXITCODE"
}

$remainingCacheEntries = @(Get-ChildItem (Join-Path $Root 'cache') -Force)
if ($remainingCacheEntries.Count -ne 0) {
    throw "cache rm --all left cache entries: $($remainingCacheEntries.Name -join ', ')"
}

$emptyShowOutput = (& $ScoExe cache show missingtool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "empty cache show failed with exit code $LASTEXITCODE`: $emptyShowOutput"
}
if ($emptyShowOutput -notmatch 'Total: 0 files, 0 B' -or $emptyShowOutput -match 'No cache entries found') {
    throw "empty cache show did not print Scoop-style zero summary: $emptyShowOutput"
}

$emptyRemoveOutput = (& $ScoExe cache rm missingtool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "empty cache rm failed with exit code $LASTEXITCODE`: $emptyRemoveOutput"
}
if ($emptyRemoveOutput -notmatch 'Deleted: 0 files, 0 B' -or $emptyRemoveOutput -match 'No cache entries found') {
    throw "empty cache rm did not print Scoop-style zero summary: $emptyRemoveOutput"
}
