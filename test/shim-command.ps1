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
$GlobalRoot = Join-Path (Split-Path -Parent $Root) 'test-shim-command-global'
if (Test-Path $GlobalRoot) {
    Remove-Item -LiteralPath $GlobalRoot -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome
$pathToolDir = Join-Path (Split-Path -Parent $Root) 'test-shim-command-path-tools'
if (Test-Path $pathToolDir) {
    Remove-Item -LiteralPath $pathToolDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $pathToolDir | Out-Null
$pathTool = Join-Path $pathToolDir 'pathtool.cmd'
Set-Content -Path $pathTool -Value '@echo path-tool' -Encoding Ascii
$pathExtOrderCom = Join-Path $pathToolDir 'pathextorder.com'
$pathExtOrderExe = Join-Path $pathToolDir 'pathextorder.exe'
Set-Content -Path $pathExtOrderCom -Value 'path-ext-com' -Encoding Ascii
Set-Content -Path $pathExtOrderExe -Value 'path-ext-exe' -Encoding Ascii
$pathScript = Join-Path $pathToolDir 'pathscriptonly.ps1'
Set-Content -Path $pathScript -Value 'Write-Output path-script' -Encoding Ascii
$env:PATH = "$(Join-Path $Root 'shims');$pathToolDir;$env:PATH"

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingSubcommandOutput = & $ScoExe shim 2>&1
$missingSubcommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingSubcommandExitCode -ne 1) {
    throw "shim without a subcommand returned $missingSubcommandExitCode instead of 1: $missingSubcommandOutput"
}
if (($missingSubcommandOutput -join "`n") -notmatch 'ERROR <subcommand> missing' -or ($missingSubcommandOutput -join "`n") -notmatch 'Usage: sco shim <subcommand> \[<shim_name>\.\.\.\] \[options\] \[other_args\]') {
    throw "shim without a subcommand did not match Scoop usage: $missingSubcommandOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidSubcommandOutput = & $ScoExe shim nope 2>&1
$invalidSubcommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidSubcommandExitCode -ne 1) {
    throw "shim with an invalid subcommand returned $invalidSubcommandExitCode instead of 1: $invalidSubcommandOutput"
}
if (($invalidSubcommandOutput -join "`n") -notmatch "ERROR 'nope' is not one of available subcommands: add, rm, list, info, alter" -or ($invalidSubcommandOutput -join "`n") -notmatch 'Usage: sco shim <subcommand> \[<shim_name>\.\.\.\] \[options\] \[other_args\]') {
    throw "shim invalid subcommand did not match Scoop usage: $invalidSubcommandOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$uppercaseInvalidSubcommandOutput = & $ScoExe shim NOPE 2>&1
$uppercaseInvalidSubcommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($uppercaseInvalidSubcommandExitCode -ne 1) {
    throw "shim with an uppercase invalid subcommand returned $uppercaseInvalidSubcommandExitCode instead of 1: $uppercaseInvalidSubcommandOutput"
}
if (($uppercaseInvalidSubcommandOutput -join "`n") -notmatch "ERROR 'NOPE' is not one of available subcommands: add, rm, list, info, alter") {
    throw "shim invalid subcommand should preserve input casing like Scoop: $uppercaseInvalidSubcommandOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAddNameOutput = & $ScoExe shim add 2>&1
$missingAddNameExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAddNameExitCode -ne 1) {
    throw "shim add without a shim name returned $missingAddNameExitCode instead of 1: $missingAddNameOutput"
}
if (($missingAddNameOutput -join "`n") -notmatch "ERROR <shim_name> must be specified for subcommand 'add'") {
    throw "shim add without a shim name did not match Scoop error: $missingAddNameOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAddPathOutput = & $ScoExe shim add justname 2>&1
$missingAddPathExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAddPathExitCode -ne 1) {
    throw "shim add without a command path returned $missingAddPathExitCode instead of 1: $missingAddPathOutput"
}
if (($missingAddPathOutput -join "`n") -notmatch "ERROR <command_path> must be specified for subcommand 'add'" -or ($missingAddPathOutput -join "`n") -notmatch 'Usage: sco shim <subcommand> \[<shim_name>\.\.\.\] \[options\] \[other_args\]') {
    throw "shim add without a command path did not match Scoop error: $missingAddPathOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingRmNameOutput = & $ScoExe shim rm 2>&1
$missingRmNameExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingRmNameExitCode -ne 1) {
    throw "shim rm without a shim name returned $missingRmNameExitCode instead of 1: $missingRmNameOutput"
}
if (($missingRmNameOutput -join "`n") -notmatch "ERROR <shim_name> must be specified for subcommand 'rm'" -or ($missingRmNameOutput -join "`n") -notmatch 'Usage: sco shim <subcommand> \[<shim_name>\.\.\.\] \[options\] \[other_args\]') {
    throw "shim rm without a shim name did not match Scoop error: $missingRmNameOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$unknownOptionOutput = & $ScoExe shim list -z 2>&1
$unknownOptionExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($unknownOptionExitCode -ne 1) {
    throw "shim list -z returned $unknownOptionExitCode instead of 1: $unknownOptionOutput"
}
if (($unknownOptionOutput -join "`n") -notmatch 'sco shim: Option -z not recognized\.') {
    throw "shim list -z did not match Scoop getopt error: $unknownOptionOutput"
}

$target = [System.IO.Path]::GetFullPath($Artifact)
& $ScoExe shim add customtool $target -- --flag value
if ($LASTEXITCODE -ne 0) {
    throw "shim add failed with exit code $LASTEXITCODE"
}

$shimPath = Join-Path $Root 'shims\customtool.cmd'
if (!(Test-Path $shimPath)) {
    throw 'shim add did not create customtool.cmd'
}

$shimContent = Get-Content -LiteralPath $shimPath -Raw
if ($shimContent -notmatch [Regex]::Escape($target) -or $shimContent -notmatch '--flag value') {
    throw "shim content did not preserve target and arguments: $shimContent"
}

& $ScoExe shim add commandtool customtool
if ($LASTEXITCODE -ne 0) {
    throw "shim add from command name failed with exit code $LASTEXITCODE"
}

$commandShimPath = Join-Path $Root 'shims\commandtool.cmd'
if (!(Test-Path $commandShimPath)) {
    throw 'shim add from command name did not create commandtool.cmd'
}

$commandShimContent = Get-Content -LiteralPath $commandShimPath -Raw
if ($commandShimContent -notmatch [Regex]::Escape($target)) {
    throw "shim add from command name did not resolve the existing shim target: $commandShimContent"
}

& $ScoExe shim rm commandtool
if ($LASTEXITCODE -ne 0) {
    throw "shim rm for command-derived shim failed with exit code $LASTEXITCODE"
}
if (Test-Path $commandShimPath) {
    throw 'shim rm did not remove commandtool.cmd'
}

& $ScoExe shim add globaltool $target --global
if ($LASTEXITCODE -ne 0) {
    throw "global shim add failed with exit code $LASTEXITCODE"
}

$globalShimPath = Join-Path $GlobalRoot 'shims\globaltool.cmd'
if (!(Test-Path $globalShimPath)) {
    throw 'shim add --global did not create globaltool.cmd'
}

& $ScoExe shim add clusteredglobal $target -gg
if ($LASTEXITCODE -ne 0) {
    throw "global shim add with clustered -gg failed with exit code $LASTEXITCODE"
}
$clusteredGlobalShimPath = Join-Path $GlobalRoot 'shims\clusteredglobal.cmd'
if (!(Test-Path $clusteredGlobalShimPath)) {
    throw 'shim add -gg did not parse clustered Scoop-style short options as global'
}

& $ScoExe shim add localfromglobal globaltool
if ($LASTEXITCODE -ne 0) {
    throw "shim add from global command name failed with exit code $LASTEXITCODE"
}

$localFromGlobalShimPath = Join-Path $Root 'shims\localfromglobal.cmd'
if (!(Test-Path $localFromGlobalShimPath)) {
    throw 'shim add from global command name did not create localfromglobal.cmd'
}

$localFromGlobalContent = Get-Content -LiteralPath $localFromGlobalShimPath -Raw
if ($localFromGlobalContent -notmatch [Regex]::Escape($target)) {
    throw "shim add from global command name did not resolve the global shim target: $localFromGlobalContent"
}

& $ScoExe shim rm localfromglobal
if ($LASTEXITCODE -ne 0) {
    throw "shim rm for local shim derived from global command failed with exit code $LASTEXITCODE"
}
if (Test-Path $localFromGlobalShimPath) {
    throw 'shim rm did not remove localfromglobal.cmd'
}

& $ScoExe shim add pathshim pathtool
if ($LASTEXITCODE -ne 0) {
    throw "shim add from PATH command name failed with exit code $LASTEXITCODE"
}

$pathShimPath = Join-Path $Root 'shims\pathshim.cmd'
if (!(Test-Path $pathShimPath)) {
    throw 'shim add from PATH command name did not create pathshim.cmd'
}

$pathShimContent = Get-Content -LiteralPath $pathShimPath -Raw
if ($pathShimContent -notmatch [Regex]::Escape($pathTool)) {
    throw "shim add from PATH command name did not resolve the PATH executable: $pathShimContent"
}

& $ScoExe shim rm pathshim
if ($LASTEXITCODE -ne 0) {
    throw "shim rm for PATH-derived shim failed with exit code $LASTEXITCODE"
}
if (Test-Path $pathShimPath) {
    throw 'shim rm did not remove pathshim.cmd'
}

& $ScoExe shim add pathextshim pathextorder
if ($LASTEXITCODE -ne 0) {
    throw "shim add from PATH command with competing extensions failed with exit code $LASTEXITCODE"
}

$pathExtShimPath = Join-Path $Root 'shims\pathextshim.cmd'
if (!(Test-Path $pathExtShimPath)) {
    throw 'shim add from PATH command with competing extensions did not create pathextshim.cmd'
}

$pathExtShimContent = Get-Content -LiteralPath $pathExtShimPath -Raw
if ($pathExtShimContent -notmatch [Regex]::Escape($pathExtOrderCom)) {
    throw "shim add should follow PowerShell/Get-Command PATHEXT precedence like Scoop: $pathExtShimContent"
}

& $ScoExe shim rm pathextshim
if ($LASTEXITCODE -ne 0) {
    throw "shim rm for PATHEXT-derived shim failed with exit code $LASTEXITCODE"
}
if (Test-Path $pathExtShimPath) {
    throw 'shim rm did not remove pathextshim.cmd'
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$pathScriptShimOutput = & $ScoExe shim add scriptshim pathscriptonly 2>&1
$pathScriptShimExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($pathScriptShimExitCode -ne 3) {
    throw "shim add from PATH-only ps1 returned $pathScriptShimExitCode instead of 3: $pathScriptShimOutput"
}
if (($pathScriptShimOutput -join "`n") -notmatch 'ERROR: Command path does not exist: pathscriptonly') {
    throw "shim add from PATH-only ps1 did not match Scoop rejection: $pathScriptShimOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidNameMissingTargetOutput = & $ScoExe shim add 'bad/name' missing-target-command 2>&1
$invalidNameMissingTargetExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidNameMissingTargetExitCode -ne 3) {
    throw "shim add invalid name with missing target returned $invalidNameMissingTargetExitCode instead of 3: $invalidNameMissingTargetOutput"
}
if (($invalidNameMissingTargetOutput -join "`n") -notmatch 'ERROR: Command path does not exist: missing-target-command') {
    throw "shim add should validate missing command path before shim name like Scoop: $invalidNameMissingTargetOutput"
}

$literalScript = Join-Path $pathToolDir 'literal-script.ps1'
Set-Content -Path $literalScript -Value 'Write-Output literal-script' -Encoding Ascii
& $ScoExe shim add literalps1 $literalScript -- -LiteralArg
if ($LASTEXITCODE -ne 0) {
    throw "shim add from literal ps1 failed with exit code $LASTEXITCODE"
}
$literalScriptShim = Join-Path $Root 'shims\literalps1.cmd'
if (!(Test-Path $literalScriptShim)) {
    throw 'shim add from literal ps1 did not create literalps1.cmd'
}
$literalScriptContent = Get-Content -LiteralPath $literalScriptShim -Raw
if ($literalScriptContent -notmatch 'where /q pwsh\.exe' -or
    $literalScriptContent -notmatch 'powershell -noprofile -ex unrestricted -file' -or
    $literalScriptContent -notmatch [Regex]::Escape($literalScript) -or
    $literalScriptContent -notmatch '-LiteralArg') {
    throw "shim add from literal ps1 did not create a Scoop-style PowerShell wrapper: $literalScriptContent"
}

$literalJar = Join-Path $pathToolDir 'literal-app.jar'
Set-Content -Path $literalJar -Value 'jar-bytes' -Encoding Ascii
& $ScoExe shim add literaljar $literalJar -- -JarArg
if ($LASTEXITCODE -ne 0) {
    throw "shim add from literal jar failed with exit code $LASTEXITCODE"
}
$literalJarShim = Join-Path $Root 'shims\literaljar.cmd'
$literalJarContent = Get-Content -LiteralPath $literalJarShim -Raw
if ($literalJarContent -notmatch 'java -jar' -or
    $literalJarContent -notmatch [Regex]::Escape($literalJar) -or
    $literalJarContent -notmatch '-JarArg' -or
    $literalJarContent -notmatch 'popd') {
    throw "shim add from literal jar did not create a Scoop-style Java wrapper: $literalJarContent"
}

$literalPy = Join-Path $pathToolDir 'literal-tool.py'
Set-Content -Path $literalPy -Value 'print("literal")' -Encoding Ascii
& $ScoExe shim add literalpy $literalPy -- -PyArg
if ($LASTEXITCODE -ne 0) {
    throw "shim add from literal py failed with exit code $LASTEXITCODE"
}
$literalPyShim = Join-Path $Root 'shims\literalpy.cmd'
$literalPyContent = Get-Content -LiteralPath $literalPyShim -Raw
if ($literalPyContent -notmatch 'python ' -or
    $literalPyContent -notmatch [Regex]::Escape($literalPy) -or
    $literalPyContent -notmatch '-PyArg') {
    throw "shim add from literal py did not create a Scoop-style Python wrapper: $literalPyContent"
}

$listOutput = & $ScoExe shim list custom
if ($LASTEXITCODE -ne 0 -or (($listOutput -join "`n") -notmatch 'customtool')) {
    throw "shim list did not include customtool: $listOutput"
}
$listJoined = $listOutput -join "`n"
if ($listJoined -notmatch 'Name\s+Source\s+Alternatives\s+IsGlobal\s+IsHidden' -or
    $listJoined -notmatch 'customtool\s+External\s+false\s+(true|false)' -or
    $listJoined -match [Regex]::Escape($target)) {
    throw "shim list should use Scoop-style metadata columns instead of path output: $listJoined"
}

$mergedListOutput = & $ScoExe shim list tool
if ($LASTEXITCODE -ne 0) {
    throw "shim list across local/global failed with exit code $LASTEXITCODE`: $mergedListOutput"
}
$mergedJoined = $mergedListOutput -join "`n"
if ($mergedJoined -notmatch 'customtool' -or $mergedJoined -notmatch 'globaltool') {
    throw "shim list without --global did not include both local and global shims: $mergedJoined"
}
if ($mergedJoined -notmatch 'customtool\s+External\s+false\s+(true|false)' -or
    $mergedJoined -notmatch 'globaltool\s+External\s+true\s+(true|false)') {
    throw "shim list did not mark local and global shims like Scoop: $mergedJoined"
}

$wildcardListOutput = & $ScoExe shim list '*'
if ($LASTEXITCODE -ne 0 -or (($wildcardListOutput -join "`n") -notmatch 'customtool') -or (($wildcardListOutput -join "`n") -notmatch 'globaltool')) {
    throw "shim list * did not list all local/global shims: $wildcardListOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidPatternOutput = & $ScoExe shim list '[' 2>&1
$invalidPatternExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidPatternExitCode -ne 1) {
    throw "shim list invalid regex returned $invalidPatternExitCode instead of 1: $invalidPatternOutput"
}
if (($invalidPatternOutput -join "`n") -notmatch 'ERROR: Invalid pattern: \[') {
    throw "shim list invalid regex did not match Scoop error: $invalidPatternOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingInfoOutput = & $ScoExe shim info missingshim 2>&1
$missingInfoExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingInfoExitCode -ne 3) {
    throw "shim info missing shim returned $missingInfoExitCode instead of 3: $missingInfoOutput"
}
if (($missingInfoOutput -join "`n") -notmatch 'ERROR: Local shim not found: missingshim') {
    throw "shim info missing shim did not match Scoop error: $missingInfoOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$globalOnlyInfoOutput = & $ScoExe shim info globaltool 2>&1
$globalOnlyInfoExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($globalOnlyInfoExitCode -ne 2) {
    throw "shim info for opposite-scope shim returned $globalOnlyInfoExitCode instead of 2: $globalOnlyInfoOutput"
}
$globalOnlyInfoJoined = $globalOnlyInfoOutput -join "`n"
if ($globalOnlyInfoJoined -notmatch 'ERROR: Local shim not found: globaltool' -or $globalOnlyInfoJoined -notmatch "But a global shim exists, run 'scoop shim info globaltool --global' to show its info") {
    throw "shim info for opposite-scope shim did not match Scoop hint: $globalOnlyInfoJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$globalOnlyAlterOutput = & $ScoExe shim alter globaltool 2>&1
$globalOnlyAlterExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($globalOnlyAlterExitCode -ne 2) {
    throw "shim alter for opposite-scope shim returned $globalOnlyAlterExitCode instead of 2: $globalOnlyAlterOutput"
}
$globalOnlyAlterJoined = $globalOnlyAlterOutput -join "`n"
if ($globalOnlyAlterJoined -notmatch 'ERROR: Local shim not found: globaltool' -or $globalOnlyAlterJoined -notmatch "But a global shim exists, run 'scoop shim alter globaltool --global' to alternate its source") {
    throw "shim alter for opposite-scope shim did not match Scoop hint: $globalOnlyAlterJoined"
}

$infoOutput = & $ScoExe shim info customtool
if ($LASTEXITCODE -ne 0) {
    throw "shim info failed with exit code $LASTEXITCODE"
}
$joinedInfo = $infoOutput -join "`n"
if ($joinedInfo -notmatch 'Name: customtool' -or
    $joinedInfo -notmatch [Regex]::Escape($target) -or
    $joinedInfo -notmatch 'Type: Application' -or
    $joinedInfo -notmatch 'IsGlobal: false' -or
    $joinedInfo -notmatch 'IsHidden: (true|false)' -or
    $joinedInfo -notmatch 'Global: false') {
    throw "shim info did not include expected fields: $joinedInfo"
}
if ($joinedInfo -match 'Alternatives:') {
    throw "shim info should not report alternatives for a single-source shim: $joinedInfo"
}

$which = (& $ScoExe which customtool).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "which customtool failed with exit code $LASTEXITCODE"
}
if ($which.Replace('\', '/') -ne $target.Replace('\', '/')) {
    throw "which customtool returned '$which', expected '$target'"
}

$nativeShimDir = Join-Path $Root 'shims'
New-Item -ItemType Directory -Force -Path $nativeShimDir | Out-Null
$nativeShim = Join-Path $nativeShimDir 'nativeshim.shim'
$nativeShimExe = Join-Path $nativeShimDir 'nativeshim.exe'
Set-Content -Path $nativeShim -Value @("path = `"$target`"", 'args = --native') -Encoding UTF8
Set-Content -Path $nativeShimExe -Value 'shim-exe-placeholder' -Encoding Ascii

$nativeList = & $ScoExe shim list nativeshim
if ($LASTEXITCODE -ne 0 -or (($nativeList -join "`n") -notmatch 'nativeshim')) {
    throw "shim list did not include Scoop-style .shim entry: $nativeList"
}
$nativeListJoined = $nativeList -join "`n"
if ($nativeListJoined -notmatch 'nativeshim\s+External\s+false\s+(true|false)' -or $nativeListJoined -match 'nativeshim\.exe') {
    throw "shim list .shim entry did not use Scoop-style metadata columns: $nativeListJoined"
}

$nativeInfo = & $ScoExe shim info nativeshim
if ($LASTEXITCODE -ne 0) {
    throw "shim info for Scoop-style .shim failed with exit code $LASTEXITCODE`: $nativeInfo"
}
$nativeInfoJoined = $nativeInfo -join "`n"
$targetForMatch = $target.Replace('\', '/')
if ($nativeInfoJoined -notmatch 'Name: nativeshim' -or $nativeInfoJoined -notmatch [Regex]::Escape($targetForMatch) -or $nativeInfoJoined -notmatch 'Source: External') {
    throw "shim info did not describe Scoop-style .shim: $nativeInfoJoined"
}

$nativeWhich = (& $ScoExe which nativeshim).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "which nativeshim failed with exit code $LASTEXITCODE"
}
if ($nativeWhich.Replace('\', '/') -ne $target.Replace('\', '/')) {
    throw "which nativeshim returned '$nativeWhich', expected '$target'"
}

$fallbackTarget = Join-Path $pathToolDir 'fallback-native.exe'
Set-Content -Path $fallbackTarget -Value 'fallback-native' -Encoding Ascii
$fallbackShim = Join-Path $nativeShimDir 'fallbackshim.shim'
$fallbackShimExe = Join-Path $nativeShimDir 'fallbackshim.exe'
$fallbackShimAlternative = Join-Path $nativeShimDir 'fallbackshim.shim.oldapp'
Set-Content -Path $fallbackShim -Value @("path = `"$target`"") -Encoding UTF8
Set-Content -Path $fallbackShimExe -Value 'shim-exe-placeholder' -Encoding Ascii
Set-Content -Path $fallbackShimAlternative -Value @("path = `"$fallbackTarget`"") -Encoding UTF8

& $ScoExe shim rm fallbackshim
if ($LASTEXITCODE -ne 0) {
    throw "shim rm for native shim with metadata-only alternative failed with exit code $LASTEXITCODE"
}
if (!(Test-Path $fallbackShim) -or !(Test-Path $fallbackShimExe) -or (Test-Path $fallbackShimAlternative)) {
    throw 'shim rm did not promote a metadata-only native alternative while preserving the runner exe'
}
$fallbackWhich = (& $ScoExe which fallbackshim).Trim()
if ($LASTEXITCODE -ne 0 -or $fallbackWhich.Replace('\', '/') -ne $fallbackTarget.Replace('\', '/')) {
    throw "shim rm did not activate the metadata-only native alternative: $fallbackWhich"
}

$nativeScriptTarget = Join-Path $pathToolDir 'native-script-target.ps1'
Set-Content -Path $nativeScriptTarget -Value 'Write-Output native-script' -Encoding Ascii
$nativePs1Shim = Join-Path $nativeShimDir 'nativeps1.ps1'
Set-Content -Path $nativePs1Shim -Value @("# $nativeScriptTarget", "& `"$nativeScriptTarget`" @args") -Encoding UTF8

$nativePs1List = & $ScoExe shim list nativeps1
if ($LASTEXITCODE -ne 0 -or (($nativePs1List -join "`n") -notmatch 'nativeps1')) {
    throw "shim list did not include Scoop-style ps1 shim: $nativePs1List"
}
$nativePs1ListJoined = $nativePs1List -join "`n"
if ($nativePs1ListJoined -notmatch 'nativeps1\s+External\s+false\s+(true|false)' -or $nativePs1ListJoined -match 'nativeps1\.ps1') {
    throw "shim list ps1 entry did not use Scoop-style metadata columns: $nativePs1ListJoined"
}

$nativePs1Info = & $ScoExe shim info nativeps1
if ($LASTEXITCODE -ne 0) {
    throw "shim info for Scoop-style ps1 failed with exit code $LASTEXITCODE`: $nativePs1Info"
}
$nativePs1InfoJoined = $nativePs1Info -join "`n"
$nativeScriptTargetForMatch = $nativeScriptTarget.Replace('\', '/')
if ($nativePs1InfoJoined -notmatch 'Name: nativeps1' -or
    $nativePs1InfoJoined -notmatch 'Type: ExternalScript' -or
    $nativePs1InfoJoined -notmatch 'IsGlobal: false' -or
    $nativePs1InfoJoined -notmatch [Regex]::Escape($nativeScriptTargetForMatch)) {
    throw "shim info did not describe Scoop-style ps1 shim: $nativePs1InfoJoined"
}

$nativePs1Which = (& $ScoExe which nativeps1).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "which nativeps1 failed with exit code $LASTEXITCODE"
}
if ($nativePs1Which.Replace('\', '/') -ne $nativeScriptTarget.Replace('\', '/')) {
    throw "which nativeps1 returned '$nativePs1Which', expected '$nativeScriptTarget'"
}

& $ScoExe shim rm nativeshim nativeps1
if ($LASTEXITCODE -ne 0) {
    throw "shim rm for Scoop-style shims failed with exit code $LASTEXITCODE"
}
if ((Test-Path $nativeShim) -or (Test-Path $nativeShimExe) -or (Test-Path $nativePs1Shim)) {
    throw 'shim rm did not remove Scoop-style shim files'
}

& $ScoExe shim rm customtool
if ($LASTEXITCODE -ne 0) {
    throw "shim rm failed with exit code $LASTEXITCODE"
}
if (Test-Path $shimPath) {
    throw 'shim rm did not remove customtool.cmd'
}

& $ScoExe shim rm literalps1
if ($LASTEXITCODE -ne 0) {
    throw "shim rm for literal ps1 failed with exit code $LASTEXITCODE"
}
if (Test-Path $literalScriptShim) {
    throw 'shim rm did not remove literalps1.cmd'
}

& $ScoExe shim rm literaljar literalpy
if ($LASTEXITCODE -ne 0) {
    throw "shim rm for literal jar/py failed with exit code $LASTEXITCODE"
}
if ((Test-Path $literalJarShim) -or (Test-Path $literalPyShim)) {
    throw 'shim rm did not remove literal jar/py shims'
}

& $ScoExe shim rm globaltool --global
if ($LASTEXITCODE -ne 0) {
    throw "global shim rm failed with exit code $LASTEXITCODE"
}
if (Test-Path $globalShimPath) {
    throw 'shim rm --global did not remove globaltool.cmd'
}

& $ScoExe shim rm clusteredglobal -gg
if ($LASTEXITCODE -ne 0) {
    throw "global shim rm with clustered -gg failed with exit code $LASTEXITCODE"
}
if (Test-Path $clusteredGlobalShimPath) {
    throw 'shim rm -gg did not remove clustered global shim'
}
