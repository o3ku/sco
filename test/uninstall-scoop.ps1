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

foreach ($path in @($Root, $GlobalRoot, $ConfigHome)) {
    if (Test-Path $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

$EnvFilePath = Join-Path (Split-Path -Parent $Root) 'test-uninstall-scoop-env.json'
if (Test-Path $EnvFilePath) {
    Remove-Item -LiteralPath $EnvFilePath -Force
}

function Write-FiletoolManifest($RootPath) {
    $bucketDir = Join-Path $RootPath 'buckets\main\bucket'
    New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
    $manifest = [ordered]@{
        version = '1.0.0'
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        bin = 'filetool.exe'
        persist = 'data'
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'filetool.json') -Encoding UTF8
}

function Reset-TestEnvironment {
    foreach ($path in @($Root, $GlobalRoot, $ConfigHome)) {
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
    if (Test-Path $EnvFilePath) {
        Remove-Item -LiteralPath $EnvFilePath -Force
    }
    New-Item -ItemType Directory -Force -Path $Root, $GlobalRoot | Out-Null
    Write-FiletoolManifest $Root
    $env:SCOOP = $Root
    $env:SCOOP_GLOBAL = $GlobalRoot
    $env:XDG_CONFIG_HOME = $ConfigHome
    $rootShim = (Join-Path $Root 'shims')
    $globalShim = (Join-Path $GlobalRoot 'shims')
    @{ PATH = "$rootShim;$globalShim;C:\Windows" } | ConvertTo-Json | Set-Content -Path $EnvFilePath -Encoding UTF8
    $env:SCOOP_ENV_FILE = $EnvFilePath
    return $EnvFilePath
}

function Install-TestApps {
    & $ScoExe install filetool --no-update-scoop | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "local install before scoop uninstall failed with exit code $LASTEXITCODE"
    }
    $previousScoop = $env:SCOOP
    $previousGlobal = $env:SCOOP_GLOBAL
    try {
        $env:SCOOP = $GlobalRoot
        Remove-Item Env:SCOOP_GLOBAL -ErrorAction SilentlyContinue
        Write-FiletoolManifest $GlobalRoot
        & $ScoExe install filetool --no-update-scoop | Out-Null
    } finally {
        $env:SCOOP = $previousScoop
        $env:SCOOP_GLOBAL = $previousGlobal
    }
    if ($LASTEXITCODE -ne 0) {
        throw "global fixture install before scoop uninstall failed with exit code $LASTEXITCODE"
    }
    Set-Content -Path (Join-Path $Root 'persist\filetool\data\settings.json') -Value '{"local":true}' -Encoding UTF8
    Set-Content -Path (Join-Path $GlobalRoot 'persist\filetool\data\settings.json') -Value '{"global":true}' -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'cache') | Out-Null
    Set-Content -Path (Join-Path $Root 'cache\manual-cache.txt') -Value 'cache' -Encoding UTF8
}

function Invoke-ScoWithInput {
    param(
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string[]]$CommandArguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ScoExe
    $startInfo.Arguments = ($CommandArguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['SCOOP'] = $Root
    $startInfo.EnvironmentVariables['SCOOP_GLOBAL'] = $GlobalRoot
    $startInfo.EnvironmentVariables['XDG_CONFIG_HOME'] = $ConfigHome
    if ($env:SCOOP_ENV_FILE) {
        $startInfo.EnvironmentVariables['SCOOP_ENV_FILE'] = $env:SCOOP_ENV_FILE
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Write([string]$InputText)
    $process.StandardInput.Write([System.Environment]::NewLine)
    $process.StandardInput.Flush()
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = (($stdout + $stderr) -replace "\r\n", "`n").TrimEnd()
    }
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$envFile = Reset-TestEnvironment
Install-TestApps

if (-not $isAdmin) {
    $globalSelf = Invoke-ScoWithInput -InputText 'n' -CommandArguments @('uninstall', 'scoop', '--global')
    if ($globalSelf.ExitCode -ne 1) {
        throw "non-admin scoop uninstall --global returned $($globalSelf.ExitCode) instead of 1: $($globalSelf.Output)"
    }
    if ($globalSelf.Output -notmatch 'ERROR You need admin rights to uninstall global apps\.') {
        throw "non-admin scoop uninstall --global did not match Scoop admin error: $($globalSelf.Output)"
    }
}

$selfUninstallArgs = if ($isAdmin) { @('uninstall', 'scoop', '--global') } else { @('uninstall', 'scoop') }
$mixedUninstallArgs = if ($isAdmin) { @('uninstall', 'filetool', 'scoop', '--global') } else { @('uninstall', 'filetool', 'scoop') }
$purgeUninstallArgs = if ($isAdmin) { @('uninstall', 'scoop', '--global', '--purge') } else { @('uninstall', 'scoop', '--purge') }

$cancel = Invoke-ScoWithInput -InputText 'n' -CommandArguments $selfUninstallArgs
$cancelOutput = $cancel.Output
if ($cancel.ExitCode -ne 0) {
    throw "cancelled scoop uninstall returned $($cancel.ExitCode) instead of 0: $cancelOutput"
}
if ($cancelOutput -notmatch 'Scoop uninstall cancelled') {
    throw "cancelled scoop uninstall did not report cancellation: $cancelOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\filetool\current\filetool.exe')) -or !(Test-Path (Join-Path $GlobalRoot 'apps\filetool\current\filetool.exe'))) {
    throw 'cancelled scoop uninstall removed installed apps'
}

$envFile = Reset-TestEnvironment
Install-TestApps

$cancelMixed = Invoke-ScoWithInput -InputText 'n' -CommandArguments $mixedUninstallArgs
$cancelMixedOutput = $cancelMixed.Output
if ($cancelMixed.ExitCode -ne 0) {
    throw "cancelled mixed uninstall with scoop returned $($cancelMixed.ExitCode) instead of 0: $cancelMixedOutput"
}
if ($cancelMixedOutput -notmatch 'Scoop uninstall cancelled') {
    throw "mixed uninstall containing scoop did not enter Scoop self-uninstall path first: $cancelMixedOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\filetool\current\filetool.exe')) -or !(Test-Path (Join-Path $GlobalRoot 'apps\filetool\current\filetool.exe'))) {
    throw 'mixed uninstall containing scoop removed apps before cancelled self-uninstall'
}

$envFile = Reset-TestEnvironment
Install-TestApps

$keep = Invoke-ScoWithInput -InputText 'y' -CommandArguments $selfUninstallArgs
$keepOutput = $keep.Output
if ($keep.ExitCode -ne 0) {
    throw "scoop uninstall returned $($keep.ExitCode) instead of 0: $keepOutput"
}
if ($keepOutput -notmatch 'Scoop has been uninstalled') {
    throw "scoop uninstall did not report success: $keepOutput"
}
foreach ($path in @(
    (Join-Path $Root 'apps'),
    (Join-Path $Root 'shims'),
    (Join-Path $Root 'cache'),
    (Join-Path $Root 'buckets')
)) {
    if (Test-Path $path) {
        throw "scoop uninstall without purge left unexpected path: $path"
    }
}
if ($isAdmin) {
    foreach ($path in @(
    (Join-Path $GlobalRoot 'apps'),
    (Join-Path $GlobalRoot 'shims')
    )) {
        if (Test-Path $path) {
            throw "scoop uninstall --global without purge left unexpected path: $path"
        }
    }
} else {
    if (!(Test-Path (Join-Path $GlobalRoot 'apps\filetool\current\filetool.exe'))) {
        throw 'non-global scoop uninstall removed global app unexpectedly'
    }
}
foreach ($path in @(
    (Join-Path $Root 'persist\filetool\data\settings.json')
)) {
    if (!(Test-Path $path)) {
        throw "scoop uninstall without purge removed persisted data: $path"
    }
}
if ($isAdmin -and !(Test-Path (Join-Path $GlobalRoot 'persist\filetool\data\settings.json'))) {
    throw 'scoop uninstall --global without purge removed global persisted data'
}
$envJson = Get-Content -LiteralPath $envFile -Raw | ConvertFrom-Json
if ([string]$envJson.PATH -match [regex]::Escape((Join-Path $Root 'shims'))) {
    throw "scoop uninstall did not remove shim paths from PATH: $($envJson.PATH)"
}
if ($isAdmin -and [string]$envJson.PATH -match [regex]::Escape((Join-Path $GlobalRoot 'shims'))) {
    throw "scoop uninstall --global did not remove global shim path from PATH: $($envJson.PATH)"
}

$envFile = Reset-TestEnvironment
Install-TestApps

$purge = Invoke-ScoWithInput -InputText 'y' -CommandArguments $purgeUninstallArgs
$purgeOutput = $purge.Output
if ($purge.ExitCode -ne 0) {
    throw "scoop uninstall --purge returned $($purge.ExitCode) instead of 0: $purgeOutput"
}
if ($purgeOutput -notmatch 'all persisted data') {
    throw "scoop uninstall --purge did not warn about persisted data: $purgeOutput"
}
if (Test-Path $Root) {
    throw "scoop uninstall --purge left local root: $Root"
}
if ($isAdmin -and (Test-Path $GlobalRoot)) {
    throw "scoop uninstall --purge left global root: $GlobalRoot"
}
if (-not $isAdmin -and !(Test-Path (Join-Path $GlobalRoot 'apps\filetool\current\filetool.exe'))) {
    throw 'non-global scoop uninstall --purge removed global app unexpectedly'
}

Remove-Item Env:SCOOP_ENV_FILE -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $EnvFilePath -Force -ErrorAction SilentlyContinue
