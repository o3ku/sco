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

function Set-TestEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$ToolConfigHome
    )

    $env:SCOOP = $ToolRoot
    $env:XDG_CONFIG_HOME = $ToolConfigHome
    $env:SCOOP_HOME = $scoopHome
    $env:SCOOP_CACHE = Join-Path $ToolRoot 'cache'
}

function Initialize-ReferenceInstall {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$ToolConfigHome
    )

    $bucketDir = Join-Path $ToolRoot 'buckets\main\bucket'
    $shimDir = Join-Path $ToolRoot 'shims'
    $cacheDir = Join-Path $ToolRoot 'cache'
    $scoopShimDir = Join-Path $ToolRoot 'apps\scoop\current\supporting\shims\kiennq'
    New-Item -ItemType Directory -Force -Path $bucketDir, $shimDir, $cacheDir, $scoopShimDir | Out-Null
    Copy-Item -LiteralPath $ScoExe -Destination (Join-Path $scoopShimDir 'shim.exe') -Force

    $artifactPath = [System.IO.Path]::GetFullPath($Artifact)
    [ordered]@{
        version = '1.0.0'
        url = $artifactPath
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        bin = 'filetool.exe'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bucketDir 'pairtool.json') -Encoding UTF8

    $legacyCacheName = 'pairtool#1.0.0#' + ($artifactPath -replace '[^\w\.\-]+', '_')
    Copy-Item -LiteralPath $artifactPath -Destination (Join-Path $cacheDir $legacyCacheName) -Force

    Set-TestEnvironment -ToolRoot $ToolRoot -ToolConfigHome $ToolConfigHome
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScoopPs1 install pairtool --no-update-scoop --skip-hash-check 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "reference scoop install pairtool failed with exit code $exitCode for ${ToolRoot}: $($output -join "`n")"
    }
}

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

    $normalized = @($Lines | ForEach-Object {
        ([string]$_ -replace "`r", '') `
            -replace "`e\[[0-9;?]*[ -/]*[@-~]", '' `
            -replace $rootPattern, '<ROOT>' `
            -replace $rootSlashPattern, '<ROOT>' `
            -replace $configPattern, '<CONFIG>' `
            -replace $configSlashPattern, '<CONFIG>' `
            -replace '\bscoop\b', 'sco' `
            -replace '\\', '/' `
            -replace '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}', '<DATE>' `
            -replace '\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2}:\d{2} [AP]M', '<DATE>'
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
    } else {
        Set-TestEnvironment -ToolRoot $scoopRoot -ToolConfigHome $scoopConfigHome
    }

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

function Convert-ExportJsonToCanonicalText {
    param([string]$Text)

    $json = $Text | ConvertFrom-Json
    $lines = New-Object System.Collections.Generic.List[string]
    $normalizeValue = {
        param($Value)
        $text = [string]$Value
        $text = $text -replace '\\', '/'
        while ($text.Contains('//')) {
            $text = $text.Replace('//', '/')
        }
        foreach ($rootValue in @($scoRoot, $scoopRoot)) {
            $rootText = ([System.IO.Path]::GetFullPath($rootValue)).TrimEnd('\') -replace '\\', '/'
            $text = $text.Replace($rootText, '<ROOT>')
        }
        $text = $text -replace '/Date\(-?\d+\)/', '<DATE>'
        $text = $text -replace '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}', '<DATE>'
        return $text
    }

    foreach ($bucket in @($json.buckets | Sort-Object Name)) {
        $lines.Add("bucket|$(&$normalizeValue $bucket.Name)|$(&$normalizeValue $bucket.Source)|$(&$normalizeValue $bucket.Updated)|$(&$normalizeValue $bucket.Manifests)")
    }

    foreach ($app in @($json.apps | Sort-Object Name)) {
        $lines.Add("app|$(&$normalizeValue $app.Name)|$(&$normalizeValue $app.Version)|$(&$normalizeValue $app.Source)|$(&$normalizeValue $app.Updated)|$(&$normalizeValue $app.Info)")
    }

    if ($json.PSObject.Properties.Name -contains 'config') {
        foreach ($property in @($json.config.PSObject.Properties | Sort-Object Name)) {
            $lines.Add("config|$(&$normalizeValue $property.Name)|$(&$normalizeValue $property.Value)")
        }
    }

    return ($lines -join "`n")
}

function Assert-PairedExportCommand {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    $sco = Invoke-PairedTool sco @Arguments
    $scoop = Invoke-PairedTool scoop @Arguments
    $display = $Arguments -join ' '

    if ($sco.ExitCode -ne $scoop.ExitCode) {
        throw "'$display' exit codes differ: sco=$($sco.ExitCode), scoop=$($scoop.ExitCode)`nsco:`n$($sco.Text)`n---`nscoop:`n$($scoop.Text)"
    }

    $scoCanonical = Convert-ExportJsonToCanonicalText $sco.Text
    $scoopCanonical = Convert-ExportJsonToCanonicalText $scoop.Text
    if ($scoCanonical -ne $scoopCanonical) {
        throw "'$display' JSON structure differs.`nsco:`n$scoCanonical`n---`nscoop:`n$scoopCanonical"
    }
}

Initialize-ReferenceInstall -ToolRoot $scoRoot -ToolConfigHome $scoConfigHome
Initialize-ReferenceInstall -ToolRoot $scoopRoot -ToolConfigHome $scoopConfigHome

Assert-PairedCommand list
Assert-PairedCommand list pair
Assert-PairedExportCommand export
Assert-PairedCommand prefix pairtool
Assert-PairedCommand which filetool
Assert-PairedCommand hold pairtool
Assert-PairedCommand hold pairtool
Assert-PairedCommand unhold pairtool
Assert-PairedCommand unhold pairtool
Assert-PairedCommand reset pairtool
Assert-PairedCommand status --local
Assert-PairedCommand cleanup pairtool
