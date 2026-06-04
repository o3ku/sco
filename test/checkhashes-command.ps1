param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
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

$bucketDir = Join-Path $Root 'buckets\main\bucket'
$sourceDir = Join-Path $Root 'sources'
$cacheDir = Join-Path $Root 'cache'
New-Item -ItemType Directory -Force -Path $bucketDir, $sourceDir, $cacheDir | Out-Null

function Get-Sha256($Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

$goodArtifact = Join-Path $sourceDir 'good.exe'
$badArtifact = Join-Path $sourceDir 'bad.exe'
$arch64Artifact = Join-Path $sourceDir 'arch64.exe'
$arch32Artifact = Join-Path $sourceDir 'arch32.exe'
$cookieArtifact = Join-Path $sourceDir 'cookie-body.exe'
Copy-Item -LiteralPath $Artifact -Destination $goodArtifact -Force
Set-Content -Path $badArtifact -Value 'bad artifact bytes' -Encoding ASCII
Set-Content -Path $arch64Artifact -Value 'arch64 bytes' -Encoding ASCII
Set-Content -Path $arch32Artifact -Value 'arch32 bytes' -Encoding ASCII
$cookieBody = 'cookie-free ok'
[System.IO.File]::WriteAllBytes($cookieArtifact, [System.Text.Encoding]::ASCII.GetBytes($cookieBody))

$goodHash = Get-Sha256 $goodArtifact
$badActual = Get-Sha256 $badArtifact
$arch64Hash = Get-Sha256 $arch64Artifact
$arch32Hash = Get-Sha256 $arch32Artifact
$cookieHash = Get-Sha256 $cookieArtifact

$goodManifest = [ordered]@{
    Version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($goodArtifact))
    hash = $goodHash
}
$goodManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'goodtool.json') -Encoding UTF8

$badManifest = [ordered]@{
    version = '1.0.0'
    URL = ([System.IO.Path]::GetFullPath($badArtifact))
    Hash = ('0' * 64)
}
$badManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'badtool.json') -Encoding UTF8

$cookieManifest = [ordered]@{
    version = '1.0.0'
    url = 'http://127.0.0.1:18210/files/cookie.exe'
    hash = $cookieHash
    cookie = [ordered]@{
        session = 'should-not-be-sent'
    }
}
$cookieManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bucketDir 'cookietool.json') -Encoding UTF8

$mismatchManifest = [ordered]@{
    version = '1.0.0'
    url = @(
        ([System.IO.Path]::GetFullPath($goodArtifact)),
        (Join-Path $sourceDir 'missing-mismatch.exe')
    )
    hash = $goodHash
}
$mismatchManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'mismatchtool.json') -Encoding UTF8

$archManifest = [ordered]@{
    version = '1.0.0'
    Architecture = [ordered]@{
        '64BIT' = [ordered]@{
            URL = ([System.IO.Path]::GetFullPath($arch64Artifact))
            Hash = ('1' * 64)
        }
        '32BIT' = [ordered]@{
            URL = ([System.IO.Path]::GetFullPath($arch32Artifact))
            Hash = $arch32Hash
        }
    }
}
$archManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bucketDir 'archtool.json') -Encoding UTF8

$emptyHashManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($goodArtifact))
    hash = ''
}
$emptyHashManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'emptyhashtool.json') -Encoding UTF8

$falsyTopUrlManifest = [ordered]@{
    version = '1.0.0'
    url = ''
    hash = ''
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            url = ([System.IO.Path]::GetFullPath($arch32Artifact))
            hash = $arch32Hash
        }
    }
}
$falsyTopUrlManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bucketDir 'falsytopurltool.json') -Encoding UTF8

$nightlyManifest = [ordered]@{
    Version = 'nightly'
    url = ([System.IO.Path]::GetFullPath($badArtifact))
    hash = ('2' * 64)
}
$nightlyManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'nightlytool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingDirOutput = & $ScoExe checkhashes goodtool 2>&1
$missingDirExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingDirExitCode -eq 0 -or ($missingDirOutput -join "`n") -notmatch 'missing mandatory parameters: Dir') {
    throw "checkhashes without -Dir did not match PowerShell mandatory parameter behavior: $missingDirOutput"
}

$staleHashCheckCache = Join-Path $cacheDir 'oldtool#HASH_CHECK#stale.exe'
Set-Content -Path $staleHashCheckCache -Value 'stale hash check cache' -Encoding ASCII

$serverJob = Start-Job -ScriptBlock {
    param($Prefix, $Body)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        for ($i = 0; $i -lt 2; $i++) {
            $context = $listener.GetContext()
            $cookie = $context.Request.Headers['Cookie']
            if ($cookie) {
                $bytes = [System.Text.Encoding]::ASCII.GetBytes("unexpected cookie: $cookie")
                $context.Response.StatusCode = 403
                if ($context.Request.HttpMethod -ne 'HEAD') {
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                $context.Response.OutputStream.Close()
                return
            }

            $bytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'application/octet-stream'
            if ($context.Request.HttpMethod -ne 'HEAD') {
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                return
            }
            $context.Response.OutputStream.Close()
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList 'http://127.0.0.1:18210/', $cookieBody

Start-Sleep -Milliseconds 300
try {
    $output = & $ScoExe checkhashes -Dir $bucketDir
    if ($LASTEXITCODE -ne 0) {
        throw "checkhashes failed with exit code $LASTEXITCODE`: $output"
    }
} finally {
    Wait-Job $serverJob -Timeout 5 | Out-Null
    Receive-Job $serverJob | Out-Null
    Remove-Job $serverJob -Force
}
$joined = $output -join "`n"
if ($joined -notmatch 'goodtool: OK') {
    throw "checkhashes did not report correct manifest: $joined"
}
if ($joined -notmatch 'cookietool: OK') {
    throw "checkhashes should not send manifest cookies: $joined"
}
if ($joined -notmatch 'badtool: Mismatch found' -or $joined -notmatch "Actual:\s+$badActual") {
    throw "checkhashes did not report bad manifest mismatch: $joined"
}
if ($joined -notmatch 'mismatchtool: URLS and hashes count mismatch\.' -or $joined -match 'missing-mismatch\.exe') {
    throw "checkhashes did not reject URL/hash count mismatch before downloading: $joined"
}
if ($joined -notmatch 'archtool: Mismatch found' -or $joined -notmatch "Actual:\s+$arch64Hash") {
    throw "checkhashes did not report architecture mismatch: $joined"
}
if ($joined -notmatch 'emptyhashtool: Mismatch found' -or $joined -notmatch "Actual:\s+$goodHash" -or $joined -match 'emptyhashtool: URLS and hashes count mismatch\.') {
    throw "checkhashes should keep an empty hash value as a hash entry like Scoop: $joined"
}
if ($joined -notmatch 'falsytopurltool: OK') {
    throw "checkhashes should fall back to architecture URLs when top-level url is falsy: $joined"
}
if ($joined -match 'nightlytool') {
    throw "checkhashes should skip nightly manifests: $joined"
}
if (Test-Path $staleHashCheckCache) {
    throw 'checkhashes did not clear stale HASH_CHECK cache entries before running'
}

Remove-Item -LiteralPath (Join-Path $bucketDir 'cookietool.json') -Force

$skipOutput = & $ScoExe checkhashes -Dir $bucketDir -SkipCorrect
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes -SkipCorrect failed with exit code $LASTEXITCODE`: $skipOutput"
}
$skipJoined = $skipOutput -join "`n"
if ($skipJoined -match 'goodtool: OK' -or $skipJoined -notmatch 'badtool: Mismatch found') {
    throw "checkhashes -SkipCorrect did not filter correct manifests: $skipJoined"
}

$switchFalseOutput = & $ScoExe checkhashes goodtool -Dir $bucketDir '-SkipCorrect:$false'
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes -SkipCorrect:`$false failed with exit code $LASTEXITCODE`: $switchFalseOutput"
}
if (($switchFalseOutput -join "`n") -notmatch 'goodtool: OK') {
    throw "checkhashes -SkipCorrect:`$false should keep correct manifests visible: $switchFalseOutput"
}

$updateCorrectOutput = & $ScoExe checkhashes goodtool -Dir $bucketDir -Update
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes -Update on correct manifest failed with exit code $LASTEXITCODE`: $updateCorrectOutput"
}
if (($updateCorrectOutput -join "`n") -notmatch 'goodtool: OK' -or ($updateCorrectOutput -join "`n") -notmatch 'Writing updated goodtool manifest') {
    throw "checkhashes -Update should rewrite correct manifests like Scoop: $updateCorrectOutput"
}

$patternOutput = & $ScoExe checkhashes good* -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes app pattern failed with exit code $LASTEXITCODE`: $patternOutput"
}
$patternJoined = $patternOutput -join "`n"
if ($patternJoined -notmatch 'goodtool: OK' -or $patternJoined -match 'badtool|archtool') {
    throw "checkhashes app pattern did not filter expected manifests: $patternJoined"
}

$positionalDirOutput = & $ScoExe checkhashes good* $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes positional App Dir failed with exit code $LASTEXITCODE`: $positionalDirOutput"
}
$positionalDirJoined = $positionalDirOutput -join "`n"
if ($positionalDirJoined -notmatch 'goodtool: OK' -or $positionalDirJoined -match 'badtool|archtool') {
    throw "checkhashes positional App Dir did not match PowerShell parameter binding: $positionalDirJoined"
}

$namedAppOutput = & $ScoExe checkhashes -App good* -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes -App failed with exit code $LASTEXITCODE`: $namedAppOutput"
}
if (($namedAppOutput -join "`n") -notmatch 'goodtool: OK') {
    throw "checkhashes -App did not select the requested manifest: $namedAppOutput"
}

$updateFalseOutput = & $ScoExe checkhashes badtool -Dir $bucketDir '-Update:$false'
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes -Update:`$false failed with exit code $LASTEXITCODE`: $updateFalseOutput"
}
$notUpdatedBad = Get-Content -LiteralPath (Join-Path $bucketDir 'badtool.json') -Raw | ConvertFrom-Json
if ($notUpdatedBad.hash -ne ('0' * 64)) {
    throw "checkhashes -Update:`$false unexpectedly updated manifest: $($notUpdatedBad | ConvertTo-Json -Depth 5 -Compress)"
}

$preservedHashCheckCache = Join-Path $cacheDir 'preserved#HASH_CHECK#stale.exe'
Set-Content -Path $preservedHashCheckCache -Value 'preserved stale hash check cache' -Encoding ASCII
$shortUseCacheOutput = & $ScoExe checkhashes goodtool -Dir $bucketDir -k
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes -k failed with exit code $LASTEXITCODE`: $shortUseCacheOutput"
}
if (($shortUseCacheOutput -join "`n") -notmatch 'goodtool: OK') {
    throw "checkhashes -k did not check the requested manifest: $shortUseCacheOutput"
}
if (!(Test-Path $preservedHashCheckCache)) {
    throw 'checkhashes -k should not clear existing HASH_CHECK cache entries like Scoop UseCache'
}
$versionCacheFiles = @(Get-ChildItem -LiteralPath $cacheDir -Filter 'goodtool#1.0.0#*' -ErrorAction SilentlyContinue)
if ($versionCacheFiles.Count -eq 0) {
    throw 'checkhashes -k did not keep versioned cache entries like Scoop UseCache'
}

$updateOutput = & $ScoExe checkhashes badtool -Dir $bucketDir -Update
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes -Update failed with exit code $LASTEXITCODE`: $updateOutput"
}
$updatedBad = Get-Content -LiteralPath (Join-Path $bucketDir 'badtool.json') -Raw | ConvertFrom-Json
if ($updatedBad.hash -ne $badActual) {
    throw "checkhashes -Update did not update top-level hash: $($updatedBad | ConvertTo-Json -Depth 5 -Compress)"
}

$archUpdateOutput = & $ScoExe checkhashes archtool -Dir $bucketDir -Update
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes architecture -Update failed with exit code $LASTEXITCODE`: $archUpdateOutput"
}
$updatedArch = Get-Content -LiteralPath (Join-Path $bucketDir 'archtool.json') -Raw | ConvertFrom-Json
if ($updatedArch.architecture.'64bit'.hash -ne $arch64Hash -or $updatedArch.architecture.'32bit'.hash -ne $arch32Hash) {
    throw "checkhashes -Update did not update architecture hashes: $($updatedArch | ConvertTo-Json -Depth 6 -Compress)"
}

$forceOutput = & $ScoExe checkhashes goodtool -Dir $bucketDir -ForceUpdate
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes -ForceUpdate failed with exit code $LASTEXITCODE`: $forceOutput"
}
if (($forceOutput -join "`n") -notmatch 'goodtool: OK' -or ($forceOutput -join "`n") -notmatch 'Writing updated goodtool manifest') {
    throw "checkhashes -ForceUpdate did not rewrite correct manifest: $forceOutput"
}

$forceFalseOutput = & $ScoExe checkhashes goodtool -Dir $bucketDir '-ForceUpdate:$false'
if ($LASTEXITCODE -ne 0) {
    throw "checkhashes -ForceUpdate:`$false failed with exit code $LASTEXITCODE`: $forceFalseOutput"
}
if (($forceFalseOutput -join "`n") -match 'Writing updated goodtool manifest') {
    throw "checkhashes -ForceUpdate:`$false unexpectedly rewrote manifest: $forceFalseOutput"
}

$fileOutput = & $ScoExe checkhashes (Join-Path $bucketDir 'goodtool.json') -Dir $bucketDir
if ($LASTEXITCODE -ne 0 -or ($fileOutput -join "`n") -notmatch 'goodtool: OK') {
    throw "checkhashes manifest filepath failed: $fileOutput"
}

$helpOutput = & $ScoExe checkhashes --help
if ($LASTEXITCODE -ne 0 -or ($helpOutput -join "`n") -notmatch 'Usage: sco checkhashes') {
    throw "checkhashes --help failed: $helpOutput"
}

$helpCommandOutput = & $ScoExe help checkhashes
if ($LASTEXITCODE -ne 0 -or ($helpCommandOutput -join "`n") -notmatch 'Usage: sco checkhashes') {
    throw "help checkhashes failed: $helpCommandOutput"
}

$ErrorActionPreference = 'Continue'
$badSwitchOutput = & $ScoExe checkhashes -Dir $bucketDir -SkipCorrect:nope 2>&1
$badSwitchExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badSwitchExitCode -eq 0 -or ($badSwitchOutput -join "`n") -notmatch 'must be a boolean value') {
    throw "checkhashes invalid switch value was not rejected: $badSwitchOutput"
}
