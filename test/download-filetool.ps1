param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$GlobalRoot,
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
if (Test-Path $GlobalRoot) {
    Remove-Item -LiteralPath $GlobalRoot -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome

function Install-GlobalStandaloneDownloadFixture($ManifestPath) {
    $previousScoop = $env:SCOOP
    $previousGlobal = $env:SCOOP_GLOBAL
    try {
        $env:SCOOP = $GlobalRoot
        Remove-Item Env:SCOOP_GLOBAL -ErrorAction SilentlyContinue
        & $ScoExe install $ManifestPath --no-update-scoop
    } finally {
        $env:SCOOP = $previousScoop
        $env:SCOOP_GLOBAL = $previousGlobal
    }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAppOutput = & $ScoExe download 2>&1
$missingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppExitCode -ne 1) {
    throw "download without an app returned $missingAppExitCode instead of 1: $missingAppOutput"
}
if (($missingAppOutput -join "`n") -notmatch 'ERROR <app> missing' -or ($missingAppOutput -join "`n") -notmatch 'Usage: sco download <app> \[options\]') {
    throw "download without an app did not match Scoop usage: $missingAppOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$noCacheOutput = & $ScoExe download $Manifest --no-cache 2>&1
$noCacheExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($noCacheExitCode -ne 1) {
    throw "download --no-cache returned $noCacheExitCode instead of 1: $noCacheOutput"
}
if (($noCacheOutput -join "`n") -notmatch 'sco download: Option --no-cache not recognized\.') {
    throw "download --no-cache did not match Scoop getopt error: $noCacheOutput"
}

$missingRemoteManifestPrefix = 'http://127.0.0.1:18217/'
$missingRemoteManifestJob = Start-Job -ScriptBlock {
    param($Prefix)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        $context = $listener.GetContext()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('missing')
        $context.Response.StatusCode = 404
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList $missingRemoteManifestPrefix
Start-Sleep -Milliseconds 300
try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $missingRemoteManifestOutput = & $ScoExe download ($missingRemoteManifestPrefix + 'missing.json') 2>&1
    $missingRemoteManifestExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Wait-Job $missingRemoteManifestJob -Timeout 5 | Out-Null
    Receive-Job $missingRemoteManifestJob | Out-Null
    Remove-Job $missingRemoteManifestJob -Force
}
if ($missingRemoteManifestExitCode -ne 0) {
    throw "download with missing remote manifest returned $missingRemoteManifestExitCode instead of Scoop's non-fatal 0: $missingRemoteManifestOutput"
}
$missingRemoteManifestJoined = $missingRemoteManifestOutput -join "`n"
if ($missingRemoteManifestJoined -notmatch "sco download: couldn't download manifest from 'http://127\.0\.0\.1:18217/missing\.json': HTTP 404" -or
    $missingRemoteManifestJoined -match 'sco install:') {
    throw "download with missing remote manifest did not use the download error prefix: $missingRemoteManifestJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$archEqualsOutput = & $ScoExe download $Manifest --arch=64bit 2>&1
$archEqualsExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($archEqualsExitCode -ne 1) {
    throw "download --arch=64bit returned $archEqualsExitCode instead of 1: $archEqualsOutput"
}
if (($archEqualsOutput -join "`n") -notmatch 'sco download: Option --arch=64bit not recognized\.') {
    throw "download --arch=64bit did not match Scoop getopt error: $archEqualsOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidArchOutput = & $ScoExe download $Manifest --arch mips 2>&1
$invalidArchExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidArchExitCode -ne 1) {
    throw "download --arch mips returned $invalidArchExitCode instead of 1: $invalidArchOutput"
}
if (($invalidArchOutput -join "`n") -notmatch "ERROR: Invalid architecture: 'mips'") {
    throw "download --arch mips did not match Scoop architecture error: $invalidArchOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$mixedOutput = & $ScoExe download missing-download-tool $Manifest 2>&1
$mixedExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($mixedExitCode -ne 0) {
    throw "download with one missing app returned $mixedExitCode instead of Scoop's non-fatal 0: $mixedOutput"
}
$mixedJoined = $mixedOutput -join "`n"
if ($mixedJoined -notmatch "couldn't find manifest for 'missing-download-tool'" -or $mixedJoined -notmatch "'filetool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download with one missing app did not report both failure and successful download: $mixedJoined"
}
$mixedCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'filetool#1.0.0#*.exe')
if ($mixedCacheFiles.Count -ne 1) {
    throw "download stopped before processing the valid manifest after a missing app: $($mixedCacheFiles.Name -join ', ')"
}

$globalStandaloneDir = Join-Path (Split-Path -Parent $Root) 'download-global-source'
New-Item -ItemType Directory -Force -Path $globalStandaloneDir | Out-Null
$globalStandaloneManifest = Join-Path $globalStandaloneDir 'downloadbothscope.json'
$artifactPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) '..\artifacts\filetool.exe'))
@{
    version = '1.0.0'
    url = $artifactPath
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
} | ConvertTo-Json | Set-Content -Path $globalStandaloneManifest -Encoding UTF8

Install-GlobalStandaloneDownloadFixture $globalStandaloneManifest
if ($LASTEXITCODE -ne 0) {
    throw "global standalone download fixture failed with exit code $LASTEXITCODE"
}

$globalStandaloneOutput = & $ScoExe download downloadbothscope --force
if ($LASTEXITCODE -ne 0) {
    throw "download should resolve a global standalone install source like Scoop, got $LASTEXITCODE`: $globalStandaloneOutput"
}
$globalStandaloneJoined = $globalStandaloneOutput -join "`n"
if ($globalStandaloneJoined -notmatch "INFO  Downloading 'downloadbothscope' \[64bit\]" -or
    $globalStandaloneJoined -notmatch "'downloadbothscope' \(1\.0\.0\) was downloaded successfully!") {
    throw "download did not use global standalone install source: $globalStandaloneJoined"
}
$globalStandaloneCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'downloadbothscope#1.0.0#*.exe')
if ($globalStandaloneCacheFiles.Count -ne 1) {
    throw "download from global standalone source did not create expected cache entry: $($globalStandaloneCacheFiles.Name -join ', ')"
}

$emptyVersionManifest = Join-Path (Split-Path -Parent $Root) 'download-empty-version-filetool.json'
$emptyVersionJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$emptyVersionJson.version = ''
$emptyVersionJson | ConvertTo-Json -Depth 5 | Set-Content -Path $emptyVersionManifest -Encoding UTF8

$badVersionManifest = Join-Path (Split-Path -Parent $Root) 'download-bad-version-filetool.json'
$badVersionJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$badVersionJson.version = '1/0'
$badVersionJson | ConvertTo-Json -Depth 5 | Set-Content -Path $badVersionManifest -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$mixedManifestErrorOutput = & $ScoExe download $emptyVersionManifest $badVersionManifest $Manifest --force 2>&1
$mixedManifestErrorExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($mixedManifestErrorExitCode -ne 0) {
    throw "download with manifest version errors returned $mixedManifestErrorExitCode instead of Scoop's non-fatal 0: $mixedManifestErrorOutput"
}
$mixedManifestErrorJoined = $mixedManifestErrorOutput -join "`n"
if ($mixedManifestErrorJoined -notmatch "ERROR Manifest doesn't specify a version\." -or
    $mixedManifestErrorJoined -notmatch "ERROR Manifest version has unsupported character '/'\." -or
    $mixedManifestErrorJoined -notmatch "'filetool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download with manifest version errors did not report failures and continue: $mixedManifestErrorJoined"
}
$emptyVersionCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-empty-version-filetool#*' -ErrorAction SilentlyContinue)
if ($emptyVersionCacheFiles.Count -ne 0) {
    throw "download with empty manifest version left cache entries: $($emptyVersionCacheFiles.Name -join ', ')"
}
$badVersionCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-bad-version-filetool#*' -ErrorAction SilentlyContinue)
if ($badVersionCacheFiles.Count -ne 0) {
    throw "download with unsupported manifest version left cache entries: $($badVersionCacheFiles.Name -join ', ')"
}

$badUrlManifest = Join-Path (Split-Path -Parent $Root) 'download-bad-url-filetool.json'
$badUrlSource = Join-Path (Split-Path -Parent $Root) 'missing-artifacts\missing-filetool.exe'
$badUrlJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$badUrlJson.url = $badUrlSource
$badUrlJson.hash = ''
$badUrlJson | ConvertTo-Json -Depth 5 | Set-Content -Path $badUrlManifest -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$mixedBadUrlOutput = & $ScoExe download $badUrlManifest $Manifest --force 2>&1
$mixedBadUrlExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($mixedBadUrlExitCode -ne 0) {
    throw "download with one bad artifact URL returned $mixedBadUrlExitCode instead of Scoop's non-fatal 0: $mixedBadUrlOutput"
}
$mixedBadUrlJoined = $mixedBadUrlOutput -join "`n"
if ($mixedBadUrlJoined -notmatch 'local artifact does not exist:' -or
    $mixedBadUrlJoined -notmatch "ERROR URL $([regex]::Escape($badUrlSource)) is not valid" -or
    $mixedBadUrlJoined -notmatch "'filetool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download with one bad artifact URL did not report failure and continue: $mixedBadUrlJoined"
}
$badUrlCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-bad-url-filetool#1.0.0#*.exe' -ErrorAction SilentlyContinue)
if ($badUrlCacheFiles.Count -ne 0) {
    throw "download with bad artifact URL left cache entries: $($badUrlCacheFiles.Name -join ', ')"
}

$output = & $ScoExe download $Manifest
if ($LASTEXITCODE -ne 0) {
    throw "download failed with exit code $LASTEXITCODE`: $output"
}
$joinedOutput = $output -join "`n"
if ($joinedOutput -notmatch "INFO  Downloading 'filetool' \[64bit\]" -or
    $joinedOutput -notmatch 'Loading filetool\.exe from cache' -or
    $joinedOutput -notmatch "'filetool' \(1\.0\.0\) was downloaded successfully!" -or
    $joinedOutput -match ' to .+cache') {
    throw "download output did not include success line: $output"
}

$cacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'filetool#1.0.0#*.exe')
if ($cacheFiles.Count -ne 1) {
    throw "Expected one cached artifact, found $($cacheFiles.Count)"
}

$forcedOutput = & $ScoExe download $Manifest --force
if ($LASTEXITCODE -ne 0) {
    throw "download --force failed with exit code $LASTEXITCODE`: $forcedOutput"
}
$forcedJoined = $forcedOutput -join "`n"
if ($forcedJoined -notmatch 'WARN  Cache is being ignored\.' -or $forcedJoined -notmatch "'filetool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download --force output did not include success line: $forcedOutput"
}

$clusteredOutput = & $ScoExe download -fs $Manifest
if ($LASTEXITCODE -ne 0) {
    throw "download clustered -fs options failed with exit code $LASTEXITCODE`: $clusteredOutput"
}
$clusteredJoined = $clusteredOutput -join "`n"
if ($clusteredJoined -notmatch 'WARN  Cache is being ignored\.' -or $clusteredJoined -notmatch 'INFO  Skipping hash verification\.' -or $clusteredJoined -notmatch "'filetool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download clustered -fs output did not include success line: $clusteredOutput"
}

$terminatorOutput = & $ScoExe download -- $Manifest
if ($LASTEXITCODE -ne 0) {
    throw "download -- terminator failed with exit code $LASTEXITCODE`: $terminatorOutput"
}
if (($terminatorOutput -join "`n") -notmatch "'filetool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download -- terminator output did not include success line: $terminatorOutput"
}

if (Test-Path (Join-Path $Root 'apps\filetool')) {
    throw "download created an app install directory"
}
if (Test-Path (Join-Path $Root 'shims\filetool.cmd')) {
    throw "download created a shim"
}

$showOutput = & $ScoExe cache show filetool
if ($LASTEXITCODE -ne 0 -or ($showOutput -join "`n") -notmatch 'filetool\s+1\.0\.0\s+\d+') {
    throw "cache show did not include downloaded filetool entry: $showOutput"
}

$fragmentManifest = Join-Path (Split-Path -Parent $Root) 'download-fragment-filetool.json'
$fragmentJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$fragmentSource = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $fragmentJson.url))
$fragmentJson.url = "$fragmentSource#/renamed-filetool.bin"
$fragmentJson.bin = 'renamed-filetool.bin'
$fragmentJson | ConvertTo-Json -Depth 5 | Set-Content -Path $fragmentManifest -Encoding UTF8

$fragmentOutput = & $ScoExe download $fragmentManifest --force
if ($LASTEXITCODE -ne 0) {
    throw "download with URL fragment filename failed with exit code $LASTEXITCODE`: $fragmentOutput"
}
if (($fragmentOutput -join "`n") -notmatch "'download-fragment-filetool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download with URL fragment filename did not include success line: $fragmentOutput"
}

$fragmentCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-fragment-filetool#1.0.0#*.bin')
if ($fragmentCacheFiles.Count -ne 1) {
    throw "Expected one URL fragment cache artifact with forced extension, found $($fragmentCacheFiles.Count)"
}
if (Test-Path (Join-Path $Root 'apps\download-fragment-filetool')) {
    throw "download with URL fragment filename created an app install directory"
}

$atNameManifest = Join-Path (Split-Path -Parent $Root) 'download-at-name@channel.json'
$atNameJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$atNameJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $atNameJson.url))
$atNameJson | ConvertTo-Json -Depth 5 | Set-Content -Path $atNameManifest -Encoding UTF8

$atNameOutput = & $ScoExe download $atNameManifest --force
if ($LASTEXITCODE -ne 0) {
    throw "download manifest path containing @ failed with exit code $LASTEXITCODE`: $atNameOutput"
}
if (($atNameOutput -join "`n") -notmatch "'download-at-name@channel' \(1\.0\.0\) was downloaded successfully!") {
    throw "download manifest path containing @ was not treated as a JSON manifest path: $atNameOutput"
}
$atNameCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-at-name@channel#1.0.0#*.exe')
if ($atNameCacheFiles.Count -ne 1) {
    throw "download manifest path containing @ did not create expected cache entry: $($atNameCacheFiles.Name -join ', ')"
}

$noAutoupdateManifest = Join-Path (Split-Path -Parent $Root) 'download-no-autoupdate-filetool.json'
$noAutoupdateJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$noAutoupdateJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $noAutoupdateJson.url))
$noAutoupdateJson | ConvertTo-Json -Depth 5 | Set-Content -Path $noAutoupdateManifest -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$noAutoupdateOutput = & $ScoExe download "$($noAutoupdateManifest)@2.0.0" 2>&1
$noAutoupdateExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($noAutoupdateExitCode -ne 1) {
    throw "download app@version without autoupdate returned $noAutoupdateExitCode instead of 1: $noAutoupdateOutput"
}
if (($noAutoupdateOutput -join "`n") -notmatch 'does not have autoupdate capability') {
    throw "download app@version without autoupdate did not report generation failure: $noAutoupdateOutput"
}
$noAutoupdateCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-no-autoupdate-filetool#*' -ErrorAction SilentlyContinue)
if ($noAutoupdateCacheFiles.Count -ne 0) {
    throw "download app@version without autoupdate left cache entries: $($noAutoupdateCacheFiles.Name -join ', ')"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}
$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$legacyManifest = Join-Path (Split-Path -Parent $Root) 'download-legacy-cache-filetool.json'
$legacyJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$legacySource = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $legacyJson.url))
$legacyJson.url = $legacySource
$legacyJson.hash = ''
$legacyJson | ConvertTo-Json -Depth 5 | Set-Content -Path $legacyManifest -Encoding UTF8

$legacyCacheDir = Join-Path $Root 'cache'
New-Item -ItemType Directory -Force -Path $legacyCacheDir | Out-Null
$legacyKey = $legacySource -replace '[^\w\.\-]+', '_'
$legacyCache = Join-Path $legacyCacheDir "download-legacy-cache-filetool#1.0.0#$legacyKey"
Set-Content -Path $legacyCache -Value 'legacy cache content' -Encoding Ascii

$legacyOutput = & $ScoExe download $legacyManifest
if ($LASTEXITCODE -ne 0) {
    throw "download with legacy cache file failed with exit code $LASTEXITCODE`: $legacyOutput"
}
$legacyCacheFiles = @(Get-ChildItem $legacyCacheDir -Filter 'download-legacy-cache-filetool#1.0.0#*')
if ($legacyCacheFiles.Count -ne 1 -or $legacyCacheFiles[0].FullName -ne $legacyCache) {
    throw "download did not reuse the legacy cache file exactly: $($legacyCacheFiles.Name -join ', ')"
}
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $legacyHashBytes = $sha256.ComputeHash([System.IO.File]::ReadAllBytes($legacyCache))
    $legacyHash = ([System.BitConverter]::ToString($legacyHashBytes)).Replace('-', '').ToLowerInvariant()
} finally {
    $sha256.Dispose()
}
$legacyJoined = $legacyOutput -join "`n"
if ($legacyJoined -notmatch "WARN  Warning: No hash in manifest\. SHA256 for '$([regex]::Escape($legacyCacheFiles[0].Name))' is:" -or
    $legacyJoined -notmatch $legacyHash) {
    throw "download with missing hash did not warn with computed SHA256: $legacyJoined"
}
if ((Get-Content -LiteralPath $legacyCache -Raw).TrimEnd() -ne 'legacy cache content') {
    throw 'download rewrote the seeded legacy cache entry instead of reusing it'
}

$typedHashManifest = Join-Path (Split-Path -Parent $Root) 'download-sha512-filetool.json'
$typedHashJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$typedHashJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $typedHashJson.url))
$typedHashJson.hash = 'sha512:5057a7ab95d0eb0e87191773763a200a119eab107d853557c5f62f9cd9273d3397da279c8e8cfd6169e59cd5dad517f91b4bffb8e7eaed062ccef3845dbaedd6'
$typedHashJson | ConvertTo-Json -Depth 5 | Set-Content -Path $typedHashManifest -Encoding UTF8

$typedHashOutput = & $ScoExe download $typedHashManifest --force
if ($LASTEXITCODE -ne 0) {
    throw "download with typed sha512 hash failed with exit code $LASTEXITCODE`: $typedHashOutput"
}
if (($typedHashOutput -join "`n") -notmatch "'download-sha512-filetool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download with typed sha512 hash did not include success line: $typedHashOutput"
}

$multiHashManifest = Join-Path (Split-Path -Parent $Root) 'download-multi-hash-filetool.json'
$multiHashSecondSource = Join-Path (Split-Path -Parent $Root) 'filetool-copy.exe'
Set-Content -Path $multiHashSecondSource -Value 'second filetool artifact' -Encoding Ascii
$multiHashSha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $multiHashSecondHashBytes = $multiHashSha256.ComputeHash([System.IO.File]::ReadAllBytes($multiHashSecondSource))
    $multiHashSecondHash = ([System.BitConverter]::ToString($multiHashSecondHashBytes)).Replace('-', '').ToLowerInvariant()
} finally {
    $multiHashSha256.Dispose()
}
$multiHashJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$multiHashJson.url = @($typedHashJson.url, $multiHashSecondSource)
$multiHashJson.hash = @(
    '0000000000000000000000000000000000000000000000000000000000000000',
    $multiHashSecondHash
)
$multiHashJson | ConvertTo-Json -Depth 5 | Set-Content -Path $multiHashManifest -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$multiHashOutput = & $ScoExe download $multiHashManifest --force 2>&1
$multiHashExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($multiHashExitCode -ne 0) {
    throw "download with one bad hash and one good URL returned $multiHashExitCode instead of Scoop's non-fatal 0: $multiHashOutput"
}
$multiHashJoined = $multiHashOutput -join "`n"
if ($multiHashJoined -notmatch 'ERROR Hash check failed!' -or
    $multiHashJoined -notmatch "'download-multi-hash-filetool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download did not continue to the second URL after a hash failure like Scoop: $multiHashJoined"
}
$multiHashCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-multi-hash-filetool#1.0.0#*.exe' -ErrorAction SilentlyContinue)
if ($multiHashCacheFiles.Count -ne 1 -or (Get-Content -LiteralPath $multiHashCacheFiles[0].FullName -Raw) -notmatch 'second filetool artifact') {
    throw "download after one hash failure should keep only the successful second URL cache entry: $($multiHashCacheFiles.Name -join ', ')"
}

$bucketDir = Join-Path $Root 'buckets\main\bucket'
$sourceForgeDir = Join-Path $Root 'sourceforge.net'
New-Item -ItemType Directory -Force -Path $bucketDir, $sourceForgeDir | Out-Null
$badHashArtifact = Join-Path $sourceForgeDir 'filetool.exe'
Copy-Item -LiteralPath ([System.IO.Path]::GetFullPath($typedHashJson.url)) -Destination $badHashArtifact -Force
$badHashManifest = [ordered]@{
    version = '1.0.0'
    url = $badHashArtifact
    hash = '0000000000000000000000000000000000000000000000000000000000000000'
    bin = 'filetool.exe'
}
$badHashManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'badhash-download-tool.json') -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$badHashOutput = & $ScoExe download badhash-download-tool 2>&1
$badHashExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badHashExitCode -ne 0) {
    throw "download with bad hash returned $badHashExitCode instead of Scoop's non-fatal 0: $badHashOutput"
}
$badHashJoined = $badHashOutput -join "`n"
if ($badHashJoined -notmatch 'ERROR Hash check failed!' -or
    $badHashJoined -notmatch 'App:\s+badhash-download-tool' -or
    $badHashJoined -notmatch 'First bytes:\s+66 69 6C 65 74 6F 6F 6C' -or
    $badHashJoined -notmatch 'Expected:\s+0000000000000000000000000000000000000000000000000000000000000000' -or
    $badHashJoined -notmatch 'Actual:\s+5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b' -or
    $badHashJoined -notmatch 'WARN  SourceForge\.net is known for causing hash validation fails\. Please try again before opening a ticket\.' -or
    $badHashJoined -notmatch 'github\.com/ScoopInstaller/Main/issues/new\?title=badhash-download-tool%401\.0\.0%3A\+hash\+check\+failed') {
    throw "download with bad hash did not report Scoop-style hash failure: $badHashJoined"
}
$badHashCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'badhash-download-tool#1.0.0#*.exe' -ErrorAction SilentlyContinue)
if ($badHashCacheFiles.Count -ne 0) {
    throw "download with bad hash left bad cache entries: $($badHashCacheFiles.Name -join ', ')"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$urlManifest = Join-Path (Split-Path -Parent $Root) 'download-url-filetool.json'
$manifestJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$artifactPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $manifestJson.url))
$manifestJson.url = $artifactPath
$manifestJson | ConvertTo-Json -Depth 5 | Set-Content -Path $urlManifest -Encoding UTF8

$listenerPrefix = 'http://127.0.0.1:18191/'
$job = Start-Job -ScriptBlock {
    param($Prefix, $File)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        $context = $listener.GetContext()
        $bytes = [System.IO.File]::ReadAllBytes($File)
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'application/json'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.OutputStream.Close()
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList $listenerPrefix, $urlManifest

Start-Sleep -Milliseconds 300
try {
    $urlOutput = & $ScoExe download ($listenerPrefix + 'filetool.json')
    if ($LASTEXITCODE -ne 0) {
        throw "download from manifest URL failed with exit code $LASTEXITCODE`: $urlOutput"
    }
} finally {
    Wait-Job $job -Timeout 5 | Out-Null
    Receive-Job $job | Out-Null
    Remove-Job $job -Force
}

$cacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'filetool#1.0.0#*.exe')
if ($cacheFiles.Count -ne 1) {
    throw "Expected one cached artifact after URL download, found $($cacheFiles.Count)"
}
if (Test-Path (Join-Path $Root 'apps\filetool')) {
    throw "download from manifest URL created an app install directory"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}
$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$cookieManifest = Join-Path (Split-Path -Parent $Root) 'download-cookie-filetool.json'
$cookieJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$cookieJson.url = 'http://127.0.0.1:18197/filetool.exe'
$cookieJson.hash = ''
$cookieJson | Add-Member -NotePropertyName cookie -NotePropertyValue ([pscustomobject][ordered]@{
    session = 'abc123'
    channel = 'stable'
})
$cookieJson | Add-Member -NotePropertyName architecture -NotePropertyValue ([pscustomobject][ordered]@{
    '64bit' = [pscustomobject][ordered]@{
        cookie = [pscustomobject][ordered]@{
            session = 'wrong-arch-cookie'
        }
    }
})
$cookieJson | ConvertTo-Json -Depth 5 | Set-Content -Path $cookieManifest -Encoding UTF8

$cookieJob = Start-Job -ScriptBlock {
    param($Prefix, $ExpectedCookie, $ExpectedReferer, $Body)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        for ($requestIndex = 0; $requestIndex -lt 2; $requestIndex += 1) {
            $context = $listener.GetContext()
            $cookie = $context.Request.Headers['Cookie']
            $userAgent = $context.Request.Headers['User-Agent']
            $referer = $context.Request.Headers['Referer']
            if ($cookie -ne $ExpectedCookie) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected cookie: $cookie")
                $context.Response.StatusCode = 403
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                return
            }
            if ($userAgent -ne 'sco') {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected user-agent: $userAgent")
                $context.Response.StatusCode = 403
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                return
            }
            if ($referer -ne $ExpectedReferer) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected referer: $referer")
                $context.Response.StatusCode = 403
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                return
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'application/octet-stream'
            $context.Response.ContentLength64 = $bytes.Length
            if ($context.Request.HttpMethod -ne 'HEAD') {
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            $context.Response.OutputStream.Close()
            if ($context.Request.HttpMethod -ne 'HEAD') {
                break
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList 'http://127.0.0.1:18197/', 'session=abc123;channel=stable', 'http://127.0.0.1:18197', 'cookie protected filetool'

Start-Sleep -Milliseconds 300
try {
    $cookieOutput = & $ScoExe download $cookieManifest --force
    if ($LASTEXITCODE -ne 0) {
        throw "download with manifest cookie failed with exit code $LASTEXITCODE`: $cookieOutput"
    }
    $cookieJoined = $cookieOutput -join "`n"
    if ($cookieJoined -notmatch "'download-cookie-filetool' \(1\.0\.0\) was downloaded successfully!") {
        throw "download with manifest cookie did not include success line: $cookieJoined"
    }
} finally {
    Wait-Job $cookieJob -Timeout 5 | Out-Null
    Receive-Job $cookieJob | Out-Null
    Remove-Job $cookieJob -Force
}

$cookieCache = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-cookie-filetool#1.0.0#*.exe')
if ($cookieCache.Count -ne 1) {
    throw "download with manifest cookie did not create one cache artifact: $($cookieCache.Name -join ', ')"
}
if ((Get-Content -LiteralPath $cookieCache[0].FullName -Raw) -notmatch 'cookie protected filetool') {
    throw 'download with manifest cookie cached unexpected content'
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}
$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$configDir = Join-Path $ConfigHome 'scoop'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
$privateHostsConfig = [ordered]@{
    private_hosts = @(
        [ordered]@{
            match = '127\.0\.0\.1:18208'
            headers = "Authorization=Bearer private-download`nX-Private-Host=download"
        }
    )
}
$privateHostsConfig | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $configDir 'config.json') -Encoding UTF8

$privateManifest = Join-Path (Split-Path -Parent $Root) 'download-private-host-filetool.json'
$privateJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$privateJson.url = 'http://127.0.0.1:18208/filetool.exe'
$privateJson.hash = ''
$privateJson | ConvertTo-Json -Depth 5 | Set-Content -Path $privateManifest -Encoding UTF8

$privateJob = Start-Job -ScriptBlock {
    param($Prefix, $Body)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        for ($requestIndex = 0; $requestIndex -lt 2; $requestIndex += 1) {
            $context = $listener.GetContext()
            $authorization = $context.Request.Headers['Authorization']
            $privateHost = $context.Request.Headers['X-Private-Host']
            if ($authorization -ne 'Bearer private-download' -or $privateHost -ne 'download') {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected private headers: $authorization / $privateHost")
                $context.Response.StatusCode = 403
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                return
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'application/octet-stream'
            $context.Response.ContentLength64 = $bytes.Length
            if ($context.Request.HttpMethod -ne 'HEAD') {
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            $context.Response.OutputStream.Close()
            if ($context.Request.HttpMethod -ne 'HEAD') {
                break
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList 'http://127.0.0.1:18208/', 'private host filetool'

Start-Sleep -Milliseconds 300
try {
    $privateOutput = & $ScoExe download $privateManifest --force
    if ($LASTEXITCODE -ne 0) {
        throw "download with PRIVATE_HOSTS headers failed with exit code $LASTEXITCODE`: $privateOutput"
    }
    if (($privateOutput -join "`n") -notmatch "'download-private-host-filetool' \(1\.0\.0\) was downloaded successfully!") {
        throw "download with PRIVATE_HOSTS headers did not include success line: $privateOutput"
    }
} finally {
    Wait-Job $privateJob -Timeout 5 | Out-Null
    Receive-Job $privateJob | Out-Null
    Remove-Job $privateJob -Force
}

$privateCache = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-private-host-filetool#1.0.0#*.exe')
if ($privateCache.Count -ne 1) {
    throw "download with PRIVATE_HOSTS headers did not create one cache artifact: $($privateCache.Name -join ', ')"
}
if ((Get-Content -LiteralPath $privateCache[0].FullName -Raw) -notmatch 'private host filetool') {
    throw 'download with PRIVATE_HOSTS headers cached unexpected content'
}

$upperSchemeManifest = Join-Path (Split-Path -Parent $Root) 'download-upper-scheme-filetool.json'
$upperSchemeJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$upperSchemeJson.url = 'HTTP://127.0.0.1:18216/filetool.exe'
$upperSchemeJson.hash = ''
$upperSchemeJson | ConvertTo-Json -Depth 5 | Set-Content -Path $upperSchemeManifest -Encoding UTF8

$upperSchemeJob = Start-Job -ScriptBlock {
    param($Prefix, $Body)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        for ($requestIndex = 0; $requestIndex -lt 2; $requestIndex += 1) {
            $context = $listener.GetContext()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'application/octet-stream'
            $context.Response.ContentLength64 = $bytes.Length
            if ($context.Request.HttpMethod -ne 'HEAD') {
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            $context.Response.OutputStream.Close()
            if ($context.Request.HttpMethod -ne 'HEAD') {
                break
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList 'http://127.0.0.1:18216/', 'upper scheme filetool'

Start-Sleep -Milliseconds 300
try {
    $upperSchemeOutput = & $ScoExe download $upperSchemeManifest --force
    if ($LASTEXITCODE -ne 0) {
        throw "download with uppercase URL scheme failed with exit code $LASTEXITCODE`: $upperSchemeOutput"
    }
    if (($upperSchemeOutput -join "`n") -notmatch "'download-upper-scheme-filetool' \(1\.0\.0\) was downloaded successfully!") {
        throw "download with uppercase URL scheme did not include success line: $upperSchemeOutput"
    }
} finally {
    Wait-Job $upperSchemeJob -Timeout 5 | Out-Null
    Receive-Job $upperSchemeJob | Out-Null
    Remove-Job $upperSchemeJob -Force
}

$upperSchemeCache = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-upper-scheme-filetool#1.0.0#*.exe')
if ($upperSchemeCache.Count -ne 1) {
    throw "download with uppercase URL scheme did not create one cache artifact: $($upperSchemeCache.Name -join ', ')"
}
if ((Get-Content -LiteralPath $upperSchemeCache[0].FullName -Raw) -notmatch 'upper scheme filetool') {
    throw 'download with uppercase URL scheme cached unexpected content'
}

$noRefererManifest = Join-Path (Split-Path -Parent $Root) 'download-sourceforge-referer-filetool.json'
$noRefererJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$noRefererJson.url = 'http://127.0.0.1:18209/sourceforge.net/filetool.exe'
$noRefererJson.hash = ''
$noRefererJson | ConvertTo-Json -Depth 5 | Set-Content -Path $noRefererManifest -Encoding UTF8

$noRefererJob = Start-Job -ScriptBlock {
    param($Prefix, $Body)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        for ($requestIndex = 0; $requestIndex -lt 2; $requestIndex += 1) {
            $context = $listener.GetContext()
            $referer = $context.Request.Headers['Referer']
            if (![string]::IsNullOrEmpty($referer)) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected referer: $referer")
                $context.Response.StatusCode = 403
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                return
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'application/octet-stream'
            $context.Response.ContentLength64 = $bytes.Length
            if ($context.Request.HttpMethod -ne 'HEAD') {
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            $context.Response.OutputStream.Close()
            if ($context.Request.HttpMethod -ne 'HEAD') {
                break
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList 'http://127.0.0.1:18209/', 'sourceforge no referer filetool'

Start-Sleep -Milliseconds 300
try {
    $noRefererOutput = & $ScoExe download $noRefererManifest --force
    if ($LASTEXITCODE -ne 0) {
        throw "download with SourceForge-style no-referer URL failed with exit code $LASTEXITCODE`: $noRefererOutput"
    }
    if (($noRefererOutput -join "`n") -notmatch "'download-sourceforge-referer-filetool' \(1\.0\.0\) was downloaded successfully!") {
        throw "download with SourceForge-style no-referer URL did not include success line: $noRefererOutput"
    }
} finally {
    Wait-Job $noRefererJob -Timeout 5 | Out-Null
    Receive-Job $noRefererJob | Out-Null
    Remove-Job $noRefererJob -Force
}

$noRefererCache = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-sourceforge-referer-filetool#1.0.0#*.exe')
if ($noRefererCache.Count -ne 1) {
    throw "download with SourceForge-style no-referer URL did not create one cache artifact: $($noRefererCache.Name -join ', ')"
}
if ((Get-Content -LiteralPath $noRefererCache[0].FullName -Raw) -notmatch 'sourceforge no referer filetool') {
    throw 'download with SourceForge-style no-referer URL cached unexpected content'
}
