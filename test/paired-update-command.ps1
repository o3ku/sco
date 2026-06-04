param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$ScoopPs1,
    [Parameter(Mandatory = $true)][string]$Root,
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
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$scoRoot = Join-Path $Root 'sco'
$scoopRoot = Join-Path $Root 'scoop'
$scoConfigHome = Join-Path $ConfigHome 'sco'
$scoopConfigHome = Join-Path $ConfigHome 'scoop'
$scoopHome = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ScoopPs1) '..'))
$artifactPath = [System.IO.Path]::GetFullPath($Artifact)
$defaultPsModulePath = 'C:\Program Files\WindowsPowerShell\Modules;C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules'

function Set-TestEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$ToolConfigHome
    )

    $env:SCOOP = $ToolRoot
    $env:XDG_CONFIG_HOME = $ToolConfigHome
    $env:SCOOP_HOME = $scoopHome
    $env:SCOOP_CACHE = Join-Path $ToolRoot 'cache'
    $env:PSModulePath = $defaultPsModulePath
}

function Write-Config {
    param([Parameter(Mandatory = $true)][string]$ToolConfigHome)

    $configDir = Join-Path $ToolConfigHome 'scoop'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    [ordered]@{
        last_update = ([System.DateTime]::Now.ToString('o'))
        'aria2-enabled' = $false
        'aria2-warning-enabled' = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $configDir 'config.json') -Encoding UTF8
}

function Write-Manifest {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $bucketDir = Join-Path $ToolRoot 'buckets\main\bucket'
    New-Item -ItemType Directory -Force -Path $bucketDir, (Join-Path $ToolRoot 'shims'), (Join-Path $ToolRoot 'cache') | Out-Null
    [ordered]@{
        version = $Version
        description = 'Paired update fixture'
        homepage = 'https://example.invalid/pairupdate'
        license = 'MIT'
        url = $artifactPath
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        bin = 'filetool.exe'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bucketDir 'pairupdate.json') -Encoding UTF8
}

function Initialize-Install {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$ToolConfigHome
    )

    Write-Config $ToolConfigHome
    Write-Manifest -ToolRoot $ToolRoot -Version '1.0.0'
    Set-TestEnvironment -ToolRoot $ToolRoot -ToolConfigHome $ToolConfigHome

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScoopPs1 install pairupdate --skip-hash-check --no-update-scoop 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "reference scoop install pairupdate failed for ${ToolRoot}: $($output -join "`n")"
    }

    Write-Manifest -ToolRoot $ToolRoot -Version '2.0.0'
}

function Normalize-Output {
    param(
        [string[]]$Lines,
        [string]$ToolRoot,
        [string]$ToolConfigHome
    )

    $rootPath = ([System.IO.Path]::GetFullPath($ToolRoot)).TrimEnd('\')
    $configPath = ([System.IO.Path]::GetFullPath($ToolConfigHome)).TrimEnd('\')
    $artifactFullPath = ([System.IO.Path]::GetFullPath($Artifact)).TrimEnd('\')

    $normalized = @($Lines | ForEach-Object {
        $line = ([string]$_ -replace "`r", '') `
            -replace "`e\[[0-9;?]*[ -/]*[@-~]", '' `
            -replace '\\', '/'
        $line = $line.Replace(($rootPath -replace '\\', '/'), '<ROOT>')
        $line = $line.Replace(($configPath -replace '\\', '/'), '<CONFIG>')
        $line = $line.Replace(($artifactFullPath -replace '\\', '/'), '<ARTIFACT>')
        $line -replace '\bscoop\b', 'sco'
    } | ForEach-Object {
        $_.TrimEnd()
    })

    while ($normalized.Count -gt 0 -and $normalized[-1] -eq '') {
        $normalized = @($normalized[0..($normalized.Count - 2)])
    }
    return ($normalized -join "`n")
}

function Invoke-PairedTool {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('sco', 'scoop')][string]$Tool,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    if ($Tool -eq 'sco') {
        Set-TestEnvironment -ToolRoot $scoRoot -ToolConfigHome $scoConfigHome
        $toolRoot = $scoRoot
        $toolConfigHome = $scoConfigHome
    } else {
        Set-TestEnvironment -ToolRoot $scoopRoot -ToolConfigHome $scoopConfigHome
        $toolRoot = $scoopRoot
        $toolConfigHome = $scoopConfigHome
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Tool -eq 'sco') {
            $output = & $ScoExe @Arguments 2>&1
            $exitCode = $LASTEXITCODE
        } else {
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScoopPs1 @Arguments 2>&1
            $exitCode = $LASTEXITCODE
        }
        [pscustomobject]@{
            ExitCode = $exitCode
            Text = Normalize-Output -Lines @($output | ForEach-Object { [string]$_ }) -ToolRoot $toolRoot -ToolConfigHome $toolConfigHome
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Assert-SharedUpdateEvents {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string]$Text
    )

    foreach ($pattern in @(
        "pairupdate: 1\.0\.0 -> 2\.0\.0",
        "Updating one outdated app:",
        "Updating 'pairupdate' \(1\.0\.0 -> 2\.0\.0\)",
        "Downloading new version",
        "Uninstalling 'pairupdate' \(1\.0\.0\)",
        "Installing 'pairupdate' \(2\.0\.0\) \[64bit\] from 'main' bucket",
        "Linking <ROOT>/apps/pairupdate/current => <ROOT>/apps/pairupdate/2\.0\.0",
        "'pairupdate' \(2\.0\.0\) was installed successfully!"
    )) {
        if ($Text -notmatch $pattern) {
            throw "$Tool update output is missing '$pattern':`n$Text"
        }
    }
}

function Installed-VersionText {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)

    $manifest = Get-Content -LiteralPath (Join-Path $ToolRoot 'apps\pairupdate\current\manifest.json') -Raw | ConvertFrom-Json
    $install = Get-Content -LiteralPath (Join-Path $ToolRoot 'apps\pairupdate\current\install.json') -Raw | ConvertFrom-Json
    return "version=$($manifest.version);bucket=$($install.bucket);arch=$($install.architecture)"
}

Initialize-Install -ToolRoot $scoRoot -ToolConfigHome $scoConfigHome
Initialize-Install -ToolRoot $scoopRoot -ToolConfigHome $scoopConfigHome

$scoUpdate = Invoke-PairedTool sco update pairupdate --skip-hash-check
$scoopUpdate = Invoke-PairedTool scoop update pairupdate --skip-hash-check
if ($scoUpdate.ExitCode -ne $scoopUpdate.ExitCode) {
    throw "update exit codes differ: sco=$($scoUpdate.ExitCode), scoop=$($scoopUpdate.ExitCode)`nsco:`n$($scoUpdate.Text)`n---`nscoop:`n$($scoopUpdate.Text)"
}

Assert-SharedUpdateEvents -Tool 'sco' -Text $scoUpdate.Text
Assert-SharedUpdateEvents -Tool 'scoop' -Text $scoopUpdate.Text

$scoState = Installed-VersionText $scoRoot
$scoopState = Installed-VersionText $scoopRoot
if ($scoState -ne $scoopState -or $scoState -ne 'version=2.0.0;bucket=main;arch=64bit') {
    throw "updated installed state differs or is wrong.`nsco: $scoState`nscoop: $scoopState"
}

