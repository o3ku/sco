param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
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

$bucketDir = Join-Path $Root 'buckets\main\bucket'
$sourceDir = Join-Path $Root 'sources'
New-Item -ItemType Directory -Force -Path $bucketDir, $sourceDir | Out-Null

$latestPage = Join-Path $sourceDir 'latest.html'
Set-Content -Path $latestPage -Value '<html><body>cmdtool 1.2.0</body></html>' -Encoding UTF8

$samePage = Join-Path $sourceDir 'same.html'
Set-Content -Path $samePage -Value '<html><body>sametool 2.0.0</body></html>' -Encoding UTF8

$replaceOnlyPage = Join-Path $sourceDir 'replaceonly.html'
Set-Content -Path $replaceOnlyPage -Value '<html><body>replaceonlytool 4.5.6</body></html>' -Encoding UTF8
$namedGroupPage = Join-Path $sourceDir 'namedgroup.html'
Set-Content -Path $namedGroupPage -Value '<html><body>namedgrouptool 7.8.9</body></html>' -Encoding UTF8
$namedReplacePage = Join-Path $sourceDir 'namedreplace.html'
Set-Content -Path $namedReplacePage -Value '<html><body>namedreplacetool 2024_06_01</body></html>' -Encoding UTF8
$urlFallbackPage = Join-Path $sourceDir 'urlfallback.html'
Set-Content -Path $urlFallbackPage -Value '<html><body>urlfallbacktool 9.9.9</body></html>' -Encoding UTF8
$stringFallbackPage = Join-Path $sourceDir 'stringfallback.html'
Set-Content -Path $stringFallbackPage -Value '<html><body>stringfallbacktool 8.8.8</body></html>' -Encoding UTF8
$sourceAliasPage = Join-Path $sourceDir 'sourcealias.html'
Set-Content -Path $sourceAliasPage -Value '<html><body>sourcealiastool 7.7.7</body></html>' -Encoding UTF8
$emptySourceForgePage = Join-Path $sourceDir 'emptysourceforge.html'
Set-Content -Path $emptySourceForgePage -Value '<html><body>emptysourceforgetool 6.6.6</body></html>' -Encoding UTF8

$updateManifest = [ordered]@{
    Version = '1.0.0'
    url = 'https://example.test/cmdtool-1.0.0.exe'
    hash = ''
    checkver = [ordered]@{
        url = $latestPage
        regex = 'cmdtool ([\d.]+)'
    }
    AutoUpdate = [ordered]@{
        URL = 'https://example.test/cmdtool-$version.exe'
        Hash = 'updatedhash'
    }
}
$updateManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bucketDir 'cmdtool.json') -Encoding UTF8

$sameManifest = [ordered]@{
    version = '2.0.0'
    url = 'https://example.test/sametool-2.0.0.exe'
    hash = ''
    CheckVer = [ordered]@{
        url = $samePage
        regex = 'sametool ([\d.]+)'
    }
    autoupdate = [ordered]@{
        url = 'https://example.test/sametool-$version.exe'
        hash = 'samehash'
    }
}
$sameManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bucketDir 'sametool.json') -Encoding UTF8

$upperExtensionManifest = [ordered]@{
    version = '2.0.0'
    url = 'https://example.test/upperchecktool-2.0.0.exe'
    hash = ''
    checkver = [ordered]@{
        url = $samePage
        regex = 'sametool ([\d.]+)'
    }
}
$upperExtensionManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bucketDir 'upperchecktool.JSON') -Encoding UTF8

$plainManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/plaintool.exe'
    hash = ''
}
$plainManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'plaintool.json') -Encoding UTF8

$emptyCheckverManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/emptycheckver.exe'
    hash = ''
    homepage = $latestPage
    checkver = ''
}
$emptyCheckverManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'emptycheckvertool.json') -Encoding UTF8

$urlFallbackManifest = [ordered]@{
    version = '1.0.0'
    url = $urlFallbackPage
    hash = ''
    checkver = [ordered]@{
        regex = 'urlfallbacktool ([\d.]+)'
    }
}
$urlFallbackManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'urlfallbacktool.json') -Encoding UTF8

$stringFallbackManifest = [ordered]@{
    version = '1.0.0'
    url = $stringFallbackPage
    hash = ''
    checkver = 'stringfallbacktool ([\d.]+)'
}
$stringFallbackManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'stringfallbacktool.json') -Encoding UTF8

$sourceAliasManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/sourcealiastool.exe'
    hash = ''
    checkver = [ordered]@{
        source = $sourceAliasPage
        regex = 'sourcealiastool ([\d.]+)'
    }
}
$sourceAliasManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'sourcealiastool.json') -Encoding UTF8

$emptySourceForgeManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/emptysourceforgetool.exe'
    hash = ''
    checkver = [ordered]@{
        url = $emptySourceForgePage
        regex = 'emptysourceforgetool ([\d.]+)'
        SourceForge = ''
    }
}
$emptySourceForgeManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'emptysourceforgetool.json') -Encoding UTF8

$noAutoManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/noauto.exe'
    hash = ''
    checkver = [ordered]@{
        url = $latestPage
        regex = 'cmdtool ([\d.]+)'
    }
}
$noAutoManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'noautotool.json') -Encoding UTF8

$stringAutoManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/stringauto.exe'
    hash = ''
    checkver = [ordered]@{
        url = $latestPage
        regex = 'cmdtool ([\d.]+)'
    }
    autoupdate = 'true'
}
$stringAutoManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'stringautotool.json') -Encoding UTF8

$brokenAutoManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/brokenautotool-1.0.0.exe'
    hash = ''
    checkver = [ordered]@{
        url = $latestPage
        regex = 'cmdtool ([\d.]+)'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'missing-brokenautotool-$version.exe')))
        hash = [ordered]@{
            mode = 'download'
        }
    }
}
$brokenAutoManifest | ConvertTo-Json -Depth 7 | Set-Content -Path (Join-Path $bucketDir 'brokenautotool.json') -Encoding UTF8

$replaceOnlyManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/replaceonlytool-1.0.0.exe'
    hash = ''
    checkver = [ordered]@{
        url = $replaceOnlyPage
        replace = '$1'
    }
}
$replaceOnlyManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'replaceonlytool.json') -Encoding UTF8

$namedGroupManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/namedgrouptool-1.0.0.exe'
    hash = ''
    checkver = [ordered]@{
        url = $namedGroupPage
        regex = 'namedgrouptool (old)?(?<version>[\d.]+)'
    }
}
$namedGroupManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'namedgrouptool.json') -Encoding UTF8

$namedReplaceManifest = [ordered]@{
    version = '1.0.0'
    url = 'https://example.test/namedreplacetool-1.0.0.exe'
    hash = ''
    checkver = [ordered]@{
        url = $namedReplacePage
        regex = 'namedreplacetool (?<major>\d+)_(?<minor>\d+)_(?<patch>\d+)'
        replace = '${major}.${minor}.${patch}'
    }
}
$namedReplaceManifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $bucketDir 'namedreplacetool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$output = & $ScoExe checkver -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "checkver failed with exit code $LASTEXITCODE`: $output"
}
$joined = $output -join "`n"
if ($joined -notmatch 'cmdtool: 1\.2\.0 \(scoop version is 1\.0\.0\) autoupdate available') {
    throw "checkver did not report updated manifest: $joined"
}
if ($joined -notmatch 'sametool: 2\.0\.0') {
    throw "checkver did not report current manifest: $joined"
}
if ($joined -notmatch 'upperchecktool: 2\.0\.0') {
    throw "checkver did not include manifest with uppercase .JSON extension: $joined"
}
if ($joined -notmatch 'namedgrouptool: 7\.8\.9 \(scoop version is 1\.0\.0\)') {
    throw "checkver did not support Scoop-style (?<version>) regex groups: $joined"
}
if ($joined -notmatch 'namedreplacetool: 2024\.06\.01 \(scoop version is 1\.0\.0\)') {
    throw "checkver did not support Scoop-style named-group replace tokens: $joined"
}
if ($joined -notmatch 'stringautotool: 1\.2\.0 \(scoop version is 1\.0\.0\) autoupdate available') {
    throw "checkver should treat truthy non-object autoupdate as supported for availability output: $joined"
}
if ($joined -match 'plaintool|emptycheckvertool') {
    throw "checkver should skip manifests without truthy checkver: $joined"
}
if ($joined -notmatch 'urlfallbacktool: couldn''t find new version' -or $joined -match 'urlfallbacktool: 9\.9\.9') {
    throw "checkver should not use manifest download url as a checkver source: $joined"
}
if ($joined -notmatch 'stringfallbacktool: couldn''t find new version' -or $joined -match 'stringfallbacktool: 8\.8\.8') {
    throw "string checkver should not use manifest download url as a source: $joined"
}
if ($joined -notmatch 'sourcealiastool: couldn''t find new version' -or $joined -match 'sourcealiastool: 7\.7\.7') {
    throw "checkver should ignore unsupported source property like Scoop: $joined"
}
if ($joined -notmatch 'emptysourceforgetool: 6\.6\.6 \(scoop version is 1\.0\.0\)') {
    throw "checkver should ignore falsy SourceForge property and keep the normal regex source: $joined"
}
if ($joined -notmatch "replaceonlytool: 'replace' requires 're' or 'regex'") {
    throw "checkver did not reject replace without regex: $joined"
}

$noAutoOutput = & $ScoExe checkver noautotool -Dir $bucketDir -Update
if ($LASTEXITCODE -ne 0) {
    throw "checkver -Update without autoupdate should not fail, got exit code $LASTEXITCODE`: $noAutoOutput"
}
$noAutoJoined = $noAutoOutput -join "`n"
if ($noAutoJoined -notmatch 'noautotool: 1\.2\.0 \(scoop version is 1\.0\.0\)' -or $noAutoJoined -match 'autoupdate available|Writing updated') {
    throw "checkver without autoupdate should report only the version delta: $noAutoJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$stringAutoUpdateOutput = & $ScoExe checkver stringautotool -Dir $bucketDir -Update 2>&1
$stringAutoUpdateExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($stringAutoUpdateExitCode -ne 0) {
    throw "checkver -Update with truthy non-object autoupdate should keep autoupdate errors non-fatal, got exit code $stringAutoUpdateExitCode`: $stringAutoUpdateOutput"
}
$stringAutoUpdateJoined = $stringAutoUpdateOutput -join "`n"
if ($stringAutoUpdateJoined -notmatch 'stringautotool: 1\.2\.0 \(scoop version is 1\.0\.0\) autoupdate available' -or $stringAutoUpdateJoined -notmatch 'does not have autoupdate capability') {
    throw "checkver -Update should attempt truthy non-object autoupdate and report the generation error: $stringAutoUpdateJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$brokenOutput = & $ScoExe checkver brokenautotool -Dir $bucketDir -Update 2>&1
$brokenExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($brokenExitCode -ne 0) {
    throw "checkver -Update should continue after autoupdate errors unless -ThrowError is used, got exit code $brokenExitCode`: $brokenOutput"
}
$brokenJoined = $brokenOutput -join "`n"
if ($brokenJoined -notmatch 'brokenautotool: 1\.2\.0 \(scoop version is 1\.0\.0\) autoupdate available' -or $brokenJoined -notmatch 'local artifact does not exist') {
    throw "checkver -Update did not report non-throwing autoupdate error: $brokenJoined"
}

$skipOutput = & $ScoExe checkver -Dir $bucketDir -SkipUpdated
if ($LASTEXITCODE -ne 0) {
    throw "checkver -SkipUpdated failed with exit code $LASTEXITCODE`: $skipOutput"
}
$skipJoined = $skipOutput -join "`n"
if ($skipJoined -notmatch 'cmdtool' -or $skipJoined -match 'sametool') {
    throw "checkver -SkipUpdated did not filter current manifests: $skipJoined"
}

$skipFalseOutput = & $ScoExe checkver 'same*' -Dir $bucketDir '-SkipUpdated:$false'
if ($LASTEXITCODE -ne 0) {
    throw "checkver -SkipUpdated:`$false failed with exit code $LASTEXITCODE`: $skipFalseOutput"
}
if (($skipFalseOutput -join "`n") -notmatch 'sametool') {
    throw "checkver -SkipUpdated:`$false should keep current manifests visible: $skipFalseOutput"
}

$patternOutput = & $ScoExe checkver 'same*' -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "checkver app pattern failed with exit code $LASTEXITCODE`: $patternOutput"
}
$patternJoined = $patternOutput -join "`n"
if ($patternJoined -notmatch 'sametool' -or $patternJoined -match 'cmdtool|plaintool') {
    throw "checkver app pattern did not filter expected manifests: $patternJoined"
}

$positionalDirOutput = & $ScoExe checkver 'same*' $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "checkver positional App Dir failed with exit code $LASTEXITCODE`: $positionalDirOutput"
}
$positionalDirJoined = $positionalDirOutput -join "`n"
if ($positionalDirJoined -notmatch 'sametool' -or $positionalDirJoined -match 'cmdtool|plaintool') {
    throw "checkver positional App Dir did not match PowerShell parameter binding: $positionalDirJoined"
}

$namedAppOutput = & $ScoExe checkver -App same* -Dir $bucketDir
if ($LASTEXITCODE -ne 0) {
    throw "checkver -App failed with exit code $LASTEXITCODE`: $namedAppOutput"
}
if (($namedAppOutput -join "`n") -notmatch 'sametool') {
    throw "checkver -App did not select the requested manifest: $namedAppOutput"
}

$inlineBindingOutput = & $ScoExe checkver '-App:same*' "--dir=$bucketDir"
if ($LASTEXITCODE -ne 0) {
    throw "checkver -App:<app> --dir=<dir> failed with exit code $LASTEXITCODE`: $inlineBindingOutput"
}
$inlineBindingJoined = $inlineBindingOutput -join "`n"
if ($inlineBindingJoined -notmatch 'sametool' -or $inlineBindingJoined -match 'cmdtool|plaintool') {
    throw "checkver inline -App/--dir binding did not filter expected manifests: $inlineBindingJoined"
}

$updateFalseOutput = & $ScoExe checkver cmdtool -Dir $bucketDir '-Update:$false'
if ($LASTEXITCODE -ne 0) {
    throw "checkver -Update:`$false failed with exit code $LASTEXITCODE`: $updateFalseOutput"
}
$notUpdated = Get-Content -LiteralPath (Join-Path $bucketDir 'cmdtool.json') -Raw | ConvertFrom-Json
if ($notUpdated.version -ne '1.0.0') {
    throw "checkver -Update:`$false unexpectedly updated manifest: $($notUpdated | ConvertTo-Json -Depth 6 -Compress)"
}

$updateOutput = & $ScoExe checkver cmdtool -Dir $bucketDir -Update
if ($LASTEXITCODE -ne 0) {
    throw "checkver -Update failed with exit code $LASTEXITCODE`: $updateOutput"
}
$updated = Get-Content -LiteralPath (Join-Path $bucketDir 'cmdtool.json') -Raw | ConvertFrom-Json
if ($updated.version -ne '1.2.0' -or $updated.url -ne 'https://example.test/cmdtool-1.2.0.exe' -or $updated.hash -ne 'updatedhash') {
    throw "checkver -Update did not write autoupdated manifest: $($updated | ConvertTo-Json -Depth 6 -Compress)"
}
$generated = Join-Path $Root 'cache\generated-manifests\cmdtool\1.2.0\cmdtool.json'
if (!(Test-Path $generated)) {
    throw "checkver -Update did not keep generated manifest: $generated"
}

$versionOutput = & $ScoExe checkver cmdtool "-Dir:$bucketDir" -Version:1.3.0 -Update
if ($LASTEXITCODE -ne 0) {
    throw "checkver -Dir:<dir> -Version:<version> -Update failed with exit code $LASTEXITCODE`: $versionOutput"
}
$versionUpdated = Get-Content -LiteralPath (Join-Path $bucketDir 'cmdtool.json') -Raw | ConvertFrom-Json
if ($versionUpdated.version -ne '1.3.0' -or $versionUpdated.url -ne 'https://example.test/cmdtool-1.3.0.exe') {
    throw "checkver inline -Dir/-Version did not write explicit version: $($versionUpdated | ConvertTo-Json -Depth 6 -Compress)"
}

$forceOutput = & $ScoExe checkver sametool -Dir $bucketDir -ForceUpdate
if ($LASTEXITCODE -ne 0) {
    throw "checkver -ForceUpdate failed with exit code $LASTEXITCODE`: $forceOutput"
}
if (($forceOutput -join "`n") -notmatch 'Forcing autoupdate!' -or ($forceOutput -join "`n") -notmatch 'Writing updated sametool manifest') {
    throw "checkver -ForceUpdate did not force write: $forceOutput"
}

$forceFalseOutput = & $ScoExe checkver sametool -Dir $bucketDir '-ForceUpdate:$false'
if ($LASTEXITCODE -ne 0) {
    throw "checkver -ForceUpdate:`$false failed with exit code $LASTEXITCODE`: $forceFalseOutput"
}
if (($forceFalseOutput -join "`n") -match 'Forcing autoupdate!|Writing updated sametool manifest') {
    throw "checkver -ForceUpdate:`$false unexpectedly forced an update: $forceFalseOutput"
}

$fileOutput = & $ScoExe checkver (Join-Path $bucketDir 'sametool.json')
if ($LASTEXITCODE -ne 0 -or ($fileOutput -join "`n") -notmatch 'sametool: 2\.0\.0') {
    throw "checkver manifest filepath failed: $fileOutput"
}

$helpOutput = & $ScoExe checkver --help
if ($LASTEXITCODE -ne 0 -or ($helpOutput -join "`n") -notmatch 'Usage: sco checkver') {
    throw "checkver --help failed: $helpOutput"
}
if (($helpOutput -join "`n") -notmatch '-ThrowError') {
    throw "checkver --help did not include -ThrowError: $helpOutput"
}

$helpCommandOutput = & $ScoExe help checkver
if ($LASTEXITCODE -ne 0 -or ($helpCommandOutput -join "`n") -notmatch 'Usage: sco checkver') {
    throw "help checkver failed: $helpCommandOutput"
}

$ErrorActionPreference = 'Continue'
$badVersionOutput = & $ScoExe checkver -Dir $bucketDir -Version 9.9.9 2>&1
$badVersionExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badVersionExitCode -eq 0 -or ($badVersionOutput -join "`n") -notmatch "Don't use '-Version' with '-App \*'") {
    throw "checkver did not reject wildcard -Version: $badVersionOutput"
}

$ErrorActionPreference = 'Continue'
$badSwitchOutput = & $ScoExe checkver -Dir $bucketDir -SkipUpdated:nope 2>&1
$badSwitchExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($badSwitchExitCode -eq 0 -or ($badSwitchOutput -join "`n") -notmatch 'must be a boolean value') {
    throw "checkver invalid switch value was not rejected: $badSwitchOutput"
}

$ErrorActionPreference = 'Continue'
$throwFalseOutput = & $ScoExe checkver brokenautotool -Dir $bucketDir -Update '-ThrowError:$false' 2>&1
$throwFalseExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($throwFalseExitCode -ne 0 -or ($throwFalseOutput -join "`n") -notmatch 'local artifact does not exist') {
    throw "checkver -ThrowError:`$false should keep autoupdate errors non-fatal: $throwFalseOutput"
}

$ErrorActionPreference = 'Continue'
$throwOutput = & $ScoExe checkver brokenautotool -Dir $bucketDir -Update -ThrowError 2>&1
$throwExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($throwExitCode -eq 0 -or ($throwOutput -join "`n") -notmatch 'local artifact does not exist') {
    throw "checkver -ThrowError did not fail on autoupdate error: $throwOutput"
}
