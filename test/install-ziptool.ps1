param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Manifest,
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

function Get-FileSha256($Path) {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hashBytes = $sha256.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha256.Dispose()
    }
    return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$versionDir = Join-Path $Root 'apps\ziptool\1.0.0'
$currentDir = Join-Path $Root 'apps\ziptool\current'
$cacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'ziptool#1.0.0#*.zip')

foreach ($path in @(
    (Join-Path $versionDir 'ziptool.exe'),
    (Join-Path $versionDir 'manifest.json'),
    (Join-Path $versionDir 'install.json'),
    (Join-Path $currentDir 'ziptool.exe'),
    (Join-Path $Root 'shims\ziptool.exe'),
    (Join-Path $Root 'shims\ziptool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "Missing expected install output: $path"
    }
}

if (Test-Path (Join-Path $versionDir 'ziptool.zip')) {
    throw 'Archive should not remain in the version directory after extraction'
}

if ($cacheFiles.Count -ne 1) {
    throw "Expected exactly one cached zip artifact, found $($cacheFiles.Count)"
}

$install = Get-Content (Join-Path $versionDir 'install.json') -Raw | ConvertFrom-Json
if ($install.downloaded -ne $true -or $install.artifact_count -ne 1) {
    throw "install.json did not record downloaded archive"
}

$manifestJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$zipSource = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $manifestJson.url))
$sourceDir = Join-Path $Root 'sources'
New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
$nupkg = Join-Path $sourceDir 'nupkgtool.nupkg'
Copy-Item -LiteralPath $zipSource -Destination $nupkg -Force
$sevenZip = Join-Path $sourceDir '7z.exe'
Set-Content -Path $sevenZip -Value '@echo 7zip' -NoNewline -Encoding Ascii

$bucketDir = Join-Path $Root 'buckets\main\bucket'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
$sevenZipManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($sevenZip))
    hash = (Get-FileSha256 $sevenZip)
    bin = '7z.exe'
}
$sevenZipManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir '7zip.json') -Encoding UTF8

$nupkgManifestPath = Join-Path (Split-Path -Parent $Root) 'nupkgtool.json'
$nupkgManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($nupkg))
    hash = (Get-FileSha256 $nupkg)
    bin = @(, @('ziptool.exe', 'nupkgtool'))
}
$nupkgManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $nupkgManifestPath -Encoding UTF8

& $ScoExe install $nupkgManifestPath --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install nupkg archive failed with exit code $LASTEXITCODE"
}

$nupkgVersionDir = Join-Path $Root 'apps\nupkgtool\1.0.0'
$nupkgCurrentDir = Join-Path $Root 'apps\nupkgtool\current'
$nupkgCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'nupkgtool#1.0.0#*.nupkg')

foreach ($path in @(
    (Join-Path $nupkgVersionDir 'ziptool.exe'),
    (Join-Path $nupkgCurrentDir 'ziptool.exe'),
    (Join-Path $Root 'shims\nupkgtool.exe'),
    (Join-Path $Root 'shims\nupkgtool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "Missing expected nupkg install output: $path"
    }
}

if (Test-Path (Join-Path $nupkgVersionDir 'nupkgtool.nupkg')) {
    throw 'NuGet package archive should not remain in the version directory after extraction'
}

if ($nupkgCacheFiles.Count -ne 1) {
    throw "Expected exactly one cached nupkg artifact, found $($nupkgCacheFiles.Count)"
}
