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

$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'filetool.json') -Encoding UTF8
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'globalexporttool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome

function Install-GlobalExportFixture($Name) {
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

& $ScoExe config aria2-enabled false
if ($LASTEXITCODE -ne 0) {
    throw "config failed with exit code $LASTEXITCODE"
}
& $ScoExe config root_path 'D:\machine-specific'
if ($LASTEXITCODE -ne 0) {
    throw "config root_path failed with exit code $LASTEXITCODE"
}

& $ScoExe install filetool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}
& $ScoExe hold filetool
if ($LASTEXITCODE -ne 0) {
    throw "hold failed with exit code $LASTEXITCODE"
}

Install-GlobalExportFixture 'globalexporttool'
if ($LASTEXITCODE -ne 0) {
    throw "global export fixture install failed with exit code $LASTEXITCODE"
}

$deprecatedDir = Join-Path $Root 'buckets\main\deprecated'
New-Item -ItemType Directory -Force -Path $deprecatedDir | Out-Null
Copy-Item -LiteralPath (Join-Path $bucketDir 'filetool.json') -Destination (Join-Path $deprecatedDir 'filetool.json') -Force
[System.IO.Directory]::Delete((Join-Path $Root 'apps\filetool\current'))

$exported = (& $ScoExe export --config) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "export failed with exit code $LASTEXITCODE`: $exported"
}

$json = $exported | ConvertFrom-Json
if ($json.buckets.Count -ne 1 -or $json.buckets[0].Name -ne 'main') {
    throw "export buckets did not include main: $exported"
}
if (-not $json.buckets[0].Source) {
    throw "export bucket source was empty: $exported"
}
if (-not $json.buckets[0].Updated -or $json.buckets[0].Manifests -ne 2) {
    throw "export bucket row did not include Scoop list_buckets metadata: $($json.buckets[0] | ConvertTo-Json -Compress)"
}

if ($json.apps.Count -ne 2) {
    throw "Expected two exported apps: $exported"
}
$app = @($json.apps | Where-Object Name -eq 'filetool')[0]
if ($app.Name -ne 'filetool' -or $app.Version -ne '1.0.0' -or $app.Source -ne 'main') {
    throw "Unexpected exported app row: $($app | ConvertTo-Json -Compress)"
}
if (-not $app.Updated) {
    throw "Exported app should include Updated from scoop list metadata: $($app | ConvertTo-Json -Compress)"
}
if ($app.Info -notmatch 'Held package') {
    throw "Exported app did not include hold info: $($app | ConvertTo-Json -Compress)"
}
if ($app.Info -notmatch 'Deprecated package') {
    throw "Exported app did not include deprecated package info from list metadata: $($app | ConvertTo-Json -Compress)"
}
if ($app.Info -notmatch 'Install failed') {
    throw "Exported app did not include failed install info from list metadata: $($app | ConvertTo-Json -Compress)"
}

$globalApp = @($json.apps | Where-Object Name -eq 'globalexporttool')[0]
if ($globalApp.Version -ne '1.0.0' -or $globalApp.Source -ne 'main') {
    throw "Unexpected exported global app row: $($globalApp | ConvertTo-Json -Compress)"
}
if (-not $globalApp.Updated) {
    throw "Exported global app should include Updated from scoop list metadata: $($globalApp | ConvertTo-Json -Compress)"
}
if ($globalApp.Info -notmatch 'Global install') {
    throw "Exported global app did not include Scoop list global marker: $($globalApp | ConvertTo-Json -Compress)"
}

if ($json.config.'aria2-enabled' -ne $false) {
    throw "Exported config did not include aria2-enabled=false: $exported"
}
if ($json.config.PSObject.Properties.Name -contains 'root_path') {
    throw "Exported config should not contain root_path: $exported"
}

$ignoredExtra = (& $ScoExe export --config ignored-arg) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "export with ignored extra argument failed with exit code $LASTEXITCODE`: $ignoredExtra"
}
$ignoredExtraJson = $ignoredExtra | ConvertFrom-Json
if ($ignoredExtraJson.config.'aria2-enabled' -ne $false) {
    throw "export did not keep config when --config was the first argument: $ignoredExtra"
}

$nonLeadingConfig = (& $ScoExe export ignored-arg --config) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "export with non-leading --config failed with exit code $LASTEXITCODE`: $nonLeadingConfig"
}
$nonLeadingConfigJson = $nonLeadingConfig | ConvertFrom-Json
if ($nonLeadingConfigJson.PSObject.Properties.Name -contains 'config') {
    throw "export should ignore non-leading --config like Scoop: $nonLeadingConfig"
}
