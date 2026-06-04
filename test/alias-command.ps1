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

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingSubcommandOutput = & $ScoExe alias 2>&1
$missingSubcommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingSubcommandExitCode -ne 1) {
    throw "alias without a subcommand returned $missingSubcommandExitCode instead of 1: $missingSubcommandOutput"
}
if (($missingSubcommandOutput -join "`n") -notmatch 'ERROR <subcommand> missing' -or ($missingSubcommandOutput -join "`n") -notmatch 'Usage: sco alias <subcommand> \[options\] \[<args>\]') {
    throw "alias without a subcommand did not match Scoop usage: $missingSubcommandOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidSubcommandOutput = & $ScoExe alias nope 2>&1
$invalidSubcommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($invalidSubcommandExitCode -ne 1) {
    throw "alias with an invalid subcommand returned $invalidSubcommandExitCode instead of 1: $invalidSubcommandOutput"
}
if (($invalidSubcommandOutput -join "`n") -notmatch "ERROR 'nope' is not one of available subcommands: add, rm, list" -or ($invalidSubcommandOutput -join "`n") -notmatch 'Usage: sco alias <subcommand> \[options\] \[<args>\]') {
    throw "alias invalid subcommand did not match Scoop usage: $invalidSubcommandOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$uppercaseInvalidSubcommandOutput = & $ScoExe alias NOPE 2>&1
$uppercaseInvalidSubcommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($uppercaseInvalidSubcommandExitCode -ne 1) {
    throw "alias with an uppercase invalid subcommand returned $uppercaseInvalidSubcommandExitCode instead of 1: $uppercaseInvalidSubcommandOutput"
}
if (($uppercaseInvalidSubcommandOutput -join "`n") -notmatch "ERROR 'NOPE' is not one of available subcommands: add, rm, list") {
    throw "alias invalid subcommand should preserve input casing like Scoop: $uppercaseInvalidSubcommandOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAddArgsOutput = & $ScoExe alias add onlyname 2>&1
$missingAddArgsExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAddArgsExitCode -ne 1) {
    throw "alias add without a command returned $missingAddArgsExitCode instead of 1: $missingAddArgsOutput"
}
if (($missingAddArgsOutput -join "`n") -notmatch "ERROR <name> and <command> must be specified for subcommand 'add'") {
    throw "alias add without a command did not match Scoop error: $missingAddArgsOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingRmArgsOutput = & $ScoExe alias rm 2>&1
$missingRmArgsExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingRmArgsExitCode -ne 1) {
    throw "alias rm without a name returned $missingRmArgsExitCode instead of 1: $missingRmArgsOutput"
}
if (($missingRmArgsOutput -join "`n") -notmatch "ERROR <name> must be specified for subcommand 'rm'") {
    throw "alias rm without a name did not match Scoop error: $missingRmArgsOutput"
}

$emptyListOutput = & $ScoExe alias list
if ($LASTEXITCODE -ne 0) {
    throw "empty alias list failed with exit code $LASTEXITCODE`: $emptyListOutput"
}
if (($emptyListOutput -join "`n") -notmatch 'INFO  No alias found\.') {
    throw "empty alias list did not match Scoop info output: $emptyListOutput"
}

$addOutput = & $ScoExe alias add sayhi 'Write-Output "alias:$($args[0])"' 'Echo first argument'
if ($LASTEXITCODE -ne 0) {
    throw "alias add failed with exit code $LASTEXITCODE`: $addOutput"
}
if (($addOutput -join "`n").Trim()) {
    throw "alias add should not print output on success: $addOutput"
}

$scriptPath = Join-Path $Root 'shims\scoop-sayhi.ps1'
if (!(Test-Path $scriptPath)) {
    throw 'alias add did not create shim script'
}

$configPath = Join-Path $ConfigHome 'scoop\config.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($config.alias.sayhi -ne 'scoop-sayhi') {
    throw 'alias add did not persist config alias entry'
}

$listOutput = & $ScoExe ALIAS LIST --VERBOSE
if ($LASTEXITCODE -ne 0) {
    throw "alias list failed with exit code $LASTEXITCODE"
}
$joined = $listOutput -join "`n"
if ($joined -notmatch 'sayhi' -or $joined -notmatch 'Echo first argument') {
    throw "alias list did not include created alias: $joined"
}

$mainHelpWithAlias = (& $ScoExe help) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "main help with alias failed with exit code $LASTEXITCODE`: $mainHelpWithAlias"
}
if ($mainHelpWithAlias -notmatch 'sayhi\s+Echo first argument') {
    throw "main help should list alias commands with summaries like Scoop: $mainHelpWithAlias"
}

$runOutput = & $ScoExe sayhi world
if ($LASTEXITCODE -ne 0) {
    throw "alias execution failed with exit code $LASTEXITCODE"
}
if (($runOutput -join "`n") -notmatch 'alias:world') {
    throw "alias execution did not pass arguments: $runOutput"
}

$uppercaseRunOutput = & $ScoExe SAYHI world
if ($LASTEXITCODE -ne 0) {
    throw "uppercase alias execution failed with exit code $LASTEXITCODE"
}
if (($uppercaseRunOutput -join "`n") -notmatch 'alias:world') {
    throw "uppercase alias execution should resolve alias command names case-insensitively: $uppercaseRunOutput"
}

$aliasHelpOutput = & $ScoExe help sayhi 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help for alias command failed with exit code $LASTEXITCODE`: $aliasHelpOutput"
}
if (($aliasHelpOutput -join "`n") -match 'alias:') {
    throw "help for alias command should not execute alias script: $aliasHelpOutput"
}

$aliasDirectHelpOutput = & $ScoExe sayhi --help 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "alias --help returned $LASTEXITCODE instead of 0 like Scoop: $aliasDirectHelpOutput"
}
if (($aliasDirectHelpOutput -join "`n") -match 'alias:') {
    throw "alias --help should forward to help instead of executing alias script: $aliasDirectHelpOutput"
}

$uppercaseAliasDirectHelpOutput = & $ScoExe SAYHI --HELP 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "uppercase alias --HELP returned $LASTEXITCODE instead of 0 like Scoop: $uppercaseAliasDirectHelpOutput"
}
if (($uppercaseAliasDirectHelpOutput -join "`n") -match 'alias:') {
    throw "uppercase alias --HELP should forward to help instead of executing alias script: $uppercaseAliasDirectHelpOutput"
}

$looseScriptPath = Join-Path $Root 'shims\scoop-loose.ps1'
@'
# Usage: scoop loose <value>
# Summary: Loose shim command
# Help: Runs a loose shim command.
Write-Output "loose:$($args[0])"
'@ | Set-Content -LiteralPath $looseScriptPath -Encoding UTF8

$looseRunOutput = & $ScoExe loose value
if ($LASTEXITCODE -ne 0) {
    throw "loose shim command execution failed with exit code $LASTEXITCODE`: $looseRunOutput"
}
if (($looseRunOutput -join "`n") -notmatch 'loose:value') {
    throw "loose shim command did not execute from shims directory like Scoop: $looseRunOutput"
}

$looseHelpOutput = & $ScoExe help loose 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help for loose shim command failed with exit code $LASTEXITCODE`: $looseHelpOutput"
}
$looseHelpJoined = $looseHelpOutput -join "`n"
if ($looseHelpJoined -notmatch 'Usage: sco loose <value>' -or $looseHelpJoined -notmatch 'Runs a loose shim command') {
    throw "help for loose shim command did not read shim script help like Scoop: $looseHelpJoined"
}

$looseDirectHelpOutput = & $ScoExe loose --help 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "loose shim --help failed with exit code $LASTEXITCODE`: $looseDirectHelpOutput"
}
$looseDirectHelpJoined = $looseDirectHelpOutput -join "`n"
if ($looseDirectHelpJoined -notmatch 'Usage: sco loose <value>' -or $looseDirectHelpJoined -match 'loose:') {
    throw "loose shim --help should be handled by Scoop's top-level help dispatcher: $looseDirectHelpJoined"
}

$mainHelpWithLooseShim = (& $ScoExe help) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "main help with loose shim command failed with exit code $LASTEXITCODE`: $mainHelpWithLooseShim"
}
if ($mainHelpWithLooseShim -notmatch 'loose\s+Loose shim command') {
    throw "main help should find shim command summaries beyond the first line like Scoop: $mainHelpWithLooseShim"
}

$wrappedTargetPath = Join-Path $Root 'wrapped-target.ps1'
@'
# Usage: scoop wrapped <value>
# Summary: Wrapped target command
# Help: Runs the wrapped target command.
Write-Output "wrapped:$($args[0])"
'@ | Set-Content -LiteralPath $wrappedTargetPath -Encoding UTF8

$wrappedShimPath = Join-Path $Root 'shims\scoop-wrapped.ps1'
$wrappedShimContent = '$path = "' + $wrappedTargetPath + '"' + "`r`n" + 'Write-Output "wrapper:$($args[0])"'
$wrappedShimContent | Set-Content -LiteralPath $wrappedShimPath -Encoding UTF8

$wrappedRunOutput = & $ScoExe wrapped value
if ($LASTEXITCODE -ne 0) {
    throw "wrapped shim command execution failed with exit code $LASTEXITCODE`: $wrappedRunOutput"
}
$wrappedRunJoined = $wrappedRunOutput -join "`n"
if ($wrappedRunJoined -notmatch 'wrapped:value' -or $wrappedRunJoined -match 'wrapper:value') {
    throw "wrapped shim command should execute the script referenced by `$path like Scoop: $wrappedRunJoined"
}

$wrappedHelpOutput = & $ScoExe help wrapped 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help for wrapped shim command failed with exit code $LASTEXITCODE`: $wrappedHelpOutput"
}
$wrappedHelpJoined = $wrappedHelpOutput -join "`n"
if ($wrappedHelpJoined -notmatch 'Usage: sco wrapped <value>' -or $wrappedHelpJoined -notmatch 'Runs the wrapped target command') {
    throw "help for wrapped shim command should read the `$path target like Scoop: $wrappedHelpJoined"
}

$mainHelpWithWrappedShim = (& $ScoExe help) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "main help with wrapped shim command failed with exit code $LASTEXITCODE`: $mainHelpWithWrappedShim"
}
if ($mainHelpWithWrappedShim -notmatch 'wrapped\s+Wrapped target command') {
    throw "main help should read `$path target summaries for shim commands like Scoop: $mainHelpWithWrappedShim"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$whichAliasOutput = & $ScoExe which sayhi 2>&1
$whichAliasExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($whichAliasExitCode -ne 0) {
    throw "which sayhi returned $whichAliasExitCode instead of 0 like Scoop: $whichAliasOutput"
}
if (($whichAliasOutput -join "`n") -notmatch "WARN  'sayhi' not found, not a scoop shim, or a broken shim\.") {
    throw "which sayhi did not match Scoop warning for alias command name: $whichAliasOutput"
}

$whichOutput = & $ScoExe which scoop-sayhi.ps1 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "which scoop-sayhi.ps1 failed with exit code $LASTEXITCODE`: $whichOutput"
}
$expectedAliasPath = ([System.IO.Path]::GetFullPath($scriptPath)).Replace('\', '/')
if (($whichOutput -join "`n") -notmatch "WARN  'scoop-sayhi\.ps1' not found, not a scoop shim, or a broken shim\.") {
    throw "which scoop-sayhi.ps1 should follow Scoop Get-Command behavior when shims is not on PATH: $whichOutput"
}

$whichNoExtensionOutput = & $ScoExe which scoop-sayhi 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "which scoop-sayhi failed with exit code $LASTEXITCODE`: $whichNoExtensionOutput"
}
if (($whichNoExtensionOutput -join "`n") -notmatch "WARN  'scoop-sayhi' not found, not a scoop shim, or a broken shim\.") {
    throw "which scoop-sayhi should follow Scoop Get-Command behavior when shims is not on PATH: $whichNoExtensionOutput"
}

Push-Location -LiteralPath (Split-Path -Parent $scriptPath)
try {
    $whichExplicitNoExtensionOutput = (& $ScoExe which .\scoop-sayhi).Trim().Replace('\', '/')
    if ($LASTEXITCODE -ne 0) {
        throw "which .\scoop-sayhi failed with exit code $LASTEXITCODE`: $whichExplicitNoExtensionOutput"
    }
    if ($whichExplicitNoExtensionOutput -ne $expectedAliasPath) {
        throw "which .\scoop-sayhi should resolve explicit extensionless alias scripts like Scoop: '$whichExplicitNoExtensionOutput', expected '$expectedAliasPath'"
    }
} finally {
    Pop-Location
}

$uppercaseWhichOutput = & $ScoExe which SCOOP-sayhi.ps1 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "which SCOOP-sayhi.ps1 failed with exit code $LASTEXITCODE`: $uppercaseWhichOutput"
}
if (($uppercaseWhichOutput -join "`n") -notmatch "WARN  'SCOOP-sayhi\.ps1' not found, not a scoop shim, or a broken shim\.") {
    throw "which SCOOP-sayhi.ps1 should follow Scoop Get-Command behavior when shims is not on PATH: $uppercaseWhichOutput"
}

Remove-Item -LiteralPath $scriptPath -Force
$brokenListOutput = & $ScoExe alias list --verbose
if ($LASTEXITCODE -ne 0) {
    throw "alias list with broken shim failed with exit code $LASTEXITCODE`: $brokenListOutput"
}
$brokenJoined = $brokenListOutput -join "`n"
if ($brokenJoined -notmatch 'sayhi\s+<BROKEN>' -or $brokenJoined -match '<BROKEN>\s+<BROKEN>') {
    throw "alias list did not match Scoop broken alias output: $brokenJoined"
}

$brokenRmOutput = & $ScoExe alias rm sayhi
if ($LASTEXITCODE -ne 0) {
    throw "alias rm for broken alias failed with exit code $LASTEXITCODE`: $brokenRmOutput"
}
if (($brokenRmOutput -join "`n") -notmatch "INFO  Removing alias 'sayhi'\.\.\.") {
    throw "alias rm for broken alias did not match Scoop info output: $brokenRmOutput"
}

$reAddOutput = & $ScoExe alias add sayhi 'Write-Output "alias:$($args[0])"' 'Echo first argument'
if ($LASTEXITCODE -ne 0) {
    throw "alias re-add failed with exit code $LASTEXITCODE`: $reAddOutput"
}
if (($reAddOutput -join "`n").Trim()) {
    throw "alias re-add should not print output on success: $reAddOutput"
}
if (!(Test-Path $scriptPath)) {
    throw 'alias re-add did not recreate shim script'
}

$rmOutput = & $ScoExe alias rm SAYHI
if ($LASTEXITCODE -ne 0) {
    throw "alias rm failed with exit code $LASTEXITCODE`: $rmOutput"
}
if (($rmOutput -join "`n") -notmatch "INFO  Removing alias 'SAYHI'\.\.\.") {
    throw "alias rm did not match Scoop info output: $rmOutput"
}
if (Test-Path $scriptPath) {
    throw 'alias rm did not remove shim script'
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($null -ne $config.alias.sayhi) {
    throw 'alias rm did not remove config alias entry'
}

$dottedAddOutput = & $ScoExe alias add dot.name 'Write-Output "dot:$($args[0])"' 'Dotted alias'
if ($LASTEXITCODE -ne 0) {
    throw "alias add with dotted name failed with exit code $LASTEXITCODE`: $dottedAddOutput"
}
if (($dottedAddOutput -join "`n").Trim()) {
    throw "alias add with dotted name should not print output on success: $dottedAddOutput"
}

$dottedScriptPath = Join-Path $Root 'shims\scoop-dot.name.ps1'
if (!(Test-Path $dottedScriptPath)) {
    throw 'alias add with dotted name did not create shim script like Scoop'
}

$dottedRunOutput = & $ScoExe dot.name value
if ($LASTEXITCODE -ne 0) {
    throw "dotted alias execution failed with exit code $LASTEXITCODE`: $dottedRunOutput"
}
if (($dottedRunOutput -join "`n") -notmatch 'dot:value') {
    throw "dotted alias execution did not pass arguments: $dottedRunOutput"
}

$dottedListOutput = (& $ScoExe alias list) -join "`n"
if ($LASTEXITCODE -ne 0 -or $dottedListOutput -notmatch 'dot\.name') {
    throw "alias list did not include dotted alias name: $dottedListOutput"
}

$dottedRmOutput = & $ScoExe alias rm dot.name
if ($LASTEXITCODE -ne 0) {
    throw "alias rm with dotted name failed with exit code $LASTEXITCODE`: $dottedRmOutput"
}
if (Test-Path $dottedScriptPath) {
    throw 'alias rm with dotted name did not remove shim script'
}
