param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome,
    [Parameter(Mandatory = $true)][string]$Artifact,
    [Parameter(Mandatory = $true)][string]$ScoopPs1
)

$ErrorActionPreference = 'Stop'

function Get-Sha256Hex([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$resolvedRootParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $Root))
if ($resolvedRootParent -notlike '*\build\*') {
    throw "Refusing to clean test root outside build tree: $Root"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$mainSource = Join-Path $Root '..\init-main-source'
if (Test-Path $mainSource) {
    Remove-Item -LiteralPath $mainSource -Recurse -Force
}
$mainBucket = Join-Path $mainSource 'bucket'
New-Item -ItemType Directory -Force -Path $mainBucket | Out-Null

$manifest = [ordered]@{
    version = '1.0.0'
    description = 'Init test app'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $mainBucket 'filetool.json') -Encoding UTF8

New-Item -ItemType Directory -Force -Path $Root | Out-Null
[ordered]@{
    main = ([System.IO.Path]::GetFullPath($mainSource))
} | ConvertTo-Json | Set-Content -Path (Join-Path $Root 'buckets.json') -Encoding UTF8

$env:SCOOP = $Root
$originalScoopCache = $env:SCOOP_CACHE
Remove-Item Env:SCOOP_CACHE -ErrorAction SilentlyContinue
$env:XDG_CONFIG_HOME = $ConfigHome
$env:SCOOP_HOME = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ScoopPs1) '..'))
$envFile = Join-Path $Root 'env.json'
$env:SCOOP_ENV_FILE = $envFile
@{ PATH = 'C:\Windows' } | ConvertTo-Json | Set-Content -Path $envFile -Encoding UTF8

$help = (& $ScoExe init --help) -join "`n"
if ($LASTEXITCODE -ne 0 -or $help -notmatch 'Usage: sco init') {
    throw "init --help failed or printed unexpected help: $help"
}

$originalPath = $env:PATH
try {
    $env:PATH = 'C:\Windows\System32;C:\Windows'
    $firstOutput = (& $ScoExe init) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "first init failed: $firstOutput"
    }
} finally {
    $env:PATH = $originalPath
}
if ($firstOutput -match 'Git is not installed|7zip is not installed') {
    throw "init should not bootstrap Git or 7zip for a local non-git main bucket: $firstOutput"
}
foreach ($pattern in @(
    'Ensured Scoop directories',
    'Set SCOOP to',
    'Set SCOOP_GLOBAL to',
    'Set SCOOP_CACHE to',
    'Added .*shims to your PATH',
    'Installed sco runtime executables to',
    'Created sco shim',
    'Added main bucket',
    'Initialized Scoop config',
    'sco init completed'
)) {
    if ($firstOutput -notmatch $pattern) {
        throw "first init output missing '$pattern': $firstOutput"
    }
}

foreach ($path in @(
    (Join-Path $Root 'apps'),
    (Join-Path $Root 'shims'),
    (Join-Path $Root 'buckets'),
    (Join-Path $Root 'cache'),
    (Join-Path $Root 'persist')
)) {
    if (!(Test-Path $path)) {
        throw "init did not create $path"
    }
}

if (!(Test-Path (Join-Path $Root 'buckets\main\bucket\filetool.json'))) {
    throw 'init did not add the main bucket'
}

$shim = Join-Path $Root 'shims\sco.cmd'
if (!(Test-Path $shim)) {
    throw 'init did not create sco.cmd shim'
}
$runtimeExe = Join-Path $Root 'apps\sco\current\sco.exe'
if (!(Test-Path $runtimeExe)) {
    throw 'init did not install sco.exe into the Scoop runtime directory'
}
$versionExe = Join-Path $Root 'apps\sco\0.6.1\sco.exe'
if (!(Test-Path $versionExe)) {
    throw 'init did not install sco.exe into the Scoop runtime version directory'
}
if ((Get-Sha256Hex $runtimeExe) -ne (Get-Sha256Hex $ScoExe)) {
    throw 'installed runtime sco.exe does not match the current sco.exe'
}
if ((Get-Sha256Hex $versionExe) -ne (Get-Sha256Hex $ScoExe)) {
    throw 'installed version sco.exe does not match the current sco.exe'
}
foreach ($path in @(
    (Join-Path $Root 'apps\sco\current\manifest.json'),
    (Join-Path $Root 'apps\sco\current\install.json'),
    (Join-Path $Root 'apps\sco\0.6.1\manifest.json'),
    (Join-Path $Root 'apps\sco\0.6.1\install.json')
)) {
    if (!(Test-Path $path)) {
        throw "init did not create Scoop-compatible sco metadata: $path"
    }
}
$scoManifest = Get-Content (Join-Path $Root 'apps\sco\current\manifest.json') -Raw | ConvertFrom-Json
if ($scoManifest.version -ne '0.6.1' -or $scoManifest.bin -ne 'sco.exe') {
    throw "sco runtime manifest is invalid: $($scoManifest | ConvertTo-Json -Compress)"
}
$shimContent = Get-Content -Path $shim -Raw
if ($shimContent -notmatch [regex]::Escape([System.IO.Path]::GetFullPath($runtimeExe))) {
    throw "sco.cmd shim does not point at installed runtime sco.exe: $shimContent"
}

$listOutput = (& $ScoExe list) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "list after init failed: $listOutput"
}
if ($listOutput -notmatch 'sco\s+0\.6\.1') {
    throw "list after init should show sco as a normal installed app: $listOutput"
}
if ($listOutput -match 'Install failed') {
    throw "list after init should not show a failed install: $listOutput"
}

$scoopListOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $ScoopPs1 list) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "reference scoop list after init failed: $scoopListOutput"
}
if ($scoopListOutput -notmatch 'sco\s+0\.6\.1') {
    throw "reference scoop list after init should show sco as a normal installed app: $scoopListOutput"
}
if ($scoopListOutput -match 'Install failed') {
    throw "reference scoop list after init should not show a failed install: $scoopListOutput"
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
$pathEntries = @([string]$envJson.PATH -split ';' | Where-Object { $_ })
$expectedShimPath = [System.IO.Path]::GetFullPath((Join-Path $Root 'shims'))
if (@($pathEntries | Where-Object { $_ -ieq $expectedShimPath }).Count -ne 1) {
    throw "init should add shims to PATH once, got: $($envJson.PATH)"
}
if ([string]$envJson.SCOOP -ne [System.IO.Path]::GetFullPath($Root)) {
    throw "init did not set SCOOP in env file: $($envJson.SCOOP)"
}
if ([string]$envJson.SCOOP_CACHE -ne [System.IO.Path]::GetFullPath((Join-Path $Root 'cache'))) {
    throw "init did not set SCOOP_CACHE in env file: $($envJson.SCOOP_CACHE)"
}

$shimWriteTime = (Get-Item $shim).LastWriteTimeUtc
$runtimeWriteTime = (Get-Item $runtimeExe).LastWriteTimeUtc
$versionWriteTime = (Get-Item $versionExe).LastWriteTimeUtc
$runtimeManifestWriteTime = (Get-Item (Join-Path $Root 'apps\sco\current\manifest.json')).LastWriteTimeUtc
$versionManifestWriteTime = (Get-Item (Join-Path $Root 'apps\sco\0.6.1\manifest.json')).LastWriteTimeUtc
$bucketWriteTime = (Get-Item (Join-Path $Root 'buckets\main')).LastWriteTimeUtc
Start-Sleep -Milliseconds 1100

$secondOutput = (& $ScoExe init) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "second init failed: $secondOutput"
}
foreach ($pattern in @(
    'SCOOP is already configured',
    'SCOOP_GLOBAL is already configured',
    'SCOOP_CACHE is already configured',
    'Scoop shims directory is already in your PATH',
    'sco runtime executables are already installed',
    'sco runtime metadata is already configured',
    'sco shim is already configured',
    'Main bucket is already added',
    'Scoop config is already initialized',
    'sco init completed'
)) {
    if ($secondOutput -notmatch $pattern) {
        throw "second init output missing '$pattern': $secondOutput"
    }
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
$pathEntries = @([string]$envJson.PATH -split ';' | Where-Object { $_ })
if (@($pathEntries | Where-Object { $_ -ieq $expectedShimPath }).Count -ne 1) {
    throw "second init duplicated shims PATH entry: $($envJson.PATH)"
}
if ((Get-Item $shim).LastWriteTimeUtc -ne $shimWriteTime) {
    throw 'second init rewrote sco.cmd shim'
}
if ((Get-Item $runtimeExe).LastWriteTimeUtc -ne $runtimeWriteTime) {
    throw 'second init rewrote runtime sco.exe'
}
if ((Get-Item $versionExe).LastWriteTimeUtc -ne $versionWriteTime) {
    throw 'second init rewrote version sco.exe'
}
if ((Get-Item (Join-Path $Root 'apps\sco\current\manifest.json')).LastWriteTimeUtc -ne $runtimeManifestWriteTime) {
    throw 'second init rewrote current sco manifest'
}
if ((Get-Item (Join-Path $Root 'apps\sco\0.6.1\manifest.json')).LastWriteTimeUtc -ne $versionManifestWriteTime) {
    throw 'second init rewrote version sco manifest'
}
if ((Get-Item (Join-Path $Root 'buckets\main')).LastWriteTimeUtc -ne $bucketWriteTime) {
    throw 'second init rewrote or replaced main bucket'
}

Remove-Item Env:SCOOP_ENV_FILE -ErrorAction SilentlyContinue
if ($null -ne $originalScoopCache) {
    $env:SCOOP_CACHE = $originalScoopCache
}
