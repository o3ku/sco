param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome,
    [Parameter(Mandatory = $true)][string]$ArtifactV1,
    [Parameter(Mandatory = $true)][string]$ArtifactV2
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

$manifestDir = Join-Path $Root 'manifests'
New-Item -ItemType Directory -Force -Path $manifestDir | Out-Null
$sourceDir = Join-Path $Root 'sources'
New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null

$firstSource = Join-Path $sourceDir 'first\filetool.exe'
$secondSource = Join-Path $sourceDir 'second\filetool.exe'
$thirdSource = Join-Path $sourceDir 'third\filetool.exe'
$firstScriptSource = Join-Path $sourceDir 'first-script\scripttool.ps1'
$secondScriptSource = Join-Path $sourceDir 'second-script\scripttool.ps1'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $firstSource) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $secondSource) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $thirdSource) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $firstScriptSource) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $secondScriptSource) | Out-Null
Copy-Item -LiteralPath $ArtifactV1 -Destination $firstSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $secondSource -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $thirdSource -Force
Set-Content -Path $firstScriptSource -Value 'Write-Output first-script' -Encoding Ascii
Set-Content -Path $secondScriptSource -Value 'Write-Output second-script' -Encoding Ascii

function Write-Manifest($Name, $Version, $Artifact, $Hash, $ShimName = 'sharedtool') {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        bin = @(, @('filetool.exe', $ShimName))
    }
    $path = Join-Path $manifestDir "$Name.json"
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $path -Encoding UTF8
    $path
}

function Write-ScriptManifest($Name, $Version, $Artifact) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = ''
        bin = @(, @('scripttool.ps1', 'sharedscript'))
    }
    $path = Join-Path $manifestDir "$Name.json"
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $path -Encoding UTF8
    $path
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:PATH = "$(Join-Path $Root 'shims');$env:PATH"

$firstManifest = Write-Manifest 'firsttool' '1.0.0' $firstSource '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$secondManifest = Write-Manifest 'secondtool' '2.0.0' $secondSource 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
$thirdManifest = Write-Manifest 'thirdtool' '3.0.0' $thirdSource '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$rmFirstManifest = Write-Manifest 'rmfirsttool' '1.0.0' $firstSource '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b' 'rmsharedtool'
$rmSecondManifest = Write-Manifest 'rmsecondtool' '2.0.0' $secondSource 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824' 'rmsharedtool'
$firstScriptManifest = Write-ScriptManifest 'firstscript' '1.0.0' $firstScriptSource
$secondScriptManifest = Write-ScriptManifest 'secondscript' '2.0.0' $secondScriptSource

& $ScoExe install $firstManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install firsttool failed with exit code $LASTEXITCODE"
}
& $ScoExe install $secondManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install secondtool failed with exit code $LASTEXITCODE"
}

$activeShim = Join-Path $Root 'shims\sharedtool.shim'
$activeShimExe = Join-Path $Root 'shims\sharedtool.exe'
$firstAlternative = Join-Path $Root 'shims\sharedtool.shim.firsttool'
$firstExeAlternative = Join-Path $Root 'shims\sharedtool.exe.firsttool'
if (!(Test-Path $activeShim) -or !(Test-Path $activeShimExe) -or !(Test-Path $firstAlternative) -or !(Test-Path $firstExeAlternative)) {
    throw 'installing duplicate shim providers did not preserve an alternative shim'
}

$info = & $ScoExe shim info sharedtool
if ($LASTEXITCODE -ne 0) {
    throw "shim info sharedtool failed with exit code $LASTEXITCODE"
}
$joined = $info -join "`n"
if ($joined -notmatch 'Source: secondtool' -or $joined -notmatch 'Alternatives: firsttool secondtool') {
    throw "shim info did not report alternatives: $joined"
}

$expectedSecond = ([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\secondtool\current\filetool.exe'))).Replace('\', '/')
$which = (& $ScoExe which sharedtool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or $which -ne $expectedSecond) {
    throw "sharedtool should initially point at secondtool: $which"
}

& $ScoExe shim alter sharedtool firsttool
if ($LASTEXITCODE -ne 0) {
    throw "shim alter failed with exit code $LASTEXITCODE"
}

$expectedFirst = ([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\firsttool\current\filetool.exe'))).Replace('\', '/')
$which = (& $ScoExe which sharedtool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or $which -ne $expectedFirst) {
    throw "sharedtool did not switch to firsttool: $which"
}

& $ScoExe install $rmFirstManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install rmfirsttool failed with exit code $LASTEXITCODE"
}
& $ScoExe install $rmSecondManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install rmsecondtool failed with exit code $LASTEXITCODE"
}

$expectedRmSecond = ([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\rmsecondtool\current\filetool.exe'))).Replace('\', '/')
$whichRm = (& $ScoExe which rmsharedtool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or $whichRm -ne $expectedRmSecond) {
    throw "rmsharedtool should initially point at rmsecondtool: $whichRm"
}

& $ScoExe shim rm rmsharedtool
if ($LASTEXITCODE -ne 0) {
    throw "shim rm for duplicate provider failed with exit code $LASTEXITCODE"
}

$expectedRmFirst = ([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\rmfirsttool\current\filetool.exe'))).Replace('\', '/')
$whichRm = (& $ScoExe which rmsharedtool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or $whichRm -ne $expectedRmFirst) {
    throw "shim rm did not promote the latest alternative like Scoop: $whichRm"
}
if (!(Test-Path (Join-Path $Root 'shims\rmsharedtool.shim')) -or !(Test-Path (Join-Path $Root 'shims\rmsharedtool.exe'))) {
    throw 'shim rm did not leave a promoted native shim active'
}

$info = & $ScoExe shim alter sharedtool
if ($LASTEXITCODE -ne 0) {
    throw "shim alter listing failed with exit code $LASTEXITCODE"
}
$joined = $info -join "`n"
if ($joined -notmatch '\* firsttool' -or $joined -notmatch '  secondtool') {
    throw "shim alter listing did not show active alternative: $joined"
}

Start-Sleep -Milliseconds 1200
& $ScoExe shim alter sharedtool secondtool
if ($LASTEXITCODE -ne 0) {
    throw "shim alter back to secondtool failed with exit code $LASTEXITCODE"
}

Start-Sleep -Milliseconds 1200
& $ScoExe install $thirdManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install thirdtool failed with exit code $LASTEXITCODE"
}

$expectedThird = ([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\thirdtool\current\filetool.exe'))).Replace('\', '/')
$which = (& $ScoExe which sharedtool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or $which -ne $expectedThird) {
    throw "sharedtool should point at thirdtool before uninstall: $which"
}

& $ScoExe uninstall thirdtool --purge
if ($LASTEXITCODE -ne 0) {
    throw "uninstall thirdtool failed with exit code $LASTEXITCODE"
}

$which = (& $ScoExe which sharedtool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or $which -ne $expectedSecond) {
    throw "uninstall did not restore the latest shim alternative like Scoop: $which"
}

& $ScoExe install $firstScriptManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install firstscript failed with exit code $LASTEXITCODE"
}
& $ScoExe install $secondScriptManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install secondscript failed with exit code $LASTEXITCODE"
}

$activePs1Shim = Join-Path $Root 'shims\sharedscript.ps1'
$activeCmdShim = Join-Path $Root 'shims\sharedscript.cmd'
$activeShellShim = Join-Path $Root 'shims\sharedscript'
$firstPs1Alternative = Join-Path $Root 'shims\sharedscript.ps1.firstscript'
$firstCmdAlternative = Join-Path $Root 'shims\sharedscript.cmd.firstscript'
$firstShellAlternative = Join-Path $Root 'shims\sharedscript.firstscript'
if (!(Test-Path $activePs1Shim) -or !(Test-Path $activeCmdShim) -or !(Test-Path $activeShellShim) -or !(Test-Path $firstPs1Alternative) -or !(Test-Path $firstCmdAlternative) -or !(Test-Path $firstShellAlternative)) {
    throw 'installing duplicate PowerShell shim providers did not preserve paired alternatives'
}

$scriptInfo = & $ScoExe shim info sharedscript
if ($LASTEXITCODE -ne 0) {
    throw "shim info sharedscript failed with exit code $LASTEXITCODE"
}
$scriptInfoJoined = $scriptInfo -join "`n"
if ($scriptInfoJoined -notmatch 'Source: secondscript' -or $scriptInfoJoined -notmatch 'Alternatives: firstscript secondscript') {
    throw "shim info did not report PowerShell alternatives: $scriptInfoJoined"
}

$expectedSecondScript = ([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\secondscript\current\scripttool.ps1'))).Replace('\', '/')
$whichScript = (& $ScoExe which sharedscript).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or $whichScript -ne $expectedSecondScript) {
    throw "sharedscript should initially point at secondscript: $whichScript"
}

& $ScoExe shim alter sharedscript firstscript
if ($LASTEXITCODE -ne 0) {
    throw "PowerShell shim alter failed with exit code $LASTEXITCODE"
}

$expectedFirstScript = ([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\firstscript\current\scripttool.ps1'))).Replace('\', '/')
$whichScript = (& $ScoExe which sharedscript).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or $whichScript -ne $expectedFirstScript) {
    throw "sharedscript did not switch to firstscript: $whichScript"
}
$activeCmdContent = Get-Content $activeCmdShim -Raw
if ($activeCmdContent -notmatch [regex]::Escape($expectedFirstScript.Replace('/', '\'))) {
    throw "PowerShell shim alter did not switch cmd companion: $activeCmdContent"
}
$activeShellContent = Get-Content $activeShellShim -Raw
if ($activeShellContent -notmatch [regex]::Escape($expectedFirstScript.Replace('/', '\'))) {
    throw "PowerShell shim alter did not switch shell companion: $activeShellContent"
}

& $ScoExe uninstall firstscript --purge
if ($LASTEXITCODE -ne 0) {
    throw "uninstall firstscript failed with exit code $LASTEXITCODE"
}
$whichScript = (& $ScoExe which sharedscript).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or $whichScript -ne $expectedSecondScript) {
    throw "uninstall did not restore PowerShell shim alternative: $whichScript"
}
if (!(Test-Path $activeCmdShim)) {
    throw 'uninstall did not restore PowerShell shim cmd companion'
}
if (!(Test-Path $activeShellShim)) {
    throw 'uninstall did not restore PowerShell shim shell companion'
}
