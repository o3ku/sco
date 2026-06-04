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
$manifestPath = Join-Path $bucketDir 'scripttool.json'
$markerDir = Join-Path $Root 'markers'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

$marker = $markerDir.Replace('\', '\\')
$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    installer = [ordered]@{
        script = @(
            "New-Item -ItemType Directory -Force -Path '$marker' | Out-Null",
            "Set-Content -Path (Join-Path '$marker' 'installer.txt') -Value `$app -NoNewline -Encoding Ascii",
            "Set-Content -Path (Join-Path '$marker' 'installer_global.txt') -Value `$global -NoNewline -Encoding Ascii"
        )
    }
    pre_uninstall = @(
        "New-Item -ItemType Directory -Force -Path '$marker' | Out-Null",
        "Set-Content -Path (Join-Path '$marker' 'pre_uninstall.txt') -Value `$version -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path '$marker' 'pre_uninstall_dir.txt') -Value `$dir -NoNewline -Encoding Ascii"
    )
    uninstaller = [ordered]@{
        script = @(
            "Set-Content -Path (Join-Path '$marker' 'uninstaller.txt') -Value `$app -NoNewline -Encoding Ascii",
            "Set-Content -Path (Join-Path '$marker' 'uninstaller_dir.txt') -Value `$dir -NoNewline -Encoding Ascii"
        )
    }
    post_uninstall = @(
        "Set-Content -Path (Join-Path '$marker' 'post_uninstall.txt') -Value `$architecture -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path '$marker' 'post_uninstall_dir.txt') -Value `$dir -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path '$marker' 'post_uninstall_dir_exists.txt') -Value (Test-Path -LiteralPath `$dir) -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path '$marker' 'post_uninstall_global.txt') -Value `$global -NoNewline -Encoding Ascii"
    )
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe install scripttool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$installer = Get-Content (Join-Path $markerDir 'installer.txt') -Raw
if ($installer -ne 'scripttool') {
    throw "installer.script did not run with app context: $installer"
}
$installerGlobal = Get-Content (Join-Path $markerDir 'installer_global.txt') -Raw
if ($installerGlobal -ne 'False') {
    throw "installer.script did not expose Scoop-style global context: $installerGlobal"
}
if (Test-Path (Join-Path $Root 'apps\scripttool\1.0.0\_hooks')) {
    throw 'installer.script left helper files in the app directory'
}

& $ScoExe uninstall scripttool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall failed with exit code $LASTEXITCODE"
}

$expected = @{
    'pre_uninstall.txt' = '1.0.0'
    'uninstaller.txt' = 'scripttool'
    'post_uninstall.txt' = '64bit'
    'post_uninstall_dir_exists.txt' = 'False'
    'post_uninstall_global.txt' = 'False'
}
foreach ($item in $expected.GetEnumerator()) {
    $path = Join-Path $markerDir $item.Key
    if (!(Test-Path $path)) {
        throw "Missing uninstall script marker: $path"
    }
    $content = Get-Content $path -Raw
    if ($content -ne $item.Value) {
        throw "Unexpected marker content for $($item.Key): $content"
    }
}

$expectedVersionDir = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\scripttool\1.0.0'))
foreach ($name in @('pre_uninstall_dir.txt', 'uninstaller_dir.txt', 'post_uninstall_dir.txt')) {
    $content = Get-Content (Join-Path $markerDir $name) -Raw
    if ([System.IO.Path]::GetFullPath($content) -ne $expectedVersionDir) {
        throw "Uninstall hook $name used '$content' instead of version directory '$expectedVersionDir'"
    }
}

if (Test-Path (Join-Path $Root 'apps\scripttool')) {
    throw 'uninstall left app directory'
}
