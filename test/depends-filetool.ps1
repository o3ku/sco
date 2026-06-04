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

function Write-Manifest($Name, $Depends, $Url = $Artifact, $Bin = 'filetool.exe', $Extra = $null) {
    $manifest = [ordered]@{
        version = '1.0.0'
        url = ([System.IO.Path]::GetFullPath($Url))
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        bin = $Bin
    }
    if ($Depends) {
        $manifest.depends = $Depends
    }
    if ($Extra) {
        foreach ($key in $Extra.Keys) {
            $manifest[$key] = $Extra[$key]
        }
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir "$Name.json") -Encoding UTF8
}

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome

function Get-DependsLines {
    param([object[]]$Output)

    @($Output | Where-Object {
        $_ -match '\S' -and $_ -notmatch '^\s*-+\s+-+\s*$'
    } | ForEach-Object {
        ([string]$_).Trim() -replace '\s+', ' '
    })
}

function Install-GlobalStandaloneDependsFixture($ManifestPath) {
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
$missingAppOutput = & $ScoExe depends 2>&1
$missingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppExitCode -ne 1) {
    throw "depends without an app returned $missingAppExitCode instead of 1: $missingAppOutput"
}
if (($missingAppOutput -join "`n") -notmatch 'ERROR <app> missing' -or ($missingAppOutput -join "`n") -notmatch 'Usage: sco depends <app>') {
    throw "depends without an app did not match Scoop usage: $missingAppOutput"
}

Write-Manifest 'deptool' $null
Write-Manifest 'apptool' 'deptool'
Write-Manifest 'circlea' 'circleb'
Write-Manifest 'circleb' 'circlea'

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$archEqualsOutput = & $ScoExe depends --arch=64bit apptool 2>&1
$archEqualsExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($archEqualsExitCode -ne 1) {
    throw "depends --arch=64bit returned $archEqualsExitCode instead of 1: $archEqualsOutput"
}
if (($archEqualsOutput -join "`n") -notmatch 'sco depends: Option --arch=64bit not recognized\.') {
    throw "depends --arch=64bit did not match Scoop getopt error: $archEqualsOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidArchOutput = & $ScoExe depends --arch mips apptool 2>&1
$invalidArchExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidArchExitCode -ne 1) {
    throw "depends --arch mips returned $invalidArchExitCode instead of 1: $invalidArchOutput"
}
if (($invalidArchOutput -join "`n") -notmatch "ERROR: Invalid architecture: 'mips'") {
    throw "depends --arch mips did not match Scoop architecture error: $invalidArchOutput"
}

[ordered]@{
    extras = 'https://example.invalid/extras'
} | ConvertTo-Json | Set-Content -Path (Join-Path $Root 'buckets.json') -Encoding UTF8
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingBucketOutput = & $ScoExe depends extras/missingdep 2>&1
$missingBucketExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingBucketExitCode -ne 1) {
    throw "depends missing bucket manifest returned $missingBucketExitCode instead of 1: $missingBucketOutput"
}
$missingBucketJoined = $missingBucketOutput -join "`n"
if ($missingBucketJoined -notmatch "WARN  Bucket 'extras' not added\. Add it with 'sco bucket add extras' or 'sco bucket add extras <repo>'\." -or
    $missingBucketJoined -notmatch "ERROR Couldn't find manifest for 'missingdep' from 'extras' bucket\.") {
    throw "depends missing bucket manifest did not match Scoop warning and error: $missingBucketJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$circularOutput = & $ScoExe depends circlea 2>&1
$circularExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($circularExitCode -ne 1) {
    throw "depends circular dependency returned $circularExitCode instead of 1: $circularOutput"
}
if (($circularOutput -join "`n") -notmatch "ERROR Circular dependency detected: 'circleb' -> 'circlea'\.") {
    throw "depends circular dependency did not match Scoop error: $circularOutput"
}

$output = & $ScoExe depends -a 64bit -- apptool
if ($LASTEXITCODE -ne 0) {
    throw "depends failed with exit code $LASTEXITCODE`: $output"
}

$lines = Get-DependsLines $output
if ($lines.Count -ne 3) {
    throw "Expected header and two dependency rows, got $($lines.Count): $($lines -join '; ')"
}
if ($lines[0] -ne 'Source Name') {
    throw "Unexpected depends header: $($lines[0])"
}
if ($lines[1] -ne 'main deptool' -or $lines[2] -ne 'main apptool') {
    throw "Unexpected dependency order: $($lines -join '; ')"
}

$otherBucketDir = Join-Path $Root 'buckets\other\bucket'
New-Item -ItemType Directory -Force -Path $otherBucketDir | Out-Null
Write-Manifest 'shareddep' $null
$otherOnlyDepManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$otherOnlyDepManifest | ConvertTo-Json | Set-Content -Path (Join-Path $otherBucketDir 'otheronlydep.json') -Encoding UTF8
$otherDepManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
    depends = 'other/otheronlydep'
}
$otherDepManifest | ConvertTo-Json | Set-Content -Path (Join-Path $otherBucketDir 'shareddep.json') -Encoding UTF8
Write-Manifest 'crossbuckettool' @('shareddep', 'other/shareddep')

$crossBucketOutput = & $ScoExe depends crossbuckettool
if ($LASTEXITCODE -ne 0) {
    throw "depends cross-bucket same-name dependencies failed with exit code $LASTEXITCODE`: $crossBucketOutput"
}
$crossBucketLines = Get-DependsLines $crossBucketOutput
if ($crossBucketLines.Count -ne 5 -or
    $crossBucketLines[1] -ne 'main shareddep' -or
    $crossBucketLines[2] -ne 'other otheronlydep' -or
    $crossBucketLines[3] -ne 'other shareddep' -or
    $crossBucketLines[4] -ne 'main crossbuckettool') {
    throw "depends should keep same-name dependencies from different buckets distinct: $($crossBucketLines -join '; ')"
}

$extraArgOutput = & $ScoExe depends apptool missingdependstool
if ($LASTEXITCODE -ne 0) {
    throw "depends with an extra positional app failed with exit code $LASTEXITCODE`: $extraArgOutput"
}
$extraArgLines = Get-DependsLines $extraArgOutput
if ($extraArgLines.Count -ne 3 -or $extraArgLines[1] -ne 'main deptool' -or $extraArgLines[2] -ne 'main apptool') {
    throw "depends did not ignore extra positional app like Scoop: $($extraArgLines -join '; ')"
}

$sourceDir = Join-Path $Root 'sources'
New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
$innounpArtifact = Join-Path $sourceDir 'innounp.exe'
$sevenZipArtifact = Join-Path $sourceDir '7z.exe'
$darkArtifact = Join-Path $sourceDir 'dark.exe'
$lessmsiArtifact = Join-Path $sourceDir 'lessmsi.exe'
Copy-Item -LiteralPath $Artifact -Destination $innounpArtifact -Force
Copy-Item -LiteralPath $Artifact -Destination $sevenZipArtifact -Force
Copy-Item -LiteralPath $Artifact -Destination $darkArtifact -Force
Copy-Item -LiteralPath $Artifact -Destination $lessmsiArtifact -Force

Write-Manifest 'innounp' $null $innounpArtifact 'innounp.exe'
Write-Manifest '7zip' $null $sevenZipArtifact '7z.exe'
Write-Manifest 'dark' $null $darkArtifact 'dark.exe'
Write-Manifest 'lessmsi' $null $lessmsiArtifact 'lessmsi.exe'
Write-Manifest 'innotool' $null $Artifact 'filetool.exe' @{ innosetup = 'true' }
Write-Manifest 'scripthelptool' $null $Artifact 'filetool.exe' @{
    pre_install = 'Expand-7zipArchive -Path $dir'
    post_install = 'Expand-DarkArchive -Path $dir'
}
$fragmentArchiveManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact)) + '#/payload.7z'
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$fragmentArchiveManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'fragmentarchivetool.json') -Encoding UTF8
$msiManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact)) + '#/payload.msi'
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$msiManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'msitool.json') -Encoding UTF8

$innoOutput = & $ScoExe depends innotool
if ($LASTEXITCODE -ne 0) {
    throw "depends innosetup helper failed with exit code $LASTEXITCODE`: $innoOutput"
}
$innoLines = Get-DependsLines $innoOutput
if ($innoLines.Count -ne 3 -or $innoLines[1] -ne 'main innounp' -or $innoLines[2] -ne 'main innotool') {
    throw "depends did not include innounp helper before Inno app: $($innoLines -join '; ')"
}

$scriptHelperOutput = & $ScoExe depends scripthelptool
if ($LASTEXITCODE -ne 0) {
    throw "depends script helper failed with exit code $LASTEXITCODE`: $scriptHelperOutput"
}
$scriptHelperLines = Get-DependsLines $scriptHelperOutput
if ($scriptHelperLines.Count -ne 4 -or $scriptHelperLines[1] -ne 'main 7zip' -or $scriptHelperLines[2] -ne 'main dark' -or $scriptHelperLines[3] -ne 'main scripthelptool') {
    throw "depends did not include script helpers before app: $($scriptHelperLines -join '; ')"
}

$fragmentArchiveOutput = & $ScoExe depends fragmentarchivetool
if ($LASTEXITCODE -ne 0) {
    throw "depends fragment archive helper failed with exit code $LASTEXITCODE`: $fragmentArchiveOutput"
}
$fragmentArchiveLines = Get-DependsLines $fragmentArchiveOutput
if ($fragmentArchiveLines.Count -ne 3 -or $fragmentArchiveLines[1] -ne 'main 7zip' -or $fragmentArchiveLines[2] -ne 'main fragmentarchivetool') {
    throw "depends did not use URL fragment filename for archive helper detection: $($fragmentArchiveLines -join '; ')"
}

$msiDefaultOutput = & $ScoExe depends msitool
if ($LASTEXITCODE -ne 0) {
    throw "depends default MSI helper check failed with exit code $LASTEXITCODE`: $msiDefaultOutput"
}
$msiDefaultLines = Get-DependsLines $msiDefaultOutput
if ($msiDefaultLines.Count -ne 2 -or $msiDefaultLines[1] -ne 'main msitool') {
    throw "depends should not include lessmsi unless use_lessmsi is enabled: $($msiDefaultLines -join '; ')"
}

& $ScoExe config use_lessmsi true | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config use_lessmsi true failed with exit code $LASTEXITCODE"
}
$msiConfiguredOutput = & $ScoExe depends msitool
if ($LASTEXITCODE -ne 0) {
    throw "depends configured MSI helper failed with exit code $LASTEXITCODE`: $msiConfiguredOutput"
}
$msiConfiguredLines = Get-DependsLines $msiConfiguredOutput
if ($msiConfiguredLines.Count -ne 3 -or $msiConfiguredLines[1] -ne 'main lessmsi' -or $msiConfiguredLines[2] -ne 'main msitool') {
    throw "depends did not include lessmsi when use_lessmsi is enabled: $($msiConfiguredLines -join '; ')"
}

$pathManifest = Join-Path (Split-Path -Parent $Root) 'pathdep.json'
@{
    version = '1.0.0'
} | ConvertTo-Json | Set-Content -Path $pathManifest -Encoding UTF8

$pathOutput = & $ScoExe depends $pathManifest
if ($LASTEXITCODE -ne 0) {
    throw "depends local manifest failed with exit code $LASTEXITCODE`: $pathOutput"
}
$expectedPathSource = ([System.IO.Path]::GetFullPath($pathManifest)).Replace('\', '/')
$pathLines = Get-DependsLines $pathOutput
if ($pathLines.Count -ne 2 -or $pathLines[1].Replace('\', '/') -ne "$expectedPathSource pathdep") {
    throw "depends local manifest did not preserve path source: $($pathLines -join '; ')"
}

$localScopeDir = Join-Path (Split-Path -Parent $Root) 'depends-local-source'
$globalScopeDir = Join-Path (Split-Path -Parent $Root) 'depends-global-source'
New-Item -ItemType Directory -Force -Path $localScopeDir, $globalScopeDir | Out-Null
$localScopeManifest = Join-Path $localScopeDir 'dependsbothscope.json'
$globalScopeManifest = Join-Path $globalScopeDir 'dependsbothscope.json'
$localOnlyDepManifest = Join-Path $localScopeDir 'localonlydep.json'
$globalOnlyDepManifest = Join-Path $globalScopeDir 'globalonlydep.json'
@{
    version = '1.0.0'
} | ConvertTo-Json | Set-Content -Path $localOnlyDepManifest -Encoding UTF8
@{
    version = '1.0.0'
} | ConvertTo-Json | Set-Content -Path $globalOnlyDepManifest -Encoding UTF8
$scopeManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$scopeManifest | ConvertTo-Json | Set-Content -Path $localScopeManifest -Encoding UTF8
& $ScoExe install $localScopeManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "local depends both-scope fixture install failed with exit code $LASTEXITCODE"
}
$scopeManifest | ConvertTo-Json | Set-Content -Path $globalScopeManifest -Encoding UTF8
Install-GlobalStandaloneDependsFixture $globalScopeManifest
if ($LASTEXITCODE -ne 0) {
    throw "global depends both-scope fixture install failed with exit code $LASTEXITCODE"
}

$scopeManifest.depends = ([System.IO.Path]::GetFullPath($localOnlyDepManifest))
$scopeManifest | ConvertTo-Json | Set-Content -Path $localScopeManifest -Encoding UTF8
$scopeManifest.depends = ([System.IO.Path]::GetFullPath($globalOnlyDepManifest))
$scopeManifest | ConvertTo-Json | Set-Content -Path $globalScopeManifest -Encoding UTF8

$bothScopeDepends = & $ScoExe depends dependsbothscope
if ($LASTEXITCODE -ne 0) {
    throw "depends both-scope installed app failed with exit code $LASTEXITCODE`: $bothScopeDepends"
}
$bothScopeLines = Get-DependsLines $bothScopeDepends
if ($bothScopeLines.Count -ne 3 -or
    $bothScopeLines[1].Replace('\', '/') -notmatch '/depends-global-source/globalonlydep\.json globalonlydep$' -or
    $bothScopeLines[2].Replace('\', '/') -notmatch '/depends-global-source/dependsbothscope\.json dependsbothscope$' -or
    ($bothScopeLines -join "`n") -match 'localonlydep') {
    throw "depends should prefer global installed manifest when both scopes exist like Scoop: $($bothScopeLines -join '; ')"
}

$remoteManifest = Join-Path (Split-Path -Parent $Root) 'remotedep.json'
@{
    version = '1.0.0'
} | ConvertTo-Json | Set-Content -Path $remoteManifest -Encoding UTF8

$listenerPrefix = 'http://127.0.0.1:18197/'
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
$remoteUrl = $listenerPrefix + 'remotedep.json'
try {
    $remoteOutput = & $ScoExe depends $remoteUrl
    if ($LASTEXITCODE -ne 0) {
        throw "depends remote manifest failed with exit code $LASTEXITCODE`: $remoteOutput"
    }
} finally {
    Wait-Job $job -Timeout 5 | Out-Null
    Receive-Job $job | Out-Null
    Remove-Job $job -Force
}

$remoteLines = Get-DependsLines $remoteOutput
if ($remoteLines.Count -ne 2 -or $remoteLines[1] -ne "$remoteUrl remotedep") {
    throw "depends remote manifest did not preserve URL source: $($remoteLines -join '; ')"
}
