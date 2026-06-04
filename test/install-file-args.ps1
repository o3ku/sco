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

$bucketDir = Join-Path $Root 'buckets\main\bucket'
$sourceDir = Join-Path $Root 'sources\fileargs'
$markerDir = Join-Path $Root 'markers'
New-Item -ItemType Directory -Force -Path $bucketDir,$sourceDir,$markerDir | Out-Null

$installer = @"
@echo off
echo installer:%1:%2>%~dp0\install-marker.txt
"@
$uninstallMarkerPath = (Join-Path $markerDir 'uninstall-marker.txt')
$uninstallRemovedMarkerPath = (Join-Path $markerDir 'uninstall-removed-marker.txt')
$uninstaller = @"
@echo off
echo uninstaller:%1:%2>$uninstallMarkerPath
"@
$tokenInstaller = @'
@echo off
echo %~1>%~dp0\token-dir.txt
echo %~2>%~dp0\token-global.txt
echo %~3>%~dp0\token-version.txt
echo %~4>%~dp0\token-spaced.txt
'@
$orderInstaller = @'
@echo off
echo file>%~dp0\order.txt
'@
$outsideMarkerPath = Join-Path $markerDir 'outside-installer.txt'
$outsideInstaller = @"
@echo off
echo outside>$outsideMarkerPath
"@
$psInstaller = @'
param(
    [string]$First,
    [string]$Second
)
Set-Content -Path (Join-Path $PSScriptRoot 'ps-marker.txt') -Value ('ps1:{0}:{1}' -f $First, $Second) -NoNewline -Encoding Ascii
Set-Content -Path (Join-Path $PSScriptRoot 'ps-context.txt') -Value (@($dir, $original_dir, $persist_dir, $architecture, $app, $version, $global) -join "`n") -NoNewline -Encoding Ascii
'@
$tool = '@echo fileargs-tool'
Set-Content -Path (Join-Path $sourceDir 'install.cmd') -Value $installer -Encoding Ascii
Set-Content -Path (Join-Path $sourceDir 'uninstall.cmd') -Value $uninstaller -Encoding Ascii
Set-Content -Path (Join-Path $sourceDir 'token.cmd') -Value $tokenInstaller -Encoding Ascii
Set-Content -Path (Join-Path $sourceDir 'order.cmd') -Value $orderInstaller -Encoding Ascii
Set-Content -Path (Join-Path $sourceDir 'outside.cmd') -Value $outsideInstaller -Encoding Ascii
Set-Content -Path (Join-Path $sourceDir 'install.ps1') -Value $psInstaller -Encoding UTF8
Set-Content -Path (Join-Path $sourceDir 'filetool.exe') -Value $tool -Encoding Ascii

$archive = Join-Path $Root 'sources\fileargs.zip'
Push-Location $sourceDir
try {
    tar -a -cf $archive install.cmd uninstall.cmd token.cmd order.cmd install.ps1 filetool.exe
} finally {
    Pop-Location
}
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $stream = [System.IO.File]::OpenRead($archive)
    try {
        $hashBytes = $sha.ComputeHash($stream)
    } finally {
        $stream.Dispose()
    }
} finally {
    $sha.Dispose()
}
$hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $stream = [System.IO.File]::OpenRead((Join-Path $sourceDir 'install.cmd'))
    try {
        $installerHashBytes = $sha.ComputeHash($stream)
    } finally {
        $stream.Dispose()
    }
} finally {
    $sha.Dispose()
}
$installerHash = ([System.BitConverter]::ToString($installerHashBytes)).Replace('-', '').ToLowerInvariant()

$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($archive))
    hash = $hash
    installer = [ordered]@{
        file = 'install.cmd'
        args = @('alpha', 'beta')
    }
    uninstaller = [ordered]@{
        file = 'uninstall.cmd'
        args = @('gamma', 'delta')
    }
    post_uninstall = "Set-Content -Path '$uninstallRemovedMarkerPath' -Value (Test-Path (Join-Path `$dir 'uninstall.cmd')) -NoNewline -Encoding Ascii"
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'fileargtool.json') -Encoding UTF8

$defaultInstallerManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'install.cmd')))
    hash = $installerHash
    installer = [ordered]@{
        args = @('alpha', 'beta')
    }
}
$defaultInstallerManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'defaultinstallertool.json') -Encoding UTF8

$keepInstallerManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($archive))
    hash = $hash
    installer = [ordered]@{
        file = 'install.cmd'
        args = @('alpha', 'beta')
        keep = $true
    }
    bin = 'filetool.exe'
}
$keepInstallerManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'keepinstallertool.json') -Encoding UTF8

$stringKeepInstallerManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($archive))
    hash = $hash
    installer = [ordered]@{
        file = 'install.cmd'
        args = @('alpha', 'beta')
        keep = 'true'
    }
    bin = 'filetool.exe'
}
$stringKeepInstallerManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'stringkeepinstallertool.json') -Encoding UTF8

$tokenArgsManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($archive))
    hash = $hash
    installer = [ordered]@{
        file = 'token.cmd'
        args = @('$dir', '$global', '$version', 'two words')
    }
    bin = 'filetool.exe'
}
$tokenArgsManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'tokenargtool.json') -Encoding UTF8

$psInstallerManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($archive))
    hash = $hash
    installer = [ordered]@{
        file = 'install.ps1'
        args = @('omega', 'two words')
    }
    bin = 'filetool.exe'
}
$psInstallerManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'psinstallertool.json') -Encoding UTF8

$fileScriptOrderManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($archive))
    hash = $hash
    installer = [ordered]@{
        file = 'order.cmd'
        script = "Add-Content -Path (Join-Path `$dir 'order.txt') -Value 'script' -Encoding Ascii"
    }
    bin = 'filetool.exe'
}
$fileScriptOrderManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'orderscripttest.json') -Encoding UTF8

$outsideInstallerManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'filetool.exe')))
    hash = ''
    installer = [ordered]@{
        file = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'outside.cmd')))
    }
    bin = 'filetool.exe'
}
$outsideInstallerManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'outsideinstallertool.json') -Encoding UTF8

$outsideUninstallerManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'filetool.exe')))
    hash = ''
    uninstaller = [ordered]@{
        file = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'outside.cmd')))
    }
    bin = 'filetool.exe'
}
$outsideUninstallerManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'outsideuninstallertool.json') -Encoding UTF8

$defaultUninstallerManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'uninstall.cmd')))
    hash = ''
    uninstaller = [ordered]@{
        args = @('epsilon', 'zeta')
    }
}
$defaultUninstallerManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'defaultuninstallertool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$outsideInstallerOutput = & $ScoExe install outsideinstallertool --no-update-scoop 2>&1
$outsideInstallerExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($outsideInstallerExitCode -ne 1) {
    throw "install with outside installer.file returned $outsideInstallerExitCode instead of 1: $outsideInstallerOutput"
}
$outsideInstallerJoined = $outsideInstallerOutput -join "`n"
if ($outsideInstallerJoined -notmatch 'outside the app directory') {
    throw "install with outside installer.file did not report Scoop-style containment error: $outsideInstallerJoined"
}
if (Test-Path $outsideMarkerPath) {
    throw 'install with outside installer.file executed the external installer'
}
if (Test-Path (Join-Path $Root 'apps\outsideinstallertool\current')) {
    throw 'install with outside installer.file created a current link'
}

& $ScoExe install outsideuninstallertool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with outside uninstaller.file failed with exit code $LASTEXITCODE"
}
Remove-Item -LiteralPath $outsideMarkerPath -Force -ErrorAction SilentlyContinue
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$outsideUninstallerOutput = & $ScoExe uninstall outsideuninstallertool 2>&1
$outsideUninstallerExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($outsideUninstallerExitCode -ne 1) {
    throw "uninstall with outside uninstaller.file returned $outsideUninstallerExitCode instead of 1: $outsideUninstallerOutput"
}
$outsideUninstallerJoined = $outsideUninstallerOutput -join "`n"
if ($outsideUninstallerJoined -notmatch 'outside the app directory') {
    throw "uninstall with outside uninstaller.file did not report Scoop-style containment error: $outsideUninstallerJoined"
}
if (Test-Path $outsideMarkerPath) {
    throw 'uninstall with outside uninstaller.file executed the external uninstaller'
}
if (!(Test-Path (Join-Path $Root 'apps\outsideuninstallertool\current'))) {
    throw 'uninstall with outside uninstaller.file removed the app after the uninstaller error'
}

& $ScoExe install defaultuninstallertool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install using first URL as uninstaller failed with exit code $LASTEXITCODE"
}
Remove-Item -LiteralPath $uninstallMarkerPath -Force -ErrorAction SilentlyContinue
& $ScoExe uninstall defaultuninstallertool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall using first URL as uninstaller failed with exit code $LASTEXITCODE"
}
$defaultUninstallContent = (Get-Content $uninstallMarkerPath -Raw).Trim()
if ($defaultUninstallContent -ne 'uninstaller:epsilon:zeta') {
    throw "uninstaller args without uninstaller.file did not execute first downloaded artifact: $defaultUninstallContent"
}
if (Test-Path (Join-Path $Root 'apps\defaultuninstallertool')) {
    throw 'default uninstaller left app directory'
}

& $ScoExe install fileargtool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$installMarker = Join-Path $Root 'apps\fileargtool\current\install-marker.txt'
if (!(Test-Path $installMarker)) {
    throw "installer file did not create marker"
}
$installContent = (Get-Content $installMarker -Raw).Trim()
if ($installContent -ne 'installer:alpha:beta') {
    throw "unexpected installer marker: $installContent"
}
if (Test-Path (Join-Path $Root 'apps\fileargtool\current\install.cmd')) {
    throw 'installer.file was not removed after successful install'
}

& $ScoExe uninstall fileargtool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall failed with exit code $LASTEXITCODE"
}

$uninstallMarker = Join-Path $markerDir 'uninstall-marker.txt'
if (!(Test-Path $uninstallMarker)) {
    throw "uninstaller file did not create marker"
}
$uninstallContent = (Get-Content $uninstallMarker -Raw).Trim()
if ($uninstallContent -ne 'uninstaller:gamma:delta') {
    throw "unexpected uninstaller marker: $uninstallContent"
}
$uninstallRemovedContent = (Get-Content $uninstallRemovedMarkerPath -Raw).Trim()
if ($uninstallRemovedContent -ne 'False') {
    throw "uninstaller.file should be removed before post_uninstall unless keep is set: $uninstallRemovedContent"
}

if (Test-Path (Join-Path $Root 'apps\fileargtool')) {
    throw 'uninstall left app directory'
}

& $ScoExe install defaultinstallertool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install using first URL as installer failed with exit code $LASTEXITCODE"
}

$defaultMarker = Join-Path $Root 'apps\defaultinstallertool\current\install-marker.txt'
if (!(Test-Path $defaultMarker)) {
    throw 'installer args without installer.file did not execute the first downloaded artifact'
}
$defaultContent = (Get-Content $defaultMarker -Raw).Trim()
if ($defaultContent -ne 'installer:alpha:beta') {
    throw "unexpected default installer marker: $defaultContent"
}
if (Test-Path (Join-Path $Root 'apps\defaultinstallertool\current\install.cmd')) {
    throw 'default installer artifact was not removed after successful install'
}

& $ScoExe install keepinstallertool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with installer.keep failed with exit code $LASTEXITCODE"
}
if (!(Test-Path (Join-Path $Root 'apps\keepinstallertool\current\install.cmd'))) {
    throw 'installer.keep did not preserve installer.file'
}

& $ScoExe install stringkeepinstallertool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with string installer.keep failed with exit code $LASTEXITCODE"
}
if (!(Test-Path (Join-Path $Root 'apps\stringkeepinstallertool\current\install.cmd'))) {
    throw 'string installer.keep should preserve installer.file like PowerShell truthiness'
}

& $ScoExe install tokenargtool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with installer arg substitutions failed with exit code $LASTEXITCODE"
}
$tokenVersionDir = Join-Path $Root 'apps\tokenargtool\1.0.0'
$tokenDir = (Get-Content (Join-Path $tokenVersionDir 'token-dir.txt') -Raw).Trim()
$expectedTokenDir = [System.IO.Path]::GetFullPath($tokenVersionDir)
if ([System.IO.Path]::GetFullPath($tokenDir) -ne $expectedTokenDir) {
    throw "installer arg `$dir was not substituted to the version directory: $tokenDir"
}
$tokenGlobal = (Get-Content (Join-Path $tokenVersionDir 'token-global.txt') -Raw).Trim()
if ($tokenGlobal -ne 'False') {
    throw "installer arg `$global was not substituted like Scoop: $tokenGlobal"
}
$tokenVersion = (Get-Content (Join-Path $tokenVersionDir 'token-version.txt') -Raw).Trim()
if ($tokenVersion -ne '1.0.0') {
    throw "installer arg `$version was not substituted: $tokenVersion"
}
$tokenSpaced = (Get-Content (Join-Path $tokenVersionDir 'token-spaced.txt') -Raw).Trim()
if ($tokenSpaced -ne 'two words') {
    throw "installer arg with spaces was not passed as one argument: $tokenSpaced"
}

& $ScoExe install psinstallertool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "PowerShell installer.file failed with exit code $LASTEXITCODE"
}
$psVersionDir = Join-Path $Root 'apps\psinstallertool\1.0.0'
$psMarker = (Get-Content (Join-Path $psVersionDir 'ps-marker.txt') -Raw).Trim()
if ($psMarker -ne 'ps1:omega:two words') {
    throw "PowerShell installer.file did not receive args: $psMarker"
}
$psContext = @(Get-Content (Join-Path $psVersionDir 'ps-context.txt'))
$expectedPsContext = @(
    [System.IO.Path]::GetFullPath($psVersionDir),
    [System.IO.Path]::GetFullPath($psVersionDir),
    [System.IO.Path]::GetFullPath((Join-Path $Root 'persist\psinstallertool')),
    '64bit',
    'psinstallertool',
    '1.0.0',
    'False'
)
if ($psContext.Count -ne $expectedPsContext.Count) {
    throw "PowerShell installer.file context had $($psContext.Count) entries: $($psContext -join ', ')"
}
for ($i = 0; $i -lt $expectedPsContext.Count; ++$i) {
    $actual = $psContext[$i]
    $expected = $expectedPsContext[$i]
    if ($i -lt 3) {
        $actual = [System.IO.Path]::GetFullPath($actual)
    }
    if ($actual -ne $expected) {
        throw "PowerShell installer.file context entry $i was '$actual', expected '$expected'"
    }
}
if (!(Test-Path (Join-Path $psVersionDir 'install.ps1'))) {
    throw 'PowerShell installer.file should be preserved after execution'
}

& $ScoExe install orderscripttest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "installer file+script order install failed with exit code $LASTEXITCODE"
}
$orderVersionDir = Join-Path $Root 'apps\orderscripttest\1.0.0'
$orderLines = @(Get-Content (Join-Path $orderVersionDir 'order.txt'))
if ($orderLines.Count -ne 2 -or $orderLines[0] -ne 'file' -or $orderLines[1] -ne 'script') {
    throw "installer.file did not run before installer.script: $($orderLines -join ',')"
}
if (Test-Path (Join-Path $orderVersionDir '_hooks')) {
    throw 'installer.file/script left helper files in the app directory'
}
