param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$ScoopPs1,
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

$scoRoot = Join-Path $Root 'sco'
$scoopRoot = Join-Path $Root 'scoop'
$scoConfigHome = Join-Path $ConfigHome 'sco'
$scoopConfigHome = Join-Path $ConfigHome 'scoop'

foreach ($dir in @(
    $scoRoot,
    $scoopRoot,
    (Join-Path $scoRoot 'shims'),
    (Join-Path $scoopRoot 'shims'),
    (Join-Path $scoRoot 'cache'),
    (Join-Path $scoopRoot 'cache'),
    (Join-Path $scoRoot 'buckets'),
    (Join-Path $scoopRoot 'buckets')
)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$scoopHome = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ScoopPs1) '..'))

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
        $line = $_.TrimEnd()
        if ($line -match '^(Name|----)\s+(Source|------)\s+(Updated|-------)\s+(Manifests|---------)$' -or
            $line -match '<ROOT>/buckets/') {
            $line = $line -replace '\s+', ' '
        }
        $line
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
        $env:SCOOP = $scoRoot
        $env:XDG_CONFIG_HOME = $scoConfigHome
    } else {
        $env:SCOOP = $scoopRoot
        $env:XDG_CONFIG_HOME = $scoopConfigHome
    }
    $env:SCOOP_HOME = $scoopHome

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

function Write-ConfigBoth {
    param([hashtable]$Value)

    foreach ($configRoot in @($scoConfigHome, $scoopConfigHome)) {
        $configDir = Join-Path $configRoot 'scoop'
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
        $Value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $configDir 'config.json') -Encoding UTF8
    }
}

function Stage-CacheBoth {
    foreach ($toolRoot in @($scoRoot, $scoopRoot)) {
        $cacheDir = Join-Path $toolRoot 'cache'
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        Set-Content -LiteralPath (Join-Path $cacheDir 'filetool#1.0.0#manual.exe') -Value 'file cache' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $cacheDir 'filetool#0.9.0#partial.exe.download') -Value 'partial cache' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $cacheDir 'othertool#2.0.0#manual.exe') -Value 'other cache' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $cacheDir 'filetool.txt') -Value 'file sidecar' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $cacheDir 'othertool.txt') -Value 'other sidecar' -Encoding Ascii
    }
}

function Stage-BucketsBoth {
    foreach ($toolRoot in @($scoRoot, $scoopRoot)) {
        [ordered]@{
            main = 'https://example.invalid/main'
            extras = 'https://example.invalid/extras'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $toolRoot 'buckets.json') -Encoding UTF8

        foreach ($bucketName in @('zzzcustom', 'extras', 'main')) {
            $bucketPath = Join-Path $toolRoot "buckets\$bucketName\bucket"
            New-Item -ItemType Directory -Force -Path $bucketPath | Out-Null
            [ordered]@{
                version = '1.0.0'
                description = "$bucketName app"
                bin = "$bucketName.exe"
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bucketPath "$bucketName.json") -Encoding UTF8
        }
    }
}

Assert-PairedCommand config
Assert-PairedCommand config missing_key
Assert-PairedCommand config aria2-enabled false
Assert-PairedCommand config aria2-enabled
Assert-PairedCommand config rm aria2-enabled
Assert-PairedCommand config aria2-enabled

Write-ConfigBoth @{
    'aria2-options' = @('--check-certificate=false', '--foo=bar')
    alias = [ordered]@{
        ls = 'scoop-list'
        rm = 'scoop-uninstall'
    }
}
Assert-PairedCommand config aria2-options
Assert-PairedCommand config alias

Assert-PairedCommand alias list
Assert-PairedCommand alias add sayhi 'Write-Output "alias:$($args[0])"' 'Echo first argument'
Assert-PairedCommand alias list
Assert-PairedCommand alias list --verbose
Assert-PairedCommand alias rm sayhi
Assert-PairedCommand alias list

Stage-CacheBoth
Assert-PairedCommand cache show
Assert-PairedCommand cache show filetool othertool
Assert-PairedCommand cache show missingtool
Assert-PairedCommand cache rm missingtool
Assert-PairedCommand cache rm filetool
Assert-PairedCommand cache show '*'

Stage-BucketsBoth
Assert-PairedCommand bucket list
Assert-PairedCommand bucket rm extras
Assert-PairedCommand bucket list
Assert-PairedCommand bucket rm missinglocal
