param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome,
    [Parameter(Mandatory = $true)][string]$GlobalRoot,
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
$manifestPath = Join-Path $bucketDir 'resettool.json'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

function Write-Manifest($Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = @(, @('filetool.exe', 'resettool'))
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}

function Install-GlobalResetFixture {
    $previousScoop = $env:SCOOP
    $previousGlobal = $env:SCOOP_GLOBAL
    try {
        $env:SCOOP = $GlobalRoot
        Remove-Item Env:SCOOP_GLOBAL -ErrorAction SilentlyContinue
        $globalBucketDir = Join-Path $GlobalRoot 'buckets\main\bucket'
        New-Item -ItemType Directory -Force -Path $globalBucketDir | Out-Null
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $globalBucketDir 'resettool.json') -Force
        & $ScoExe install resettool --no-update-scoop
    } finally {
        $env:SCOOP = $previousScoop
        $env:SCOOP_GLOBAL = $previousGlobal
    }
}

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$resetHelp = (& $ScoExe reset --help) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "reset --help failed with exit code $LASTEXITCODE`: $resetHelp"
}
if ($resetHelp -match '--global') {
    throw "reset help should not advertise --global: $resetHelp"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAppOutput = & $ScoExe reset 2>&1
$missingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppExitCode -ne 1) {
    throw "reset without an app returned $missingAppExitCode instead of 1: $missingAppOutput"
}
if (($missingAppOutput -join "`n") -notmatch 'ERROR <app> missing' -or ($missingAppOutput -join "`n") -notmatch 'Usage: sco reset <app>' -or ($missingAppOutput -join "`n") -match 'Usage: sco reset <app> \[version\] \[options\]') {
    throw "reset without an app did not match Scoop usage output: $missingAppOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAppWithTerminatorOutput = & $ScoExe reset -- 2>&1
$missingAppWithTerminatorExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppWithTerminatorExitCode -ne 1) {
    throw "reset -- without an app returned $missingAppWithTerminatorExitCode instead of 1: $missingAppWithTerminatorOutput"
}
if (($missingAppWithTerminatorOutput -join "`n") -notmatch 'ERROR <app> missing' -or ($missingAppWithTerminatorOutput -join "`n") -notmatch 'Usage: sco reset <app>' -or ($missingAppWithTerminatorOutput -join "`n") -match 'Usage: sco reset <app> \[version\] \[options\]') {
    throw "reset -- without an app did not match Scoop usage output: $missingAppWithTerminatorOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$globalOptionOutput = & $ScoExe reset --global resettool 2>&1
$globalOptionExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($globalOptionExitCode -ne 1) {
    throw "reset --global returned $globalOptionExitCode instead of 1: $globalOptionOutput"
}
if (($globalOptionOutput -join "`n") -notmatch 'sco reset: Option --global not recognized\.') {
    throw "reset --global did not match Scoop getopt error: $globalOptionOutput"
}

$emptyAllOutput = (& $ScoExe reset --all) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "reset --all on empty install set returned $LASTEXITCODE`: $emptyAllOutput"
}
if ($emptyAllOutput.Trim()) {
    throw "reset --all on empty install set should not print output: $emptyAllOutput"
}

Write-Manifest '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
& $ScoExe install resettool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$v2Source = Join-Path $Root 'sources\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $v2Source) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $v2Source -Force
Write-Manifest '1.1.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'

& $ScoExe update resettool
if ($LASTEXITCODE -ne 0) {
    throw "update failed with exit code $LASTEXITCODE"
}

$currentContent = (Get-Content (Join-Path $Root 'apps\resettool\current\filetool.exe') -Raw).TrimEnd()
if ($currentContent -ne '@echo filetool-v2') {
    throw "current did not update to v2 before reset: $currentContent"
}

New-Item -ItemType Directory -Force -Path (Join-Path $GlobalRoot 'apps\resettool') | Out-Null

$resetTerminatorOutput = (& $ScoExe reset -- resettool 1.0.0) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "reset -- terminator failed with exit code $LASTEXITCODE`: $resetTerminatorOutput"
}
if ($resetTerminatorOutput -notmatch 'Resetting resettool \(1\.0\.0\)\.' -or
    $resetTerminatorOutput -notmatch 'Linking .+apps\\resettool\\current => .+apps\\resettool\\1\.0\.0' -or
    $resetTerminatorOutput -match 'Junction created') {
    throw "reset -- terminator did not print Scoop-style current relink output: $resetTerminatorOutput"
}

$currentContent = (Get-Content (Join-Path $Root 'apps\resettool\current\filetool.exe') -Raw).TrimEnd()
if ($currentContent -ne 'filetool fixture') {
    throw "current did not reset to v1: $currentContent"
}

$currentManifest = Get-Content (Join-Path $Root 'apps\resettool\current\manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne '1.0.0') {
    throw "current manifest did not reset to 1.0.0"
}

& $ScoExe reset resettool@1.1.0
if ($LASTEXITCODE -ne 0) {
    throw "reset app@version failed with exit code $LASTEXITCODE"
}
$currentManifest = Get-Content (Join-Path $Root 'apps\resettool\current\manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne '1.1.0') {
    throw 'reset app@version did not reset to 1.1.0'
}

$missingAppOutput = & $ScoExe reset missing-resettool 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "reset missing app should report an error but exit 0, got $LASTEXITCODE`: $missingAppOutput"
}
if (($missingAppOutput -join "`n") -notmatch "'missing-resettool' isn't installed\.") {
    throw "reset missing app did not report Scoop-style error: $missingAppOutput"
}

$missingAppVersionOutput = & $ScoExe reset missing-resettool@1.0.0 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "reset missing app@version should report an error but exit 0, got $LASTEXITCODE`: $missingAppVersionOutput"
}
$missingAppVersionJoined = $missingAppVersionOutput -join "`n"
if ($missingAppVersionJoined -notmatch "'missing-resettool' isn't installed\." -or $missingAppVersionJoined -match 'missing-resettool \(1\.0\.0\)') {
    throw "reset missing app@version should report the missing app before the version: $missingAppVersionJoined"
}

$missingVersionOutput = & $ScoExe reset resettool@9.9.9 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "reset missing version should report an error but exit 0, got $LASTEXITCODE`: $missingVersionOutput"
}
if (($missingVersionOutput -join "`n") -notmatch "'resettool \(9\.9\.9\)' isn't installed\.") {
    throw "reset missing version did not report Scoop-style error: $missingVersionOutput"
}

$missingSeparateVersionOutput = & $ScoExe reset resettool 9.9.9 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "reset missing separate version should report an error but exit 0, got $LASTEXITCODE`: $missingSeparateVersionOutput"
}
if (($missingSeparateVersionOutput -join "`n") -notmatch "'resettool \(9\.9\.9\)' isn't installed\.") {
    throw "reset missing separate version did not report Scoop-style error: $missingSeparateVersionOutput"
}

$shim = Get-Content (Join-Path $Root 'shims\resettool.shim') -Raw
if ($shim -notmatch 'apps\\resettool\\current\\filetool\.exe') {
    throw "reset did not recreate shim against current: $shim"
}

& $ScoExe reset main/resettool 1.1.0
if ($LASTEXITCODE -ne 0) {
    throw "bucket-qualified reset failed with exit code $LASTEXITCODE"
}

$currentManifest = Get-Content (Join-Path $Root 'apps\resettool\current\manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne '1.1.0') {
    throw "bucket-qualified reset did not normalize app name to reset 1.1.0"
}

$otherManifestPath = Join-Path $bucketDir 'otherreset.json'
$otherManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(, @('filetool.exe', 'otherreset'))
}
$otherManifest | ConvertTo-Json | Set-Content -Path $otherManifestPath -Encoding UTF8

& $ScoExe install otherreset --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install otherreset before multi reset failed with exit code $LASTEXITCODE"
}

Remove-Item -LiteralPath (Join-Path $Root 'shims\resettool.exe') -Force
Remove-Item -LiteralPath (Join-Path $Root 'shims\resettool.shim') -Force
Remove-Item -LiteralPath (Join-Path $Root 'shims\otherreset.exe') -Force
Remove-Item -LiteralPath (Join-Path $Root 'shims\otherreset.shim') -Force
& $ScoExe reset resettool otherreset
if ($LASTEXITCODE -ne 0) {
    throw "multi-app reset failed with exit code $LASTEXITCODE"
}
if (!(Test-Path (Join-Path $Root 'shims\resettool.exe')) -or !(Test-Path (Join-Path $Root 'shims\resettool.shim'))) {
    throw 'multi-app reset did not recreate resettool shim'
}
if (!(Test-Path (Join-Path $Root 'shims\otherreset.exe')) -or !(Test-Path (Join-Path $Root 'shims\otherreset.shim'))) {
    throw 'multi-app reset did not recreate otherreset shim'
}

$staleResetManifestPath = Join-Path $bucketDir 'stalereset.json'
function Write-StaleResetManifest($Version, $Artifact, $Hash, $ShimName) {
    $staleResetManifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = @(, @('filetool.exe', $ShimName))
    }
    $staleResetManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $staleResetManifestPath -Encoding UTF8
}

Write-StaleResetManifest '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b' 'stalereset-old'
& $ScoExe install stalereset --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install stalereset before stale shim reset failed with exit code $LASTEXITCODE"
}
Write-StaleResetManifest '2.0.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824' 'stalereset-new'
& $ScoExe update stalereset --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "update stalereset before stale shim reset failed with exit code $LASTEXITCODE"
}
& $ScoExe reset stalereset@1.0.0
if ($LASTEXITCODE -ne 0) {
    throw "reset stalereset to old version failed with exit code $LASTEXITCODE"
}
if (!(Test-Path (Join-Path $Root 'shims\stalereset-old.shim')) -or
    !(Test-Path (Join-Path $Root 'shims\stalereset-new.shim'))) {
    throw 'reset should create selected-version shims without removing previous-version shims like Scoop'
}
& $ScoExe uninstall stalereset
if ($LASTEXITCODE -ne 0) {
    throw "uninstall stalereset failed with exit code $LASTEXITCODE"
}
Remove-Item -LiteralPath (Join-Path $Root 'shims\stalereset-new.exe') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Root 'shims\stalereset-new.shim') -Force -ErrorAction SilentlyContinue

Install-GlobalResetFixture
if ($LASTEXITCODE -ne 0) {
    throw "global fixture install before both-scope reset failed with exit code $LASTEXITCODE"
}

$globalShim = Join-Path $GlobalRoot 'shims\resettool.shim'
$globalShimExe = Join-Path $GlobalRoot 'shims\resettool.exe'
Remove-Item -LiteralPath $globalShim -Force
Remove-Item -LiteralPath $globalShimExe -Force
$bothScopeResetOutput = (& $ScoExe reset resettool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "reset should prefer global install when both scopes exist, got $LASTEXITCODE`: $bothScopeResetOutput"
}
if ($isAdmin) {
    if (!(Test-Path $globalShim) -or !(Test-Path $globalShimExe)) {
        throw 'plain reset did not recreate global shim when both local and global installs existed'
    }
} else {
    if ($bothScopeResetOutput -notmatch "WARN  'resettool' \(1\.1\.0\) is a global app\. You need admin rights to reset it\. Skipping\.") {
        throw "non-admin reset of global-preferred app did not warn and skip like Scoop: $bothScopeResetOutput"
    }
    if ((Test-Path $globalShim) -or (Test-Path $globalShimExe)) {
        throw 'non-admin reset of global-preferred app recreated global shims instead of skipping'
    }
}

& $ScoExe uninstall resettool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall before global reset check failed with exit code $LASTEXITCODE"
}

Remove-Item -LiteralPath $globalShim -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $globalShimExe -Force -ErrorAction SilentlyContinue
$globalOnlyResetOutput = (& $ScoExe reset resettool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "reset should auto-target global install when local install is absent, got $LASTEXITCODE`: $globalOnlyResetOutput"
}

if (!(Test-Path (Join-Path $GlobalRoot 'apps\resettool\current\filetool.exe'))) {
    throw 'global reset did not keep global current filetool.exe'
}
if ($isAdmin) {
    if (!(Test-Path (Join-Path $GlobalRoot 'shims\resettool.exe')) -or !(Test-Path (Join-Path $GlobalRoot 'shims\resettool.shim'))) {
        throw 'global reset did not recreate global shim'
    }
} else {
    if ($globalOnlyResetOutput -notmatch "WARN  'resettool' \(1\.1\.0\) is a global app\. You need admin rights to reset it\. Skipping\.") {
        throw "non-admin reset of global-only app did not warn and skip like Scoop: $globalOnlyResetOutput"
    }
    if ((Test-Path (Join-Path $GlobalRoot 'shims\resettool.exe')) -or (Test-Path (Join-Path $GlobalRoot 'shims\resettool.shim'))) {
        throw 'non-admin reset of global-only app recreated global shims instead of skipping'
    }
}
