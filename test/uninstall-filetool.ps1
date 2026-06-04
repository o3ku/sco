param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Manifest,
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

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$plainMissingAppOutput = & $ScoExe uninstall 2>&1
$plainMissingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($plainMissingAppExitCode -ne 1) {
    throw "uninstall without arguments returned $plainMissingAppExitCode instead of 1: $plainMissingAppOutput"
}
$plainMissingAppJoined = $plainMissingAppOutput -join "`n"
if ($plainMissingAppJoined -notmatch 'ERROR <app> missing' -or $plainMissingAppJoined -notmatch 'Usage: sco uninstall <app> \[options\]') {
    throw "uninstall without arguments did not match Scoop usage output: $plainMissingAppJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAppOutput = & $ScoExe uninstall --global 2>&1
$missingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppExitCode -ne 1) {
    throw "uninstall without an app returned $missingAppExitCode instead of 1: $missingAppOutput"
}
$missingAppJoined = $missingAppOutput -join "`n"
if ($missingAppJoined -notmatch 'ERROR <app> missing' -or $missingAppJoined -notmatch 'Usage: sco uninstall <app> \[options\]') {
    throw "uninstall without an app did not match Scoop usage output: $missingAppJoined"
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $globalNonAdminOutput = & $ScoExe uninstall --global definitely-missing-global-tool 2>&1
    $globalNonAdminExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($globalNonAdminExitCode -ne 1) {
        throw "non-admin uninstall --global returned $globalNonAdminExitCode instead of 1: $globalNonAdminOutput"
    }
    if (($globalNonAdminOutput -join "`n") -notmatch 'ERROR You need admin rights to uninstall global apps\.') {
        throw "non-admin uninstall --global did not match Scoop admin error: $globalNonAdminOutput"
    }
}

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

if (!(Test-Path (Join-Path $Root 'apps\filetool\current\filetool.exe'))) {
    throw 'install did not produce current filetool.exe'
}
if (!(Test-Path (Join-Path $Root 'shims\filetool.exe')) -or !(Test-Path (Join-Path $Root 'shims\filetool.shim'))) {
    throw 'install did not produce filetool shim'
}

$currentJunction = Join-Path $Root 'apps\filetool\current'
attrib +r $currentJunction
& $ScoExe uninstall filetool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall failed with exit code $LASTEXITCODE"
}

foreach ($path in @(
    (Join-Path $Root 'apps\filetool'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (Test-Path $path) {
        throw "Uninstall left unexpected path: $path"
    }
}

$cacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'filetool#1.0.0#*.exe')
if ($cacheFiles.Count -ne 1) {
    throw "Expected cache to remain after uninstall, found $($cacheFiles.Count) cache files"
}

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "reinstall before failed-layout uninstall failed with exit code $LASTEXITCODE"
}

$brokenCurrent = Join-Path $Root 'apps\filetool\current'
[System.IO.Directory]::Delete($brokenCurrent)
$brokenLayoutOutput = (& $ScoExe uninstall filetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "uninstall of failed layout returned $LASTEXITCODE`: $brokenLayoutOutput"
}
if ($brokenLayoutOutput -notmatch "ERROR 'filetool' isn't installed correctly\." -or
    $brokenLayoutOutput -notmatch "Uninstalling 'filetool' \(1\.0\.0\)\." -or
    $brokenLayoutOutput -notmatch "'filetool' was uninstalled\.") {
    throw "uninstall of failed layout did not match Scoop-style output: $brokenLayoutOutput"
}
foreach ($path in @(
    (Join-Path $Root 'apps\filetool'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (Test-Path $path) {
        throw "Uninstall of failed layout left unexpected path: $path"
    }
}

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "reinstall before bucket-qualified uninstall failed with exit code $LASTEXITCODE"
}

$terminatorOutput = (& $ScoExe uninstall -- filetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "uninstall -- terminator failed with exit code $LASTEXITCODE`: $terminatorOutput"
}
if ($terminatorOutput -notmatch "Uninstalling 'filetool' \(1\.0\.0\)\." -or $terminatorOutput -notmatch "'filetool' was uninstalled\.") {
    throw "uninstall -- terminator did not uninstall filetool: $terminatorOutput"
}
if ($terminatorOutput -notmatch 'Unlinking .+apps\\filetool\\current') {
    throw "uninstall -- terminator did not report current junction unlink like Scoop: $terminatorOutput"
}
if (Test-Path (Join-Path $Root 'apps\filetool')) {
    throw 'uninstall -- terminator left filetool app directory behind'
}

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "reinstall before bucket-qualified uninstall failed with exit code $LASTEXITCODE"
}

$qualifiedOutput = (& $ScoExe uninstall local/filetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "bucket-qualified uninstall failed with exit code $LASTEXITCODE`: $qualifiedOutput"
}
if ($qualifiedOutput -notmatch "Uninstalling 'filetool' \(1\.0\.0\)\." -or $qualifiedOutput -notmatch "'filetool' was uninstalled\.") {
    throw "bucket-qualified uninstall did not normalize app name: $qualifiedOutput"
}
if (Test-Path (Join-Path $Root 'apps\filetool')) {
    throw 'bucket-qualified uninstall left filetool app directory behind'
}

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "reinstall before duplicate uninstall failed with exit code $LASTEXITCODE"
}

$duplicateOutput = (& $ScoExe uninstall filetool filetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "duplicate uninstall failed with exit code $LASTEXITCODE`: $duplicateOutput"
}
if ($duplicateOutput -notmatch "Uninstalling 'filetool' \(1\.0\.0\)\." -or $duplicateOutput -notmatch "'filetool' was uninstalled\.") {
    throw "duplicate uninstall did not uninstall filetool once: $duplicateOutput"
}
if ($duplicateOutput -match "ERROR 'filetool' isn't installed\.") {
    throw "duplicate uninstall should ignore repeated app arguments like Scoop: $duplicateOutput"
}
if (Test-Path (Join-Path $Root 'apps\filetool')) {
    throw 'duplicate uninstall left filetool app directory behind'
}

$missingOutput = (& $ScoExe uninstall missingtool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "uninstall missing app should skip with exit 0, got $LASTEXITCODE`: $missingOutput"
}
if ($missingOutput -notmatch "ERROR 'missingtool' isn't installed\.") {
    throw "uninstall missing app did not print Scoop-style error: $missingOutput"
}

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "reinstall before wrong-scope uninstall failed with exit code $LASTEXITCODE"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$wrongScopeOutput = (& $ScoExe uninstall filetool --global 2>&1) -join "`n"
$wrongScopeExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($wrongScopeExitCode -ne 0) {
        throw "wrong-scope uninstall should skip with exit 0, got $wrongScopeExitCode`: $wrongScopeOutput"
    }
    if ($wrongScopeOutput -notmatch "ERROR 'filetool' isn't installed globally, but it may be installed locally\.") {
        throw "wrong-scope uninstall did not print global/local hint: $wrongScopeOutput"
    }
    if ($wrongScopeOutput -notmatch 'WARN  Try again without the --global \(or -g\) flag instead\.') {
        throw "wrong-scope uninstall did not print retry hint: $wrongScopeOutput"
    }
} else {
    if ($wrongScopeExitCode -ne 1) {
        throw "non-admin wrong-scope uninstall --global returned $wrongScopeExitCode instead of 1: $wrongScopeOutput"
    }
    if ($wrongScopeOutput -notmatch 'ERROR You need admin rights to uninstall global apps\.') {
        throw "non-admin wrong-scope uninstall --global did not match Scoop admin error: $wrongScopeOutput"
    }
}
if (!(Test-Path (Join-Path $Root 'apps\filetool\current\filetool.exe'))) {
    throw 'wrong-scope uninstall removed the local app unexpectedly'
}

$oldVersionDir = Join-Path $Root 'apps\filetool\0.9.0'
New-Item -ItemType Directory -Force -Path $oldVersionDir | Out-Null
Set-Content -Path (Join-Path $oldVersionDir 'stale.txt') -Value 'old version' -NoNewline -Encoding Ascii
$oldVersionOutput = (& $ScoExe uninstall filetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "uninstall with old version failed with exit code $LASTEXITCODE`: $oldVersionOutput"
}
if ($oldVersionOutput -notmatch 'Removing older version \(0\.9\.0\)\.' -or
    $oldVersionOutput -notmatch "'filetool' was uninstalled\.") {
    throw "uninstall with old version did not report older version removal like Scoop: $oldVersionOutput"
}
if (Test-Path (Join-Path $Root 'apps\filetool')) {
    throw 'uninstall with old version left app root behind'
}

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "reinstall before purge uninstall failed with exit code $LASTEXITCODE"
}

$persistDir = Join-Path $Root 'persist\filetool'
New-Item -ItemType Directory -Force -Path $persistDir | Out-Null
Set-Content -Path (Join-Path $persistDir 'settings.json') -Value '{"persisted":true}' -Encoding UTF8
$purgeOutput = (& $ScoExe uninstall filetool --purge) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "purge uninstall failed with exit code $LASTEXITCODE`: $purgeOutput"
}
if ($purgeOutput -notmatch "Uninstalling 'filetool' \(1\.0\.0\)\." -or $purgeOutput -notmatch 'Removing persisted data\.' -or $purgeOutput -notmatch "'filetool' was uninstalled\.") {
    throw "purge uninstall did not print Scoop-style messages: $purgeOutput"
}
if (Test-Path $persistDir) {
    throw 'purge uninstall left persisted data behind'
}

$runningManifest = Join-Path (Split-Path -Parent $Root) 'uninstall-runningtool.json'
$runningJson = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($env:ComSpec))
    hash = ''
    bin = 'cmd.exe'
    pre_uninstall = @(
        "Set-Content -Path (Join-Path `$env:SCOOP 'running-pre-uninstall.txt') -Value 'ran' -Encoding ASCII"
    )
}
$runningJson | ConvertTo-Json | Set-Content -Path $runningManifest -Encoding UTF8

$runningInstallOutput = (& $ScoExe install $runningManifest --no-update-scoop --skip-hash-check) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install runningtool failed with exit code $LASTEXITCODE`: $runningInstallOutput"
}

$runningExe = Join-Path $Root 'apps\uninstall-runningtool\current\cmd.exe'
$process = $null
try {
    $process = Start-Process -FilePath $runningExe -ArgumentList '/d /c ping -n 30 127.0.0.1 > nul' -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    if ($process.HasExited) {
        throw 'runningtool process exited before uninstall could inspect it'
    }

    $runningOutput = (& $ScoExe uninstall uninstall-runningtool) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "uninstall with running process should skip with exit 0 like Scoop, got $LASTEXITCODE`: $runningOutput"
    }
    $runningPathPattern = [regex]::Escape((Join-Path $Root 'apps\uninstall-runningtool')) + '\\(current|1\.0\.0)\\cmd\.exe'
    if ($runningOutput -notmatch 'still running\. Close them and try again' -or
        $runningOutput -notmatch $runningPathPattern -or
        $runningOutput -match "'uninstall-runningtool' was uninstalled\.") {
        throw "uninstall with running process did not match Scoop skip behavior: $runningOutput"
    }
    if (!(Test-Path $runningExe)) {
        throw 'uninstall with running process removed the app instead of skipping'
    }
    if (!(Test-Path (Join-Path $Root 'running-pre-uninstall.txt'))) {
        throw 'uninstall with running process should run pre_uninstall before skipping like Scoop'
    }
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit()
    }
}

$runningCleanupOutput = (& $ScoExe uninstall uninstall-runningtool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "uninstall after stopping runningtool failed with exit code $LASTEXITCODE`: $runningCleanupOutput"
}
