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
$manifestPath = Join-Path $bucketDir 'envtool.json'
$envFile = Join-Path $Root 'env.json'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'config\scoop') | Out-Null

@{ use_isolated_path = $true } | ConvertTo-Json | Set-Content -Path (Join-Path $Root 'config\scoop\config.json') -Encoding UTF8

$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    env_add_path = @('', '.', 'bin')
    pre_install = "New-Item -ItemType Directory -Force -Path (Join-Path `$dir 'bin') | Out-Null"
    installer = [ordered]@{
        script = @(
            "`$envFile = `$env:SCOOP_ENV_FILE",
            "`$envJson = if (Test-Path `$envFile) { Get-Content `$envFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }",
            "`$envJson | Add-Member -Force -NotePropertyName PATH -NotePropertyValue (`$dir + ';' + (Join-Path `$dir 'bin') + ';C:\Windows')",
            "`$envJson | ConvertTo-Json | Set-Content -Path `$envFile -Encoding UTF8"
        )
    }
    env_set = [ordered]@{
        ENVTOOL_HOME = '$dir'
        ENVTOOL_BIN = '$dir\bin'
        ENVTOOL_ORIGINAL = '$original_dir'
        ENVTOOL_PERSIST = '$persist_dir\settings'
        ENVTOOL_FROM_ENV = '$env:SCO_TEST_EXPAND'
        ENVTOOL_FROM_ENV_BRACED = '${env:SCO_TEST_EXPAND}\child'
        ENVTOOL_VERSION = '$Version'
        ENVTOOL_APP = '${APP}'
        ENVTOOL_ARCH = '$architecture'
        ENVTOOL_ESCAPED = '`$dir'
        ENVTOOL_UNKNOWN = '$directory'
        ENVTOOL_ENABLED = $true
        ENVTOOL_COUNT = 3
        ENVTOOL_EMPTY = $null
    }
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = (Join-Path $Root 'config')
$env:SCOOP_ENV_FILE = $envFile
$env:SCO_TEST_EXPAND = 'expanded-from-process-env'

$installOutput = (& $ScoExe install envtool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE`: $installOutput"
}

if (!(Test-Path $envFile)) {
    throw 'install did not write isolated environment file'
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
$expectedPath = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\envtool\current')).TrimEnd('\')
$expectedBinPath = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\envtool\current\bin')).TrimEnd('\')
$expectedOriginalPath = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\envtool\1.0.0')).TrimEnd('\')
$expectedOriginalBinPath = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\envtool\1.0.0\bin')).TrimEnd('\')
if ($installOutput -notmatch "WARN  Installer added '$([regex]::Escape($expectedOriginalPath))' to path\. Removing\." -or
    $installOutput -notmatch "WARN  Installer added '$([regex]::Escape($expectedOriginalBinPath))' to path\. Removing\.") {
    throw "install did not warn about removing installer-added PATH entries like Scoop: $installOutput"
}
$actualPath = [string]$envJson.SCOOP_PATH
$installerPath = [string]$envJson.PATH
if ($installerPath -ne '%SCOOP_PATH%;C:\Windows') {
    throw "isolated env_add_path should add %SCOOP_PATH% to PATH and remove installer-added app paths like Scoop: $installerPath"
}
$pathEntries = @($actualPath -split ';' | Where-Object { $_ })
if ($pathEntries.Count -ne 2 -or $pathEntries[0].TrimEnd('\') -ne $expectedPath -or $pathEntries[1].TrimEnd('\') -ne $expectedBinPath) {
    throw "SCOOP_PATH was not set to current app paths. Expected $expectedPath;$expectedBinPath, got $actualPath"
}
if ([string]$envJson.ENVTOOL_HOME -ne $expectedPath) {
    throw "ENVTOOL_HOME was not expanded from `$dir. Got $($envJson.ENVTOOL_HOME)"
}
if ([string]$envJson.ENVTOOL_BIN -ne $expectedBinPath) {
    throw "ENVTOOL_BIN was not expanded from `$dir\\bin. Got $($envJson.ENVTOOL_BIN)"
}
$expectedPersistSettingPath = [System.IO.Path]::GetFullPath((Join-Path $Root 'persist\envtool\settings')).TrimEnd('\')
if ([string]$envJson.ENVTOOL_ORIGINAL -ne $expectedOriginalPath) {
    throw "ENVTOOL_ORIGINAL was not expanded from `$original_dir. Got $($envJson.ENVTOOL_ORIGINAL)"
}
if ([string]$envJson.ENVTOOL_PERSIST -ne $expectedPersistSettingPath) {
    throw "ENVTOOL_PERSIST was not expanded from `$persist_dir. Got $($envJson.ENVTOOL_PERSIST)"
}
if ([string]$envJson.ENVTOOL_FROM_ENV -ne 'expanded-from-process-env') {
    throw "ENVTOOL_FROM_ENV was not expanded from `$env:SCO_TEST_EXPAND. Got $($envJson.ENVTOOL_FROM_ENV)"
}
if ([string]$envJson.ENVTOOL_FROM_ENV_BRACED -ne 'expanded-from-process-env\child') {
    throw "ENVTOOL_FROM_ENV_BRACED was not expanded from `${env:SCO_TEST_EXPAND}. Got $($envJson.ENVTOOL_FROM_ENV_BRACED)"
}
if ([string]$envJson.ENVTOOL_VERSION -ne '1.0.0') {
    throw "ENVTOOL_VERSION was not expanded from case-insensitive `$Version. Got $($envJson.ENVTOOL_VERSION)"
}
if ([string]$envJson.ENVTOOL_APP -ne 'envtool') {
    throw "ENVTOOL_APP was not expanded from braced case-insensitive `${APP}. Got $($envJson.ENVTOOL_APP)"
}
if ([string]$envJson.ENVTOOL_ARCH -ne '64bit') {
    throw "ENVTOOL_ARCH was not expanded from `$architecture. Got $($envJson.ENVTOOL_ARCH)"
}
if ([string]$envJson.ENVTOOL_ESCAPED -ne '$dir') {
    throw "ENVTOOL_ESCAPED should preserve an escaped dollar like PowerShell ExpandString. Got $($envJson.ENVTOOL_ESCAPED)"
}
if ([string]$envJson.ENVTOOL_UNKNOWN) {
    throw "unknown PowerShell variables should expand to an empty string, not partially match `$dir: $($envJson.ENVTOOL_UNKNOWN)"
}
if ([string]$envJson.ENVTOOL_ENABLED -ne 'True') {
    throw "boolean env_set value was not converted like Scoop/PowerShell: $($envJson.ENVTOOL_ENABLED)"
}
if ([string]$envJson.ENVTOOL_COUNT -ne '3') {
    throw "numeric env_set value was not converted like Scoop/PowerShell: $($envJson.ENVTOOL_COUNT)"
}
if ([string]$envJson.ENVTOOL_EMPTY) {
    throw "null env_set value was not converted to an empty string: $($envJson.ENVTOOL_EMPTY)"
}

$envJson | Add-Member -Force -NotePropertyName PATH -NotePropertyValue ($expectedPath + ';' + $expectedBinPath + ';%SCOOP_PATH%;C:\Windows')
$envJson | ConvertTo-Json | Set-Content -Path $envFile -Encoding UTF8

& $ScoExe uninstall envtool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall failed with exit code $LASTEXITCODE"
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
if ([string]$envJson.SCOOP_PATH) {
    throw "uninstall did not remove env_add_path: $($envJson.SCOOP_PATH)"
}
if ([string]$envJson.PATH -ne '%SCOOP_PATH%;C:\Windows') {
    throw "uninstall should remove app paths from PATH while keeping the isolated %SCOOP_PATH% bridge like Scoop: $($envJson.PATH)"
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_HOME') {
    throw 'uninstall did not remove env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_BIN') {
    throw 'uninstall did not remove expanded env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_ORIGINAL') {
    throw 'uninstall did not remove original_dir env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_PERSIST') {
    throw 'uninstall did not remove persist_dir env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_FROM_ENV') {
    throw 'uninstall did not remove env-expanded env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_FROM_ENV_BRACED') {
    throw 'uninstall did not remove braced env-expanded env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_VERSION') {
    throw 'uninstall did not remove version env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_APP') {
    throw 'uninstall did not remove app env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_ARCH') {
    throw 'uninstall did not remove architecture env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_ESCAPED') {
    throw 'uninstall did not remove escaped env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_UNKNOWN') {
    throw 'uninstall did not remove unknown env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_ENABLED') {
    throw 'uninstall did not remove boolean env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_COUNT') {
    throw 'uninstall did not remove numeric env_set variable'
}
if ($envJson.PSObject.Properties.Name -contains 'ENVTOOL_EMPTY') {
    throw 'uninstall did not remove null env_set variable'
}

$numericEnvManifestPath = Join-Path $bucketDir 'numericenvtool.json'
$numericEnvManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    env_add_path = 1
    pre_install = "New-Item -ItemType Directory -Force -Path (Join-Path `$dir '1') | Out-Null"
    bin = 'filetool.exe'
}
$numericEnvManifest | ConvertTo-Json | Set-Content -Path $numericEnvManifestPath -Encoding UTF8
@{ PATH = 'C:\Windows' } | ConvertTo-Json | Set-Content -Path $envFile -Encoding UTF8

$numericEnvInstallOutput = (& $ScoExe install numericenvtool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install with numeric env_add_path failed with exit code $LASTEXITCODE`: $numericEnvInstallOutput"
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
$expectedNumericEnvPath = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\numericenvtool\current\1')).TrimEnd('\')
$numericPathEntries = @([string]$envJson.SCOOP_PATH -split ';' | Where-Object { $_ })
if ($numericPathEntries.Count -ne 1 -or $numericPathEntries[0].TrimEnd('\') -ne $expectedNumericEnvPath) {
    throw "numeric env_add_path should be stringified and added like Scoop. Expected $expectedNumericEnvPath, got $($envJson.SCOOP_PATH)"
}
if ([string]$envJson.PATH -ne '%SCOOP_PATH%;C:\Windows') {
    throw "numeric env_add_path should keep isolated PATH bridge like Scoop: $($envJson.PATH)"
}

& $ScoExe uninstall numericenvtool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall after numeric env_add_path failed with exit code $LASTEXITCODE"
}

@{ use_isolated_path = 'SCOOP_CUSTOM_PATH' } | ConvertTo-Json | Set-Content -Path (Join-Path $Root 'config\scoop\config.json') -Encoding UTF8
@{ PATH = 'C:\Windows' } | ConvertTo-Json | Set-Content -Path $envFile -Encoding UTF8

$customInstallOutput = (& $ScoExe install envtool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "custom isolated path install failed with exit code $LASTEXITCODE`: $customInstallOutput"
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
if ([string]$envJson.PATH -ne '%SCOOP_CUSTOM_PATH%;C:\Windows') {
    throw "custom isolated path should bridge PATH through %SCOOP_CUSTOM_PATH%, got $($envJson.PATH)"
}
$customPathEntries = @([string]$envJson.SCOOP_CUSTOM_PATH -split ';' | Where-Object { $_ })
if ($customPathEntries.Count -ne 2 -or $customPathEntries[0].TrimEnd('\') -ne $expectedPath -or $customPathEntries[1].TrimEnd('\') -ne $expectedBinPath) {
    throw "SCOOP_CUSTOM_PATH was not set to current app paths. Expected $expectedPath;$expectedBinPath, got $($envJson.SCOOP_CUSTOM_PATH)"
}
if ([string]$envJson.SCOOP_PATH) {
    throw "custom isolated path install should not write SCOOP_PATH: $($envJson.SCOOP_PATH)"
}

& $ScoExe uninstall envtool
if ($LASTEXITCODE -ne 0) {
    throw "custom isolated path uninstall failed with exit code $LASTEXITCODE"
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
if ([string]$envJson.SCOOP_CUSTOM_PATH) {
    throw "custom isolated path uninstall did not remove env_add_path: $($envJson.SCOOP_CUSTOM_PATH)"
}
if ([string]$envJson.PATH -ne '%SCOOP_CUSTOM_PATH%;C:\Windows') {
    throw "custom isolated path uninstall should keep bridge variable in PATH like Scoop: $($envJson.PATH)"
}
