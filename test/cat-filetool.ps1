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

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome

function Install-GlobalStandaloneCatFixture($ManifestPath) {
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
$missingAppOutput = & $ScoExe cat 2>&1
$missingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppExitCode -ne 1) {
    throw "cat without an app returned $missingAppExitCode instead of 1: $missingAppOutput"
}
if (($missingAppOutput -join "`n") -notmatch 'ERROR <app> missing' -or ($missingAppOutput -join "`n") -notmatch 'Usage: sco cat <app>') {
    throw "cat without an app did not match Scoop usage: $missingAppOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingManifestOutput = & $ScoExe cat missingcattool 2>&1
$missingManifestExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingManifestExitCode -ne 1) {
    throw "cat missing manifest returned $missingManifestExitCode instead of 1: $missingManifestOutput"
}
if (($missingManifestOutput -join "`n") -notmatch "Couldn't find manifest for 'missingcattool'\.") {
    throw "cat missing manifest did not match Scoop error: $missingManifestOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingBucketManifestOutput = & $ScoExe cat extras/missingcattool 2>&1
$missingBucketManifestExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingBucketManifestExitCode -ne 1) {
    throw "cat missing bucket manifest returned $missingBucketManifestExitCode instead of 1: $missingBucketManifestOutput"
}
if (($missingBucketManifestOutput -join "`n") -notmatch "Couldn't find manifest for 'missingcattool' from 'extras' bucket\.") {
    throw "cat missing bucket manifest did not match Scoop error: $missingBucketManifestOutput"
}

$manifestPath = Join-Path (Split-Path -Parent $Root) 'cattool.json'
$manifest = [ordered]@{
    version = '1.0.0'
    description = 'Cat command standalone test tool'
    homepage = 'https://example.test/cattool'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json -Compress | Set-Content -Path $manifestPath -Encoding UTF8

$pathOutput = & $ScoExe cat $manifestPath
if ($LASTEXITCODE -ne 0) {
    throw "cat local manifest failed with exit code $LASTEXITCODE`: $pathOutput"
}
if (($pathOutput -join "`n") -notmatch 'Cat command standalone test tool') {
    throw "cat local manifest output did not include description: $pathOutput"
}
if ($pathOutput.Count -lt 2 -or $pathOutput -notcontains '    "description": "Cat command standalone test tool",') {
    throw "cat local manifest output was not pretty-printed JSON: $pathOutput"
}

$extraArgOutput = & $ScoExe cat $manifestPath ignored-extra
if ($LASTEXITCODE -ne 0) {
    throw "cat with an extra positional argument failed with exit code $LASTEXITCODE`: $extraArgOutput"
}
if (($extraArgOutput -join "`n") -notmatch 'Cat command standalone test tool') {
    throw "cat did not ignore extra positional arguments like Scoop: $extraArgOutput"
}

$localScopeDir = Join-Path (Split-Path -Parent $Root) 'cat-local-source'
$globalScopeDir = Join-Path (Split-Path -Parent $Root) 'cat-global-source'
New-Item -ItemType Directory -Force -Path $localScopeDir, $globalScopeDir | Out-Null
$localScopeManifestPath = Join-Path $localScopeDir 'catbothscope.json'
$globalScopeManifestPath = Join-Path $globalScopeDir 'catbothscope.json'
$scopeManifest = [ordered]@{
    version = '1.0.0'
    description = 'Cat local scope manifest'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$scopeManifest | ConvertTo-Json | Set-Content -Path $localScopeManifestPath -Encoding UTF8
& $ScoExe install $localScopeManifestPath --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "local cat both-scope fixture install failed with exit code $LASTEXITCODE"
}

$scopeManifest.description = 'Cat global scope manifest'
$scopeManifest | ConvertTo-Json | Set-Content -Path $globalScopeManifestPath -Encoding UTF8
Install-GlobalStandaloneCatFixture $globalScopeManifestPath
if ($LASTEXITCODE -ne 0) {
    throw "global cat both-scope fixture install failed with exit code $LASTEXITCODE"
}

$bothScopeCatOutput = & $ScoExe cat catbothscope
if ($LASTEXITCODE -ne 0) {
    throw "cat both-scope installed app failed with exit code $LASTEXITCODE`: $bothScopeCatOutput"
}
$bothScopeCatJoined = $bothScopeCatOutput -join "`n"
if ($bothScopeCatJoined -notmatch 'Cat global scope manifest' -or $bothScopeCatJoined -match 'Cat local scope manifest') {
    throw "cat should prefer global installed manifest when both scopes exist like Scoop: $bothScopeCatJoined"
}

$fakeBin = Join-Path $Root 'fake-bin'
$batLog = Join-Path $Root 'bat-args.txt'
$batInput = Join-Path $Root 'bat-input.json'
New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
@"
@echo off
echo %*> "$batLog"
more > "$batInput"
echo BAT-CALLED
"@ | Set-Content -Path (Join-Path $fakeBin 'bat.cmd') -Encoding Ascii
$oldPath = $env:PATH
try {
    $env:PATH = "$fakeBin;$oldPath"
    & $ScoExe config cat_style numbers | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "config cat_style failed with exit code $LASTEXITCODE"
    }

    $styledOutput = (& $ScoExe cat $manifestPath) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "cat with cat_style failed with exit code $LASTEXITCODE`: $styledOutput"
    }
    if ($styledOutput -notmatch 'BAT-CALLED') {
        throw "cat with cat_style did not use bat: $styledOutput"
    }
    $batArgs = Get-Content -LiteralPath $batLog -Raw
    if ($batArgs.Trim() -notmatch '^--no-paging --style "?numbers"? --language json$') {
        throw "cat with cat_style passed unexpected bat args: $batArgs"
    }
    $batJson = Get-Content -LiteralPath $batInput -Raw
    if ($batJson -notmatch 'Cat command standalone test tool' -or $batJson -notmatch '"description": "Cat command standalone test tool"') {
        throw "cat with cat_style did not pipe pretty JSON to bat: $batJson"
    }
} finally {
    $env:PATH = $oldPath
    & $ScoExe config rm cat_style | Out-Null
}

$remoteManifest = Join-Path (Split-Path -Parent $Root) 'remote-cattool.json'
$manifest.description = 'Cat command remote manifest test tool'
$manifest | ConvertTo-Json | Set-Content -Path $remoteManifest -Encoding UTF8

$listenerPrefix = 'http://127.0.0.1:18192/'
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
    $urlOutput = & $ScoExe cat ($listenerPrefix + 'remotecat.json')
    if ($LASTEXITCODE -ne 0) {
        throw "cat manifest URL failed with exit code $LASTEXITCODE`: $urlOutput"
    }
    if (($urlOutput -join "`n") -notmatch 'Cat command remote manifest test tool') {
        throw "cat manifest URL output did not include description: $urlOutput"
    }
} finally {
    Wait-Job $job -Timeout 5 | Out-Null
    Receive-Job $job | Out-Null
    Remove-Job $job -Force
}
