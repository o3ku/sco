param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$GlobalRoot,
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
if (Test-Path $GlobalRoot) {
    Remove-Item -LiteralPath $GlobalRoot -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$bucketDir = Join-Path $Root 'buckets\main\bucket'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

function Write-Manifest($Name, $Depends, $Directory = $bucketDir) {
    $manifest = [ordered]@{
        version = '1.0.0'
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        bin = 'filetool.exe'
    }
    if ($Depends) {
        $manifest.depends = $Depends
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $Directory "$Name.json") -Encoding UTF8
}

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome

function Install-GlobalStandaloneInstallFixture($ManifestPath) {
    $previousScoop = $env:SCOOP
    $previousGlobal = $env:SCOOP_GLOBAL
    try {
        $env:SCOOP = $GlobalRoot
        Remove-Item Env:SCOOP_GLOBAL -ErrorAction SilentlyContinue
        & $ScoExe install $ManifestPath --no-update-scoop
    } finally {
        $env:SCOOP = $previousScoop
        $env:SCOOP_GLOBAL = $previousGlobal
    }
}

Write-Manifest 'deptool' $null
Write-Manifest 'apptool' 'deptool'
Write-Manifest 'othertool' $null
Write-Manifest '1' $null
Write-Manifest 'numericdeptool' 1
Write-Manifest 'circlea' 'circleb'
Write-Manifest 'circleb' 'circlea'

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$circularOutput = & $ScoExe install circlea --no-update-scoop 2>&1
$circularExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($circularExitCode -ne 1) {
    throw "install circular dependency returned $circularExitCode instead of 1: $circularOutput"
}
if (($circularOutput -join "`n") -notmatch "ERROR Circular dependency detected: 'circleb' -> 'circlea'\.") {
    throw "install circular dependency did not match Scoop error: $circularOutput"
}

$numericDepInstallOutput = (& $ScoExe install numericdeptool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install with numeric dependency failed with exit code $LASTEXITCODE`: $numericDepInstallOutput"
}
$numericDepIndex = $numericDepInstallOutput.IndexOf("Installing '1' (1.0.0) [64bit] from 'main' bucket")
$numericAppIndex = $numericDepInstallOutput.IndexOf("Installing 'numericdeptool' (1.0.0) [64bit] from 'main' bucket")
if ($numericDepIndex -lt 0 -or $numericAppIndex -lt 0 -or $numericDepIndex -gt $numericAppIndex) {
    throw "install should stringify and install numeric dependencies before the requested app like Scoop: $numericDepInstallOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\1\current\filetool.exe')) -or !(Test-Path (Join-Path $Root 'apps\numericdeptool\current\filetool.exe'))) {
    throw 'install with numeric dependency did not create expected app directories'
}

& $ScoExe install apptool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

foreach ($path in @(
    (Join-Path $Root 'apps\deptool\current\filetool.exe'),
    (Join-Path $Root 'apps\apptool\current\filetool.exe')
)) {
    if (!(Test-Path $path)) {
        throw "Missing dependency install output: $path"
    }
}

$listOutput = & $ScoExe list
$joined = $listOutput -join "`n"
if ($joined -notmatch 'deptool' -or $joined -notmatch 'apptool') {
    throw "list did not include dependency and app: $joined"
}

$multiInstallOutput = (& $ScoExe install apptool othertool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "multi install with already-installed explicit app failed with exit code $LASTEXITCODE`: $multiInstallOutput"
}
if ($multiInstallOutput -notmatch "WARN  'apptool' \(1\.0\.0\) is already installed\. Skipping\.") {
    throw "multi install did not warn for explicit already-installed app: $multiInstallOutput"
}
if ($multiInstallOutput -match "deptool'.*Skipping" -or $multiInstallOutput -match "Installing 'deptool'" -or $multiInstallOutput -match "Installing 'apptool'") {
    throw "multi install did not silently prune already-installed dependency/app: $multiInstallOutput"
}
if ($multiInstallOutput -notmatch "Installing 'othertool' \(1\.0\.0\) \[64bit\] from 'main' bucket" -or $multiInstallOutput -notmatch "'othertool' \(1\.0\.0\) was installed successfully!") {
    throw "multi install did not install remaining app: $multiInstallOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\othertool\current\filetool.exe'))) {
    throw 'multi install did not install othertool'
}

$globalStandaloneDir = Join-Path (Split-Path -Parent $Root) 'install-global-source'
New-Item -ItemType Directory -Force -Path $globalStandaloneDir | Out-Null
$globalStandaloneManifest = Join-Path $globalStandaloneDir 'installbothscope.json'
@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
} | ConvertTo-Json | Set-Content -Path $globalStandaloneManifest -Encoding UTF8

Install-GlobalStandaloneInstallFixture $globalStandaloneManifest
if ($LASTEXITCODE -ne 0) {
    throw "global standalone install fixture failed with exit code $LASTEXITCODE"
}

$localFromGlobalOutput = (& $ScoExe install installbothscope --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install should resolve a global standalone install source for local install like Scoop, got $LASTEXITCODE`: $localFromGlobalOutput"
}
if ($localFromGlobalOutput -notmatch "Installing 'installbothscope' \(1\.0\.0\) \[64bit\] from '.*/install-global-source/installbothscope\.json'") {
    throw "install did not report global standalone manifest source: $localFromGlobalOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\installbothscope\current\filetool.exe'))) {
    throw 'install did not create local app from global standalone source'
}
$localFromGlobalInstall = Get-Content (Join-Path $Root 'apps\installbothscope\current\install.json') -Raw | ConvertFrom-Json
if ($localFromGlobalInstall.bucket -or $localFromGlobalInstall.url.Replace('\', '/') -notlike '*/install-global-source/installbothscope.json') {
    throw "local install did not record global standalone source: $($localFromGlobalInstall | ConvertTo-Json -Compress)"
}

$otherBucketDir = Join-Path $Root 'buckets\other\bucket'
New-Item -ItemType Directory -Force -Path $otherBucketDir | Out-Null
Write-Manifest 'shareddep' $null
Write-Manifest 'otheronlydep' $null $otherBucketDir
Write-Manifest 'shareddep' 'other/otheronlydep' $otherBucketDir
Write-Manifest 'crossbuckettool' @('shareddep', 'other/shareddep')

$crossInstallOutput = (& $ScoExe install crossbuckettool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install with same-name cross-bucket dependencies failed with exit code $LASTEXITCODE`: $crossInstallOutput"
}
if ($crossInstallOutput -notmatch "Installing 'shareddep' \(1\.0\.0\) \[64bit\] from 'main' bucket" -or
    $crossInstallOutput -notmatch "Installing 'otheronlydep' \(1\.0\.0\) \[64bit\] from 'other' bucket" -or
    $crossInstallOutput -notmatch "Installing 'crossbuckettool' \(1\.0\.0\) \[64bit\] from 'main' bucket") {
    throw "install should resolve same-name dependencies from different buckets without dropping either request: $crossInstallOutput"
}
if ($crossInstallOutput -match "Installing 'shareddep' \(1\.0\.0\) \[64bit\] from 'other' bucket") {
    throw "install should not reinstall a dependency whose app name is already installed: $crossInstallOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\crossbuckettool\current\filetool.exe'))) {
    throw 'cross-bucket dependency install did not install the requested app'
}
if (!(Test-Path (Join-Path $Root 'apps\otheronlydep\current\filetool.exe'))) {
    throw 'cross-bucket dependency traversal skipped dependency unique to other/shareddep'
}

$deprecatedDir = Join-Path $Root 'buckets\main\deprecated'
New-Item -ItemType Directory -Force -Path $deprecatedDir | Out-Null
Copy-Item -LiteralPath (Join-Path $bucketDir 'apptool.json') -Destination (Join-Path $deprecatedDir 'APPTOOL.JSON') -Force

$appToolInstallPath = Join-Path $Root 'apps\apptool\current\install.json'
$appToolInstall = Get-Content $appToolInstallPath -Raw | ConvertFrom-Json
$appToolInstall.bucket = 'MAIN'
$appToolInstall | ConvertTo-Json | Set-Content -Path $appToolInstallPath -Encoding UTF8

$deprecatedListOutput = & $ScoExe list
if ($LASTEXITCODE -ne 0) {
    throw "list failed after marking app deprecated with exit code $LASTEXITCODE"
}
$deprecatedListJoined = $deprecatedListOutput -join "`n"
if ($deprecatedListJoined -notmatch 'apptool' -or $deprecatedListJoined -notmatch 'Deprecated package') {
    throw "list did not report deprecated package info: $deprecatedListJoined"
}

$deprecatedStatusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status failed for deprecated app with exit code $LASTEXITCODE"
}
$deprecatedStatusJoined = $deprecatedStatusOutput -join "`n"
if ($deprecatedStatusJoined -notmatch 'apptool' -or $deprecatedStatusJoined -notmatch 'Deprecated') {
    throw "status did not report deprecated app: $deprecatedStatusJoined"
}

& $ScoExe uninstall deptool
if ($LASTEXITCODE -ne 0) {
    throw "dependency uninstall failed with exit code $LASTEXITCODE"
}

$statusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status failed after dependency removal with exit code $LASTEXITCODE"
}

$statusJoined = $statusOutput -join "`n"
if ($statusJoined -notmatch 'apptool' -or $statusJoined -notmatch 'deptool') {
    throw "status did not report missing dependency for apptool: $statusJoined"
}
