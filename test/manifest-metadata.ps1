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
$manifestPath = Join-Path $bucketDir 'metatool.json'
$envFile = Join-Path $Root 'env.json'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

$manifest = [ordered]@{
    version = '1.0.0'
    description = 'Manifest metadata test tool'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
    psmodule = [ordered]@{
        name = 'MetaModule'
    }
    suggest = [ordered]@{
        editor = @('vim', 'nano')
        shell = 'pwsh'
    }
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:SCOOP_ENV_FILE = $envFile

$summary = (& $ScoExe manifest $manifestPath) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "manifest failed with exit code $LASTEXITCODE`: $summary"
}
foreach ($pattern in @('psmodule: 1', 'suggest: 2')) {
    if ($summary -notmatch $pattern) {
        throw "manifest summary missing '$pattern': $summary"
    }
}

$info = (& $ScoExe info metatool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info failed with exit code $LASTEXITCODE`: $info"
}
foreach ($pattern in @(
    'PowerShell module\s+:\s+MetaModule',
    'Suggestions\s+:\s+vim \| nano \| pwsh'
)) {
    if ($info -notmatch $pattern) {
        throw "info output missing '$pattern': $info"
    }
}
if ($info -match 'editor:' -or $info -match 'shell:') {
    throw "info suggestions should not include feature names like Scoop: $info"
}

$installOutput = (& $ScoExe install metatool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE`: $installOutput"
}
foreach ($pattern in @(
    "Adding .+modules.* to your PowerShell module path\.",
    "Installing PowerShell module 'MetaModule'",
    "Linking .+MetaModule.+=>.+metatool.+current",
    "'metatool' suggests installing 'vim' or 'nano'\.",
    "'metatool' suggests installing 'pwsh'\."
)) {
    if ($installOutput -notmatch $pattern) {
        throw "install output missing suggestion '$pattern': $installOutput"
    }
}

$modulePath = Join-Path $Root 'modules\MetaModule'
if (!(Test-Path $modulePath)) {
    throw 'install did not create PowerShell module link'
}
if (!(Test-Path (Join-Path $modulePath 'manifest.json'))) {
    throw 'PowerShell module link does not expose app current files'
}

$envJson = Get-Content $envFile -Raw | ConvertFrom-Json
$expectedModulesDir = [System.IO.Path]::GetFullPath((Join-Path $Root 'modules')).TrimEnd('\')
$expectedDefaultModulesDir = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules')).TrimEnd('\')
$modulePathEntries = @([string]$envJson.PSModulePath -split ';' | Where-Object { $_ })
if ($modulePathEntries.Count -lt 1 -or $modulePathEntries[0].TrimEnd('\') -ne $expectedModulesDir) {
    throw "PSModulePath did not start with modules dir. Expected $expectedModulesDir, got $($envJson.PSModulePath)"
}
if ($modulePathEntries.Count -lt 2 -or $modulePathEntries[1].TrimEnd('\') -ne $expectedDefaultModulesDir) {
    throw "PSModulePath did not preserve the default user module path. Expected second entry $expectedDefaultModulesDir, got $($envJson.PSModulePath)"
}

& $ScoExe reset metatool
if ($LASTEXITCODE -ne 0) {
    throw "reset failed with exit code $LASTEXITCODE"
}
if (!(Test-Path (Join-Path $modulePath 'install.json'))) {
    throw 'reset did not preserve PowerShell module link to current app files'
}

$uninstallOutput = (& $ScoExe uninstall metatool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "uninstall failed with exit code $LASTEXITCODE`: $uninstallOutput"
}
if ($uninstallOutput -notmatch "Uninstalling PowerShell module 'MetaModule'\." -or
    $uninstallOutput -notmatch 'Removing .+MetaModule') {
    throw "uninstall did not report PowerShell module removal like Scoop: $uninstallOutput"
}
if (Test-Path $modulePath) {
    throw 'uninstall did not remove PowerShell module link'
}

$stringSuggestManifestPath = Join-Path $bucketDir 'stringsuggesttool.json'
$stringSuggestManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
    suggest = 'pwsh'
}
$stringSuggestManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $stringSuggestManifestPath -Encoding UTF8

$stringSuggestInfo = (& $ScoExe info stringsuggesttool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info should ignore non-object suggest like Scoop, got exit code $LASTEXITCODE`: $stringSuggestInfo"
}
if ($stringSuggestInfo -match 'Suggestions') {
    throw "info should not report suggestions for non-object suggest like Scoop: $stringSuggestInfo"
}

$stringSuggestInstallOutput = (& $ScoExe install stringsuggesttool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install should ignore non-object suggest like Scoop, got exit code $LASTEXITCODE`: $stringSuggestInstallOutput"
}
if ($stringSuggestInstallOutput -match 'suggests installing') {
    throw "install should not print suggestions for non-object suggest like Scoop: $stringSuggestInstallOutput"
}
& $ScoExe uninstall stringsuggesttool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall stringsuggesttool failed with exit code $LASTEXITCODE"
}

$numericSuggestManifestPath = Join-Path $bucketDir 'numericsuggesttool.json'
$numericSuggestManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
    suggest = [ordered]@{
        runtime = 1
    }
}
$numericSuggestManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $numericSuggestManifestPath -Encoding UTF8

$numericSuggestInfo = (& $ScoExe info numericsuggesttool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info should stringify numeric suggest value like Scoop, got exit code $LASTEXITCODE`: $numericSuggestInfo"
}
if ($numericSuggestInfo -notmatch 'Suggestions\s+:\s+1(\s|$)') {
    throw "info should report numeric suggest value as a string like Scoop: $numericSuggestInfo"
}

$numericSuggestInstallOutput = (& $ScoExe install numericsuggesttool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install should stringify numeric suggest value like Scoop, got exit code $LASTEXITCODE`: $numericSuggestInstallOutput"
}
if ($numericSuggestInstallOutput -notmatch "'numericsuggesttool' suggests installing '1'\.") {
    throw "install should print numeric suggest value as a string like Scoop: $numericSuggestInstallOutput"
}
& $ScoExe uninstall numericsuggesttool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall numericsuggesttool failed with exit code $LASTEXITCODE"
}

$resetModuleManifestPath = Join-Path $bucketDir 'resetmoduletool.json'
function Write-ResetModuleManifest($Version, $ModuleName) {
    $resetModuleManifest = [ordered]@{
        version = $Version
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        bin = 'filetool.exe'
        psmodule = [ordered]@{
            name = $ModuleName
        }
    }
    $resetModuleManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $resetModuleManifestPath -Encoding UTF8
}

Write-ResetModuleManifest '1.0.0' 'ResetModuleOne'
& $ScoExe install resetmoduletool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install resetmoduletool failed with exit code $LASTEXITCODE"
}
if (!(Test-Path (Join-Path $Root 'modules\ResetModuleOne'))) {
    throw 'install did not create initial reset module link'
}

Write-ResetModuleManifest '2.0.0' 'ResetModuleTwo'
$resetModuleUpdateOutput = (& $ScoExe update resetmoduletool --no-cache) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "update resetmoduletool failed with exit code $LASTEXITCODE`: $resetModuleUpdateOutput"
}
if (!(Test-Path (Join-Path $Root 'modules\ResetModuleTwo')) -or (Test-Path (Join-Path $Root 'modules\ResetModuleOne'))) {
    throw "update should switch PowerShell module from ResetModuleOne to ResetModuleTwo: $resetModuleUpdateOutput"
}

$resetModuleOutput = (& $ScoExe reset resetmoduletool@1.0.0) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "reset resetmoduletool failed with exit code $LASTEXITCODE`: $resetModuleOutput"
}
if ($resetModuleOutput -match 'PowerShell module' -or
    !(Test-Path (Join-Path $Root 'modules\ResetModuleTwo')) -or
    (Test-Path (Join-Path $Root 'modules\ResetModuleOne'))) {
    throw "reset should not uninstall or install PowerShell modules like Scoop: $resetModuleOutput"
}

& $ScoExe uninstall resetmoduletool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall resetmoduletool failed with exit code $LASTEXITCODE"
}
Remove-Item -LiteralPath (Join-Path $Root 'modules\ResetModuleTwo') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $Root 'modules\ResetModuleOne') -Recurse -Force -ErrorAction SilentlyContinue

$archMetaManifestPath = Join-Path $bucketDir 'archmetatool.json'
$archMetaManifest = [ordered]@{
    version = '1.0.0'
    description = 'Top-level metadata test tool'
    homepage = 'https://example.test/top/'
    license = 'MIT'
    notes = 'top note in $dir'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
    psmodule = [ordered]@{
        name = 'TopModule'
    }
    suggest = [ordered]@{
        shell = 'pwsh'
    }
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            description = 'Architecture metadata test tool'
            homepage = 'https://example.test/arch/'
            license = 'GPL-3.0-only'
            notes = 'arch note in $dir'
            psmodule = [ordered]@{
                name = 'ArchModule'
            }
            suggest = [ordered]@{
                vcs = 'git'
            }
        }
    }
}
$archMetaManifest | ConvertTo-Json -Depth 7 | Set-Content -Path $archMetaManifestPath -Encoding UTF8

$archMetaInfo = (& $ScoExe info archmetatool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info for architecture metadata fixture failed with exit code $LASTEXITCODE`: $archMetaInfo"
}
if ($archMetaInfo -notmatch 'PowerShell module\s+:\s+TopModule' -or
    $archMetaInfo -notmatch 'Suggestions\s+:\s+pwsh' -or
    $archMetaInfo -notmatch 'Description\s+:\s+Top-level metadata test tool' -or
    $archMetaInfo -notmatch 'Website\s+:\s+https://example\.test/top' -or
    $archMetaInfo -notmatch 'License\s+:\s+MIT' -or
    $archMetaInfo -notmatch 'top note in <root>' -or
    $archMetaInfo -match 'ArchModule|git|Architecture metadata|example\.test/arch|GPL-3\.0-only|arch note') {
    throw "info should use top-level metadata like Scoop: $archMetaInfo"
}

$archMetaInstallOutput = (& $ScoExe install archmetatool --no-update-scoop) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "install for architecture metadata fixture failed with exit code $LASTEXITCODE`: $archMetaInstallOutput"
}
if ($archMetaInstallOutput -notmatch "Installing PowerShell module 'TopModule'" -or
    $archMetaInstallOutput -match 'ArchModule' -or
    $archMetaInstallOutput -notmatch "'archmetatool' suggests installing 'pwsh'\." -or
    $archMetaInstallOutput -match "'archmetatool' suggests installing 'git'\." -or
    $archMetaInstallOutput -notmatch 'top note in .+apps\\archmetatool\\current' -or
    $archMetaInstallOutput -match 'arch note') {
    throw "install should use top-level metadata like Scoop: $archMetaInstallOutput"
}
if (!(Test-Path (Join-Path $Root 'modules\TopModule'))) {
    throw 'install did not create top-level PowerShell module link'
}
if (Test-Path (Join-Path $Root 'modules\ArchModule')) {
    throw 'install should not create architecture-specific PowerShell module link'
}

& $ScoExe uninstall archmetatool
if ($LASTEXITCODE -ne 0) {
    throw "uninstall for architecture metadata fixture failed with exit code $LASTEXITCODE"
}

$badModuleManifestPath = Join-Path $bucketDir 'badmoduletool.json'
$badModuleManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
    psmodule = [ordered]@{}
}
$badModuleManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $badModuleManifestPath -Encoding UTF8

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$badModuleOutput = & $ScoExe install badmoduletool --no-update-scoop 2>&1
$badModuleExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badModuleExitCode -ne 1) {
    throw "install with psmodule missing name returned $badModuleExitCode instead of 1: $badModuleOutput"
}
if (($badModuleOutput -join "`n") -notmatch "Invalid manifest: The 'name' property is missing from 'psmodule'\.") {
    throw "install with psmodule missing name did not match Scoop error: $badModuleOutput"
}
if (Test-Path (Join-Path $Root 'apps\badmoduletool')) {
    throw 'install with psmodule missing name created an app directory'
}

$badStringModuleManifestPath = Join-Path $bucketDir 'badstringmoduletool.json'
$badStringModuleManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
    psmodule = 'MetaModule'
}
$badStringModuleManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $badStringModuleManifestPath -Encoding UTF8

$ErrorActionPreference = 'Continue'
$badStringModuleOutput = & $ScoExe install badstringmoduletool --no-update-scoop 2>&1
$badStringModuleExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badStringModuleExitCode -ne 1) {
    throw "install with non-object psmodule returned $badStringModuleExitCode instead of 1: $badStringModuleOutput"
}
if (($badStringModuleOutput -join "`n") -notmatch "Invalid manifest: The 'name' property is missing from 'psmodule'\.") {
    throw "install with non-object psmodule did not match Scoop missing-name error: $badStringModuleOutput"
}
if (Test-Path (Join-Path $Root 'apps\badstringmoduletool')) {
    throw 'install with non-object psmodule created an app directory'
}
