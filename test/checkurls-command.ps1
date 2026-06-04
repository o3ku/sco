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
$configDir = Join-Path $ConfigHome 'scoop'
New-Item -ItemType Directory -Force -Path $bucketDir, $sourceDir, $configDir | Out-Null

$localArtifact = Join-Path $sourceDir 'localtool.exe'
Copy-Item -LiteralPath $Artifact -Destination $localArtifact -Force

$privateHostsConfig = [ordered]@{
    private_hosts = @(
        [ordered]@{
            Match = '127\.0\.0\.1:18209'
            Headers = 'X-Private-Host=checkurls'
        }
    )
}
$privateHostsConfig | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $configDir 'config.json') -Encoding UTF8

$validManifest = [ordered]@{
    version = '1.0.0'
    URL = @(
        'http://127.0.0.1:18209/files/protected.exe',
        ([System.IO.Path]::GetFullPath($localArtifact))
    )
    Hash = @('', '')
    Cookie = [ordered]@{
        session = 'checkurls'
    }
    bin = 'protected.exe'
}
$validManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bucketDir 'validurltool.json') -Encoding UTF8

$badManifest = [ordered]@{
    version = '1.0.0'
    url = 'http://127.0.0.1:18209/files/missing.exe'
    hash = ''
    bin = 'missing.exe'
}
$badManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bucketDir 'badurltool.json') -Encoding UTF8

$topLevelArchManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($localArtifact))
    hash = ''
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            url = (Join-Path $sourceDir 'missing-arch.exe')
            hash = ''
        }
    }
    bin = 'localtool.exe'
}
$topLevelArchManifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $bucketDir 'toplevelarchtool.json') -Encoding UTF8

$upperExtensionManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($localArtifact))
    hash = ''
    bin = 'localtool.exe'
}
$upperExtensionManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bucketDir 'upperurltool.JSON') -Encoding UTF8

$falsyCookieManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($localArtifact))
    hash = ''
    cookie = ''
    bin = 'localtool.exe'
}
$falsyCookieManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bucketDir 'falsycookietool.json') -Encoding UTF8

$falsyTopUrlManifest = [ordered]@{
    version = '1.0.0'
    url = ''
    hash = ''
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            url = ([System.IO.Path]::GetFullPath($localArtifact))
            hash = ''
        }
    }
    bin = 'localtool.exe'
}
$falsyTopUrlManifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $bucketDir 'falsytopurltool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingDirOutput = & $ScoExe checkurls validurltool 2>&1
$missingDirExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingDirExitCode -eq 0 -or ($missingDirOutput -join "`n") -notmatch 'missing mandatory parameters: Dir') {
    throw "checkurls without -Dir did not match PowerShell mandatory parameter behavior: $missingDirOutput"
}

$serverJob = Start-Job -ScriptBlock {
    param($Prefix)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        for ($i = 0; $i -lt 2; $i++) {
            $context = $listener.GetContext()
            $path = $context.Request.Url.AbsolutePath
            if ($path -eq '/files/protected.exe') {
                $privateHost = $context.Request.Headers['X-Private-Host']
                $cookie = $context.Request.Headers['Cookie']
                if ($privateHost -ne 'checkurls' -or $cookie -ne 'session=checkurls') {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected headers: $privateHost / $cookie")
                    $context.Response.StatusCode = 403
                    $context.Response.ContentLength64 = $bytes.Length
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $context.Response.OutputStream.Close()
                    continue
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('ok')
                $context.Response.StatusCode = 200
                $context.Response.ContentType = 'application/octet-stream'
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                continue
            }

            $bytes = [System.Text.Encoding]::UTF8.GetBytes('missing')
            $context.Response.StatusCode = 404
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList 'http://127.0.0.1:18209/'

Start-Sleep -Milliseconds 300
try {
    $output = & $ScoExe checkurls -Dir $bucketDir
    if ($LASTEXITCODE -ne 0) {
        throw "checkurls failed with exit code $LASTEXITCODE`: $output"
    }
} finally {
    Wait-Job $serverJob -Timeout 5 | Out-Null
    Receive-Job $serverJob | Out-Null
    Remove-Job $serverJob -Force
}

$joined = $output -join "`n"
if ($joined -notmatch '\[2\]\[2\]\[0\] validurltool') {
    throw "checkurls did not report all valid URLs for validurltool: $joined"
}
if ($joined -notmatch '\[1\]\[1\]\[0\] toplevelarchtool' -or $joined -match 'missing-arch\.exe') {
    throw "checkurls did not prefer top-level URLs over architecture URLs: $joined"
}
if ($joined -notmatch '\[1\]\[1\]\[0\] upperurltool') {
    throw "checkurls did not include manifest with uppercase .JSON extension: $joined"
}
if ($joined -notmatch '\[1\]\[1\]\[0\] falsycookietool') {
    throw "checkurls should ignore falsy cookie values without skipping the manifest: $joined"
}
if ($joined -notmatch '\[1\]\[1\]\[0\] falsytopurltool') {
    throw "checkurls should fall back to architecture URLs when top-level url is falsy: $joined"
}
if ($joined -notmatch '\[1\]\[0\]\[1\] badurltool') {
    throw "checkurls did not report failed URL for badurltool: $joined"
}
if ($joined -notmatch 'HTTP 404 \(http://127\.0\.0\.1:18209/files/missing\.exe\)') {
    throw "checkurls did not include failed URL detail: $joined"
}

$skipOutput = & $ScoExe checkurls badurltool -Dir $bucketDir -SkipValid
if ($LASTEXITCODE -ne 0) {
    throw "checkurls badurltool -SkipValid failed with exit code $LASTEXITCODE`: $skipOutput"
}
$skipJoined = $skipOutput -join "`n"
if ($skipJoined -match 'validurltool' -or $skipJoined -notmatch 'badurltool') {
    throw "checkurls -SkipValid did not filter valid manifests: $skipJoined"
}

$namedAppOutput = & $ScoExe checkurls -App badurltool $bucketDir -SkipValid
if ($LASTEXITCODE -ne 0) {
    throw "checkurls -App with positional Dir failed with exit code $LASTEXITCODE`: $namedAppOutput"
}
$namedAppJoined = $namedAppOutput -join "`n"
if ($namedAppJoined -match 'validurltool' -or $namedAppJoined -notmatch 'badurltool') {
    throw "checkurls -App with positional Dir did not match PowerShell parameter binding: $namedAppJoined"
}

$inlineDirOutput = & $ScoExe checkurls badurltool "-Dir:$bucketDir" -SkipValid
if ($LASTEXITCODE -ne 0) {
    throw "checkurls -Dir:<dir> failed with exit code $LASTEXITCODE`: $inlineDirOutput"
}
$inlineDirJoined = $inlineDirOutput -join "`n"
if ($inlineDirJoined -match 'validurltool' -or $inlineDirJoined -notmatch 'badurltool') {
    throw "checkurls -Dir:<dir> did not bind inline value: $inlineDirJoined"
}

$switchFalseOutput = & $ScoExe checkurls toplevelarchtool "--dir=$bucketDir" '-SkipValid:$false'
if ($LASTEXITCODE -ne 0) {
    throw "checkurls -SkipValid:`$false failed with exit code $LASTEXITCODE`: $switchFalseOutput"
}
if (($switchFalseOutput -join "`n") -notmatch 'toplevelarchtool') {
    throw "checkurls -SkipValid:`$false should keep valid manifests visible: $switchFalseOutput"
}

$helpOutput = & $ScoExe checkurls --help
if ($LASTEXITCODE -ne 0 -or ($helpOutput -join "`n") -notmatch 'Usage: sco checkurls' -or ($helpOutput -join "`n") -notmatch '-Timeout') {
    throw "checkurls --help failed: $helpOutput"
}

$timeoutOutput = & $ScoExe checkurls absenttool "--dir=$bucketDir" -Timeout:1 -SkipValid
if ($LASTEXITCODE -ne 0) {
    throw "checkurls --dir=<dir> -Timeout:<seconds> failed with exit code $LASTEXITCODE`: $timeoutOutput"
}
if (($timeoutOutput -join "`n") -match 'validurltool|badurltool') {
    throw "checkurls --dir=<dir> -Timeout:<seconds> did not run with SkipValid filtering: $timeoutOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$badTimeoutOutput = & $ScoExe checkurls -Dir $bucketDir -Timeout nope 2>&1
$badTimeoutExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badTimeoutExitCode -eq 0 -or ($badTimeoutOutput -join "`n") -notmatch 'must be a non-negative integer') {
    throw "checkurls -Timeout rejected value incorrectly: $badTimeoutOutput"
}

$ErrorActionPreference = 'Continue'
$badSwitchOutput = & $ScoExe checkurls -Dir $bucketDir -SkipValid:nope 2>&1
$badSwitchExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badSwitchExitCode -eq 0 -or ($badSwitchOutput -join "`n") -notmatch 'must be a boolean value') {
    throw "checkurls invalid switch value was not rejected: $badSwitchOutput"
}
