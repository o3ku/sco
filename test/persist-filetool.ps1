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

$bucketDir = Join-Path $Root 'buckets\main\bucket'
$manifestPath = Join-Path $bucketDir 'persisttool.json'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

function Write-Manifest($Version, $Artifact, $Hash) {
    $manifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = $Hash
        persist = 'data'
        bin = 'filetool.exe'
        shortcuts = @(, @('filetool.exe', 'Persist Tool'))
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:SCOOP_SHORTCUT_DIR = Join-Path $Root 'shortcuts'

Write-Manifest '1.0.0' $ArtifactV1 '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$installOutput = (& $ScoExe install persisttool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE`: $installOutput"
}
if ($installOutput -notmatch 'Persisting data') {
    throw "install did not report persisted data like Scoop: $installOutput"
}
$linkIndex = $installOutput.IndexOf('Linking ')
$persistIndex = $installOutput.IndexOf('Persisting data')
if ($linkIndex -lt 0 -or $persistIndex -lt 0 -or $linkIndex -gt $persistIndex) {
    throw "install should report current link before persisted data like Scoop: $installOutput"
}

$currentData = Join-Path $Root 'apps\persisttool\current\data'
$persistData = Join-Path $Root 'persist\persisttool\data'
if (!(Test-Path $currentData)) {
    throw 'install did not create current persist data path'
}
if (!(Test-Path $persistData)) {
    throw 'install did not create persist store path'
}

Set-Content -Path (Join-Path $currentData 'settings.json') -Value '{"kept":true}' -NoNewline -Encoding Ascii
if (!(Test-Path (Join-Path $persistData 'settings.json'))) {
    throw 'writing through current persist path did not reach persist store'
}

$v2Source = Join-Path $Root 'sources\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $v2Source) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $v2Source -Force

Write-Manifest '1.1.0' $v2Source 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
$updateOutput = (& $ScoExe update persisttool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "update failed with exit code $LASTEXITCODE`: $updateOutput"
}
if ($updateOutput -notmatch 'Persisting data') {
    throw "update did not report persisted data like Scoop: $updateOutput"
}
$updateUninstallIndex = $updateOutput.IndexOf("Uninstalling 'persisttool' (1.0.0)")
$updatePersistIndex = $updateOutput.IndexOf('Persisting data')
if ($updateUninstallIndex -lt 0 -or $updatePersistIndex -lt 0 -or $updateUninstallIndex -gt $updatePersistIndex) {
    throw "update should report old uninstall before persisted data like Scoop: $updateOutput"
}

$currentSettings = Join-Path $Root 'apps\persisttool\current\data\settings.json'
if (!(Test-Path $currentSettings)) {
    throw 'updated current version did not relink persist data'
}
$content = Get-Content $currentSettings -Raw
if ($content -ne '{"kept":true}') {
    throw "persisted content changed after update: $content"
}

& $ScoExe uninstall persisttool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall failed with exit code $LASTEXITCODE"
}

if (Test-Path (Join-Path $Root 'apps\persisttool')) {
    throw 'uninstall left app directory'
}
if (!(Test-Path (Join-Path $persistData 'settings.json'))) {
    throw 'uninstall removed persisted data without purge'
}

& $ScoExe install persisttool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "reinstall before reset-link test failed with exit code $LASTEXITCODE"
}
$currentPersistPath = Join-Path $Root 'apps\persisttool\current\data'
if (Test-Path $currentPersistPath) {
    Remove-Item -LiteralPath $currentPersistPath -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $currentPersistPath | Out-Null
Set-Content -Path (Join-Path $currentPersistPath 'ordinary.txt') -Value 'ordinary-data' -Encoding Ascii

$resetOutput = (& $ScoExe reset persisttool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "reset with an ordinary persist path failed with exit code $LASTEXITCODE`: $resetOutput"
}
$resetShortcutIndex = $resetOutput.IndexOf('Creating shortcut for Persist Tool')
$resetPersistIndex = $resetOutput.IndexOf('Persisting data')
if ($resetShortcutIndex -lt 0 -or $resetPersistIndex -lt 0 -or $resetShortcutIndex -gt $resetPersistIndex) {
    throw "reset should recreate shortcuts before relinking persisted data like Scoop: $resetOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\persisttool\current\data.original\ordinary.txt'))) {
    throw 'reset did not preserve an ordinary persist path as data.original before relinking persisted data'
}

& $ScoExe install persisttool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "reinstall before purge failed with exit code $LASTEXITCODE"
}

& $ScoExe uninstall -p persisttool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall -p failed with exit code $LASTEXITCODE"
}

if (Test-Path (Join-Path $Root 'persist\persisttool')) {
    throw 'uninstall -p left persisted data directory'
}

function Assert-CurrentFalsyPersistManifestIsSkipped($Label) {
    $emptyPersistOutput = (& $ScoExe install persisttool --no-update-scoop) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "install with $Label persist failed with exit code $LASTEXITCODE`: $emptyPersistOutput"
    }
    if ($emptyPersistOutput -match 'Persisting') {
        throw "install with $Label persist should not report persisted data like Scoop: $emptyPersistOutput"
    }
    if (Test-Path (Join-Path $Root 'persist\persisttool')) {
        throw "install with $Label persist should not create a persist store"
    }

    & $ScoExe uninstall persisttool
    if ($LASTEXITCODE -ne 0) {
        throw "uninstall after $Label persist install failed with exit code $LASTEXITCODE"
    }
}

$emptyStringPersistManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    persist = ''
    bin = 'filetool.exe'
}
$emptyStringPersistManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
Assert-CurrentFalsyPersistManifestIsSkipped 'empty-string'

$emptyArrayPersistManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    persist = @('')
    bin = 'filetool.exe'
}
$emptyArrayPersistManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
Assert-CurrentFalsyPersistManifestIsSkipped 'single-empty-array'
