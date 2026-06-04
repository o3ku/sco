param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
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
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$bucketDir = Join-Path $Root 'buckets\main\bucket'
$manifestPath = Join-Path $bucketDir 'holdtool.json'
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
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingHoldOutput = & $ScoExe hold --global 2>&1
$missingHoldExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingHoldExitCode -ne 1) {
    throw "hold without an app returned $missingHoldExitCode instead of 1: $missingHoldOutput"
}
$missingHoldJoined = $missingHoldOutput -join "`n"
if ($missingHoldJoined -notmatch 'Usage: sco hold <apps>' -or $missingHoldJoined -match 'Usage: sco hold <app> \[options\]' -or $missingHoldJoined -match '<app> missing') {
    throw "hold without an app did not match Scoop usage-only output: $missingHoldJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingUnholdOutput = & $ScoExe unhold --global 2>&1
$missingUnholdExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingUnholdExitCode -ne 1) {
    throw "unhold without an app returned $missingUnholdExitCode instead of 1: $missingUnholdOutput"
}
$missingUnholdJoined = $missingUnholdOutput -join "`n"
if ($missingUnholdJoined -notmatch 'Usage: sco unhold <app>' -or $missingUnholdJoined -match 'Usage: sco unhold <app> \[options\]' -or $missingUnholdJoined -match '<app> missing') {
    throw "unhold without an app did not match Scoop usage-only output: $missingUnholdJoined"
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $globalHoldOutput = & $ScoExe hold --global definitely-missing-global-tool 2>&1
    $globalHoldExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($globalHoldExitCode -ne 1) {
        throw "non-admin hold --global returned $globalHoldExitCode instead of 1: $globalHoldOutput"
    }
    if (($globalHoldOutput -join "`n") -notmatch 'ERROR You need admin rights to hold a global app\.') {
        throw "non-admin hold --global did not match Scoop admin error: $globalHoldOutput"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $globalUnholdOutput = & $ScoExe unhold --global definitely-missing-global-tool 2>&1
    $globalUnholdExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($globalUnholdExitCode -ne 1) {
        throw "non-admin unhold --global returned $globalUnholdExitCode instead of 1: $globalUnholdOutput"
    }
    if (($globalUnholdOutput -join "`n") -notmatch 'ERROR You need admin rights to unhold a global app\.') {
        throw "non-admin unhold --global did not match Scoop admin error: $globalUnholdOutput"
    }
}

$selfHoldOutput = (& $ScoExe hold scoop) -join "`n"
if ($LASTEXITCODE -ne 0 -or $selfHoldOutput -notmatch 'scoop is now held') {
    throw "hold scoop failed: $selfHoldOutput"
}

$configPath = Join-Path $ConfigHome 'scoop\config.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if (-not [string]$config.hold_update_until) {
    throw "hold scoop did not set hold_update_until: $($config | ConvertTo-Json -Compress)"
}

$selfUnholdOutput = (& $ScoExe unhold scoop) -join "`n"
if ($LASTEXITCODE -ne 0 -or $selfUnholdOutput -notmatch 'scoop is no longer held') {
    throw "unhold scoop failed: $selfUnholdOutput"
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($config.PSObject.Properties.Name -contains 'hold_update_until') {
    throw "unhold scoop did not remove hold_update_until: $($config | ConvertTo-Json -Compress)"
}

Write-Manifest '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
& $ScoExe install holdtool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$holdUnknownOutput = & $ScoExe hold -z holdtool 2>&1
$holdUnknownExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($holdUnknownExitCode -ne 1) {
    throw "hold -z returned $holdUnknownExitCode instead of 1: $holdUnknownOutput"
}
if (($holdUnknownOutput -join "`n") -notmatch 'sco hold: Option -z not recognized\.') {
    throw "hold -z did not match Scoop getopt error: $holdUnknownOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$multiHoldOutput = & $ScoExe hold missing-holdtool holdtool 2>&1
$multiHoldExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($multiHoldExitCode -ne 1) {
    throw "hold with one missing app returned $multiHoldExitCode instead of 1: $multiHoldOutput"
}
$multiHoldJoined = $multiHoldOutput -join "`n"
if ($multiHoldJoined -notmatch "ERROR 'missing-holdtool' is not installed\." -or $multiHoldJoined -notmatch 'holdtool is now held') {
    throw "hold with one missing app did not report both failure and successful hold: $multiHoldJoined"
}
$installJson = Get-Content (Join-Path $Root 'apps\holdtool\current\install.json') -Raw | ConvertFrom-Json
if ($installJson.hold -ne $true) {
    throw 'hold stopped before processing the installed app after a missing app'
}

$repeatHoldOutput = (& $ScoExe hold -- holdtool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "hold failed with exit code $LASTEXITCODE`: $repeatHoldOutput"
}
if ($repeatHoldOutput -notmatch "INFO  'holdtool' is already held\.") {
    throw "repeat hold did not match Scoop info output: $repeatHoldOutput"
}

$installJson = Get-Content (Join-Path $Root 'apps\holdtool\current\install.json') -Raw | ConvertFrom-Json
if ($installJson.hold -ne $true) {
    throw 'hold did not set install.json hold flag'
}

$currentHeldStatus = (& $ScoExe status) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "status for current held app failed with exit code $LASTEXITCODE"
}
if ($currentHeldStatus -match 'holdtool\s+1\.0\.0') {
    throw "status should not list a held app that is otherwise current: $currentHeldStatus"
}
if ($currentHeldStatus -notmatch "WARN  Scoop bucket\(s\) out of date\. Run 'scoop update' to get the latest changes\.") {
    throw "status should still report bucket update state for a current held app: $currentHeldStatus"
}

$v2Source = Join-Path $Root 'sources\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $v2Source) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $v2Source -Force
Write-Manifest '1.1.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'

$statusOutput = (& $ScoExe status) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "status failed with exit code $LASTEXITCODE"
}
if ($statusOutput -notmatch 'holdtool' -or $statusOutput -notmatch 'Held package') {
    throw "status did not report held app: $statusOutput"
}

Remove-Item -LiteralPath $manifestPath -Force
$removedHeldStatus = (& $ScoExe status) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "status failed for held app with removed manifest with exit code $LASTEXITCODE"
}
if ($removedHeldStatus -notmatch 'holdtool' -or $removedHeldStatus -notmatch 'Held package' -or $removedHeldStatus -notmatch 'Manifest removed') {
    throw "status did not report both held and removed manifest info: $removedHeldStatus"
}
Write-Manifest '1.1.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'

$updateOutput = (& $ScoExe update '*') -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "update * failed while held with exit code $LASTEXITCODE"
}
if ($updateOutput -notmatch 'held to version 1\.0\.0') {
    throw "update * did not skip held app: $updateOutput"
}

$forceHeldOutput = (& $ScoExe update '*' --force) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "update * --force failed while held with exit code $LASTEXITCODE"
}
if ($forceHeldOutput -notmatch 'held to version 1\.0\.0' -or
    $forceHeldOutput -notmatch "Latest versions for all apps are installed! For more information try 'sco status'" -or
    $forceHeldOutput -match "There aren't any apps installed") {
    throw "update * --force did not handle a held-only app set like Scoop: $forceHeldOutput"
}

$currentManifest = Get-Content (Join-Path $Root 'apps\holdtool\current\manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne '1.0.0') {
    throw 'held app was unexpectedly updated'
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$unholdUnknownOutput = & $ScoExe unhold -z holdtool 2>&1
$unholdUnknownExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($unholdUnknownExitCode -ne 1) {
    throw "unhold -z returned $unholdUnknownExitCode instead of 1: $unholdUnknownOutput"
}
if (($unholdUnknownOutput -join "`n") -notmatch 'sco unhold: Option -z not recognized\.') {
    throw "unhold -z did not match Scoop getopt error: $unholdUnknownOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$multiUnholdOutput = & $ScoExe unhold missing-holdtool holdtool 2>&1
$multiUnholdExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($multiUnholdExitCode -ne 1) {
    throw "unhold with one missing app returned $multiUnholdExitCode instead of 1: $multiUnholdOutput"
}
$multiUnholdJoined = $multiUnholdOutput -join "`n"
if ($multiUnholdJoined -notmatch "ERROR 'missing-holdtool' is not installed\." -or $multiUnholdJoined -notmatch 'holdtool is no longer held') {
    throw "unhold with one missing app did not report both failure and successful unhold: $multiUnholdJoined"
}
$installJson = Get-Content (Join-Path $Root 'apps\holdtool\current\install.json') -Raw | ConvertFrom-Json
if ($installJson.PSObject.Properties.Name -contains 'hold') {
    throw 'unhold stopped before processing the installed app after a missing app'
}

$bucketHoldOutput = (& $ScoExe hold main/holdtool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "bucket-qualified hold failed with exit code $LASTEXITCODE`: $bucketHoldOutput"
}
if ($bucketHoldOutput -notmatch 'holdtool is now held') {
    throw "bucket-qualified hold did not normalize app name like Scoop: $bucketHoldOutput"
}
$installJson = Get-Content (Join-Path $Root 'apps\holdtool\current\install.json') -Raw | ConvertFrom-Json
if ($installJson.hold -ne $true) {
    throw 'bucket-qualified hold did not set hold flag on holdtool'
}

$bucketUnholdOutput = (& $ScoExe unhold main/holdtool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "bucket-qualified unhold failed with exit code $LASTEXITCODE`: $bucketUnholdOutput"
}
if ($bucketUnholdOutput -notmatch 'holdtool is no longer held') {
    throw "bucket-qualified unhold did not normalize app name like Scoop: $bucketUnholdOutput"
}
$installJson = Get-Content (Join-Path $Root 'apps\holdtool\current\install.json') -Raw | ConvertFrom-Json
if ($installJson.PSObject.Properties.Name -contains 'hold') {
    throw 'bucket-qualified unhold did not remove hold flag from holdtool'
}

$repeatUnholdOutput = (& $ScoExe unhold -- holdtool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "unhold failed with exit code $LASTEXITCODE`: $repeatUnholdOutput"
}
if ($repeatUnholdOutput -notmatch "INFO  'holdtool' is not held\.") {
    throw "repeat unhold did not match Scoop info output: $repeatUnholdOutput"
}
$installJson = Get-Content (Join-Path $Root 'apps\holdtool\current\install.json') -Raw | ConvertFrom-Json
if ($installJson.PSObject.Properties.Name -contains 'hold') {
    throw 'unhold did not remove install.json hold flag'
}

& $ScoExe update '*'
if ($LASTEXITCODE -ne 0) {
    throw "update * after unhold failed with exit code $LASTEXITCODE"
}
$currentManifest = Get-Content (Join-Path $Root 'apps\holdtool\current\manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne '1.1.0') {
    throw 'unheld app did not update to 1.1.0'
}
