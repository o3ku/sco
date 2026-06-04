param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome
)

$ErrorActionPreference = 'Stop'

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$GlobalRoot = Join-Path (Split-Path -Parent $Root) 'test-list-query-global'
if (Test-Path $GlobalRoot) {
    Remove-Item -LiteralPath $GlobalRoot -Recurse -Force
}
$env:SCOOP_GLOBAL = $GlobalRoot

$installJson = Join-Path $Root 'apps\demo\1.0\install.json'
$install = Get-Content -Path $installJson -Raw | ConvertFrom-Json
$install | Add-Member -NotePropertyName hold -NotePropertyValue $true -Force
$install.architecture = '32bit'
$install | ConvertTo-Json | Set-Content -Path $installJson -Encoding UTF8

$listOutput = & $ScoExe list
if ($LASTEXITCODE -ne 0) {
    throw "list returned exit code $LASTEXITCODE`: $listOutput"
}
$listJoined = $listOutput -join "`n"
foreach ($pattern in @(
    'Name\s+Version\s+Source\s+Updated\s+Info',
    'demo\s+1\.0\s+main\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s+Held package, 32bit'
)) {
if ($listJoined -notmatch $pattern) {
        throw "list output missing pattern '$pattern': $listJoined"
    }
}

$globalAppRoot = Join-Path $GlobalRoot 'apps\globaldemo'
$globalVersion = Join-Path $globalAppRoot '1.0'
$globalCurrent = Join-Path $globalAppRoot 'current'
New-Item -ItemType Directory -Force -Path $globalVersion, $globalCurrent | Out-Null
@{
    version = '1.0'
    bin = 'demo.exe'
} | ConvertTo-Json | Set-Content -Path (Join-Path $globalCurrent 'manifest.json') -Encoding UTF8
@{
    bucket = 'main'
    architecture = '64bit'
} | ConvertTo-Json | Set-Content -Path (Join-Path $globalVersion 'install.json') -Encoding UTF8

$globalListOutput = & $ScoExe list '^globaldemo$'
if ($LASTEXITCODE -ne 0) {
    throw "list global app query returned exit code $LASTEXITCODE`: $globalListOutput"
}
$globalListJoined = $globalListOutput -join "`n"
if ($globalListJoined -notmatch 'globaldemo\s+1\.0\s+main\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s+Global install') {
    throw "list global app did not report global install in Info like Scoop: $globalListJoined"
}
if ($globalListJoined -match 'globaldemo\s+1\.0\s+main\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s+Global install\s+global(\s|$)') {
    throw "list global app should not append an extra bare global marker: $globalListJoined"
}

$localLateRoot = Join-Path $Root 'apps\zzlocaldemo'
$localLateVersion = Join-Path $localLateRoot '1.0'
$localLateCurrent = Join-Path $localLateRoot 'current'
New-Item -ItemType Directory -Force -Path $localLateVersion, $localLateCurrent | Out-Null
@{
    version = '1.0'
    bin = 'demo.exe'
} | ConvertTo-Json | Set-Content -Path (Join-Path $localLateCurrent 'manifest.json') -Encoding UTF8
@{
    bucket = 'main'
    architecture = '64bit'
} | ConvertTo-Json | Set-Content -Path (Join-Path $localLateVersion 'install.json') -Encoding UTF8

$globalEarlyRoot = Join-Path $GlobalRoot 'apps\aaglobaldemo'
$globalEarlyVersion = Join-Path $globalEarlyRoot '1.0'
$globalEarlyCurrent = Join-Path $globalEarlyRoot 'current'
New-Item -ItemType Directory -Force -Path $globalEarlyVersion, $globalEarlyCurrent | Out-Null
@{
    version = '1.0'
    bin = 'demo.exe'
} | ConvertTo-Json | Set-Content -Path (Join-Path $globalEarlyCurrent 'manifest.json') -Encoding UTF8
@{
    bucket = 'main'
    architecture = '64bit'
} | ConvertTo-Json | Set-Content -Path (Join-Path $globalEarlyVersion 'install.json') -Encoding UTF8

$scopeOrderOutput = & $ScoExe list 'demo$'
if ($LASTEXITCODE -ne 0) {
    throw "list scope-order query returned exit code $LASTEXITCODE`: $scopeOrderOutput"
}
$scopeOrderJoined = $scopeOrderOutput -join "`n"
$localLateIndex = $scopeOrderJoined.IndexOf('zzlocaldemo')
$globalEarlyIndex = $scopeOrderJoined.IndexOf('aaglobaldemo')
if ($localLateIndex -lt 0 -or $globalEarlyIndex -lt 0 -or $localLateIndex -gt $globalEarlyIndex) {
    throw "list should output all local apps before global apps like Scoop, regardless of name sort: $scopeOrderJoined"
}

$noMatchOutput = & $ScoExe list '^missing$'
if ($LASTEXITCODE -ne 0) {
    throw "list query with no matches returned exit code $LASTEXITCODE`: $noMatchOutput"
}

$joined = $noMatchOutput -join "`n"
if ($joined -notmatch "Installed apps matching '\^missing\$':") {
    throw "list query with no matches did not print matching header: $joined"
}
if ($joined -match "There aren't any apps installed") {
    throw "list query with no matches reported an empty install set: $joined"
}
if ($joined -match 'demo') {
    throw "list query with no matches included installed app rows: $joined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidRegexOutput = & $ScoExe list '[' 2>&1
$invalidRegexExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidRegexExitCode -ne 1) {
    throw "invalid regex list returned $invalidRegexExitCode instead of 1: $invalidRegexOutput"
}
if (($invalidRegexOutput -join "`n") -notmatch 'Invalid regular expression') {
    throw "invalid regex list did not report regex parse error: $invalidRegexOutput"
}
