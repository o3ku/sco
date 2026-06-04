param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$GlobalRoot,
    [Parameter(Mandatory = $true)][string]$ConfigHome
)

$ErrorActionPreference = 'Stop'

$resolvedRootParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $Root))
if ($resolvedRootParent -notlike '*\build\msvc-release*') {
    throw "Refusing to clean test root outside build tree: $Root"
}

foreach ($path in @($Root, $GlobalRoot, $ConfigHome)) {
    if (Test-Path $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAppOutput = & $ScoExe prefix 2>&1
$missingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppExitCode -ne 1) {
    throw "prefix without an app returned $missingAppExitCode instead of 1: $missingAppOutput"
}
if (($missingAppOutput -join "`n") -notmatch 'Usage: sco prefix <app>' -or ($missingAppOutput -join "`n") -match '<app> missing') {
    throw "prefix without an app did not match Scoop usage-only output: $missingAppOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingOutput = & $ScoExe prefix missingtool 2>&1
$missingExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingExitCode -ne 1) {
    throw "prefix missing app returned $missingExitCode instead of 1: $missingOutput"
}
if (($missingOutput -join "`n") -notmatch "Could not find app path for 'missingtool'\.") {
    throw "prefix missing app did not print Scoop-style error: $missingOutput"
}

$localCurrent = Join-Path $Root 'apps\localtool\current'
New-Item -ItemType Directory -Force -Path $localCurrent | Out-Null
$localPrefix = (& $ScoExe prefix localtool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0) {
    throw "prefix localtool failed with exit code $LASTEXITCODE"
}
$expectedLocal = ([System.IO.Path]::GetFullPath($localCurrent)).Replace('\', '/')
if ($localPrefix -ne $expectedLocal) {
    throw "prefix localtool returned '$localPrefix', expected '$expectedLocal'"
}

$globalCurrent = Join-Path $GlobalRoot 'apps\globaltool\current'
New-Item -ItemType Directory -Force -Path $globalCurrent | Out-Null
$globalPrefix = (& $ScoExe prefix globaltool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0) {
    throw "prefix globaltool failed with exit code $LASTEXITCODE"
}
$expectedGlobal = ([System.IO.Path]::GetFullPath($globalCurrent)).Replace('\', '/')
if ($globalPrefix -ne $expectedGlobal) {
    throw "prefix globaltool did not fall back to global app path: '$globalPrefix', expected '$expectedGlobal'"
}
