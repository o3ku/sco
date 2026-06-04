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
$manifestPath = Join-Path $bucketDir 'shortcuttool.json'
$shortcutDir = Join-Path $Root 'shortcuts'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    pre_install = "Copy-Item -LiteralPath (Join-Path `$dir 'filetool.exe') -Destination (Join-Path `$dir '1') -Force"
    shortcuts = @(
        @('filetool.exe', 'Tools\Shortcut Tool', @('--from-shortcut', '$dir', '$persist_dir')),
        @('filetool.exe', 'Tools\Numeric Arg', 1),
        @(1, 1),
        @('filetool.exe', 'Tools\Empty Icon', '', '')
    )
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:SCOOP_SHORTCUT_DIR = $shortcutDir

$installOutput = (& $ScoExe install shortcuttool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE`: $installOutput"
}
if ($installOutput -notmatch 'Creating shortcut for Tools\\Shortcut Tool \(filetool\.exe\)') {
    throw "install did not report shortcut creation like Scoop: $installOutput"
}
if ($installOutput -notmatch "Creating shortcut for Tools\\Empty Icon \(filetool\.exe\) failed: Couldn't find icon") {
    throw "install did not treat an empty shortcut icon as a missing icon like Scoop: $installOutput"
}

$shortcut = Join-Path $shortcutDir 'Tools\Shortcut Tool.lnk'
if (!(Test-Path $shortcut)) {
    throw "shortcut was not created: $shortcut"
}
$numericShortcut = Join-Path $shortcutDir 'Tools\Numeric Arg.lnk'
if (!(Test-Path $numericShortcut)) {
    throw "shortcut with numeric arguments was not created: $numericShortcut"
}
$numericTargetShortcut = Join-Path $shortcutDir '1.lnk'
if (!(Test-Path $numericTargetShortcut)) {
    throw "shortcut with numeric target and name was not created: $numericTargetShortcut"
}
if (Test-Path (Join-Path $shortcutDir 'Tools\Empty Icon.lnk')) {
    throw 'shortcut with an empty icon entry should not be created'
}

$shell = New-Object -ComObject WScript.Shell
$created = $shell.CreateShortcut($shortcut)
$expectedCurrentDir = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\shortcuttool\current'))
$expectedPersistDir = [System.IO.Path]::GetFullPath((Join-Path $Root 'persist\shortcuttool'))
$expectedShortcutArgs = "--from-shortcut $expectedCurrentDir $expectedPersistDir"
if ($created.Arguments -ne $expectedShortcutArgs) {
    throw "shortcut arguments were not set: $($created.Arguments)"
}
if ($created.TargetPath -notlike '*apps\shortcuttool\current\filetool.exe') {
    throw "shortcut target was not current filetool.exe: $($created.TargetPath)"
}
$createdNumeric = $shell.CreateShortcut($numericShortcut)
if ($createdNumeric.Arguments -ne '1') {
    throw "shortcut numeric arguments should be stringified like Scoop: $($createdNumeric.Arguments)"
}
$createdNumericTarget = $shell.CreateShortcut($numericTargetShortcut)
$expectedNumericTarget = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\shortcuttool\current\1'))
if ($createdNumericTarget.TargetPath -ne $expectedNumericTarget) {
    throw "shortcut numeric target should be stringified like Scoop. Expected $expectedNumericTarget, got $($createdNumericTarget.TargetPath)"
}

$uninstallOutput = (& $ScoExe uninstall shortcuttool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "uninstall failed with exit code $LASTEXITCODE`: $uninstallOutput"
}
if ($uninstallOutput -notmatch 'Removing shortcut .+Tools\\Shortcut Tool\.lnk') {
    throw "uninstall did not report shortcut removal like Scoop: $uninstallOutput"
}
if (Test-Path $shortcut) {
    throw "shortcut was not removed on uninstall: $shortcut"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $shortcutDir) {
    Remove-Item -LiteralPath $shortcutDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

$missingShortcutManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    shortcuts = @(
        @('missing.exe', 'Tools\Missing Target'),
        @('filetool.exe', 'Tools\Missing Icon', '', 'missing.ico')
    )
    bin = 'filetool.exe'
}
$missingShortcutManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

$missingOutput = (& $ScoExe install shortcuttool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install with missing shortcut target/icon should continue like Scoop, got exit code $LASTEXITCODE`: $missingOutput"
}
if ($missingOutput -notmatch "Creating shortcut for Tools\\Missing Target \(missing\.exe\) failed: Couldn't find" -or
    $missingOutput -notmatch "Creating shortcut for Tools\\Missing Icon \(filetool\.exe\) failed: Couldn't find icon") {
    throw "install with missing shortcut target/icon did not report Scoop-style shortcut failures: $missingOutput"
}
if (!(Test-Path (Join-Path $Root 'apps\shortcuttool\current\filetool.exe'))) {
    throw 'install with missing shortcut target/icon did not install the app'
}
foreach ($missingShortcut in @(
    (Join-Path $shortcutDir 'Tools\Missing Target.lnk'),
    (Join-Path $shortcutDir 'Tools\Missing Icon.lnk')
)) {
    if (Test-Path $missingShortcut) {
        throw "shortcut with missing target/icon should not be created: $missingShortcut"
    }
}

foreach ($falsyShortcut in @(
    [pscustomobject]@{
        Path = Join-Path $bucketDir 'emptystringshortcuttool.json'
        Value = ''
        Label = 'empty-string'
    },
    [pscustomobject]@{
        Path = Join-Path $bucketDir 'singleemptyarrayshortcuttool.json'
        Value = @('')
        Label = 'single-empty-array'
    }
)) {
    $falsyShortcutManifest = [ordered]@{
        version = '1.0.0'
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        shortcuts = $falsyShortcut.Value
        bin = 'filetool.exe'
    }
    $falsyShortcutManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $falsyShortcut.Path -Encoding UTF8

    $falsyShortcutOutput = (& $ScoExe install $falsyShortcut.Path --no-update-scoop) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "install with $($falsyShortcut.Label) shortcuts failed with exit code $LASTEXITCODE`: $falsyShortcutOutput"
    }
    if ($falsyShortcutOutput -match 'Creating shortcut') {
        throw "install with $($falsyShortcut.Label) shortcuts should not create shortcuts like Scoop: $falsyShortcutOutput"
    }
}
