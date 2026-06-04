param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
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

$sourceDir = Join-Path $Root 'sources\extract-src'
$payloadDir = Join-Path $sourceDir 'package-1.0.0'
$nestedDir = Join-Path $sourceDir 'ignored-dir'
$archive = Join-Path $Root 'sources\extracttool.zip'
$bucketDir = Join-Path $Root 'buckets\main\bucket'
$manifestPath = Join-Path $bucketDir 'extracttool.json'

New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $nestedDir | Out-Null
Set-Content -Path (Join-Path $payloadDir 'extracttool.exe') -Value '@echo extracttool' -NoNewline -Encoding Ascii
Set-Content -Path (Join-Path $nestedDir 'ignored.txt') -Value 'ignored' -NoNewline -Encoding Ascii
Compress-Archive -Path $payloadDir, $nestedDir -DestinationPath $archive -Force

$hash = Get-FileSha256 $archive
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($archive))
    hash = $hash
    extract_dir = 'package-1.0.0'
    bin = 'extracttool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe install extracttool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

foreach ($path in @(
    (Join-Path $Root 'apps\extracttool\1.0.0\extracttool.exe'),
    (Join-Path $Root 'apps\extracttool\current\extracttool.exe'),
    (Join-Path $Root 'shims\extracttool.exe'),
    (Join-Path $Root 'shims\extracttool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "Missing expected extract_dir install output: $path"
    }
}

foreach ($path in @(
    (Join-Path $Root 'apps\extracttool\1.0.0\package-1.0.0'),
    (Join-Path $Root 'apps\extracttool\1.0.0\ignored-dir'),
    (Join-Path $Root 'apps\extracttool\1.0.0\extracttool.zip')
)) {
    if (Test-Path $path) {
        throw "extract_dir left unexpected path: $path"
    }
}

$content = Get-Content (Join-Path $Root 'apps\extracttool\current\extracttool.exe') -Raw
if ($content -ne '@echo extracttool') {
    throw "Unexpected extracted content: $content"
}

$sidecar = Join-Path $Root 'sources\paired-sidecar.txt'
Set-Content -Path $sidecar -Value 'sidecar' -NoNewline -Encoding Ascii
$pairedManifestPath = Join-Path $bucketDir 'pairedextracttool.json'
$pairedManifest = [ordered]@{
    version = '1.0.0'
    url = @(
        ([System.IO.Path]::GetFullPath($sidecar)),
        ([System.IO.Path]::GetFullPath($archive))
    )
    hash = @(
        (Get-FileSha256 $sidecar),
        $hash
    )
    extract_dir = 'package-1.0.0'
    bin = @(, @('extracttool.exe', 'pairedextracttool'))
}
$pairedManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $pairedManifestPath -Encoding UTF8

& $ScoExe install pairedextracttool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with non-archive URL before extract_dir archive failed with exit code $LASTEXITCODE"
}

foreach ($path in @(
    (Join-Path $Root 'apps\pairedextracttool\1.0.0\extracttool.exe'),
    (Join-Path $Root 'apps\pairedextracttool\current\extracttool.exe'),
    (Join-Path $Root 'shims\pairedextracttool.exe'),
    (Join-Path $Root 'shims\pairedextracttool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "Missing expected paired extract_dir install output: $path"
    }
}

foreach ($path in @(
    (Join-Path $Root 'apps\pairedextracttool\1.0.0\package-1.0.0'),
    (Join-Path $Root 'apps\pairedextracttool\1.0.0\ignored-dir'),
    (Join-Path $Root 'apps\pairedextracttool\1.0.0\extracttool.zip')
)) {
    if (Test-Path $path) {
        throw "paired extract_dir left unexpected path: $path"
    }
}
