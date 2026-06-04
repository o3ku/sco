param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$WorkDir
)

$ErrorActionPreference = 'Stop'

$resolvedParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $WorkDir))
if ($resolvedParent -notlike '*\build\msvc-release*') {
    throw "Refusing to clean test directory outside build tree: $WorkDir"
}

if (Test-Path $WorkDir) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$missingUrlOutput = & $ScoExe create
if ($LASTEXITCODE -ne 0) {
    throw "create without a URL returned $LASTEXITCODE instead of 0: $missingUrlOutput"
}
if (($missingUrlOutput -join "`n") -notmatch 'Usage: sco create <url>' -or ($missingUrlOutput -join "`n") -match 'Usage: sco create <url> \[options\]') {
    throw "create without a URL did not show Scoop-style help: $missingUrlOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidUrlOutput = & $ScoExe create 'not-a-url' 2>&1
$invalidUrlExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidUrlExitCode -ne 1) {
    throw "create with invalid URL returned $invalidUrlExitCode instead of 1: $invalidUrlOutput"
}
if (($invalidUrlOutput -join "`n") -notmatch 'Error: not-a-url is not a valid URL') {
    throw "create invalid URL did not match Scoop error: $invalidUrlOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$dashUrlOutput = & $ScoExe create -z 2>&1
$dashUrlExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($dashUrlExitCode -ne 1) {
    throw "create -z returned $dashUrlExitCode instead of 1: $dashUrlOutput"
}
if (($dashUrlOutput -join "`n") -notmatch 'Error: -z is not a valid URL' -or ($dashUrlOutput -join "`n") -match 'unknown option') {
    throw "create -z did not treat -z as the URL like Scoop: $dashUrlOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingHostOutput = & $ScoExe create 'https://' 2>&1
$missingHostExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingHostExitCode -ne 1) {
    throw "create with a missing URL host returned $missingHostExitCode instead of 1: $missingHostOutput"
}
if (($missingHostOutput -join "`n") -notmatch 'Error: https:// is not a valid URL') {
    throw "create with a missing URL host did not match Scoop error: $missingHostOutput"
}

$manifestPath = Join-Path $WorkDir 'demoapp.json'
& $ScoExe create 'https://example.com/downloads/demoapp-1.2.3.zip' --hash '0123456789abcdef' --output $manifestPath --homepage 'https://example.com/demoapp' --license MIT
if ($LASTEXITCODE -ne 0) {
    throw "create failed with exit code $LASTEXITCODE"
}

if (!(Test-Path $manifestPath)) {
    throw 'create did not write expected manifest path'
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.version -ne '1.2.3') {
    throw "create did not infer version: $($manifest.version)"
}
if ($manifest.url -ne 'https://example.com/downloads/demoapp-1.2.3.zip') {
    throw "create did not preserve url: $($manifest.url)"
}
if ($manifest.hash -ne '0123456789abcdef') {
    throw "create did not preserve hash: $($manifest.hash)"
}
if ($manifest.bin -ne 'demoapp-1.2.3.zip') {
    throw "create did not infer bin from filename: $($manifest.bin)"
}
if ($manifest.depends -ne '') {
    throw "create did not use Scoop's empty-string depends template field: $($manifest.depends | ConvertTo-Json -Compress)"
}
if ($manifest.homepage -ne 'https://example.com/demoapp' -or $manifest.license -ne 'MIT') {
    throw 'create did not preserve homepage/license fields'
}

$extraManifestPath = Join-Path $WorkDir 'extraapp.json'
& $ScoExe create 'https://example.com/downloads/extraapp-1.0.0.zip' ignored-extra --output $extraManifestPath
if ($LASTEXITCODE -ne 0) {
    throw "create with an extra positional argument failed with exit code $LASTEXITCODE"
}
if (!(Test-Path $extraManifestPath)) {
    throw 'create with an extra positional argument did not write expected manifest'
}
$extraManifest = Get-Content -LiteralPath $extraManifestPath -Raw | ConvertFrom-Json
if ($extraManifest.url -ne 'https://example.com/downloads/extraapp-1.0.0.zip' -or $extraManifest.version -ne '1.0.0') {
    throw "create did not ignore extra positional arguments like Scoop: $($extraManifest | ConvertTo-Json -Compress)"
}

$summary = & $ScoExe manifest $manifestPath
if ($LASTEXITCODE -ne 0) {
    throw "created manifest could not be parsed with exit code $LASTEXITCODE"
}
$joined = $summary -join "`n"
if ($joined -notmatch 'version: 1\.2\.3' -or $joined -notmatch 'urls: 1' -or $joined -notmatch 'bins: 1') {
    throw "created manifest summary missing expected fields: $joined"
}

$customPath = Join-Path $WorkDir 'custom.json'
& $ScoExe create 'https://example.com/releases/tool-v9.8.7.exe' --name 'Custom Tool' --version '10.0.0' --bin 'custom.exe' --output $customPath
if ($LASTEXITCODE -ne 0) {
    throw "create with overrides failed with exit code $LASTEXITCODE"
}

$custom = Get-Content -LiteralPath $customPath -Raw | ConvertFrom-Json
if ($custom.version -ne '10.0.0' -or $custom.bin -ne 'custom.exe') {
    throw 'create did not honor version/bin overrides'
}

$ftpPath = Join-Path $WorkDir 'ftp.json'
& $ScoExe create 'ftp://example.com/releases/ftptool-2.0.0.zip' --name ftptool --version '2.0.0' --bin ftptool.exe --output $ftpPath
if ($LASTEXITCODE -ne 0) {
    throw "create rejected a valid non-HTTP URL with exit code $LASTEXITCODE"
}
$ftpManifest = Get-Content -LiteralPath $ftpPath -Raw | ConvertFrom-Json
if ($ftpManifest.url -ne 'ftp://example.com/releases/ftptool-2.0.0.zip') {
    throw "create did not preserve FTP URL: $($ftpManifest.url)"
}

Push-Location $WorkDir
try {
    & $ScoExe create 'https://example.com/releases/plainpackage.nupkg'
    if ($LASTEXITCODE -ne 0) {
        throw "create with a nupkg URL failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
$nupkgManifestPath = Join-Path $WorkDir 'plainpackage.json'
if (!(Test-Path $nupkgManifestPath)) {
    throw 'create did not strip the final URL extension for the default manifest name'
}
$nupkgManifest = Get-Content -LiteralPath $nupkgManifestPath -Raw | ConvertFrom-Json
if ($nupkgManifest.url -ne 'https://example.com/releases/plainpackage.nupkg') {
    throw "create did not preserve nupkg URL: $($nupkgManifest.url)"
}

Push-Location $WorkDir
try {
    & $ScoExe create 'https://example.com/releases/tarapp-1.2.3.tar.gz'
    if ($LASTEXITCODE -ne 0) {
        throw "create with a tar.gz URL failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
$tarManifestPath = Join-Path $WorkDir 'tarapp.json'
if (!(Test-Path $tarManifestPath)) {
    throw 'create did not preserve multi-part archive extension handling for the default manifest name'
}
$tarManifest = Get-Content -LiteralPath $tarManifestPath -Raw | ConvertFrom-Json
if ($tarManifest.version -ne '1.2.3' -or $tarManifest.url -ne 'https://example.com/releases/tarapp-1.2.3.tar.gz') {
    throw "create did not infer tar.gz manifest fields correctly: $($tarManifest | ConvertTo-Json -Compress)"
}
