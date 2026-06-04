param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome,
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
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$bucketDir = Join-Path $Root 'buckets\main\bucket'
$manifestPath = Join-Path $bucketDir 'nojunctiontool.json'
$envFile = Join-Path $Root 'env.json'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ConfigHome 'scoop') | Out-Null

function Write-Manifest($Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = @(, @('filetool.exe', 'nojunctiontool'))
        env_add_path = @('', '.', 'bin')
        pre_install = "New-Item -ItemType Directory -Force -Path (Join-Path `$dir 'bin') | Out-Null"
        env_set = [ordered]@{
            NOJUNCTION_HOME = '$dir'
            NOJUNCTION_BIN = '$dir\bin'
        }
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:SCOOP_ENV_FILE = $envFile
$env:PATH = "$(Join-Path $Root 'shims');$env:PATH"

@{ use_isolated_path = $true } | ConvertTo-Json | Set-Content -Path (Join-Path $ConfigHome 'scoop\config.json') -Encoding UTF8

& $ScoExe config no_junction true
if ($LASTEXITCODE -ne 0) {
    throw "config no_junction failed with exit code $LASTEXITCODE"
}

Write-Manifest '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
& $ScoExe install nojunctiontool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$v1Dir = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\nojunctiontool\1.0.0')).TrimEnd('\')
$currentDir = Join-Path $Root 'apps\nojunctiontool\current'
if (Test-Path $currentDir) {
    throw 'install created current alias even though no_junction is enabled'
}
if (!(Test-Path (Join-Path $v1Dir 'filetool.exe'))) {
    throw 'install did not place artifact in version directory'
}

$prefix = (& $ScoExe prefix nojunctiontool).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "prefix failed with exit code $LASTEXITCODE`: $prefix"
}
if ([System.IO.Path]::GetFullPath($prefix).TrimEnd('\') -ne $v1Dir) {
    throw "prefix did not resolve to version directory with no_junction: $prefix"
}

$shim = Get-Content (Join-Path $Root 'shims\nojunctiontool.shim') -Raw
if ($shim -match 'apps\\nojunctiontool\\current\\filetool\.exe' -or $shim -notmatch 'apps\\nojunctiontool\\1\.0\.0\\filetool\.exe') {
    throw "shim did not target version directory under no_junction: $shim"
}

$which = (& $ScoExe which nojunctiontool).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "which failed with exit code $LASTEXITCODE`: $which"
}
if ([System.IO.Path]::GetFullPath($which).TrimEnd('\') -ne (Join-Path $v1Dir 'filetool.exe')) {
    throw "which did not resolve versioned shim target: $which"
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
$expectedBinV1 = [System.IO.Path]::GetFullPath((Join-Path $v1Dir 'bin')).TrimEnd('\')
$pathEntries = @([string]$envJson.SCOOP_PATH -split ';' | Where-Object { $_ })
if ($pathEntries.Count -ne 2 -or $pathEntries[0].TrimEnd('\') -ne $v1Dir -or $pathEntries[1].TrimEnd('\') -ne $expectedBinV1) {
    throw "env_add_path did not use version directories under no_junction: $($envJson.SCOOP_PATH)"
}
if ([string]$envJson.NOJUNCTION_HOME -ne $v1Dir -or [string]$envJson.NOJUNCTION_BIN -ne $expectedBinV1) {
    throw "env_set did not expand `$dir to version directory under no_junction: $($envJson | ConvertTo-Json -Compress)"
}

$v2Source = Join-Path $Root 'sources\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $v2Source) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $v2Source -Force
Write-Manifest '1.1.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'

& $ScoExe update nojunctiontool
if ($LASTEXITCODE -ne 0) {
    throw "update failed with exit code $LASTEXITCODE"
}
if (Test-Path $currentDir) {
    throw 'update created current alias even though no_junction is enabled'
}

$v2Dir = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\nojunctiontool\1.1.0')).TrimEnd('\')
$updatedPrefix = (& $ScoExe prefix nojunctiontool).Trim()
if ([System.IO.Path]::GetFullPath($updatedPrefix).TrimEnd('\') -ne $v2Dir) {
    throw "prefix did not move to updated version directory: $updatedPrefix"
}

$updatedContent = (Get-Content (Join-Path $v2Dir 'filetool.exe') -Raw).TrimEnd()
if ($updatedContent -ne '@echo filetool-v2') {
    throw "update did not install v2 artifact: $updatedContent"
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
$expectedBinV2 = [System.IO.Path]::GetFullPath((Join-Path $v2Dir 'bin')).TrimEnd('\')
$pathEntries = @([string]$envJson.SCOOP_PATH -split ';' | Where-Object { $_ })
if ($pathEntries.Count -ne 2 -or $pathEntries[0].TrimEnd('\') -ne $v2Dir -or $pathEntries[1].TrimEnd('\') -ne $expectedBinV2) {
    throw "update did not replace env_add_path version directories: $($envJson.SCOOP_PATH)"
}

& $ScoExe reset nojunctiontool 1.0.0
if ($LASTEXITCODE -ne 0) {
    throw "reset failed with exit code $LASTEXITCODE"
}
if (Test-Path $currentDir) {
    throw 'reset created current alias even though no_junction is enabled'
}
$resetShim = Get-Content (Join-Path $Root 'shims\nojunctiontool.shim') -Raw
if ($resetShim -match 'apps\\nojunctiontool\\current\\filetool\.exe' -or $resetShim -notmatch 'apps\\nojunctiontool\\1\.0\.0\\filetool\.exe') {
    throw "reset did not recreate shim against selected version directory: $resetShim"
}
$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
$pathEntries = @([string]$envJson.SCOOP_PATH -split ';' | Where-Object { $_ })
if ($pathEntries.Count -ne 2 -or $pathEntries[0].TrimEnd('\') -ne $v1Dir -or $pathEntries[1].TrimEnd('\') -ne $expectedBinV1) {
    throw "reset did not replace env_add_path with selected version directories: $($envJson.SCOOP_PATH)"
}

& $ScoExe uninstall nojunctiontool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall failed with exit code $LASTEXITCODE"
}
if (Test-Path (Join-Path $Root 'apps\nojunctiontool')) {
    throw 'uninstall left app directory behind'
}
$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
if ([string]$envJson.SCOOP_PATH -or ($envJson.PSObject.Properties.Name -contains 'NOJUNCTION_HOME') -or ($envJson.PSObject.Properties.Name -contains 'NOJUNCTION_BIN')) {
    throw "uninstall did not remove no_junction env entries: $($envJson | ConvertTo-Json -Compress)"
}
