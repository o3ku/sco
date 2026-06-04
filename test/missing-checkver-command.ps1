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
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

$supportedManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/supported.exe'
    hash = ''
    checkver = 'supported ([\d.]+)'
    autoupdate = [ordered]@{
        url = 'https://example.test/supported-$version.exe'
    }
}
$supportedManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'supportedtool.json') -Encoding UTF8

$checkverOnlyManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/checkver.exe'
    hash = ''
    checkver = 'checkveronly ([\d.]+)'
}
$checkverOnlyManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'checkveronly.json') -Encoding UTF8

$autoupdateOnlyManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/autoupdate.exe'
    hash = ''
    autoupdate = [ordered]@{
        url = 'https://example.test/autoupdate-$version.exe'
    }
}
$autoupdateOnlyManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'autoupdateonly.json') -Encoding UTF8

$plainManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/plain.exe'
    hash = ''
}
$plainManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'plaintool.json') -Encoding UTF8

Set-Content -Path (Join-Path $bucketDir 'badtool.json') -Value '{bad json' -Encoding UTF8

$emptySettingsManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/empty.exe'
    hash = ''
    checkver = ''
    autoupdate = ''
}
$emptySettingsManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'emptysettingstool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingDirOutput = & $ScoExe missing-checkver supportedtool 2>&1
$missingDirExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingDirExitCode -eq 0 -or ($missingDirOutput -join "`n") -notmatch 'missing mandatory parameters: Dir') {
    throw "missing-checkver without -Dir did not match PowerShell mandatory parameter behavior: $missingDirOutput"
}

$output = & $ScoExe missing-checkver -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "missing-checkver failed with exit code $LASTEXITCODE`: $output"
}

$joined = $output -join "`n"
if ($joined -notmatch '\[C\]\[A\] supportedtool') {
    throw "missing-checkver did not report supported manifest: $joined"
}
if ($joined -notmatch '\[C\]\[ \] checkveronly') {
    throw "missing-checkver did not report checkver-only manifest: $joined"
}
if ($joined -notmatch '\[ \]\[A\] autoupdateonly') {
    throw "missing-checkver did not report autoupdate-only manifest: $joined"
}
if ($joined -notmatch '\[ \]\[ \] plaintool') {
    throw "missing-checkver did not report unsupported manifest: $joined"
}
if ($joined -notmatch '\[ \]\[ \] badtool') {
    throw "missing-checkver should report invalid JSON manifests as unsupported like Scoop: $joined"
}
if ($joined -notmatch '\[ \]\[ \] emptysettingstool') {
    throw "missing-checkver should treat empty checkver/autoupdate values as absent: $joined"
}

$skipOutput = & $ScoExe missing-checkver -Dir $bucketDir -SkipSupported
if ($LASTEXITCODE -ne 0) {
    throw "missing-checkver -SkipSupported failed with exit code $LASTEXITCODE`: $skipOutput"
}
$skipJoined = $skipOutput -join "`n"
if ($skipJoined -match 'supportedtool' -or $skipJoined -notmatch 'plaintool' -or $skipJoined -notmatch 'badtool' -or $skipJoined -notmatch 'emptysettingstool' -or $skipJoined -notmatch 'checkveronly' -or $skipJoined -notmatch 'autoupdateonly') {
    throw "missing-checkver -SkipSupported did not filter only fully supported manifests: $skipJoined"
}

$skipFalseOutput = & $ScoExe missing-checkver -Dir $bucketDir '-SkipSupported:$false'
if ($LASTEXITCODE -ne 0) {
    throw "missing-checkver -SkipSupported:`$false failed with exit code $LASTEXITCODE`: $skipFalseOutput"
}
if (($skipFalseOutput -join "`n") -notmatch 'supportedtool') {
    throw "missing-checkver -SkipSupported:`$false should keep supported manifests visible: $skipFalseOutput"
}

$patternOutput = & $ScoExe missing-checkver '*only' -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "missing-checkver app pattern failed with exit code $LASTEXITCODE`: $patternOutput"
}
$patternJoined = $patternOutput -join "`n"
if ($patternJoined -match 'supportedtool|plaintool' -or $patternJoined -notmatch 'checkveronly' -or $patternJoined -notmatch 'autoupdateonly') {
    throw "missing-checkver app pattern did not match expected manifests: $patternJoined"
}

$singleCharPatternOutput = & $ScoExe missing-checkver 'checkver?nly' -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "missing-checkver ? app pattern failed with exit code $LASTEXITCODE`: $singleCharPatternOutput"
}
$singleCharPatternJoined = $singleCharPatternOutput -join "`n"
if ($singleCharPatternJoined -notmatch 'checkveronly' -or $singleCharPatternJoined -match 'autoupdateonly|supportedtool|plaintool') {
    throw "missing-checkver ? app pattern did not match PowerShell wildcard behavior: $singleCharPatternJoined"
}

$positionalDirOutput = & $ScoExe missing-checkver '*only' $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "missing-checkver positional App Dir failed with exit code $LASTEXITCODE`: $positionalDirOutput"
}
$positionalDirJoined = $positionalDirOutput -join "`n"
if ($positionalDirJoined -match 'supportedtool|plaintool' -or $positionalDirJoined -notmatch 'checkveronly' -or $positionalDirJoined -notmatch 'autoupdateonly') {
    throw "missing-checkver positional App Dir did not match PowerShell parameter binding: $positionalDirJoined"
}

$namedAppOutput = & $ScoExe missing-checkver -App '*only' -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "missing-checkver -App failed with exit code $LASTEXITCODE`: $namedAppOutput"
}
if (($namedAppOutput -join "`n") -match 'supportedtool|plaintool') {
    throw "missing-checkver -App did not select the requested manifests: $namedAppOutput"
}

$helpOutput = & $ScoExe missing-checkver --help
if ($LASTEXITCODE -ne 0 -or ($helpOutput -join "`n") -notmatch 'Usage: sco missing-checkver') {
    throw "missing-checkver --help failed: $helpOutput"
}

$ErrorActionPreference = 'Continue'
$badSwitchOutput = & $ScoExe missing-checkver -Dir $bucketDir -SkipSupported:nope 2>&1
$badSwitchExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badSwitchExitCode -eq 0 -or ($badSwitchOutput -join "`n") -notmatch 'must be a boolean value') {
    throw "missing-checkver invalid switch value was not rejected: $badSwitchOutput"
}
