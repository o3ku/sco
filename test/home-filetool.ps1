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
    description = 'Homepage command test tool'
    homepage = 'https://example.test/hometool'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'hometool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome

function Install-GlobalStandaloneHomeFixture($ManifestPath) {
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
$missingAppOutput = & $ScoExe home 2>&1
$missingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppExitCode -ne 1) {
    throw "home without an app returned $missingAppExitCode instead of 1: $missingAppOutput"
}
$missingAppJoined = $missingAppOutput -join "`n"
if ($missingAppJoined -notmatch 'Usage: sco home <app>' -or $missingAppJoined -match 'Usage: sco home <app> \[options\]' -or $missingAppJoined -match '<app> missing') {
    throw "home without an app did not match Scoop usage-only output: $missingAppJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingOutput = & $ScoExe home missinghometool --show 2>&1
$missingExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingExitCode -ne 1) {
    throw "home missing manifest returned $missingExitCode instead of 1: $missingOutput"
}
if (($missingOutput -join "`n") -notmatch "Could not find manifest for 'missinghometool'\.") {
    throw "home missing manifest did not match Scoop error: $missingOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$showAsAppOutput = & $ScoExe home --show 2>&1
$showAsAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($showAsAppExitCode -ne 1) {
    throw "home --show returned $showAsAppExitCode instead of 1: $showAsAppOutput"
}
if (($showAsAppOutput -join "`n") -notmatch "Could not find manifest for '--show'\." -or ($showAsAppOutput -join "`n") -match 'Usage: sco home <app>') {
    throw "home --show did not treat --show as the app name like Scoop: $showAsAppOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$dashAppOutput = & $ScoExe home -z 2>&1
$dashAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($dashAppExitCode -ne 1) {
    throw "home -z returned $dashAppExitCode instead of 1: $dashAppOutput"
}
if (($dashAppOutput -join "`n") -notmatch "Could not find manifest for '-z'\." -or ($dashAppOutput -join "`n") -match 'unknown option') {
    throw "home -z did not treat -z as the app name like Scoop: $dashAppOutput"
}

$output = (& $ScoExe home hometool --show).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "home --show failed with exit code $LASTEXITCODE`: $output"
}
if ($output -ne 'https://example.test/hometool') {
    throw "Unexpected homepage output: $output"
}

$extraArgOutput = (& $ScoExe home hometool ignored-extra --show).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "home with an extra positional argument failed with exit code $LASTEXITCODE`: $extraArgOutput"
}
if ($extraArgOutput -ne 'https://example.test/hometool') {
    throw "home did not ignore extra positional arguments like Scoop: $extraArgOutput"
}

$standaloneManifest = Join-Path (Split-Path -Parent $Root) 'standalone-home.json'
$manifest.homepage = 'https://example.test/standalone-home'
$manifest | ConvertTo-Json | Set-Content -Path $standaloneManifest -Encoding UTF8

$pathOutput = (& $ScoExe home $standaloneManifest --show).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "home local manifest failed with exit code $LASTEXITCODE`: $pathOutput"
}
if ($pathOutput -ne 'https://example.test/standalone-home') {
    throw "Unexpected homepage output for local manifest: $pathOutput"
}

$localScopeDir = Join-Path (Split-Path -Parent $Root) 'home-local-source'
$globalScopeDir = Join-Path (Split-Path -Parent $Root) 'home-global-source'
New-Item -ItemType Directory -Force -Path $localScopeDir, $globalScopeDir | Out-Null
$localScopeManifest = Join-Path $localScopeDir 'homebothscope.json'
$globalScopeManifest = Join-Path $globalScopeDir 'homebothscope.json'
$scopeManifest = [ordered]@{
    version = '1.0.0'
    homepage = 'https://example.test/home-local-scope'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$scopeManifest | ConvertTo-Json | Set-Content -Path $localScopeManifest -Encoding UTF8
& $ScoExe install $localScopeManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "local home both-scope fixture install failed with exit code $LASTEXITCODE"
}
$scopeManifest.homepage = 'https://example.test/home-global-scope'
$scopeManifest | ConvertTo-Json | Set-Content -Path $globalScopeManifest -Encoding UTF8
Install-GlobalStandaloneHomeFixture $globalScopeManifest
if ($LASTEXITCODE -ne 0) {
    throw "global home both-scope fixture install failed with exit code $LASTEXITCODE"
}
$bothScopeHome = (& $ScoExe home homebothscope --show).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "home both-scope installed app failed with exit code $LASTEXITCODE`: $bothScopeHome"
}
if ($bothScopeHome -ne 'https://example.test/home-global-scope') {
    throw "home should prefer global installed manifest when both scopes exist like Scoop: $bothScopeHome"
}

$missingHomepageManifest = Join-Path (Split-Path -Parent $Root) 'missing-homepage-alias.json'
$manifest.Remove('homepage')
$manifest | ConvertTo-Json | Set-Content -Path $missingHomepageManifest -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingHomepageOutput = & $ScoExe home $missingHomepageManifest --show 2>&1
$missingHomepageExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingHomepageExitCode -ne 1) {
    throw "home missing homepage returned $missingHomepageExitCode instead of 1: $missingHomepageOutput"
}
if (($missingHomepageOutput -join "`n") -notmatch "Could not find homepage in manifest for '$([regex]::Escape($missingHomepageManifest))'\.") {
    throw "home missing homepage did not use original argument like Scoop: $missingHomepageOutput"
}

$remoteManifest = Join-Path (Split-Path -Parent $Root) 'remote-home.json'
$manifest['homepage'] = 'https://example.test/remote-home'
$manifest | ConvertTo-Json | Set-Content -Path $remoteManifest -Encoding UTF8

$listenerPrefix = 'http://127.0.0.1:18193/'
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
} -ArgumentList $listenerPrefix, $remoteManifest

Start-Sleep -Milliseconds 300
try {
    $urlOutput = (& $ScoExe home ($listenerPrefix + 'remotehome.json') --show).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "home manifest URL failed with exit code $LASTEXITCODE`: $urlOutput"
    }
    if ($urlOutput -ne 'https://example.test/remote-home') {
        throw "Unexpected homepage output for manifest URL: $urlOutput"
    }
} finally {
    Wait-Job $job -Timeout 5 | Out-Null
    Receive-Job $job | Out-Null
    Remove-Job $job -Force
}
