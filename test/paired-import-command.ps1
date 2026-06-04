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

$bucketSource = Join-Path $Root 'bucket-source'
$bucketDir = Join-Path $bucketSource 'bucket'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

$artifactPath = [System.IO.Path]::GetFullPath($Artifact)
[ordered]@{
    version = '1.0.0'
    url = $artifactPath
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bucketDir 'importtool.json') -Encoding UTF8

git -C $bucketSource init | Out-Null
git -C $bucketSource config user.email sco-test@example.invalid | Out-Null
git -C $bucketSource config user.name sco-test | Out-Null
git -C $bucketSource add bucket/importtool.json | Out-Null
git -C $bucketSource commit -m 'import bucket' | Out-Null

$scoopFile = Join-Path $Root 'scoopfile.json'
$bucketSourceUrl = 'file:///' + (([System.IO.Path]::GetFullPath($bucketSource)) -replace '\\', '/')
[ordered]@{
    config = [ordered]@{
        'aria2-enabled' = $false
        last_update = ([System.DateTime]::Now.ToString('o'))
    }
    buckets = @(
        [ordered]@{
            Name = 'pairimport'
            Source = $bucketSourceUrl
        }
    )
    apps = @(
        [ordered]@{
            Name = 'importtool'
            Version = '1.0.0'
            Source = 'pairimport'
            Info = 'Held package'
        }
    )
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $scoopFile -Encoding UTF8

$scoRoot = Join-Path $Root 'sco'
$scoopRoot = Join-Path $Root 'scoop'
$scoConfigHome = Join-Path $ConfigHome 'sco'
$scoopConfigHome = Join-Path $ConfigHome 'scoop'
$scoopHome = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ScoopPs1) '..'))
$defaultPsModulePath = 'C:\Program Files\WindowsPowerShell\Modules;C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules'

foreach ($dir in @(
    $scoRoot,
    $scoopRoot,
    (Join-Path $scoRoot 'shims'),
    (Join-Path $scoopRoot 'shims'),
    (Join-Path $scoRoot 'cache'),
    (Join-Path $scoopRoot 'cache'),
    (Join-Path $scoRoot 'buckets'),
    (Join-Path $scoopRoot 'buckets'),
    $scoConfigHome,
    $scoopConfigHome
)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

function Set-PairedEnvironment {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('sco', 'scoop')][string]$Tool
    )

    if ($Tool -eq 'sco') {
        $env:SCOOP = $scoRoot
        $env:XDG_CONFIG_HOME = $scoConfigHome
    } else {
        $env:SCOOP = $scoopRoot
        $env:XDG_CONFIG_HOME = $scoopConfigHome
    }
    $env:SCOOP_HOME = $scoopHome
    $env:SCOOP_CACHE = Join-Path $env:SCOOP 'cache'
    $env:PSModulePath = $defaultPsModulePath
}

function Normalize-Output {
    param(
        [string[]]$Lines,
        [string]$ToolRoot,
        [string]$ToolConfigHome
    )

    $rootPath = ([System.IO.Path]::GetFullPath($ToolRoot)).TrimEnd('\')
    $rootSlashPath = $rootPath -replace '\\', '/'
    $configPath = ([System.IO.Path]::GetFullPath($ToolConfigHome)).TrimEnd('\')
    $configSlashPath = $configPath -replace '\\', '/'
    $bucketPath = ([System.IO.Path]::GetFullPath($bucketSource)).TrimEnd('\')
    $bucketSlashPath = $bucketPath -replace '\\', '/'
    $artifactSlashPath = $artifactPath -replace '\\', '/'

    $normalized = @($Lines | ForEach-Object {
        $line = ([string]$_ -replace "`r", '') `
            -replace "`e\[[0-9;?]*[ -/]*[@-~]", '' `
            -replace '\\', '/'
        $line = $line.Replace($rootSlashPath, '<ROOT>')
        $line = $line.Replace($configSlashPath, '<CONFIG>')
        $line = $line.Replace($bucketSlashPath, '<BUCKET>')
        $line = $line.Replace($artifactSlashPath, '<ARTIFACT>')
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

    Set-PairedEnvironment $Tool
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

function Convert-ExportJsonToCanonicalText {
    param([string]$Text)

    $json = $Text | ConvertFrom-Json
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($bucket in @($json.buckets | Sort-Object Name)) {
        $source = ([string]$bucket.Source -replace '\\', '/').Replace(([System.IO.Path]::GetFullPath($bucketSource) -replace '\\', '/'), '<BUCKET>')
        $lines.Add("bucket|$($bucket.Name)|$source|$($bucket.Manifests)")
    }
    foreach ($app in @($json.apps | Sort-Object Name)) {
        $lines.Add("app|$($app.Name)|$($app.Version)|$($app.Source)|$($app.Info)")
    }
    if ($json.PSObject.Properties.Name -contains 'config') {
        foreach ($property in @($json.config.PSObject.Properties | Sort-Object Name)) {
            if ($property.Name -eq 'scoop_branch') {
                continue
            }
            $lines.Add("config|$($property.Name)|$($property.Value)")
        }
    }
    return ($lines -join "`n")
}

$scoImport = Invoke-PairedTool sco import $scoopFile
$scoopImport = Invoke-PairedTool scoop import $scoopFile
if ($scoImport.ExitCode -ne $scoopImport.ExitCode) {
    throw "import exit codes differ: sco=$($scoImport.ExitCode), scoop=$($scoopImport.ExitCode)`nsco:`n$($scoImport.Text)`n---`nscoop:`n$($scoopImport.Text)"
}

foreach ($pattern in @(
    "'aria2-enabled' has been set to 'False'",
    "'last_update' has been set to '",
    "Installing 'importtool' \(1\.0\.0\) \[64bit\] from 'pairimport' bucket",
    "Linking <ROOT>/apps/importtool/current => <ROOT>/apps/importtool/1\.0\.0",
    "'importtool' \(1\.0\.0\) was installed successfully!",
    "importtool is now held and can not be updated anymore\."
)) {
    if ($scoImport.Text -notmatch $pattern) {
        throw "sco import output is missing '$pattern': $($scoImport.Text)"
    }
    if ($scoopImport.Text -notmatch $pattern) {
        throw "scoop import output is missing '$pattern': $($scoopImport.Text)"
    }
}

$scoExport = Invoke-PairedTool sco export
$scoopExport = Invoke-PairedTool scoop export
$scoCanonical = Convert-ExportJsonToCanonicalText $scoExport.Text
$scoopCanonical = Convert-ExportJsonToCanonicalText $scoopExport.Text
if ($scoCanonical -ne $scoopCanonical) {
    throw "export after import differs.`nsco:`n$scoCanonical`n---`nscoop:`n$scoopCanonical"
}
