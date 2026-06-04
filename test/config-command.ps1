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

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$emptyOutput = & $ScoExe config
if ($LASTEXITCODE -ne 0) {
    throw "config with no config file failed with exit code $LASTEXITCODE`: $emptyOutput"
}
if (($emptyOutput -join "`n").Trim()) {
    throw "config with no config file should not print an empty JSON object: $emptyOutput"
}

$shortHelpOutput = (& $ScoExe config -h) -join "`n"
if ($LASTEXITCODE -ne 0 -or $shortHelpOutput -notmatch 'Usage: sco config \[rm\] name \[value\]' -or $shortHelpOutput -notmatch 'use_sqlite_cache') {
    throw "config -h should be handled by Scoop's top-level help dispatcher: $shortHelpOutput"
}

$setOutput = (& $ScoExe config aria2-enabled false) -join "`n"
if ($LASTEXITCODE -ne 0 -or $setOutput -notmatch "'aria2-enabled' has been set to 'false'") {
    throw "config set failed: $setOutput"
}

$getOutput = (& $ScoExe config aria2-enabled) -join "`n"
if ($LASTEXITCODE -ne 0 -or $getOutput.Trim() -ne 'False') {
    throw "config get did not return false boolean: $getOutput"
}

$configPath = Join-Path $ConfigHome 'scoop\config.json'
$json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($json.'aria2-enabled' -ne $false) {
    throw "config set did not persist a JSON boolean: $($json | ConvertTo-Json -Compress)"
}

$rmOutput = (& $ScoExe config rm aria2-enabled) -join "`n"
if ($LASTEXITCODE -ne 0 -or $rmOutput -notmatch "'aria2-enabled' has been removed") {
    throw "config rm failed: $rmOutput"
}

$getRemovedOutput = (& $ScoExe config aria2-enabled) -join "`n"
if ($LASTEXITCODE -ne 0 -or $getRemovedOutput -notmatch "'aria2-enabled' is not set") {
    throw "config get after rm did not report unset: $getRemovedOutput"
}

$missingRmOutput = (& $ScoExe config rm) -join "`n"
if ($LASTEXITCODE -ne 0 -or $missingRmOutput.Trim() -ne "'' has been removed") {
    throw "config rm without a name did not match Scoop's non-fatal output: $missingRmOutput"
}

$json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($json.PSObject.Properties.Name -contains '') {
    throw "config rm without a name should not create an empty config key: $($json | ConvertTo-Json -Compress)"
}

$setUppercaseOutput = (& $ScoExe config aria2-enabled TRUE) -join "`n"
if ($LASTEXITCODE -ne 0 -or $setUppercaseOutput -notmatch "'aria2-enabled' has been set to 'TRUE'") {
    throw "config set with uppercase boolean failed: $setUppercaseOutput"
}

$getUppercaseOutput = (& $ScoExe config aria2-enabled) -join "`n"
if ($LASTEXITCODE -ne 0 -or $getUppercaseOutput.Trim() -ne 'True') {
    throw "config get did not return true boolean after uppercase set: $getUppercaseOutput"
}

$json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($json.'aria2-enabled' -ne $true) {
    throw "config uppercase boolean did not persist as a JSON boolean: $($json | ConvertTo-Json -Compress)"
}

$setLiteralBoolOutput = (& $ScoExe config literal-bool '$true') -join "`n"
if ($LASTEXITCODE -ne 0 -or $setLiteralBoolOutput.Trim() -ne "'literal-bool' has been set to '`$true'") {
    throw "config set literal `$true string failed: $setLiteralBoolOutput"
}

$getLiteralBoolOutput = (& $ScoExe config literal-bool) -join "`n"
if ($LASTEXITCODE -ne 0 -or $getLiteralBoolOutput.Trim() -ne '$true') {
    throw "config get literal `$true should return the original string like Scoop: $getLiteralBoolOutput"
}

$json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($json.'literal-bool' -ne '$true') {
    throw "config literal `$true should persist as a JSON string, not a boolean: $($json | ConvertTo-Json -Compress)"
}

@{
    Default_Architecture = '32bit'
    MIXED_BOOL = $true
} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

$mixedCaseGetOutput = (& $ScoExe config default_architecture) -join "`n"
if ($LASTEXITCODE -ne 0 -or $mixedCaseGetOutput.Trim() -ne '32bit') {
    throw "config get should read existing keys case-insensitively like Scoop: $mixedCaseGetOutput"
}

$mixedCaseSetOutput = (& $ScoExe config mixed_bool false) -join "`n"
if ($LASTEXITCODE -ne 0 -or $mixedCaseSetOutput -notmatch "'mixed_bool' has been set to 'false'") {
    throw "config set should update existing mixed-case keys case-insensitively: $mixedCaseSetOutput"
}
$json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($json.MIXED_BOOL -ne $false -or ($json.PSObject.Properties.Name -ccontains 'mixed_bool')) {
    throw "config set created a duplicate normalized key instead of updating the existing key: $($json | ConvertTo-Json -Compress)"
}

$mixedCaseRmOutput = (& $ScoExe config rm default_architecture) -join "`n"
if ($LASTEXITCODE -ne 0 -or $mixedCaseRmOutput -notmatch "'default_architecture' has been removed") {
    throw "config rm should remove existing mixed-case keys case-insensitively: $mixedCaseRmOutput"
}
$json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($json.PSObject.Properties.Name -ccontains 'Default_Architecture') {
    throw "config rm did not remove mixed-case key: $($json | ConvertTo-Json -Compress)"
}

$setUppercaseOutput = (& $ScoExe config aria2-enabled TRUE) -join "`n"
if ($LASTEXITCODE -ne 0 -or $setUppercaseOutput -notmatch "'aria2-enabled' has been set to 'TRUE'") {
    throw "config set with uppercase boolean after mixed-case checks failed: $setUppercaseOutput"
}

$setStringOutput = (& $ScoExe config foo abc) -join "`n"
if ($LASTEXITCODE -ne 0 -or $setStringOutput -notmatch "'foo' has been set to 'abc'") {
    throw "config set string failed: $setStringOutput"
}

$allOutput = (& $ScoExe config) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "config get all failed: $allOutput"
}
if ($allOutput -match '^\s*\{') {
    throw "config get all should use Scoop-style table formatting, not JSON: $allOutput"
}
if ($allOutput -notmatch 'aria2-enabled' -or $allOutput -notmatch 'foo' -or $allOutput -notmatch 'True' -or $allOutput -notmatch 'abc') {
    throw "config get all did not include expected table values: $allOutput"
}

@{
    'aria2-options' = @('--check-certificate=false', '--foo=bar')
    alias = [ordered]@{
        ls = 'scoop-list'
        rm = 'scoop-uninstall'
    }
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

$arrayOutput = (& $ScoExe config aria2-options) -join "`n"
if ($LASTEXITCODE -ne 0 -or $arrayOutput.Trim() -ne "--check-certificate=false`n--foo=bar") {
    throw "config get array did not emit one value per line like Scoop: $arrayOutput"
}

$objectOutput = (& $ScoExe config alias) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "config get object failed: $objectOutput"
}
if ($objectOutput -match '^\s*\{') {
    throw "config get object should use Scoop-style table formatting, not JSON: $objectOutput"
}
if ($objectOutput -notmatch 'ls\s+rm' -or $objectOutput -notmatch 'scoop-list\s+scoop-uninstall') {
    throw "config get object did not include expected table values: $objectOutput"
}

$bucketDir = Join-Path $Root 'buckets\main\bucket'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
$sqliteManifest = [ordered]@{
    version = '1.0.0'
    description = 'Config initialized SQLite cache manifest'
    bin = 'configcache.exe'
}
$sqliteManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'configcache.json') -Encoding UTF8
$indexPath = Join-Path $Root 'cache\buckets.index.json'
Remove-Item -LiteralPath $indexPath -Force -ErrorAction SilentlyContinue

$sqliteOutput = (& $ScoExe config use_sqlite_cache true) -join "`n"
if ($LASTEXITCODE -ne 0 -or $sqliteOutput -notmatch 'Initializing SQLite cache') {
    throw "config use_sqlite_cache true did not initialize cache: $sqliteOutput"
}
if (!(Test-Path $indexPath)) {
    throw "config use_sqlite_cache true did not create bucket manifest index: $indexPath"
}
$index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
$indexEntry = @($index.entries | Where-Object { $_.name -eq 'configcache' })[0]
if ($null -eq $indexEntry -or $indexEntry.description -ne 'Config initialized SQLite cache manifest') {
    throw "config use_sqlite_cache true did not index bucket manifests: $($index | ConvertTo-Json -Compress)"
}

& $ScoExe config default_architecture arm64 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config default_architecture arm64 failed with exit code $LASTEXITCODE"
}
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$arm64SqliteOutput = & $ScoExe config use_sqlite_cache true 2>&1
$arm64SqliteExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($arm64SqliteExit -ne 1) {
    throw "config use_sqlite_cache true under arm64 default architecture returned $arm64SqliteExit instead of 1: $arm64SqliteOutput"
}
if (($arm64SqliteOutput -join "`n") -notmatch 'SQLite cache is not supported on ARM64 platform') {
    throw "config use_sqlite_cache true under arm64 default architecture did not match Scoop error: $arm64SqliteOutput"
}
& $ScoExe config rm default_architecture | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config rm default_architecture failed with exit code $LASTEXITCODE"
}

$envFile = Join-Path $Root 'env.json'
$env:SCOOP_ENV_FILE = $envFile
$appPath = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\pathtool\current')).TrimEnd('\')
$appBinPath = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\pathtool\current\bin')).TrimEnd('\')
New-Item -ItemType Directory -Force -Path $appBinPath | Out-Null
@{ PATH = "$appPath;$appBinPath;C:\Windows" } | ConvertTo-Json | Set-Content -Path $envFile -Encoding UTF8

$enableIsolatedOutput = (& $ScoExe config use_isolated_path true) -join "`n"
if ($LASTEXITCODE -ne 0 -or $enableIsolatedOutput -notmatch "'use_isolated_path' has been set to 'true'") {
    throw "config use_isolated_path true failed: $enableIsolatedOutput"
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
if ([string]$envJson.PATH -ne '%SCOOP_PATH%;C:\Windows') {
    throw "config use_isolated_path true did not bridge PATH through SCOOP_PATH: $($envJson.PATH)"
}
$scoopPathEntries = @([string]$envJson.SCOOP_PATH -split ';' | Where-Object { $_ })
if ($scoopPathEntries.Count -ne 2 -or $scoopPathEntries[0].TrimEnd('\') -ne $appPath -or $scoopPathEntries[1].TrimEnd('\') -ne $appBinPath) {
    throw "config use_isolated_path true did not move app paths into SCOOP_PATH: $($envJson.SCOOP_PATH)"
}

$customIsolatedOutput = (& $ScoExe config use_isolated_path scoop_alt_path) -join "`n"
if ($LASTEXITCODE -ne 0 -or $customIsolatedOutput -notmatch "'use_isolated_path' has been set to 'scoop_alt_path'") {
    throw "config use_isolated_path custom variable failed: $customIsolatedOutput"
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
if ([string]$envJson.PATH -ne '%SCOOP_ALT_PATH%;C:\Windows') {
    throw "config use_isolated_path custom variable did not replace PATH bridge: $($envJson.PATH)"
}
if ([string]$envJson.SCOOP_PATH) {
    throw "config use_isolated_path custom variable did not clear old SCOOP_PATH: $($envJson.SCOOP_PATH)"
}
$customPathEntries = @([string]$envJson.SCOOP_ALT_PATH -split ';' | Where-Object { $_ })
if ($customPathEntries.Count -ne 2 -or $customPathEntries[0].TrimEnd('\') -ne $appPath -or $customPathEntries[1].TrimEnd('\') -ne $appBinPath) {
    throw "config use_isolated_path custom variable did not move app paths into SCOOP_ALT_PATH: $($envJson.SCOOP_ALT_PATH)"
}

$disableIsolatedOutput = (& $ScoExe config rm use_isolated_path) -join "`n"
if ($LASTEXITCODE -ne 0 -or $disableIsolatedOutput -notmatch "'use_isolated_path' has been removed") {
    throw "config rm use_isolated_path failed: $disableIsolatedOutput"
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
if ([string]$envJson.SCOOP_ALT_PATH) {
    throw "config rm use_isolated_path did not clear custom isolated variable: $($envJson.SCOOP_ALT_PATH)"
}
$restoredPathEntries = @([string]$envJson.PATH -split ';' | Where-Object { $_ })
if ($restoredPathEntries.Count -ne 3 -or $restoredPathEntries[0].TrimEnd('\') -ne $appPath -or $restoredPathEntries[1].TrimEnd('\') -ne $appBinPath -or $restoredPathEntries[2] -ne 'C:\Windows') {
    throw "config rm use_isolated_path did not restore app paths to PATH: $($envJson.PATH)"
}
