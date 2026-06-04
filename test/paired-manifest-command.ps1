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
$defaultPsModulePath = 'C:\Program Files\WindowsPowerShell\Modules;C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules'

function Initialize-Bucket {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)

    $bucketDir = Join-Path $ToolRoot 'buckets\main\bucket'
    New-Item -ItemType Directory -Force -Path $bucketDir, (Join-Path $ToolRoot 'shims'), (Join-Path $ToolRoot 'cache') | Out-Null

    [ordered]@{
        version = '1.0.0'
        description = 'Paired dependency fixture'
        homepage = 'https://example.invalid/depone'
        license = 'MIT'
        bin = 'depone.exe'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bucketDir 'depone.json') -Encoding UTF8

    [ordered]@{
        version = '1.0.0'
        description = 'Second paired dependency fixture'
        homepage = 'https://example.invalid/deptwo'
        license = 'MIT'
        bin = 'deptwo.exe'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bucketDir 'deptwo.json') -Encoding UTF8

    [ordered]@{
        version = '1.0.0'
        description = 'Paired manifest command fixture'
        homepage = 'https://example.invalid/pairmanifest'
        license = 'MIT'
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        bin = 'filetool.exe'
        depends = @('depone', 'deptwo')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bucketDir 'pairmanifest.json') -Encoding UTF8
}

Initialize-Bucket -ToolRoot $scoRoot
Initialize-Bucket -ToolRoot $scoopRoot

function Normalize-Output {
    param(
        [string[]]$Lines,
        [string]$ToolRoot,
        [string]$ToolConfigHome
    )

    $rootPath = ([System.IO.Path]::GetFullPath($ToolRoot)).TrimEnd('\')
    $configPath = ([System.IO.Path]::GetFullPath($ToolConfigHome)).TrimEnd('\')
    $rootPattern = [regex]::Escape($rootPath)
    $rootSlashPattern = [regex]::Escape(($rootPath -replace '\\', '/'))
    $configPattern = [regex]::Escape($configPath)
    $configSlashPattern = [regex]::Escape(($configPath -replace '\\', '/'))
    $artifactPath = [regex]::Escape(([System.IO.Path]::GetFullPath($Artifact)).TrimEnd('\'))
    $artifactSlashPath = [regex]::Escape((([System.IO.Path]::GetFullPath($Artifact)).TrimEnd('\') -replace '\\', '/'))

    $normalized = @($Lines | ForEach-Object {
        ([string]$_ -replace "`r", '') `
            -replace "`e\[[0-9;?]*[ -/]*[@-~]", '' `
            -replace $rootPattern, '<ROOT>' `
            -replace $rootSlashPattern, '<ROOT>' `
            -replace $configPattern, '<CONFIG>' `
            -replace $configSlashPattern, '<CONFIG>' `
            -replace $artifactPath, '<ARTIFACT>' `
            -replace $artifactSlashPath, '<ARTIFACT>' `
            -replace '\bscoop\b', 'sco' `
            -replace '\\', '/' `
            -replace '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}', '<DATE>' `
            -replace '\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2}:\d{2} [AP]M', '<DATE>'
    } | ForEach-Object {
        $line = $_.TrimEnd()
        if ($line -match '^(Name|----)\s+(Version|-------)\s+(Source|------)\s+(Binaries|--------)$' -or
            $line -match '^(Name|----)\s+(Source|------)$' -or
            $line -match '^(depone|deptwo|pairmanifest)\s+') {
            $line = $line -replace '\s+', ' '
        }
        $line
    })

    while ($normalized.Count -gt 0 -and $normalized[-1] -eq '') {
        $normalized = @($normalized[0..($normalized.Count - 2)])
    }
    while ($normalized.Count -gt 0 -and $normalized[0] -eq '') {
        if ($normalized.Count -eq 1) {
            $normalized = @()
        } else {
            $normalized = @($normalized[1..($normalized.Count - 1)])
        }
    }
    return ($normalized -join "`n")
}

function Invoke-PairedTool {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('sco', 'scoop')][string]$Tool,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    if ($Tool -eq 'sco') {
        $env:SCOOP = $scoRoot
        $env:XDG_CONFIG_HOME = $scoConfigHome
    } else {
        $env:SCOOP = $scoopRoot
        $env:XDG_CONFIG_HOME = $scoopConfigHome
    }
    $env:SCOOP_HOME = $scoopHome
    $env:PSModulePath = $defaultPsModulePath

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Tool -eq 'sco') {
            $output = & $ScoExe @Arguments 2>&1
            $exitCode = $LASTEXITCODE
            $text = Normalize-Output -Lines @($output | ForEach-Object { [string]$_ }) -ToolRoot $scoRoot -ToolConfigHome $scoConfigHome
        } else {
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScoopPs1 @Arguments 2>&1
            $exitCode = $LASTEXITCODE
            $text = Normalize-Output -Lines @($output | ForEach-Object { [string]$_ }) -ToolRoot $scoopRoot -ToolConfigHome $scoopConfigHome
        }
        [pscustomobject]@{
            ExitCode = $exitCode
            Text = $text
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Assert-PairedCommand {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    $sco = Invoke-PairedTool sco @Arguments
    $scoop = Invoke-PairedTool scoop @Arguments
    $display = $Arguments -join ' '

    if ($sco.ExitCode -ne $scoop.ExitCode) {
        throw "'$display' exit codes differ: sco=$($sco.ExitCode), scoop=$($scoop.ExitCode)`nsco:`n$($sco.Text)`n---`nscoop:`n$($scoop.Text)"
    }
    if ($sco.Text -ne $scoop.Text) {
        throw "'$display' output differs.`nsco:`n$($sco.Text)`n---`nscoop:`n$($scoop.Text)"
    }
}

Assert-PairedCommand search pairmanifest
Assert-PairedCommand search dep
Assert-PairedCommand cat pairmanifest
Assert-PairedCommand cat main/pairmanifest
Assert-PairedCommand depends pairmanifest
Assert-PairedCommand info pairmanifest
