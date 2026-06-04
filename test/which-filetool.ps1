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
$pathToolDir = Join-Path (Split-Path -Parent $Root) 'test-which-path-tools'
if (Test-Path $pathToolDir) {
    Remove-Item -LiteralPath $pathToolDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $pathToolDir | Out-Null
$pathTool = Join-Path $pathToolDir 'pathtool.cmd'
Set-Content -Path $pathTool -Value '@echo path-tool' -Encoding Ascii
$pathComTool = Join-Path $pathToolDir 'pathtoolcom.com'
Set-Content -Path $pathComTool -Value 'path-com-tool' -Encoding Ascii
$pathExtOrderCom = Join-Path $pathToolDir 'pathextorder.com'
$pathExtOrderExe = Join-Path $pathToolDir 'pathextorder.exe'
$pathExtOrderBat = Join-Path $pathToolDir 'pathextorder.bat'
$pathExtOrderCmd = Join-Path $pathToolDir 'pathextorder.cmd'
Set-Content -Path $pathExtOrderCom -Value 'path-ext-com' -Encoding Ascii
Set-Content -Path $pathExtOrderExe -Value 'path-ext-exe' -Encoding Ascii
Set-Content -Path $pathExtOrderBat -Value '@echo path-ext-bat' -Encoding Ascii
Set-Content -Path $pathExtOrderCmd -Value '@echo path-ext-cmd' -Encoding Ascii
$pathScript = Join-Path $pathToolDir 'pathscriptonly.ps1'
Set-Content -Path $pathScript -Value 'Write-Output path-script' -Encoding Ascii
$explicitPathTool = Join-Path $pathToolDir 'explicitlocal.cmd'
Set-Content -Path $explicitPathTool -Value '@echo explicit-local' -Encoding Ascii
$explicitScriptFirstCmd = Join-Path $pathToolDir 'explicit-script-first.cmd'
$explicitScriptFirstPs1 = Join-Path $pathToolDir 'explicit-script-first.ps1'
Set-Content -Path $explicitScriptFirstCmd -Value '@echo explicit-cmd' -Encoding Ascii
Set-Content -Path $explicitScriptFirstPs1 -Value 'Write-Output explicit-script' -Encoding Ascii
$env:PATH = "$pathToolDir;$env:SystemRoot\System32;$env:SystemRoot"

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingCommandOutput = & $ScoExe which 2>&1
$missingCommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingCommandExitCode -ne 1) {
    throw "which without a command returned $missingCommandExitCode instead of 1: $missingCommandOutput"
}
if (($missingCommandOutput -join "`n") -notmatch 'ERROR <command> missing' -or ($missingCommandOutput -join "`n") -notmatch 'Usage: sco which <command>') {
    throw "which without a command did not match Scoop usage: $missingCommandOutput"
}

$whichHelp = (& $ScoExe which --help) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "which --help failed with exit code $LASTEXITCODE`: $whichHelp"
}
if ($whichHelp -match '--global') {
    throw "which help should not advertise a --global option: $whichHelp"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$dashCommandOutput = & $ScoExe which --global 2>&1
$dashCommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($dashCommandExitCode -ne 0) {
    throw "which --global should treat --global as a command name and return 0 like Scoop, got $dashCommandExitCode`: $dashCommandOutput"
}
if (($dashCommandOutput -join "`n") -notmatch "WARN  '--global' not found, not a scoop shim, or a broken shim\.") {
    throw "which --global did not treat --global as the command name like Scoop: $dashCommandOutput"
}

$pathWhich = (& $ScoExe which pathtool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0) {
    throw "which pathtool failed with exit code $LASTEXITCODE"
}
$expectedPathTool = ([System.IO.Path]::GetFullPath($pathTool)).Replace('\', '/')
if ($pathWhich -ne $expectedPathTool) {
    throw "which pathtool returned '$pathWhich', expected '$expectedPathTool'"
}

$pathComWhich = (& $ScoExe which pathtoolcom).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0) {
    throw "which pathtoolcom failed with exit code $LASTEXITCODE"
}
$expectedPathComTool = ([System.IO.Path]::GetFullPath($pathComTool)).Replace('\', '/')
if ($pathComWhich -ne $expectedPathComTool) {
    throw "which pathtoolcom returned '$pathComWhich', expected '$expectedPathComTool'"
}

$pathExtOrderWhich = (& $ScoExe which pathextorder).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0) {
    throw "which pathextorder failed with exit code $LASTEXITCODE"
}
$expectedPathExtOrderTool = ([System.IO.Path]::GetFullPath($pathExtOrderCom)).Replace('\', '/')
if ($pathExtOrderWhich -ne $expectedPathExtOrderTool) {
    throw "which should follow PowerShell/Get-Command PATHEXT precedence like Scoop: '$pathExtOrderWhich', expected '$expectedPathExtOrderTool'"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$pathScriptOutput = & $ScoExe which pathscriptonly 2>&1
$pathScriptExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($pathScriptExitCode -ne 0) {
    throw "which pathscriptonly returned $pathScriptExitCode instead of 0 like Scoop: $pathScriptOutput"
}
if (($pathScriptOutput -join "`n") -notmatch "WARN  'pathscriptonly' not found, not a scoop shim, or a broken shim\.") {
    throw "which pathscriptonly did not match Scoop warning for non-Application PATH command: $pathScriptOutput"
}

Push-Location -LiteralPath $pathToolDir
try {
    $explicitPathWhich = (& $ScoExe which .\explicitlocal).Trim().Replace('\', '/')
    if ($LASTEXITCODE -ne 0) {
        throw "which .\explicitlocal failed with exit code $LASTEXITCODE"
    }
    $expectedExplicitPathTool = ([System.IO.Path]::GetFullPath($explicitPathTool)).Replace('\', '/')
    if ($explicitPathWhich -ne $expectedExplicitPathTool) {
        throw "which should resolve explicit path commands like Scoop: '$explicitPathWhich', expected '$expectedExplicitPathTool'"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $explicitScriptFirstOutput = & $ScoExe which .\explicit-script-first 2>&1
    $explicitScriptFirstExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($explicitScriptFirstExitCode -ne 0) {
        throw "which .\explicit-script-first should follow PowerShell explicit-path .ps1 precedence and return 0 like Scoop, got $explicitScriptFirstExitCode`: $explicitScriptFirstOutput"
    }
    if (($explicitScriptFirstOutput -join "`n") -notmatch "WARN  '\.\\explicit-script-first' not found, not a scoop shim, or a broken shim\.") {
        throw "which .\explicit-script-first did not match Scoop warning for explicit .ps1 precedence: $explicitScriptFirstOutput"
    }
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Pop-Location
}

& $ScoExe install $Manifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$expected = ([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\filetool\current\filetool.exe'))).Replace('\', '/')

$whichOutput = & $ScoExe which filetool 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "which filetool returned $LASTEXITCODE instead of 0 like Scoop: $whichOutput"
}
if (($whichOutput -join "`n") -notmatch "WARN  'filetool' not found, not a scoop shim, or a broken shim\.") {
    throw "which filetool should not find a bare .shim file unless PowerShell can resolve a shim command: $whichOutput"
}

$whichExtraOutput = & $ScoExe which filetool ignored-extra 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "which with an extra positional argument returned $LASTEXITCODE instead of 0 like Scoop: $whichExtraOutput"
}
if (($whichExtraOutput -join "`n") -notmatch "WARN  'filetool' not found, not a scoop shim, or a broken shim\.") {
    throw "which should ignore extra positional arguments while preserving Scoop warning behavior: $whichExtraOutput"
}

$orphanAppCurrent = Join-Path $Root 'apps\orphanedwhich\current'
New-Item -ItemType Directory -Force -Path $orphanAppCurrent | Out-Null
Copy-Item -LiteralPath (Join-Path $Root 'apps\filetool\current\filetool.exe') -Destination (Join-Path $orphanAppCurrent 'filetool.exe') -Force
$orphanManifest = [ordered]@{
    version = '1.0.0'
    bin = @(, @('filetool.exe', 'orphanedwhich'))
}
$orphanManifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $orphanAppCurrent 'manifest.json') -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$orphanOutput = & $ScoExe which orphanedwhich 2>&1
$orphanExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($orphanExitCode -ne 0) {
    throw "which orphanedwhich returned $orphanExitCode instead of 0 like Scoop: $orphanOutput"
}
if (($orphanOutput -join "`n") -notmatch "WARN  'orphanedwhich' not found, not a scoop shim, or a broken shim\.") {
    throw "which orphanedwhich should not fall back to installed manifest bin entries: $orphanOutput"
}

$whichExeOutput = & $ScoExe which filetool.exe 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "which filetool.exe returned $LASTEXITCODE instead of 0 like Scoop: $whichExeOutput"
}
if (($whichExeOutput -join "`n") -notmatch "WARN  'filetool\.exe' not found, not a scoop shim, or a broken shim\.") {
    throw "which filetool.exe should not find a bare .shim file unless PowerShell can resolve a shim command: $whichExeOutput"
}

$shadowTool = Join-Path $pathToolDir 'filetool.exe'
Set-Content -Path $shadowTool -Value 'path-shadow-tool' -Encoding Ascii
$shadowWhich = (& $ScoExe which filetool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0) {
    throw "which filetool with PATH shadow failed with exit code $LASTEXITCODE"
}
$expectedShadow = ([System.IO.Path]::GetFullPath($shadowTool)).Replace('\', '/')
if ($shadowWhich -ne $expectedShadow) {
    throw "which should honor PATH precedence like Scoop: '$shadowWhich', expected '$expectedShadow'"
}
Remove-Item -LiteralPath $shadowTool -Force

Push-Location -LiteralPath $pathToolDir
try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $missingExplicitPathOutput = & $ScoExe which .\filetool.exe 2>&1
    $missingExplicitPathExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($missingExplicitPathExitCode -ne 0) {
        throw "which .\filetool.exe should not fall back to an installed shim when the explicit path is missing and should return 0 like Scoop, got $missingExplicitPathExitCode`: $missingExplicitPathOutput"
    }
    if (($missingExplicitPathOutput -join "`n") -notmatch "WARN  '\.\\filetool\.exe' not found, not a scoop shim, or a broken shim\.") {
        throw "which .\filetool.exe did not match Scoop warning for a missing explicit path: $missingExplicitPathOutput"
    }
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Pop-Location
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingOutput = & $ScoExe which missingtool 2>&1
$missingExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingExitCode -ne 0) {
    throw "which missingtool returned $missingExitCode instead of 0 like Scoop: $missingOutput"
}
if (($missingOutput -join "`n") -notmatch "WARN  'missingtool' not found, not a scoop shim, or a broken shim\.") {
    throw "which missingtool did not report Scoop-compatible warning: $missingOutput"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $GlobalRoot) {
    Remove-Item -LiteralPath $GlobalRoot -Recurse -Force
}

$previousScoop = $env:SCOOP
$previousGlobal = $env:SCOOP_GLOBAL
try {
    $env:SCOOP = $GlobalRoot
    Remove-Item Env:SCOOP_GLOBAL -ErrorAction SilentlyContinue
    & $ScoExe install $Manifest --no-update-scoop
} finally {
    $env:SCOOP = $previousScoop
    $env:SCOOP_GLOBAL = $previousGlobal
}
if ($LASTEXITCODE -ne 0) {
    throw "global fixture install failed with exit code $LASTEXITCODE"
}

$expectedGlobal = ([System.IO.Path]::GetFullPath((Join-Path $GlobalRoot 'apps\filetool\current\filetool.exe'))).Replace('\', '/')
$globalWhichOutput = & $ScoExe which filetool 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "which global-only bare .shim returned $LASTEXITCODE instead of 0 like Scoop: $globalWhichOutput"
}
if (($globalWhichOutput -join "`n") -notmatch "WARN  'filetool' not found, not a scoop shim, or a broken shim\.") {
    throw "which should not find a global-only bare .shim unless PowerShell can resolve a shim command: $globalWhichOutput"
}
