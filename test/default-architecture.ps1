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
$manifestPath = Join-Path $bucketDir 'archtool.json'
$markerDir = Join-Path $Root 'markers'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

function Convert-InstallArchitectureKeyToUpper {
    param([Parameter(Mandatory = $true)][string]$Path)

    $installJson = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $rewritten = [ordered]@{}
    foreach ($property in $installJson.PSObject.Properties) {
        if ($property.Name -eq 'architecture') {
            $rewritten['Architecture'] = $property.Value
        } else {
            $rewritten[$property.Name] = $property.Value
        }
    }
    $rewritten | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$artifact64 = Join-Path $Root 'sources\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $artifact64) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $artifact64 -Force

$manifest = [ordered]@{
    version = '1.0.0'
    architecture = [ordered]@{
        '32bit' = [ordered]@{
            url = ([System.IO.Path]::GetFullPath($ArtifactV1))
            hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
            post_uninstall = "Set-Content -Path '$($markerDir.Replace('\', '\\'))\archtool-uninstall.txt' -Value 32bit -NoNewline -Encoding Ascii"
        }
        '64bit' = [ordered]@{
            url = ([System.IO.Path]::GetFullPath($artifact64))
            hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
            post_uninstall = "Set-Content -Path '$($markerDir.Replace('\', '\\'))\archtool-uninstall.txt' -Value 64bit -NoNewline -Encoding Ascii"
        }
    }
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

$unsupportedManifest = [ordered]@{
    version = '1.0.0'
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            pre_install = "Set-Content -Path (Join-Path `$dir 'marker.txt') -Value unsupported -Encoding Ascii"
        }
    }
}
$unsupportedManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'unsupportedarchtool.json') -Encoding UTF8

$emptyArchFallbackManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            url = ''
            hash = ''
        }
    }
    bin = 'filetool.exe'
}
$emptyArchFallbackManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'emptyarchfallbacktool.json') -Encoding UTF8

$singleEmptyArrayArchFallbackManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            url = @('')
            hash = @('')
        }
    }
    bin = 'filetool.exe'
}
$singleEmptyArrayArchFallbackManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'singleemptyarrayarchfallbacktool.json') -Encoding UTF8

$falsyArchitectureManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    architecture = ''
    bin = 'filetool.exe'
}
$falsyArchitectureManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'falsyarchitecturetool.json') -Encoding UTF8

$falsySelectedArchitectureManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    architecture = [ordered]@{
        '64bit' = ''
    }
    bin = 'filetool.exe'
}
$falsySelectedArchitectureManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'falsyselectedarchitecturetool.json') -Encoding UTF8

$arm64NullManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            url = ([System.IO.Path]::GetFullPath($artifact64))
            hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        }
        arm64 = $null
    }
    bin = 'filetool.exe'
}
$arm64NullManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'arm64nulltool.json') -Encoding UTF8

$arm64LiteralManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($ArtifactV1))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    notes = @('arm64')
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            url = ([System.IO.Path]::GetFullPath($artifact64))
            hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        }
    }
    bin = 'filetool.exe'
}
$arm64LiteralManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'arm64literaltool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe config default_architecture x86
if ($LASTEXITCODE -ne 0) {
    throw "config default_architecture failed with exit code $LASTEXITCODE"
}

& $ScoExe install archtool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install using default_architecture failed with exit code $LASTEXITCODE"
}

$install = Get-Content (Join-Path $Root 'apps\archtool\current\install.json') -Raw | ConvertFrom-Json
if ($install.architecture -ne '32bit') {
    throw "install did not normalize default_architecture x86 to 32bit: $($install | ConvertTo-Json -Compress)"
}

$content = Get-Content (Join-Path $Root 'apps\archtool\current\filetool.exe') -Raw
if ($content -notmatch 'fixture') {
    throw "install did not select 32bit artifact from default_architecture: $content"
}

$listOutput = & $ScoExe list
if ($LASTEXITCODE -ne 0) {
    throw "list after default_architecture install failed with exit code $LASTEXITCODE`: $listOutput"
}
if (($listOutput -join "`n") -match 'archtool.*32bit') {
    throw "list treated normalized default_architecture x86 as non-default architecture: $listOutput"
}

& $ScoExe uninstall archtool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall before explicit arch install failed with exit code $LASTEXITCODE"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$unsupportedInstallOutput = & $ScoExe install unsupportedarchtool --arch x64 --no-update-scoop 2>&1
$unsupportedInstallExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($unsupportedInstallExit -eq 0) {
    throw "install unsupported architecture unexpectedly succeeded: $unsupportedInstallOutput"
}
if (($unsupportedInstallOutput -join "`n") -notmatch "doesn't support current architecture") {
    throw "install unsupported architecture did not emit Scoop-style error: $unsupportedInstallOutput"
}
if (Test-Path (Join-Path $Root 'apps\unsupportedarchtool')) {
    throw 'install unsupported architecture created an app layout'
}

& $ScoExe install emptyarchfallbacktool --arch x64 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install did not fall back from empty architecture-specific URL to the top-level URL"
}

$emptyFallbackInstall = Get-Content (Join-Path $Root 'apps\emptyarchfallbacktool\current\install.json') -Raw | ConvertFrom-Json
if ($emptyFallbackInstall.architecture -ne '64bit') {
    throw "empty architecture-specific URL fallback did not preserve requested architecture: $($emptyFallbackInstall | ConvertTo-Json -Compress)"
}
$emptyFallbackContent = Get-Content (Join-Path $Root 'apps\emptyarchfallbacktool\current\filetool.exe') -Raw
if ($emptyFallbackContent -notmatch 'fixture') {
    throw "empty architecture-specific URL fallback did not install top-level artifact: $emptyFallbackContent"
}
& $ScoExe uninstall emptyarchfallbacktool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall empty architecture fallback tool failed with exit code $LASTEXITCODE"
}

& $ScoExe install singleemptyarrayarchfallbacktool --arch x64 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install did not fall back from single-empty-array architecture-specific URL to the top-level URL"
}

$singleEmptyArrayFallbackInstall = Get-Content (Join-Path $Root 'apps\singleemptyarrayarchfallbacktool\current\install.json') -Raw | ConvertFrom-Json
if ($singleEmptyArrayFallbackInstall.architecture -ne '64bit') {
    throw "single-empty-array architecture fallback did not preserve requested architecture: $($singleEmptyArrayFallbackInstall | ConvertTo-Json -Compress)"
}
$singleEmptyArrayFallbackContent = Get-Content (Join-Path $Root 'apps\singleemptyarrayarchfallbacktool\current\filetool.exe') -Raw
if ($singleEmptyArrayFallbackContent -notmatch 'fixture') {
    throw "single-empty-array architecture fallback did not install top-level artifact: $singleEmptyArrayFallbackContent"
}
& $ScoExe uninstall singleemptyarrayarchfallbacktool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall single-empty-array architecture fallback tool failed with exit code $LASTEXITCODE"
}

foreach ($falsyArchitectureTool in @('falsyarchitecturetool', 'falsyselectedarchitecturetool')) {
    & $ScoExe install $falsyArchitectureTool --arch x64 --no-update-scoop
    if ($LASTEXITCODE -ne 0) {
        throw "install did not fall back from falsy architecture metadata for $falsyArchitectureTool"
    }

    $falsyArchitectureInstall = Get-Content (Join-Path $Root "apps\$falsyArchitectureTool\current\install.json") -Raw | ConvertFrom-Json
    if ($falsyArchitectureInstall.architecture -ne '64bit') {
        throw "falsy architecture metadata did not preserve requested architecture for ${falsyArchitectureTool}: $($falsyArchitectureInstall | ConvertTo-Json -Compress)"
    }
    $falsyArchitectureContent = Get-Content (Join-Path $Root "apps\$falsyArchitectureTool\current\filetool.exe") -Raw
    if ($falsyArchitectureContent -notmatch 'fixture') {
        throw "falsy architecture metadata did not install top-level artifact for ${falsyArchitectureTool}: $falsyArchitectureContent"
    }
    & $ScoExe uninstall $falsyArchitectureTool
    if ($LASTEXITCODE -ne 0) {
        throw "uninstall falsy architecture metadata tool failed for $falsyArchitectureTool"
    }
}

& $ScoExe install arm64nulltool --arch arm64 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install arm64 null marker tool failed with exit code $LASTEXITCODE"
}
$arm64NullInstall = Get-Content (Join-Path $Root 'apps\arm64nulltool\current\install.json') -Raw | ConvertFrom-Json
if ($arm64NullInstall.architecture -ne 'arm64') {
    throw "arm64 null marker did not preserve requested architecture: $($arm64NullInstall | ConvertTo-Json -Compress)"
}
$arm64NullContent = Get-Content (Join-Path $Root 'apps\arm64nulltool\current\filetool.exe') -Raw
if ($arm64NullContent -notmatch 'fixture') {
    throw "arm64 null marker should use top-level artifact instead of falling back: $arm64NullContent"
}
& $ScoExe uninstall arm64nulltool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall arm64 null marker tool failed with exit code $LASTEXITCODE"
}

& $ScoExe install arm64literaltool --arch arm64 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install arm64 literal marker tool failed with exit code $LASTEXITCODE"
}
$arm64LiteralInstall = Get-Content (Join-Path $Root 'apps\arm64literaltool\current\install.json') -Raw | ConvertFrom-Json
if ($arm64LiteralInstall.architecture -ne 'arm64') {
    throw "arm64 literal marker did not preserve requested architecture: $($arm64LiteralInstall | ConvertTo-Json -Compress)"
}
$arm64LiteralContent = Get-Content (Join-Path $Root 'apps\arm64literaltool\current\filetool.exe') -Raw
if ($arm64LiteralContent -notmatch 'fixture') {
    throw "arm64 literal marker should use top-level artifact instead of falling back: $arm64LiteralContent"
}
& $ScoExe uninstall arm64literaltool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall arm64 literal marker tool failed with exit code $LASTEXITCODE"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$unsupportedDownloadOutput = & $ScoExe download unsupportedarchtool --arch x64 --force 2>&1
$unsupportedDownloadExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($unsupportedDownloadExit -ne 0) {
    throw "download unsupported architecture returned $unsupportedDownloadExit instead of Scoop's non-fatal 0: $unsupportedDownloadOutput"
}
if (($unsupportedDownloadOutput -join "`n") -notmatch "doesn't support current architecture") {
    throw "download unsupported architecture did not emit Scoop-style error: $unsupportedDownloadOutput"
}
$unsupportedCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'unsupportedarchtool#1.0.0#*' -ErrorAction SilentlyContinue)
if ($unsupportedCacheFiles.Count -ne 0) {
    throw 'download unsupported architecture created a cache entry'
}

& $ScoExe install archtool --arch arm64 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install --arch arm64 fallback failed with exit code $LASTEXITCODE"
}

$expectedArm64Fallback = if ([System.Environment]::OSVersion.Version.Build -ge 22000) { '64bit' } else { '32bit' }
$install = Get-Content (Join-Path $Root 'apps\archtool\current\install.json') -Raw | ConvertFrom-Json
if ($install.architecture -ne $expectedArm64Fallback) {
    throw "install --arch arm64 did not record Scoop fallback architecture ${expectedArm64Fallback}: $($install | ConvertTo-Json -Compress)"
}

$content = Get-Content (Join-Path $Root 'apps\archtool\current\filetool.exe') -Raw
$expectedArm64Content = if ($expectedArm64Fallback -eq '64bit') { 'v2' } else { 'fixture' }
if ($content -notmatch $expectedArm64Content) {
    throw "install --arch arm64 did not select fallback ${expectedArm64Fallback} artifact: $content"
}

Remove-Item -LiteralPath (Join-Path $Root 'cache') -Recurse -Force -ErrorAction SilentlyContinue
$downloadOutput = & $ScoExe download archtool --arch arm64 --force
if ($LASTEXITCODE -ne 0) {
    throw "download --arch arm64 fallback failed with exit code $LASTEXITCODE`: $downloadOutput"
}
$cacheFile = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'archtool#1.0.0#*' | Select-Object -First 1)
if ($cacheFile.Count -ne 1) {
    throw "download --arch arm64 did not create one cache artifact"
}
$cacheContent = Get-Content -LiteralPath $cacheFile[0].FullName -Raw
if ($cacheContent -notmatch $expectedArm64Content) {
    throw "download --arch arm64 selected wrong fallback ${expectedArm64Fallback} artifact: $cacheContent"
}

& $ScoExe uninstall archtool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall before explicit x64 install failed with exit code $LASTEXITCODE"
}

& $ScoExe install archtool --arch x64 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install --arch x64 failed with exit code $LASTEXITCODE"
}

$install = Get-Content (Join-Path $Root 'apps\archtool\current\install.json') -Raw | ConvertFrom-Json
if ($install.architecture -ne '64bit') {
    throw "install did not normalize --arch x64 to 64bit: $($install | ConvertTo-Json -Compress)"
}

$content = Get-Content (Join-Path $Root 'apps\archtool\current\filetool.exe') -Raw
if ($content -notmatch 'v2') {
    throw "install --arch x64 did not select 64bit artifact: $content"
}

$archtoolInstallPath = Join-Path $Root 'apps\archtool\current\install.json'
Convert-InstallArchitectureKeyToUpper -Path $archtoolInstallPath

& $ScoExe config default_architecture x86
if ($LASTEXITCODE -ne 0) {
    throw "config default_architecture before update failed with exit code $LASTEXITCODE"
}

$artifact64v2 = Join-Path $Root 'sources-v2\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $artifact64v2) | Out-Null
Copy-Item -LiteralPath $ArtifactV2 -Destination $artifact64v2 -Force

$manifest.version = '1.1.0'
$manifest.architecture.'64bit'.url = ([System.IO.Path]::GetFullPath($artifact64v2))
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

& $ScoExe update archtool --no-cache
if ($LASTEXITCODE -ne 0) {
    throw "update should reuse installed architecture failed with exit code $LASTEXITCODE"
}

$install = Get-Content (Join-Path $Root 'apps\archtool\current\install.json') -Raw | ConvertFrom-Json
if ($install.architecture -ne '64bit') {
    throw "update did not reuse installed 64bit architecture: $($install | ConvertTo-Json -Compress)"
}

$content = Get-Content (Join-Path $Root 'apps\archtool\current\filetool.exe') -Raw
if ($content -notmatch 'v2') {
    throw "update reused default architecture instead of installed 64bit architecture: $content"
}

Convert-InstallArchitectureKeyToUpper -Path $archtoolInstallPath

New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
Remove-Item -LiteralPath (Join-Path $markerDir 'archtool-uninstall.txt') -Force -ErrorAction SilentlyContinue
& $ScoExe uninstall archtool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall after 64bit update failed with exit code $LASTEXITCODE"
}
$uninstallArch = Get-Content (Join-Path $markerDir 'archtool-uninstall.txt') -Raw
if ($uninstallArch -ne '64bit') {
    throw "uninstall did not reuse installed 64bit architecture: $uninstallArch"
}
