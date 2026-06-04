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

function Invoke-ScoWithInput {
    param(
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string[]]$CommandArguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ScoExe
    $startInfo.Arguments = ($CommandArguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['SCOOP'] = $Root
    $startInfo.EnvironmentVariables['XDG_CONFIG_HOME'] = $ConfigHome

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Write([string]$InputText)
    $process.StandardInput.Write([System.Environment]::NewLine)
    $process.StandardInput.Flush()
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = (($stdout + $stderr) -replace "\r\n", "`n").TrimEnd()
    }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAppOutput = & $ScoExe install 2>&1
$missingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppExitCode -ne 1) {
    throw "install without an app returned $missingAppExitCode instead of 1: $missingAppOutput"
}
if (($missingAppOutput -join "`n") -notmatch 'ERROR <app> missing' -or ($missingAppOutput -join "`n") -notmatch 'Usage: sco install <app> \[options\]') {
    throw "install without an app did not match Scoop usage: $missingAppOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidArchOutput = & $ScoExe install $Manifest --ARCH mips --NO-UPDATE-SCOOP 2>&1
$invalidArchExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidArchExitCode -ne 1) {
    throw "install --ARCH mips returned $invalidArchExitCode instead of 1: $invalidArchOutput"
}
if (($invalidArchOutput -join "`n") -notmatch "ERROR: Invalid architecture: 'mips'") {
    throw "install --ARCH mips did not match Scoop architecture error: $invalidArchOutput"
}

$globalRoot = Join-Path (Split-Path -Parent $Root) 'test-filetool-global'
if (Test-Path $globalRoot) {
    Remove-Item -LiteralPath $globalRoot -Recurse -Force
}
$env:SCOOP_GLOBAL = $globalRoot
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $globalInstallOutput = & $ScoExe install $Manifest --global --no-update-scoop 2>&1
    $globalInstallExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($globalInstallExitCode -ne 1) {
        throw "install --global without admin returned $globalInstallExitCode instead of 1: $globalInstallOutput"
    }
    if (($globalInstallOutput -join "`n") -notmatch 'ERROR: you need admin rights to install global apps') {
        throw "install --global without admin did not match Scoop error: $globalInstallOutput"
    }
    if (Test-Path (Join-Path $globalRoot 'apps\filetool')) {
        throw 'install --global without admin should not create global app files'
    }
}

& $ScoExe config show_manifest true | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config show_manifest failed with exit code $LASTEXITCODE"
}

$cancelManifestInstall = Invoke-ScoWithInput -InputText 'n' -CommandArguments @('install', $Manifest, '--no-update-scoop')
$cancelOutput = $cancelManifestInstall.Output
if ($cancelManifestInstall.ExitCode -ne 0) {
    throw "cancelled show_manifest install returned $($cancelManifestInstall.ExitCode): $cancelOutput"
}
if ($cancelOutput -notmatch 'Manifest: filetool\.json' -or $cancelOutput -notmatch '"version": "1\.0\.0"' -or $cancelOutput -notmatch 'Continue installation\? \[Y/n\]:') {
    throw "show_manifest install did not display manifest and prompt: $cancelOutput"
}
if (Test-Path (Join-Path $Root 'apps\filetool')) {
    throw 'show_manifest install cancellation installed the app'
}

$acceptManifestInstall = Invoke-ScoWithInput -InputText 'y' -CommandArguments @('install', $Manifest, '--no-update-scoop')
$acceptOutput = $acceptManifestInstall.Output
if ($acceptManifestInstall.ExitCode -ne 0) {
    throw "accepted show_manifest install returned $($acceptManifestInstall.ExitCode): $acceptOutput"
}
if ($acceptOutput -notmatch "Installing 'filetool' \(1\.0\.0\) \[64bit\] from '.+filetool\.json'" -or $acceptOutput -notmatch "'filetool' \(1\.0\.0\) was installed successfully!" -or !(Test-Path (Join-Path $Root 'apps\filetool\current\filetool.exe'))) {
    throw "show_manifest install did not continue after confirmation: $acceptOutput"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$installOutput = (& $ScoExe install $Manifest --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE`: $installOutput"
}
if ($installOutput -notmatch "Installing 'filetool' \(1\.0\.0\) \[64bit\] from '.+filetool\.json'" -or
    $installOutput -notmatch 'Linking .+apps\\filetool\\current => .+apps\\filetool\\1\.0\.0' -or
    $installOutput -notmatch "'filetool' \(1\.0\.0\) was installed successfully!" -or
    $installOutput -match 'Junction created') {
    throw "install did not print Scoop-style install progress: $installOutput"
}

$versionDir = Join-Path $Root 'apps\filetool\1.0.0'
$currentDir = Join-Path $Root 'apps\filetool\current'
$cacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'filetool#1.0.0#*.exe')

foreach ($path in @(
    (Join-Path $versionDir 'filetool.exe'),
    (Join-Path $versionDir 'manifest.json'),
    (Join-Path $versionDir 'install.json'),
    (Join-Path $currentDir 'filetool.exe'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "Missing expected install output: $path"
    }
}

$nativeShimMetadata = Get-Content (Join-Path $Root 'shims\filetool.shim') -Raw
$expectedNativeShimTarget = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\filetool\current\filetool.exe')))
if ($nativeShimMetadata -notmatch "path = `"$expectedNativeShimTarget`"") {
    throw "native exe shim metadata did not point at current filetool: $nativeShimMetadata"
}

if ($cacheFiles.Count -ne 1) {
    throw "Expected exactly one cached artifact, found $($cacheFiles.Count)"
}

$install = Get-Content (Join-Path $versionDir 'install.json') -Raw | ConvertFrom-Json
if ($install.downloaded -ne $true -or $install.artifact_count -ne 1) {
    throw "install.json did not record downloaded artifact"
}
if ($install.PSObject.Properties.Name -contains 'bucket') {
    throw "standalone manifest install should not record an empty bucket source: $($install | ConvertTo-Json -Compress)"
}

[System.IO.Directory]::Delete($currentDir)
$repairFailedInstallOutput = (& $ScoExe install $Manifest --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install repair for missing current link failed with exit code $LASTEXITCODE`: $repairFailedInstallOutput"
}
if ($repairFailedInstallOutput -notmatch 'INFO  Repair previous failed installation of filetool\.' -or
    $repairFailedInstallOutput -notmatch 'Resetting filetool \(1\.0\.0\)\.' -or
    $repairFailedInstallOutput -notmatch "'filetool' \(1\.0\.0\) is already installed" -or
    !(Test-Path (Join-Path $currentDir 'filetool.exe'))) {
    throw "install should repair a previous failed layout before reporting the app installed: $repairFailedInstallOutput"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$noCacheInstallOutput = (& $ScoExe install $Manifest -K --NO-UPDATE-SCOOP) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install -K failed with exit code $LASTEXITCODE`: $noCacheInstallOutput"
}
if ($noCacheInstallOutput -notmatch 'WARN  Cache is being ignored\.' -or
    $noCacheInstallOutput -notmatch "'filetool' \(1\.0\.0\) was installed successfully!") {
    throw "install -K did not print Scoop-style progress: $noCacheInstallOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\filetool\1.0.0\filetool.exe')) -or
    !(Test-Path (Join-Path $Root 'apps\filetool\current\filetool.exe'))) {
    throw 'install -K did not install the artifact'
}
$noCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'filetool#1.0.0#*.exe' -ErrorAction SilentlyContinue)
if ($noCacheFiles.Count -ne 0) {
    throw "install --no-cache left cache entries: $($noCacheFiles.Name -join ', ')"
}
$noCacheInstall = Get-Content (Join-Path $Root 'apps\filetool\1.0.0\install.json') -Raw | ConvertFrom-Json
if ($noCacheInstall.use_cache -ne $false) {
    throw 'install -K did not record use_cache=false'
}

$binArgsManifest = Join-Path (Split-Path -Parent $Root) 'install-binargs-filetool.json'
$binArgsJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$binArgsJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $binArgsJson.url))
$binArgsJson.bin = @(, @('filetool.exe', 'binargtool', '--home "$dir" --persist "$persist_dir"'))
$binArgsJson | ConvertTo-Json -Depth 5 | Set-Content -Path $binArgsManifest -Encoding UTF8

& $ScoExe install $binArgsManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with bin args failed with exit code $LASTEXITCODE"
}
$binArgsShim = Get-Content (Join-Path $Root 'shims\binargtool.shim') -Raw
$binArgsDir = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\install-binargs-filetool\current')))
$binArgsPersist = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'persist\install-binargs-filetool')))
$expectedHomeArg = '--home "' + $binArgsDir + '"'
$expectedPersistArg = '--persist "' + $binArgsPersist + '"'
if ($binArgsShim -match '\$dir' -or $binArgsShim -match '\$persist_dir' -or $binArgsShim -notmatch $expectedHomeArg -or $binArgsShim -notmatch $expectedPersistArg) {
    throw "bin shim args did not substitute Scoop path tokens: $binArgsShim"
}

$binArrayArgsManifest = Join-Path (Split-Path -Parent $Root) 'install-binarrayargs-filetool.json'
$binArrayArgsJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$binArrayArgsJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $binArrayArgsJson.url))
$binArrayArgsJson.bin = @(, @('filetool.exe', 'binarrayargtool', @('--home', '$dir', '--persist', '$persist_dir')))
$binArrayArgsJson | ConvertTo-Json -Depth 6 | Set-Content -Path $binArrayArgsManifest -Encoding UTF8

& $ScoExe install $binArrayArgsManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with bin array args failed with exit code $LASTEXITCODE"
}
$binArrayArgsShim = Get-Content (Join-Path $Root 'shims\binarrayargtool.shim') -Raw
$binArrayArgsDir = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\install-binarrayargs-filetool\current')))
$binArrayArgsPersist = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'persist\install-binarrayargs-filetool')))
if ($binArrayArgsShim -match '\$dir' -or $binArrayArgsShim -match '\$persist_dir' -or
    $binArrayArgsShim -notmatch "--home $binArrayArgsDir" -or
    $binArrayArgsShim -notmatch "--persist $binArrayArgsPersist") {
    throw "bin shim array args did not join and substitute Scoop path tokens: $binArrayArgsShim"
}

$binNumericArgsManifest = Join-Path (Split-Path -Parent $Root) 'install-binnumericargs-filetool.json'
$binNumericArgsJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$binNumericArgsJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $binNumericArgsJson.url))
$binNumericArgsJson.bin = @(, @('filetool.exe', 'binnumericargtool', 1))
$binNumericArgsJson | ConvertTo-Json -Depth 5 | Set-Content -Path $binNumericArgsManifest -Encoding UTF8

& $ScoExe install $binNumericArgsManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with numeric bin args failed with exit code $LASTEXITCODE"
}
$binNumericArgsShim = Get-Content (Join-Path $Root 'shims\binnumericargtool.shim') -Raw
if ($binNumericArgsShim -notmatch 'args = 1(\r?\n|$)') {
    throw "bin shim numeric args should be stringified like Scoop: $binNumericArgsShim"
}

$binMixedArgsManifest = Join-Path (Split-Path -Parent $Root) 'install-binmixedargs-filetool.json'
$binMixedArgsJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$binMixedArgsJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $binMixedArgsJson.url))
$binMixedArgsJson.bin = @(, @('filetool.exe', 'binmixedargtool', @('--count', 1)))
$binMixedArgsJson | ConvertTo-Json -Depth 6 | Set-Content -Path $binMixedArgsManifest -Encoding UTF8

& $ScoExe install $binMixedArgsManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with mixed bin args failed with exit code $LASTEXITCODE"
}
$binMixedArgsShim = Get-Content (Join-Path $Root 'shims\binmixedargtool.shim') -Raw
if ($binMixedArgsShim -notmatch 'args = --count 1(\r?\n|$)') {
    throw "bin shim mixed args should be stringified and joined like Scoop: $binMixedArgsShim"
}

$psManifestRoot = Join-Path (Split-Path -Parent $Root) 'install-psbin-source'
if (Test-Path $psManifestRoot) {
    Remove-Item -LiteralPath $psManifestRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $psManifestRoot | Out-Null
$psBinScript = Join-Path $psManifestRoot 'psbintool.ps1'
Set-Content -Path $psBinScript -Value 'Write-Output ps-bin-tool' -Encoding Ascii
$psBinManifest = Join-Path (Split-Path -Parent $Root) 'install-psbin-filetool.json'
$psBinManifestJson = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($psBinScript))
    hash = ''
    bin = @(, @('psbintool.ps1', 'psbintool', '-ManifestArg'))
}
$psBinManifestJson | ConvertTo-Json -Depth 5 | Set-Content -Path $psBinManifest -Encoding UTF8

& $ScoExe install $psBinManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with PowerShell bin target failed with exit code $LASTEXITCODE"
}
$psBinShim = Get-Content (Join-Path $Root 'shims\psbintool.cmd') -Raw
$psBinPs1ShimPath = Join-Path $Root 'shims\psbintool.ps1'
$psBinShellShimPath = Join-Path $Root 'shims\psbintool'
if (!(Test-Path $psBinPs1ShimPath)) {
    throw 'install did not create PowerShell ps1 shim companion'
}
if (!(Test-Path $psBinShellShimPath)) {
    throw 'install did not create PowerShell shell shim companion'
}
$psBinPs1Shim = Get-Content $psBinPs1ShimPath -Raw
$psBinShellShim = Get-Content $psBinShellShimPath -Raw
$expectedPsBinTarget = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\install-psbin-filetool\current\psbintool.ps1')))
if ($psBinShim -notmatch 'where /q pwsh\.exe' -or
    $psBinShim -notmatch 'powershell -noprofile -ex unrestricted -file' -or
    $psBinShim -notmatch $expectedPsBinTarget -or
    $psBinShim -notmatch '-ManifestArg') {
    throw "install did not create a Scoop-style PowerShell bin shim: $psBinShim"
}
if ($psBinPs1Shim -notmatch $expectedPsBinTarget -or $psBinPs1Shim -notmatch '# source install-psbin-filetool' -or $psBinPs1Shim -notmatch '-ManifestArg') {
    throw "install did not create a Scoop-style PowerShell ps1 shim: $psBinPs1Shim"
}
if ($psBinShellShim -notmatch '#!/bin/sh' -or $psBinShellShim -notmatch $expectedPsBinTarget -or $psBinShellShim -notmatch '# source install-psbin-filetool' -or $psBinShellShim -notmatch '-ManifestArg') {
    throw "install did not create a Scoop-style PowerShell shell shim: $psBinShellShim"
}

$typedBinSourceRoot = Join-Path (Split-Path -Parent $Root) 'install-typed-bin-source'
if (Test-Path $typedBinSourceRoot) {
    Remove-Item -LiteralPath $typedBinSourceRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $typedBinSourceRoot | Out-Null
$jarBinArtifact = Join-Path $typedBinSourceRoot 'apptool.jar'
$pyBinArtifact = Join-Path $typedBinSourceRoot 'scripttool.py'
Set-Content -Path $jarBinArtifact -Value 'jar-bytes' -Encoding Ascii
Set-Content -Path $pyBinArtifact -Value 'print("script")' -Encoding Ascii
$typedBinManifest = Join-Path (Split-Path -Parent $Root) 'install-typedbin-filetool.json'
$typedBinManifestJson = [ordered]@{
    version = '1.0.0'
    url = @(
        ([System.IO.Path]::GetFullPath($jarBinArtifact)),
        ([System.IO.Path]::GetFullPath($pyBinArtifact))
    )
    hash = @('', '')
    bin = @(
        @('apptool.jar', 'jarbintool', '-JarManifestArg'),
        @('scripttool.py', 'pybintool', '-PyManifestArg')
    )
}
$typedBinManifestJson | ConvertTo-Json -Depth 5 | Set-Content -Path $typedBinManifest -Encoding UTF8

& $ScoExe install $typedBinManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with jar/py bin targets failed with exit code $LASTEXITCODE"
}
$jarBinShim = Get-Content (Join-Path $Root 'shims\jarbintool.cmd') -Raw
$pyBinShim = Get-Content (Join-Path $Root 'shims\pybintool.cmd') -Raw
$jarBinShellShim = Get-Content (Join-Path $Root 'shims\jarbintool') -Raw
$pyBinShellShim = Get-Content (Join-Path $Root 'shims\pybintool') -Raw
$expectedJarBinTarget = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\install-typedbin-filetool\current\apptool.jar')))
$expectedPyBinTarget = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\install-typedbin-filetool\current\scripttool.py')))
if ($jarBinShim -notmatch 'java -jar' -or
    $jarBinShim -notmatch $expectedJarBinTarget -or
    $jarBinShim -notmatch '-JarManifestArg' -or
    $jarBinShim -notmatch 'popd') {
    throw "install did not create a Scoop-style Java bin shim: $jarBinShim"
}
if ($pyBinShim -notmatch 'python ' -or
    $pyBinShim -notmatch $expectedPyBinTarget -or
    $pyBinShim -notmatch '-PyManifestArg') {
    throw "install did not create a Scoop-style Python bin shim: $pyBinShim"
}
if ($jarBinShellShim -notmatch '#!/bin/sh' -or
    $jarBinShellShim -notmatch 'java\.exe -jar' -or
    $jarBinShellShim -notmatch $expectedJarBinTarget -or
    $jarBinShellShim -notmatch '-JarManifestArg') {
    throw "install did not create a Scoop-style Java shell shim: $jarBinShellShim"
}
if ($pyBinShellShim -notmatch '#!/bin/sh' -or
    $pyBinShellShim -notmatch 'python\.exe' -or
    $pyBinShellShim -notmatch $expectedPyBinTarget -or
    $pyBinShellShim -notmatch '-PyManifestArg') {
    throw "install did not create a Scoop-style Python shell shim: $pyBinShellShim"
}

$pathBinToolDir = Join-Path (Split-Path -Parent $Root) 'install-path-bin-tools'
if (Test-Path $pathBinToolDir) {
    Remove-Item -LiteralPath $pathBinToolDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $pathBinToolDir | Out-Null
$pathBinTool = Join-Path $pathBinToolDir 'pathtool.cmd'
$pathPsBinTool = Join-Path $pathBinToolDir 'pathscript.ps1'
Set-Content -Path $pathBinTool -Value '@echo path-bin-tool' -Encoding Ascii
Set-Content -Path $pathPsBinTool -Value 'Write-Output path-ps-bin-tool' -Encoding Ascii
$oldPath = $env:PATH
$env:PATH = "$pathBinToolDir;$env:PATH"
try {
    $pathBinManifest = Join-Path (Split-Path -Parent $Root) 'install-pathbin-filetool.json'
    $pathBinJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
    $pathBinJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $pathBinJson.url))
    $pathBinJson.bin = @('filetool.exe', @('pathtool.cmd', 'pathbintool'), @('pathscript.ps1', 'pathpsbintool'))
    $pathBinJson | ConvertTo-Json -Depth 5 | Set-Content -Path $pathBinManifest -Encoding UTF8

    & $ScoExe install $pathBinManifest --no-update-scoop
    if ($LASTEXITCODE -ne 0) {
        throw "install with PATH bin target failed with exit code $LASTEXITCODE"
    }
    $pathBinShim = Get-Content (Join-Path $Root 'shims\pathbintool.cmd') -Raw
    $expectedPathBinTool = [regex]::Escape([System.IO.Path]::GetFullPath($pathBinTool))
    if ($pathBinShim -notmatch $expectedPathBinTool -or $pathBinShim -match 'apps\\install-pathbin-filetool\\current\\pathtool\.cmd') {
        throw "install did not resolve manifest bin target from PATH like Scoop: $pathBinShim"
    }
    $pathPsBinShim = Get-Content (Join-Path $Root 'shims\pathpsbintool.cmd') -Raw
    $pathPsBinPs1Shim = Get-Content (Join-Path $Root 'shims\pathpsbintool.ps1') -Raw
    $expectedPathPsBinTool = [regex]::Escape([System.IO.Path]::GetFullPath($pathPsBinTool))
    if ($pathPsBinShim -notmatch $expectedPathPsBinTool -or
        $pathPsBinPs1Shim -notmatch $expectedPathPsBinTool -or
        $pathPsBinShim -match 'apps\\install-pathbin-filetool\\current\\pathscript\.ps1') {
        throw "install did not resolve PowerShell manifest bin target from PATH like Scoop: $pathPsBinShim`n$pathPsBinPs1Shim"
    }
} finally {
    $env:PATH = $oldPath
}

$notesManifest = Join-Path (Split-Path -Parent $Root) 'install-notes-filetool.json'
$notesJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$notes = [ordered]@{
    version = $notesJson.version
    url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $notesJson.url))
    hash = $notesJson.hash
    bin = $notesJson.bin
    notes = @('current at $dir', 'original at $original_dir', 'persist at $persist_dir')
}
$notes | ConvertTo-Json -Depth 5 | Set-Content -Path $notesManifest -Encoding UTF8

$notesOutput = (& $ScoExe install $notesManifest --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install with notes failed with exit code $LASTEXITCODE`: $notesOutput"
}
$notesCurrent = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\install-notes-filetool\current')))
$notesOriginal = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\install-notes-filetool\1.0.0')))
$notesPersist = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'persist\install-notes-filetool')))
if ($notesOutput -notmatch "Notes`n-----" -or $notesOutput -notmatch "current at $notesCurrent" -or $notesOutput -notmatch "original at $notesOriginal" -or $notesOutput -notmatch "persist at $notesPersist") {
    throw "install did not print Scoop-style notes with substituted paths: $notesOutput"
}

$numericNotesManifest = Join-Path (Split-Path -Parent $Root) 'install-numericnotes-filetool.json'
$numericNotesJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$numericNotes = [ordered]@{
    version = $numericNotesJson.version
    url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $numericNotesJson.url))
    hash = $numericNotesJson.hash
    bin = $numericNotesJson.bin
    notes = 1
}
$numericNotes | ConvertTo-Json -Depth 5 | Set-Content -Path $numericNotesManifest -Encoding UTF8

$numericNotesOutput = (& $ScoExe install $numericNotesManifest --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install with numeric notes failed with exit code $LASTEXITCODE`: $numericNotesOutput"
}
if ($numericNotesOutput -notmatch "Notes`n-----\s+1(\s|$)") {
    throw "install should stringify numeric notes like Scoop: $numericNotesOutput"
}

foreach ($falsyManifest in @(
    [pscustomobject]@{
        Path = Join-Path (Split-Path -Parent $Root) 'install-falsy-string-filetool.json'
        Bin = ''
        Notes = ''
        Label = 'empty-string'
    },
    [pscustomobject]@{
        Path = Join-Path (Split-Path -Parent $Root) 'install-falsy-array-filetool.json'
        Bin = @('')
        Notes = @('')
        Label = 'single-empty-array'
    }
)) {
    $falsyJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
    $falsy = [ordered]@{
        version = $falsyJson.version
        url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $falsyJson.url))
        hash = $falsyJson.hash
        bin = $falsyManifest.Bin
        notes = $falsyManifest.Notes
        cookie = $falsyManifest.Bin
        env_set = $falsyManifest.Bin
        installer = $falsyManifest.Bin
        uninstaller = $falsyManifest.Bin
        psmodule = $falsyManifest.Bin
        suggest = $falsyManifest.Bin
    }
    $falsy | ConvertTo-Json -Depth 5 | Set-Content -Path $falsyManifest.Path -Encoding UTF8

    $falsyOutput = (& $ScoExe install $falsyManifest.Path --no-update-scoop) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "install with $($falsyManifest.Label) bin/notes failed with exit code $LASTEXITCODE`: $falsyOutput"
    }
    if ($falsyOutput -match "Notes`n-----") {
        throw "install with $($falsyManifest.Label) notes should not print a Notes block like Scoop: $falsyOutput"
    }
    if ($falsyOutput -match 'PowerShell module|suggests installing') {
        throw "install with $($falsyManifest.Label) falsy object fields should skip psmodule/suggest like Scoop: $falsyOutput"
    }
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$fragmentManifest = Join-Path (Split-Path -Parent $Root) 'install-fragment-filetool.json'
$fragmentJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$fragmentSource = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $fragmentJson.url))
$fragmentJson.url = "$fragmentSource#/renamed-filetool.bin"
$fragmentJson.bin = 'renamed-filetool.bin'
$fragmentJson | ConvertTo-Json -Depth 5 | Set-Content -Path $fragmentManifest -Encoding UTF8

& $ScoExe install $fragmentManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with URL fragment filename failed with exit code $LASTEXITCODE"
}

foreach ($path in @(
    (Join-Path $Root 'apps\install-fragment-filetool\1.0.0\renamed-filetool.bin'),
    (Join-Path $Root 'apps\install-fragment-filetool\current\renamed-filetool.bin'),
    (Join-Path $Root 'shims\renamed-filetool.cmd')
)) {
    if (!(Test-Path $path)) {
        throw "Missing URL fragment install output: $path"
    }
}
if (Test-Path (Join-Path $Root 'apps\install-fragment-filetool\current\filetool.exe')) {
    throw 'URL fragment install kept original artifact filename instead of forced filename'
}
$fragmentCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'install-fragment-filetool#1.0.0#*.bin')
if ($fragmentCacheFiles.Count -ne 1) {
    throw "Expected exactly one URL fragment cache artifact with forced extension, found $($fragmentCacheFiles.Count)"
}

$numericBinManifest = Join-Path (Split-Path -Parent $Root) 'install-numericbin-filetool.json'
$numericBinJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$numericBinSource = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $numericBinJson.url))
$numericBinJson.url = "$numericBinSource#/1"
$numericBinJson.bin = 1
$numericBinJson | ConvertTo-Json -Depth 5 | Set-Content -Path $numericBinManifest -Encoding UTF8

& $ScoExe install $numericBinManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with numeric bin failed with exit code $LASTEXITCODE"
}
foreach ($path in @(
    (Join-Path $Root 'apps\install-numericbin-filetool\1.0.0\1'),
    (Join-Path $Root 'apps\install-numericbin-filetool\current\1'),
    (Join-Path $Root 'shims\1.cmd')
)) {
    if (!(Test-Path $path)) {
        throw "Missing numeric bin install output: $path"
    }
}
$numericBinShim = Get-Content (Join-Path $Root 'shims\1.cmd') -Raw
$expectedNumericBinTarget = [regex]::Escape([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\install-numericbin-filetool\current\1')))
if ($numericBinShim -notmatch $expectedNumericBinTarget) {
    throw "numeric bin shim should target the stringified bin path like Scoop: $numericBinShim"
}

$typedHashManifest = Join-Path (Split-Path -Parent $Root) 'install-sha512-filetool.json'
$typedHashJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$typedHashJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $typedHashJson.url))
$typedHashJson.hash = 'sha512:5057a7ab95d0eb0e87191773763a200a119eab107d853557c5f62f9cd9273d3397da279c8e8cfd6169e59cd5dad517f91b4bffb8e7eaed062ccef3845dbaedd6'
$typedHashJson | ConvertTo-Json -Depth 5 | Set-Content -Path $typedHashManifest -Encoding UTF8

& $ScoExe install $typedHashManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install with typed sha512 hash failed with exit code $LASTEXITCODE"
}
if (!(Test-Path (Join-Path $Root 'apps\install-sha512-filetool\current\filetool.exe'))) {
    throw 'install with typed sha512 hash did not produce current filetool.exe'
}

$noHashManifest = Join-Path (Split-Path -Parent $Root) 'install-nohash-filetool.json'
$noHashJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$noHashJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $noHashJson.url))
$noHashJson.hash = ''
$noHashJson | ConvertTo-Json -Depth 5 | Set-Content -Path $noHashManifest -Encoding UTF8

$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $noHashBytes = $sha256.ComputeHash([System.IO.File]::ReadAllBytes($noHashJson.url))
    $noHashExpected = ([System.BitConverter]::ToString($noHashBytes)).Replace('-', '').ToLowerInvariant()
} finally {
    $sha256.Dispose()
}

$noHashOutput = (& $ScoExe install $noHashManifest --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install with missing hash failed with exit code $LASTEXITCODE`: $noHashOutput"
}
if ($noHashOutput -notmatch "WARN  Warning: No hash in manifest\. SHA256 for 'filetool\.exe' is:" -or
    $noHashOutput -notmatch $noHashExpected -or
    $noHashOutput -notmatch "'install-nohash-filetool' \(1\.0\.0\) was installed successfully!") {
    throw "install with missing hash did not warn with computed SHA256: $noHashOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\install-nohash-filetool\current\filetool.exe'))) {
    throw 'install with missing hash did not produce current filetool.exe'
}

$badHashManifest = Join-Path (Split-Path -Parent $Root) 'install-badhash-filetool.json'
$badHashJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$badHashJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $badHashJson.url))
$badHashJson.hash = '0000000000000000000000000000000000000000000000000000000000000000'
$badHashJson | ConvertTo-Json -Depth 5 | Set-Content -Path $badHashManifest -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$badHashOutput = & $ScoExe install $badHashManifest --no-update-scoop --no-cache 2>&1
$badHashExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badHashExitCode -ne 1) {
    throw "install with bad hash returned $badHashExitCode instead of 1: $badHashOutput"
}
$badHashJoined = $badHashOutput -join "`n"
if ($badHashJoined -match 'install error:' -or
    $badHashJoined -notmatch 'ERROR Hash check failed!' -or
    $badHashJoined -notmatch 'App:\s+install-badhash-filetool' -or
    $badHashJoined -notmatch 'First bytes:\s+66 69 6C 65 74 6F 6F 6C' -or
    $badHashJoined -notmatch 'Expected:\s+0000000000000000000000000000000000000000000000000000000000000000' -or
    $badHashJoined -notmatch "Actual:\s+$noHashExpected" -or
    $badHashJoined -notmatch 'Please contact the bucket maintainer!' -or
    $badHashJoined -match "'install-badhash-filetool' \(1\.0\.0\) was installed successfully!") {
    throw "install with bad hash did not report Scoop-style hash failure: $badHashJoined"
}
$badHashCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'install-badhash-filetool#1.0.0#*.exe' -ErrorAction SilentlyContinue)
if ($badHashCacheFiles.Count -ne 0) {
    throw "install with bad hash left bad cache entries: $($badHashCacheFiles.Name -join ', ')"
}
if (Test-Path (Join-Path $Root 'apps\install-badhash-filetool\current')) {
    throw 'install with bad hash created a current link'
}

$badHashJson.hash = $noHashExpected
$badHashJson | ConvertTo-Json -Depth 5 | Set-Content -Path $badHashManifest -Encoding UTF8
$retryFailedInstallOutput = (& $ScoExe install $badHashManifest --no-update-scoop --no-cache) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "retry after failed install returned $LASTEXITCODE`: $retryFailedInstallOutput"
}
if ($retryFailedInstallOutput -notmatch "'install-badhash-filetool' \(1\.0\.0\) was installed successfully!" -or
    $retryFailedInstallOutput -match 'is already installed') {
    throw "retry after failed install should purge partial layout instead of treating it as installed: $retryFailedInstallOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\install-badhash-filetool\current\filetool.exe')) -or
    !(Test-Path (Join-Path $Root 'apps\install-badhash-filetool\1.0.0\install.json'))) {
    throw 'retry after failed install did not create a complete app layout'
}

$postInstallFailManifest = Join-Path (Split-Path -Parent $Root) 'postfail-filetool.json'
$postInstallFailJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$postInstallFailJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $postInstallFailJson.url))
$postInstallFailJson | Add-Member -Force -NotePropertyName post_install -NotePropertyValue 'throw "post install failed intentionally"'
$postInstallFailJson | ConvertTo-Json -Depth 5 | Set-Content -Path $postInstallFailManifest -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$postInstallFailOutput = & $ScoExe install $postInstallFailManifest --no-update-scoop 2>&1
$postInstallFailExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($postInstallFailExitCode -ne 1) {
    throw "install with failing post_install returned $postInstallFailExitCode instead of 1: $postInstallFailOutput"
}
$postInstallFailJoined = $postInstallFailOutput -join "`n"
if ($postInstallFailJoined -notmatch 'post_install script failed for postfail-filetool' -or
    $postInstallFailJoined -match "'postfail-filetool' \(1\.0\.0\) was installed successfully!") {
    throw "install with failing post_install did not report a failed install: $postInstallFailJoined"
}
if (Test-Path (Join-Path $Root 'apps\postfail-filetool\1.0.0\install.json')) {
    throw 'failing post_install should not write install.json before the install is complete'
}
if (Test-Path (Join-Path $Root 'apps\postfail-filetool\1.0.0\manifest.json')) {
    throw 'failing post_install should not write manifest.json before the install is complete'
}

$postInstallFailJson.PSObject.Properties.Remove('post_install')
$postInstallFailJson | ConvertTo-Json -Depth 5 | Set-Content -Path $postInstallFailManifest -Encoding UTF8
$postInstallRetryOutput = (& $ScoExe install $postInstallFailManifest --no-update-scoop --no-cache) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "retry after failing post_install returned $LASTEXITCODE`: $postInstallRetryOutput"
}
if ($postInstallRetryOutput -notmatch 'Purging previous failed installation of postfail-filetool' -or
    $postInstallRetryOutput -match 'is already installed' -or
    $postInstallRetryOutput -notmatch "'postfail-filetool' \(1\.0\.0\) was installed successfully!") {
    throw "retry after failing post_install should purge the incomplete layout and reinstall: $postInstallRetryOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\postfail-filetool\1.0.0\install.json')) -or
    !(Test-Path (Join-Path $Root 'apps\postfail-filetool\current\filetool.exe'))) {
    throw 'retry after failing post_install did not create a complete app layout'
}

$badUrlManifest = Join-Path (Split-Path -Parent $Root) 'install-badurl-filetool.json'
$badUrlSource = Join-Path (Split-Path -Parent $Root) 'missing-artifacts\missing-filetool.exe'
$badUrlJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$badUrlJson.url = $badUrlSource
$badUrlJson.hash = ''
$badUrlJson | ConvertTo-Json -Depth 5 | Set-Content -Path $badUrlManifest -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$badUrlOutput = & $ScoExe install $badUrlManifest --no-update-scoop --no-cache 2>&1
$badUrlExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badUrlExitCode -ne 1) {
    throw "install with bad artifact URL returned $badUrlExitCode instead of 1: $badUrlOutput"
}
$badUrlJoined = $badUrlOutput -join "`n"
if ($badUrlJoined -match 'install error:' -or
    $badUrlJoined -notmatch 'local artifact does not exist:' -or
    $badUrlJoined -notmatch "ERROR URL $([regex]::Escape($badUrlSource)) is not valid" -or
    $badUrlJoined -match "'install-badurl-filetool' \(1\.0\.0\) was installed successfully!") {
    throw "install with bad artifact URL did not report Scoop-style URL failure: $badUrlJoined"
}
if (Test-Path (Join-Path $Root 'apps\install-badurl-filetool\current')) {
    throw 'install with bad artifact URL created a current link'
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$emptyVersionManifest = Join-Path (Split-Path -Parent $Root) 'install-empty-version-filetool.json'
$emptyVersionJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$emptyVersionJson.version = ''
$emptyVersionJson | ConvertTo-Json -Depth 5 | Set-Content -Path $emptyVersionManifest -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$emptyVersionOutput = & $ScoExe install $emptyVersionManifest --no-update-scoop 2>&1
$emptyVersionExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($emptyVersionExitCode -ne 1) {
    throw "install with empty manifest version returned $emptyVersionExitCode instead of 1: $emptyVersionOutput"
}
if (($emptyVersionOutput -join "`n") -notmatch "Manifest doesn't specify a version\.") {
    throw "install with empty manifest version did not match Scoop error: $emptyVersionOutput"
}
if (Test-Path (Join-Path $Root 'apps\install-empty-version-filetool')) {
    throw 'install with empty manifest version created an app directory'
}

$badVersionManifest = Join-Path (Split-Path -Parent $Root) 'install-bad-version-filetool.json'
$badVersionJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$badVersionJson.version = '1.0.0/preview'
$badVersionJson | ConvertTo-Json -Depth 5 | Set-Content -Path $badVersionManifest -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$badVersionOutput = & $ScoExe install $badVersionManifest --no-update-scoop 2>&1
$badVersionExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badVersionExitCode -ne 1) {
    throw "install with unsupported manifest version returned $badVersionExitCode instead of 1: $badVersionOutput"
}
if (($badVersionOutput -join "`n") -notmatch "Manifest version has unsupported character '/'\.") {
    throw "install with unsupported manifest version did not match Scoop error: $badVersionOutput"
}
if (Test-Path (Join-Path $Root 'apps\install-bad-version-filetool')) {
    throw 'install with unsupported manifest version created an app directory'
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$upperLocalManifest = Join-Path (Split-Path -Parent $Root) 'upperlocaltool.JSON'
$upperLocalJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$upperLocalJson.url = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $upperLocalJson.url))
$upperLocalJson | ConvertTo-Json -Depth 5 | Set-Content -Path $upperLocalManifest -Encoding UTF8

$upperLocalOutput = (& $ScoExe install $upperLocalManifest --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install from uppercase .JSON manifest path failed with exit code $LASTEXITCODE`: $upperLocalOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\upperlocaltool\current\filetool.exe'))) {
    throw 'install from uppercase .JSON manifest path did not install the expected app'
}

$urlManifest = Join-Path (Split-Path -Parent $Root) 'install-url-filetool.json'
$manifestJson = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$artifactPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Manifest) $manifestJson.url))
$manifestJson.url = $artifactPath
$manifestJson | ConvertTo-Json -Depth 5 | Set-Content -Path $urlManifest -Encoding UTF8

$listenerPrefix = 'http://127.0.0.1:18190/'
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
    $upperSchemeManifestUrl = ($listenerPrefix -replace '^http', 'HTTP') + 'filetool.json'
    & $ScoExe install $upperSchemeManifestUrl --no-update-scoop
    if ($LASTEXITCODE -ne 0) {
        throw "install from uppercase-scheme manifest URL failed with exit code $LASTEXITCODE"
    }
} finally {
    Wait-Job $job -Timeout 5 | Out-Null
    Receive-Job $job | Out-Null
    Remove-Job $job -Force
}

foreach ($path in @(
    (Join-Path $Root 'apps\filetool\current\filetool.exe'),
    (Join-Path $Root 'apps\filetool\current\manifest.json'),
    (Join-Path $Root 'shims\filetool.exe'),
    (Join-Path $Root 'shims\filetool.shim')
)) {
    if (!(Test-Path $path)) {
        throw "Missing URL install output: $path"
    }
}
