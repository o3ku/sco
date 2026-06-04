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
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

function Write-Manifest($Name, $Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = 'filetool.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir "$Name.json") -Encoding UTF8
}

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

& $ScoExe config last_update (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config last_update before empty update all failed with exit code $LASTEXITCODE"
}

$emptyStarOutput = (& $ScoExe update '*') -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "empty update * failed with exit code $LASTEXITCODE`: $emptyStarOutput"
}
if ($emptyStarOutput.Trim()) {
    throw "empty update * should not print output like Scoop: $emptyStarOutput"
}

$emptyForceAllOutput = (& $ScoExe update --all --force) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "empty update --all --force failed with exit code $LASTEXITCODE`: $emptyForceAllOutput"
}
if ($emptyForceAllOutput.Trim()) {
    throw "empty update --all --force should not print output like Scoop: $emptyForceAllOutput"
}

Write-Manifest 'filetool' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
Write-Manifest 'othertool' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
Write-Manifest 'globaltool' '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'

& $ScoExe install filetool othertool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$v2Source = Join-Path $Root 'sources\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $v2Source) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $v2Source -Force

Write-Manifest 'filetool' '1.1.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'

$updateOutput = & $ScoExe update '*'
if ($LASTEXITCODE -ne 0) {
    throw "update * failed with exit code $LASTEXITCODE"
}

$joined = $updateOutput -join "`n"
if ($joined -notmatch 'filetool: 1\.0\.0 -> 1\.1\.0') {
    throw "update * did not report filetool as outdated: $joined"
}
if ($joined -match 'othertool:') {
    throw "update * should not report current othertool as outdated: $joined"
}

$filetoolManifest = Get-Content (Join-Path $Root 'apps\filetool\current\manifest.json') -Raw | ConvertFrom-Json
if ($filetoolManifest.version -ne '1.1.0') {
    throw "filetool was not updated to 1.1.0"
}

$othertoolManifest = Get-Content (Join-Path $Root 'apps\othertool\current\manifest.json') -Raw | ConvertFrom-Json
if ($othertoolManifest.version -ne '1.0.0') {
    throw "othertool should remain at 1.0.0"
}

$currentContent = Get-Content (Join-Path $Root 'apps\filetool\current\filetool.exe') -Raw
if ($currentContent -ne '@echo filetool-v2') {
    throw "filetool current did not switch to updated artifact: $currentContent"
}

$forceSource = Join-Path $Root 'sources\othertool-force\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $forceSource) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $forceSource -Force
Write-Manifest 'othertool' '1.0.0' $forceSource 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'

$forceOutput = & $ScoExe update '*' --force --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "update * --force failed with exit code $LASTEXITCODE`: $forceOutput"
}
$forceJoined = $forceOutput -join "`n"
if ($forceJoined -notmatch 'Force updating 2 apps') {
    throw "update * --force did not include all installed apps: $forceJoined"
}
if ($forceJoined -notmatch "Reinstalled 'othertool' \(1\.0\.0\)") {
    throw "update * --force did not reinstall current othertool: $forceJoined"
}

$othertoolContent = Get-Content (Join-Path $Root 'apps\othertool\current\filetool.exe') -Raw
if ($othertoolContent -notmatch 'filetool-v2') {
    throw "update * --force did not refresh current othertool artifact: $othertoolContent"
}

$oldOthertoolDirs = @(Get-ChildItem (Join-Path $Root 'apps\othertool') -Directory -Filter '_1.0.0.old*')
if ($oldOthertoolDirs.Count -lt 1) {
    throw 'update * --force did not preserve old othertool version directory'
}

function Install-GlobalFixture($Name) {
    $previousScoop = $env:SCOOP
    $previousGlobal = $env:SCOOP_GLOBAL
    try {
        $env:SCOOP = $GlobalRoot
        Remove-Item Env:SCOOP_GLOBAL -ErrorAction SilentlyContinue
        $globalBucketDir = Join-Path $GlobalRoot 'buckets\main\bucket'
        New-Item -ItemType Directory -Force -Path $globalBucketDir | Out-Null
        Copy-Item -LiteralPath (Join-Path $bucketDir "$Name.json") -Destination (Join-Path $globalBucketDir "$Name.json") -Force
        & $ScoExe install $Name --no-update-scoop
    } finally {
        $env:SCOOP = $previousScoop
        $env:SCOOP_GLOBAL = $previousGlobal
    }
}

Install-GlobalFixture 'globaltool'
if ($LASTEXITCODE -ne 0) {
    throw "global fixture install failed with exit code $LASTEXITCODE"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$wrongScopeExplicitOutput = & $ScoExe update globaltool 2>&1
$wrongScopeExplicitExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($wrongScopeExplicitExitCode -ne 0) {
    throw "update global-only app without --global should skip with exit 0 like Scoop, got $wrongScopeExplicitExitCode`: $wrongScopeExplicitOutput"
}
$wrongScopeExplicitJoined = $wrongScopeExplicitOutput -join "`n"
if ($wrongScopeExplicitJoined -notmatch "ERROR 'globaltool' isn't installed locally, but it may be installed globally\." -or
    $wrongScopeExplicitJoined -notmatch 'WARN  Try again with the --global \(or -g\) flag instead\.') {
    throw "update global-only app without --global did not print Scoop wrong-scope hint: $wrongScopeExplicitJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$wrongScopeGlobalOutput = & $ScoExe update filetool --global 2>&1
$wrongScopeGlobalExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
$wrongScopeGlobalJoined = $wrongScopeGlobalOutput -join "`n"
if ($isAdmin) {
    if ($wrongScopeGlobalExitCode -ne 0) {
        throw "update local app with --global should skip with exit 0 like Scoop, got $wrongScopeGlobalExitCode`: $wrongScopeGlobalOutput"
    }
    if ($wrongScopeGlobalJoined -notmatch "ERROR 'filetool' isn't installed globally, but it may be installed locally\." -or
        $wrongScopeGlobalJoined -notmatch 'WARN  Try again without the --global \(or -g\) flag instead\.') {
        throw "update local app with --global did not print Scoop wrong-scope hint: $wrongScopeGlobalJoined"
    }
} else {
    if ($wrongScopeGlobalExitCode -ne 1) {
        throw "non-admin update local app with --global returned $wrongScopeGlobalExitCode instead of 1: $wrongScopeGlobalJoined"
    }
    if ($wrongScopeGlobalJoined -notmatch 'ERROR: You need admin rights to update global apps\.') {
        throw "non-admin update local app with --global did not match Scoop admin error: $wrongScopeGlobalJoined"
    }
}

$globalSource = Join-Path $Root 'sources\globaltool-v2\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $globalSource) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $globalSource -Force
Write-Manifest 'filetool' '1.2.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
Write-Manifest 'globaltool' '1.1.0' $globalSource 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$globalAllOutput = & $ScoExe update '*' --global 2>&1
$globalAllExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
$globalAllJoined = $globalAllOutput -join "`n"
if ($isAdmin) {
    if ($globalAllExitCode -ne 0) {
        throw "update * --global failed with exit code $globalAllExitCode`: $globalAllOutput"
    }
    if ($globalAllJoined -notmatch 'filetool: 1\.1\.0 -> 1\.2\.0' -or $globalAllJoined -notmatch 'globaltool: 1\.0\.0 -> 1\.1\.0') {
        throw "update * --global should include both local and global apps like Scoop: $globalAllJoined"
    }

    $filetoolManifest = Get-Content (Join-Path $Root 'apps\filetool\current\manifest.json') -Raw | ConvertFrom-Json
    if ($filetoolManifest.version -ne '1.2.0') {
        throw "update * --global did not update local filetool, found $($filetoolManifest.version)"
    }

    $globaltoolManifest = Get-Content (Join-Path $GlobalRoot 'apps\globaltool\current\manifest.json') -Raw | ConvertFrom-Json
    if ($globaltoolManifest.version -ne '1.1.0') {
        throw "update * --global did not update global globaltool, found $($globaltoolManifest.version)"
    }
} else {
    if ($globalAllExitCode -ne 1) {
        throw "non-admin update * --global returned $globalAllExitCode instead of 1: $globalAllJoined"
    }
    if ($globalAllJoined -notmatch 'ERROR: You need admin rights to update global apps\.') {
        throw "non-admin update * --global did not match Scoop admin error: $globalAllJoined"
    }
}
