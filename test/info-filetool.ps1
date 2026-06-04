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
$manifestPath = Join-Path $bucketDir 'infotool.json'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

$manifest = [ordered]@{
    version = '1.0.0'
    description = 'Info command test tool'
    homepage = 'https://example.test/infotool/'
    license = [ordered]@{
        identifier = 'MIT'
        url = 'https://example.test/licenses/MIT'
    }
    depends = 'deptool'
    env_add_path = @('bin', '.')
    env_set = [ordered]@{
        INFOTOOL_HOME = '$dir\data'
        INFOTOOL_MODE = 'test'
    }
    notes = @('first note in $dir', 'original at $original_dir', 'persisted at $persist_dir')
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(
        'filetool.exe',
        @('filetool.exe', 'infocli')
    )
    shortcuts = @(
        , @('filetool.exe', 'Info Tool')
    )
}
$manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

$depManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$depManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'deptool.json') -Encoding UTF8

$numberLicenseManifest = [ordered]@{
    version = '1.0.0'
    license = 1
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$numberLicenseManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'numberlicensetool.json') -Encoding UTF8

$numericIdentifierLicenseManifest = [ordered]@{
    version = '1.0.0'
    license = [ordered]@{
        identifier = 1
        url = 'https://example.test/licenses/1'
    }
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$numericIdentifierLicenseManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'numericidentifierlicensetool.json') -Encoding UTF8

$numericDescriptionManifest = [ordered]@{
    version = '1.0.0'
    description = 1
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$numericDescriptionManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'numericdescriptiontool.json') -Encoding UTF8

$numericDependsManifest = [ordered]@{
    version = '1.0.0'
    depends = 1
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$numericDependsManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'numericdependstool.json') -Encoding UTF8

$numericEnvAddPathManifest = [ordered]@{
    version = '1.0.0'
    env_add_path = 1
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$numericEnvAddPathManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'numericenvpathtool.json') -Encoding UTF8

$numericBinManifest = [ordered]@{
    version = '1.0.0'
    bin = 1
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$numericBinManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'numericbintool.json') -Encoding UTF8

$numericShortcutManifest = [ordered]@{
    version = '1.0.0'
    shortcuts = @(, @('filetool.exe', 1))
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$numericShortcutManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'numericshortcuttool.json') -Encoding UTF8

$numericNotesManifest = [ordered]@{
    version = '1.0.0'
    notes = 1
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$numericNotesManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'numericnotestool.json') -Encoding UTF8

$mixedNotesManifest = [ordered]@{
    version = '1.0.0'
    notes = @(1, 'note in $dir')
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$mixedNotesManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'mixednotestool.json') -Encoding UTF8

$urlOnlyLicenseManifest = [ordered]@{
    version = '1.0.0'
    license = [ordered]@{
        url = 'https://example.test/license'
    }
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$urlOnlyLicenseManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'urlonlylicensetool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome

function Install-GlobalInfoFixture($Name) {
    $previousScoop = $env:SCOOP
    $previousGlobal = $env:SCOOP_GLOBAL
    try {
        $env:SCOOP = $GlobalRoot
        Remove-Item Env:SCOOP_GLOBAL -ErrorAction SilentlyContinue
        $globalBucketDir = Join-Path $GlobalRoot 'buckets\main\bucket'
        New-Item -ItemType Directory -Force -Path $globalBucketDir | Out-Null
        Copy-Item -LiteralPath (Join-Path $bucketDir "$Name.json") -Destination (Join-Path $globalBucketDir "$Name.json") -Force
        & $ScoExe install $Name --no-update-scoop
    } finally {
        $env:SCOOP = $previousScoop
        $env:SCOOP_GLOBAL = $previousGlobal
    }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingInfoOutput = & $ScoExe info --verbose 2>&1
$missingInfoExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingInfoExitCode -ne 1) {
    throw "info without an app returned $missingInfoExitCode instead of 1: $missingInfoOutput"
}
$missingInfoJoined = $missingInfoOutput -join "`n"
if ($missingInfoJoined -notmatch 'Usage: sco info <app> \[options\]' -or $missingInfoJoined -match '<app> missing') {
    throw "info without an app did not match Scoop usage-only output: $missingInfoJoined"
}

$numberLicenseInfo = (& $ScoExe info numberlicensetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info with numeric license failed with exit code $LASTEXITCODE`: $numberLicenseInfo"
}
if ($numberLicenseInfo -notmatch 'License\s+:\s+1(\s|$)' -or $numberLicenseInfo -match 'spdx\.org') {
    throw "plain info should stringify numeric license without SPDX URL like Scoop: $numberLicenseInfo"
}

$numberLicenseVerboseInfo = (& $ScoExe info numberlicensetool --verbose) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "verbose info with numeric license failed with exit code $LASTEXITCODE`: $numberLicenseVerboseInfo"
}
if ($numberLicenseVerboseInfo -notmatch 'License\s+:\s+1 \(https://spdx\.org/licenses/1\.html\)') {
    throw "verbose info should stringify numeric license and add SPDX URL like Scoop: $numberLicenseVerboseInfo"
}

$numericIdentifierLicenseInfo = (& $ScoExe info numericidentifierlicensetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info with numeric license identifier failed with exit code $LASTEXITCODE`: $numericIdentifierLicenseInfo"
}
if ($numericIdentifierLicenseInfo -notmatch 'License\s+:\s+1(\s|$)' -or $numericIdentifierLicenseInfo -match 'licenses/1') {
    throw "plain info should stringify numeric structured license identifier without URL like Scoop: $numericIdentifierLicenseInfo"
}

$numericIdentifierLicenseVerboseInfo = (& $ScoExe info numericidentifierlicensetool --verbose) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "verbose info with numeric license identifier failed with exit code $LASTEXITCODE`: $numericIdentifierLicenseVerboseInfo"
}
if ($numericIdentifierLicenseVerboseInfo -notmatch 'License\s+:\s+1 \(https://example\.test/licenses/1\)') {
    throw "verbose info should stringify numeric structured license identifier and keep URL like Scoop: $numericIdentifierLicenseVerboseInfo"
}

$numericDescriptionInfo = (& $ScoExe info numericdescriptiontool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info with numeric description failed with exit code $LASTEXITCODE`: $numericDescriptionInfo"
}
if ($numericDescriptionInfo -notmatch 'Description\s+:\s+1(\s|$)') {
    throw "info should stringify numeric description like Scoop: $numericDescriptionInfo"
}

$numericDependsInfo = (& $ScoExe info numericdependstool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info with numeric depends failed with exit code $LASTEXITCODE`: $numericDependsInfo"
}
if ($numericDependsInfo -notmatch 'Dependencies\s+:\s+1(\s|$)') {
    throw "info should stringify numeric depends like Scoop: $numericDependsInfo"
}

$numericEnvPathInfo = (& $ScoExe info numericenvpathtool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info with numeric env_add_path failed with exit code $LASTEXITCODE`: $numericEnvPathInfo"
}
if ($numericEnvPathInfo -notmatch 'Path Added\s+:\s+<root>\\1(\s|$)') {
    throw "info should stringify numeric env_add_path like Scoop: $numericEnvPathInfo"
}

$numericBinInfo = (& $ScoExe info numericbintool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info with numeric bin failed with exit code $LASTEXITCODE`: $numericBinInfo"
}
if ($numericBinInfo -notmatch 'Binaries\s+:\s+1(\s|$)') {
    throw "info should stringify numeric bin like Scoop: $numericBinInfo"
}

$numericShortcutInfo = (& $ScoExe info numericshortcuttool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info with numeric shortcut name failed with exit code $LASTEXITCODE`: $numericShortcutInfo"
}
if ($numericShortcutInfo -notmatch 'Shortcuts\s+:\s+1(\s|$)') {
    throw "info should stringify numeric shortcut name like Scoop: $numericShortcutInfo"
}

$numericNotesInfo = (& $ScoExe info numericnotestool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info with numeric notes failed with exit code $LASTEXITCODE`: $numericNotesInfo"
}
if ($numericNotesInfo -notmatch 'Notes\s+:\s+1(\s|$)') {
    throw "info should stringify numeric notes like Scoop: $numericNotesInfo"
}

$mixedNotesInfo = (& $ScoExe info mixednotestool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info with mixed notes failed with exit code $LASTEXITCODE`: $mixedNotesInfo"
}
if ($mixedNotesInfo -notmatch "Notes\s+:\s+1\s+note in <root>") {
    throw "info should stringify mixed notes and substitute path tokens like Scoop: $mixedNotesInfo"
}

$urlOnlyLicenseInfo = (& $ScoExe info urlonlylicensetool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info with url-only structured license failed with exit code $LASTEXITCODE`: $urlOnlyLicenseInfo"
}
if ($urlOnlyLicenseInfo -notmatch 'License\s+:\s+@\{url=https://example\.test/license\}(\s|$)') {
    throw "plain info should stringify url-only structured license object like Scoop: $urlOnlyLicenseInfo"
}

$urlOnlyLicenseVerboseInfo = (& $ScoExe info urlonlylicensetool --verbose) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "verbose info with url-only structured license failed with exit code $LASTEXITCODE`: $urlOnlyLicenseVerboseInfo"
}
if ($urlOnlyLicenseVerboseInfo -notmatch 'License\s+:\s+@\{url=https://example\.test/license\} \(https://spdx\.org/licenses/@\{url=https://example\.test/license\}\.html\)') {
    throw "verbose info should stringify url-only structured license object like Scoop: $urlOnlyLicenseVerboseInfo"
}

& $ScoExe install infotool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$oldVersionDir = Join-Path $Root 'apps\infotool\0.9.0'
New-Item -ItemType Directory -Force -Path $oldVersionDir | Out-Null
Set-Content -Path (Join-Path $oldVersionDir 'old.txt') -Value 'old-version-data' -Encoding UTF8
$oldInstall = [ordered]@{
    bucket = 'main'
    architecture = '64bit'
}
$oldInstall | ConvertTo-Json | Set-Content -Path (Join-Path $oldVersionDir 'install.json') -Encoding UTF8
$persistDir = Join-Path $Root 'persist\infotool'
New-Item -ItemType Directory -Force -Path $persistDir | Out-Null
Set-Content -Path (Join-Path $persistDir 'settings.json') -Value '{"persisted":true}' -Encoding UTF8

$plainInfoOutput = & $ScoExe info infotool
if ($LASTEXITCODE -ne 0) {
    throw "plain info failed with exit code $LASTEXITCODE"
}
$plainInfoJoined = $plainInfoOutput -join "`n"
if ($plainInfoJoined -notmatch 'License\s+:\s+MIT') {
    throw "plain info did not show license identifier: $plainInfoJoined"
}
if ($plainInfoJoined -notmatch 'Website\s+:\s+https://example\.test/infotool\s*(\r?\n|$)' -or $plainInfoJoined -match 'Website\s+:\s+https://example\.test/infotool/') {
    throw "plain info did not trim homepage trailing slash like Scoop: $plainInfoJoined"
}
if ($plainInfoJoined -match 'licenses/MIT') {
    throw "plain info should not show structured license URL without --verbose: $plainInfoJoined"
}
if ($plainInfoJoined -notmatch 'Updated at\s+:\s+\d{4}-\d{2}-\d{2} (\d{2}:\d{2}:\d{2}|T\d{2}:\d{2}:\d{2})') {
    throw "plain info did not show manifest updated timestamp: $plainInfoJoined"
}
if ($plainInfoJoined -notmatch 'Updated by\s+:\s+\S+') {
    throw "plain info did not show manifest updater: $plainInfoJoined"
}
if ($plainInfoJoined -notmatch 'Installed\s+:\s+(0\.9\.0\s+1\.0\.0|1\.0\.0\s+0\.9\.0)') {
    throw "plain info did not list all installed versions: $plainInfoJoined"
}
if ($plainInfoJoined -notmatch 'INFOTOOL_HOME = <root>\\data' -or $plainInfoJoined -notmatch 'Path Added\s+:\s+<root>\\bin\s+<root>') {
    throw "plain info did not keep environment/path output rooted: $plainInfoJoined"
}
if ($plainInfoJoined -notmatch 'first note in <root>' -or $plainInfoJoined -notmatch 'original at <root>' -or $plainInfoJoined -notmatch 'persisted at <root>') {
    throw "plain info did not substitute notes with root placeholders: $plainInfoJoined"
}

$arch32Artifact = Join-Path $Root 'sources\arch32\filetool.exe'
$arch64Artifact = Join-Path $Root 'sources\arch64\filetool.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $arch32Artifact), (Split-Path -Parent $arch64Artifact) | Out-Null
Copy-Item -LiteralPath $Artifact -Destination $arch32Artifact -Force
Copy-Item -LiteralPath $Artifact -Destination $arch64Artifact -Force
$artifactHash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$archManifest = [ordered]@{
    version = '1.0.0'
    architecture = [ordered]@{
        '32bit' = [ordered]@{
            url = ([System.IO.Path]::GetFullPath($arch32Artifact))
            hash = $artifactHash
            bin = @(, @('filetool.exe', 'info32'))
            shortcuts = @(, @('filetool.exe', 'Info 32'))
            env_add_path = 'bin32'
            env_set = [ordered]@{ INFOTOOL_ARCH = '32bit' }
        }
        '64bit' = [ordered]@{
            url = ([System.IO.Path]::GetFullPath($arch64Artifact))
            hash = $artifactHash
            bin = @(, @('filetool.exe', 'info64'))
            shortcuts = @(, @('filetool.exe', 'Info 64'))
            env_add_path = 'bin64'
            env_set = [ordered]@{ INFOTOOL_ARCH = '64bit' }
        }
    }
}
$archManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'infoarch.json') -Encoding UTF8

& $ScoExe install infoarch --arch 32bit --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install infoarch --arch 32bit failed with exit code $LASTEXITCODE"
}
$archInfoOutput = & $ScoExe info infoarch
if ($LASTEXITCODE -ne 0) {
    throw "info installed 32bit architecture app failed with exit code $LASTEXITCODE`: $archInfoOutput"
}
$archInfoJoined = $archInfoOutput -join "`n"
foreach ($pattern in @(
    'Binaries\s+:\s+info32\.exe',
    'Shortcuts\s+:\s+Info 32',
    'INFOTOOL_ARCH = 32bit',
    'Path Added\s+:\s+<root>\\bin32'
)) {
    if ($archInfoJoined -notmatch $pattern) {
        throw "info did not use installed 32bit architecture for pattern '$pattern': $archInfoJoined"
    }
}
foreach ($pattern in @('info64', 'Info 64', 'INFOTOOL_ARCH = 64bit', 'bin64')) {
if ($archInfoJoined -match $pattern) {
        throw "info leaked default 64bit architecture data '$pattern' for installed 32bit app: $archInfoJoined"
    }
}

$scopeManifest = [ordered]@{
    version = '1.0.0'
    description = 'Both-scope info command test tool'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    env_set = [ordered]@{ SCOPEINFO_HOME = '$dir\data' }
    bin = @(, @('filetool.exe', 'scopeinfotool'))
}
$scopeManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'scopeinfotool.json') -Encoding UTF8

& $ScoExe install scopeinfotool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "local both-scope info fixture install failed with exit code $LASTEXITCODE"
}
Install-GlobalInfoFixture 'scopeinfotool'
if ($LASTEXITCODE -ne 0) {
    throw "global both-scope info fixture install failed with exit code $LASTEXITCODE"
}

$bothScopeInfo = & $ScoExe info scopeinfotool --verbose
if ($LASTEXITCODE -ne 0) {
    throw "both-scope info failed with exit code $LASTEXITCODE`: $bothScopeInfo"
}
$bothScopeJoined = $bothScopeInfo -join "`n"
$expectedGlobalAppPath = ([regex]::Escape(([System.IO.Path]::GetFullPath((Join-Path $GlobalRoot 'apps\scopeinfotool\1.0.0'))).Replace('\', '/')))
$unexpectedLocalAppPath = ([regex]::Escape(([System.IO.Path]::GetFullPath((Join-Path $Root 'apps\scopeinfotool\1.0.0'))).Replace('\', '/')))
if ($bothScopeJoined -notmatch 'Installed\s+:\s+.*/apps/scopeinfotool/1\.0\.0' -or
    $bothScopeJoined -notmatch [regex]::Escape($GlobalRoot.Replace('\', '/')) -or
    $bothScopeJoined -notmatch 'SCOPEINFO_HOME = .*[\\/]apps[\\/]scopeinfotool[\\/]current[\\/]data') {
    throw "info should prefer global install when both scopes exist like Scoop: $bothScopeJoined"
}
if ($bothScopeJoined -match $unexpectedLocalAppPath -or $bothScopeJoined -notmatch $expectedGlobalAppPath) {
    throw "both-scope info mixed local/global paths: $bothScopeJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$infoUnknownOutput = & $ScoExe info -z infotool 2>&1
$infoUnknownExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($infoUnknownExitCode -ne 1) {
    throw "info -z returned $infoUnknownExitCode instead of 1: $infoUnknownOutput"
}
if (($infoUnknownOutput -join "`n") -notmatch 'sco info: Option -z not recognized\.') {
    throw "info -z did not match Scoop getopt error: $infoUnknownOutput"
}

$extraArgInfoOutput = & $ScoExe info infotool ignored-extra
if ($LASTEXITCODE -ne 0) {
    throw "info with an extra positional argument failed with exit code $LASTEXITCODE`: $extraArgInfoOutput"
}
$extraArgInfoJoined = $extraArgInfoOutput -join "`n"
if ($extraArgInfoJoined -notmatch 'Name\s+:\s+infotool' -or $extraArgInfoJoined -match 'ignored-extra') {
    throw "info did not ignore extra positional arguments like Scoop: $extraArgInfoJoined"
}

$infoOutput = & $ScoExe info -v -- infotool
if ($LASTEXITCODE -ne 0) {
    throw "info failed with exit code $LASTEXITCODE"
}

$joined = $infoOutput -join "`n"
foreach ($pattern in @(
    'Name\s+:\s+infotool',
    'Description\s+:\s+Info command test tool',
    'Version\s+:\s+1\.0\.0',
    'Source\s+:\s+main',
    'Website\s+:\s+https://example\.test/infotool',
    'License\s+:\s+MIT \(https://example\.test/licenses/MIT\)',
    'Dependencies\s+:\s+deptool',
    'Updated at\s+:\s+\d{4}-\d{2}-\d{2} (\d{2}:\d{2}:\d{2}|T\d{2}:\d{2}:\d{2})',
    'Updated by\s+:\s+\S+',
    'Manifest\s+:\s+.*/buckets/main/bucket/infotool\.json',
    'Installed\s+:\s+.*/apps/infotool/1\.0\.0\s+.*/apps/infotool/0\.9\.0',
    'Installed size\s+:\s+Current version:\s+\d+(\.\d)? [KMG]?B',
    'Binaries\s+:\s+filetool\.exe \| infocli\.exe',
    'Shortcuts\s+:\s+Info Tool',
    'Environment\s+:',
    'INFOTOOL_HOME = .*apps.infotool.current.data',
    'INFOTOOL_MODE = test',
    'Path Added\s+:',
    'apps.infotool.current.bin',
    'Old versions:\s+\d+(\.\d)? [KMG]?B',
    'Persisted data:\s+\d+(\.\d)? [KMG]?B',
    'Total:\s+\d+(\.\d)? [KMG]?B',
    'first note in .*apps.infotool.current',
    'original at .*apps.infotool.1\.0\.0',
    'persisted at .*persist.infotool'
)) {
    if ($joined -notmatch $pattern) {
        throw "info output missing pattern '$pattern': $joined"
    }
}

$deprecatedDir = Join-Path $Root 'buckets\main\deprecated'
New-Item -ItemType Directory -Force -Path $deprecatedDir | Out-Null
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $deprecatedDir 'infotool.json') -Force

$deprecatedInfoOutput = & $ScoExe info infotool --verbose
if ($LASTEXITCODE -ne 0) {
    throw "deprecated info failed with exit code $LASTEXITCODE`: $deprecatedInfoOutput"
}
$deprecatedInfoJoined = $deprecatedInfoOutput -join "`n"
if ($deprecatedInfoJoined -notmatch 'Name\s+:\s+infotool \(DEPRECATED\)' -or $deprecatedInfoJoined -notmatch 'Manifest\s+:\s+.*/buckets/main/deprecated/infotool\.json') {
    throw "info did not report deprecated installed app metadata: $deprecatedInfoJoined"
}

Remove-Item -LiteralPath $manifestPath -Force
$deprecatedOnlyInfoOutput = & $ScoExe info infotool --verbose
if ($LASTEXITCODE -ne 0) {
    throw "deprecated-only info failed with exit code $LASTEXITCODE`: $deprecatedOnlyInfoOutput"
}
$deprecatedOnlyInfoJoined = $deprecatedOnlyInfoOutput -join "`n"
if ($deprecatedOnlyInfoJoined -notmatch 'Name\s+:\s+infotool \(DEPRECATED\)' -or $deprecatedOnlyInfoJoined -notmatch 'Manifest\s+:\s+.*/buckets/main/deprecated/infotool\.json') {
    throw "info did not resolve deprecated manifest after bucket manifest removal: $deprecatedOnlyInfoJoined"
}

if (Test-Path $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifestPath) | Out-Null

$standaloneManifest = Join-Path (Split-Path -Parent $Root) 'standaloneinfo.json'
$standalone = [ordered]@{
    version = '1.0.0'
    description = 'Standalone info command test tool'
    homepage = 'https://example.test/standaloneinfo'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$standalone | ConvertTo-Json | Set-Content -Path $standaloneManifest -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe install $standaloneManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "standalone install failed with exit code $LASTEXITCODE"
}

$standaloneInfo = & $ScoExe info standaloneinfo --verbose
if ($LASTEXITCODE -ne 0) {
    throw "info installed standalone failed with exit code $LASTEXITCODE`: $standaloneInfo"
}
$standaloneJoined = $standaloneInfo -join "`n"
foreach ($pattern in @(
    'Name\s+:\s+standaloneinfo',
    'Description\s+:\s+Standalone info command test tool',
    'Source\s+:\s+.*/standaloneinfo\.json',
    'Manifest\s+:\s+.*/standaloneinfo\.json',
    'Installed\s+:\s+.*/apps/standaloneinfo/1\.0\.0'
)) {
    if ($standaloneJoined -notmatch $pattern) {
        throw "installed standalone info output missing pattern '$pattern': $standaloneJoined"
    }
}

$alternateStandaloneDir = Join-Path (Split-Path -Parent $Root) 'alternate-standalone-source'
New-Item -ItemType Directory -Force -Path $alternateStandaloneDir | Out-Null
$alternateStandaloneManifest = Join-Path $alternateStandaloneDir 'standaloneinfo.json'
$standalone.version = '9.9.9'
$standalone.description = 'Alternate standalone info command test tool'
$standalone | ConvertTo-Json | Set-Content -Path $alternateStandaloneManifest -Encoding UTF8

$alternateStandaloneInfo = & $ScoExe info $alternateStandaloneManifest --verbose
if ($LASTEXITCODE -ne 0) {
    throw "info alternate standalone manifest failed with exit code $LASTEXITCODE`: $alternateStandaloneInfo"
}
$alternateStandaloneJoined = $alternateStandaloneInfo -join "`n"
if ($alternateStandaloneJoined -notmatch 'Name\s+:\s+standaloneinfo' -or
    $alternateStandaloneJoined -notmatch 'Version\s+:\s+9\.9\.9' -or
    $alternateStandaloneJoined -notmatch 'Source\s+:\s+.*/alternate-standalone-source/standaloneinfo\.json') {
    throw "alternate standalone info did not describe the queried manifest source: $alternateStandaloneJoined"
}
if ($alternateStandaloneJoined -match 'Installed\s+:' -or $alternateStandaloneJoined -match 'Path\s+:') {
    throw "alternate standalone info should not report installed state for a different manifest source: $alternateStandaloneJoined"
}

Remove-Item -LiteralPath (Join-Path $Root 'apps\standaloneinfo') -Recurse -Force
$uninstalledStandaloneInfo = & $ScoExe info $standaloneManifest --verbose
if ($LASTEXITCODE -ne 0) {
    throw "info uninstalled standalone manifest failed with exit code $LASTEXITCODE`: $uninstalledStandaloneInfo"
}
$uninstalledStandaloneJoined = $uninstalledStandaloneInfo -join "`n"
if ($uninstalledStandaloneJoined -notmatch 'Download size\s+:\s+\d+(\.\d)? [KMG]?B') {
    throw "uninstalled standalone info did not show local artifact download size: $uninstalledStandaloneJoined"
}
if ($uninstalledStandaloneJoined -match 'Installed\s+:') {
    throw "uninstalled standalone info should not report installed versions: $uninstalledStandaloneJoined"
}

$remoteManifest = Join-Path (Split-Path -Parent $Root) 'remote-info.json'
$listenerPrefix = 'http://127.0.0.1:18194/'
$standalone.description = 'Remote info command test tool'
$standalone.homepage = 'https://example.test/remoteinfo'
$standalone.url = $listenerPrefix + 'remote-artifact.exe'
$standalone.hash = ''
$standalone | ConvertTo-Json | Set-Content -Path $remoteManifest -Encoding UTF8

$job = Start-Job -ScriptBlock {
    param($Prefix, $File)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    try {
        for ($i = 0; $i -lt 2; $i++) {
            $context = $listener.GetContext()
            if ($context.Request.HttpMethod -eq 'HEAD' -and $context.Request.Url.AbsolutePath -eq '/remote-artifact.exe') {
                $context.Response.StatusCode = 200
                $context.Response.ContentLength64 = 12345
                $context.Response.OutputStream.Close()
            } else {
                $bytes = [System.IO.File]::ReadAllBytes($File)
                $context.Response.StatusCode = 200
                $context.Response.ContentType = 'application/json'
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList $listenerPrefix, $remoteManifest

Start-Sleep -Milliseconds 300
try {
    $remoteInfo = & $ScoExe info ($listenerPrefix + 'remoteinfo.json') --verbose
    if ($LASTEXITCODE -ne 0) {
        throw "info manifest URL failed with exit code $LASTEXITCODE`: $remoteInfo"
    }
    $remoteJoined = $remoteInfo -join "`n"
    foreach ($pattern in @(
        'Name\s+:\s+remoteinfo',
        'Description\s+:\s+Remote info command test tool',
        'Source\s+:\s+http://127\.0\.0\.1:18194/remoteinfo\.json',
        'Manifest\s+:\s+.*/cache/remote-manifests/.*/remoteinfo\.json',
        'Download size\s+:\s+12\.1 KB'
    )) {
        if ($remoteJoined -notmatch $pattern) {
            throw "remote info output missing pattern '$pattern': $remoteJoined"
        }
    }
} finally {
    Wait-Job $job -Timeout 5 | Out-Null
    Receive-Job $job | Out-Null
    Remove-Job $job -Force
}
