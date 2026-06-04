param(
    [Parameter(Mandatory = $true)][string]$ScoExe
)

$ErrorActionPreference = 'Stop'

$installHelp = & $ScoExe help install 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help install failed with exit code ${LASTEXITCODE}: $installHelp"
}
if (($installHelp -join "`n") -notmatch 'Usage: sco install <app>') {
    throw "help install did not show install usage: $installHelp"
}
$installHelpJoined = $installHelp -join "`n"
if ($installHelpJoined -notmatch "The usual way to install an app \(uses your local 'buckets'\)" -or
    $installHelpJoined -notmatch 'sco install gh@2\.7\.0' -or
    $installHelpJoined -notmatch 'sco install https://raw\.githubusercontent\.com/ScoopInstaller/Main/master/bucket/runat\.json' -or
    $installHelpJoined -notmatch 'sco install \\path\\to\\app\.json@version' -or
    $installHelpJoined -notmatch 'Skip hash validation \(use with caution!\)' -or
    $installHelpJoined -notmatch "Don't update Scoop before installing if it's outdated") {
    throw "help install should include Scoop-style install examples and option wording: $installHelpJoined"
}

$uppercaseInstallHelp = & $ScoExe HELP INSTALL 2>&1
if ($LASTEXITCODE -ne 0 -or ($uppercaseInstallHelp -join "`n") -notmatch 'Usage: sco install <app>') {
    throw "HELP INSTALL should resolve command names case-insensitively like Scoop: $uppercaseInstallHelp"
}

$uppercaseDirectInstallHelp = & $ScoExe INSTALL --HELP 2>&1
if ($LASTEXITCODE -ne 0 -or ($uppercaseDirectInstallHelp -join "`n") -notmatch 'Usage: sco install <app>') {
    throw "INSTALL --HELP should resolve command and help option case-insensitively like Scoop: $uppercaseDirectInstallHelp"
}

$helpHelp = & $ScoExe help help 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help help failed with exit code ${LASTEXITCODE}: $helpHelp"
}
if (($helpHelp -join "`n") -notmatch 'Usage: sco help <command>') {
    throw "help help did not show help command usage: $helpHelp"
}

foreach ($helpArg in @('-h', '--help', '/?')) {
    $directHelp = & $ScoExe install $helpArg 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "install $helpArg failed with exit code ${LASTEXITCODE}: $directHelp"
    }
    if (($directHelp -join "`n") -notmatch 'Usage: sco install <app>') {
        throw "install $helpArg should forward to install help like Scoop: $directHelp"
    }
}

$statusHelp = & $ScoExe help status 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help status failed with exit code ${LASTEXITCODE}: $statusHelp"
}
$statusHelpJoined = $statusHelp -join "`n"
if ($statusHelpJoined -notmatch 'Usage: sco status' -or $statusHelpJoined -match 'Usage: sco status \[-l\|--local\]') {
    throw "help status should match Scoop usage without embedding options in the usage line: $statusHelpJoined"
}
if ($statusHelpJoined -notmatch '-l, --local') {
    throw "help status should still document the Scoop --local option: $statusHelpJoined"
}

$createHelp = & $ScoExe help create 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help create failed with exit code ${LASTEXITCODE}: $createHelp"
}
$createHelpJoined = $createHelp -join "`n"
if ($createHelpJoined -notmatch 'Usage: sco create <url>' -or $createHelpJoined -match 'Usage: sco create <url> \[options\]') {
    throw "help create should match Scoop usage without advertising sco-only non-interactive options: $createHelpJoined"
}

$exportHelp = & $ScoExe help export 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help export failed with exit code ${LASTEXITCODE}: $exportHelp"
}
$exportHelpJoined = $exportHelp -join "`n"
if ($exportHelpJoined -notmatch 'Usage: sco export > scoopfile\.json' -or $exportHelpJoined -match 'Usage: sco export \[options\]') {
    throw "help export should match Scoop redirection-style usage: $exportHelpJoined"
}
if ($exportHelpJoined -notmatch 'Exports installed apps, buckets \(and optionally configs\) in JSON format' -or
    $exportHelpJoined -notmatch '-c, --config\s+Export the Scoop configuration file too') {
    throw "help export should include Scoop-style export documentation: $exportHelpJoined"
}

$dependsHelp = & $ScoExe help depends 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help depends failed with exit code ${LASTEXITCODE}: $dependsHelp"
}
$dependsHelpJoined = $dependsHelp -join "`n"
if ($dependsHelpJoined -notmatch 'Usage: sco depends <app>' -or $dependsHelpJoined -match 'Usage: sco depends <app> \[options\]') {
    throw "help depends should match Scoop usage without embedding options in the usage line: $dependsHelpJoined"
}
if ($dependsHelpJoined -notmatch "List dependencies for an app, in the order they'll be installed" -or
    $dependsHelpJoined -notmatch '-a, --arch') {
    throw "help depends should include Scoop-style depends documentation: $dependsHelpJoined"
}

$checkupHelp = & $ScoExe help checkup 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help checkup failed with exit code ${LASTEXITCODE}: $checkupHelp"
}
$checkupHelpJoined = $checkupHelp -join "`n"
if ($checkupHelpJoined -notmatch 'Usage: sco checkup' -or
    $checkupHelpJoined -notmatch 'Performs a series of diagnostic tests to try to identify things that may' -or
    $checkupHelpJoined -notmatch 'cause problems with Scoop\.') {
    throw "help checkup should include Scoop-style checkup documentation: $checkupHelpJoined"
}

$downloadHelp = & $ScoExe help download 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help download failed with exit code ${LASTEXITCODE}: $downloadHelp"
}
$downloadHelpJoined = $downloadHelp -join "`n"
if ($downloadHelpJoined -notmatch 'Usage: sco download <app> \[options\]' -or
    $downloadHelpJoined -notmatch "The usual way to download an app, without installing it \(uses your local 'buckets'\)" -or
    $downloadHelpJoined -notmatch 'sco download gh@2\.7\.0' -or
    $downloadHelpJoined -notmatch 'sco download https://raw\.githubusercontent\.com/ScoopInstaller/Main/master/bucket/runat\.json' -or
    $downloadHelpJoined -notmatch 'sco download path\\to\\app\.json' -or
    $downloadHelpJoined -notmatch 'Force download \(overwrite cache\)' -or
    $downloadHelpJoined -notmatch 'Skip hash verification \(use with caution!\)') {
    throw "help download should include Scoop-style download examples and option wording: $downloadHelpJoined"
}

$searchHelp = & $ScoExe help search 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help search failed with exit code ${LASTEXITCODE}: $searchHelp"
}
$searchHelpJoined = $searchHelp -join "`n"
if ($searchHelpJoined -notmatch 'Usage: sco search <query>' -or $searchHelpJoined -match 'Usage: sco search \[query\]') {
    throw "help search should match Scoop usage line: $searchHelpJoined"
}
if ($searchHelpJoined -notmatch 'Searches for apps that are available to install\.' -or
    $searchHelpJoined -notmatch 'If used with \[query\], shows app names that match the query\.' -or
    $searchHelpJoined -notmatch "With 'use_sqlite_cache' enabled" -or
    $searchHelpJoined -notmatch 'Without \[query\], shows all the available apps\.') {
    throw "help search should include Scoop-style search documentation: $searchHelpJoined"
}

$configHelp = & $ScoExe help config 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help config failed with exit code ${LASTEXITCODE}: $configHelp"
}
$configHelpJoined = $configHelp -join "`n"
if ($configHelpJoined -notmatch 'Usage: sco config \[rm\] name \[value\]' -or
    $configHelpJoined -notmatch 'Settings' -or
    $configHelpJoined -notmatch 'use_sqlite_cache: \$true\|\$false' -or
    $configHelpJoined -notmatch 'use_isolated_path: \$true\|\$false\|\[string\]' -or
    $configHelpJoined -notmatch 'ARIA2 configuration' -or
    $configHelpJoined -notmatch 'aria2-options:') {
    throw "help config should include Scoop-style configuration documentation: $configHelpJoined"
}

$aliasHelp = & $ScoExe help alias 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help alias failed with exit code ${LASTEXITCODE}: $aliasHelp"
}
$aliasHelpJoined = $aliasHelp -join "`n"
if ($aliasHelpJoined -notmatch 'Usage: sco alias <subcommand> \[options\] \[<args>\]' -or
    $aliasHelpJoined -notmatch 'Available subcommands: add, rm, list\.' -or
    $aliasHelpJoined -notmatch 'Aliases are custom Scoop subcommands' -or
    $aliasHelpJoined -notmatch 'sco alias add <name> <command> \[<description>\]' -or
    $aliasHelpJoined -notmatch '-v, --verbose') {
    throw "help alias should include Scoop-style alias documentation: $aliasHelpJoined"
}

$catHelp = & $ScoExe help cat 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help cat failed with exit code ${LASTEXITCODE}: $catHelp"
}
$catHelpJoined = $catHelp -join "`n"
if ($catHelpJoined -notmatch 'Usage: sco cat <app>' -or
    $catHelpJoined -notmatch 'Show content of specified manifest\.' -or
    $catHelpJoined -notmatch 'bat.+pretty-print the JSON' -or
    $catHelpJoined -notmatch 'cat_style') {
    throw "help cat should include Scoop-style cat documentation: $catHelpJoined"
}

$cacheHelp = & $ScoExe help cache 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help cache failed with exit code ${LASTEXITCODE}: $cacheHelp"
}
$cacheHelpJoined = $cacheHelp -join "`n"
if ($cacheHelpJoined -notmatch 'Usage: sco cache show\|rm \[app\(s\)\]' -or
    $cacheHelpJoined -notmatch 'Scoop caches downloads' -or
    $cacheHelpJoined -notmatch 'sco cache show' -or
    $cacheHelpJoined -notmatch 'sco cache rm <app>' -or
    $cacheHelpJoined -notmatch 'sco cache rm \*' -or
    $cacheHelpJoined -notmatch '-a, --all') {
    throw "help cache should include Scoop-style cache documentation: $cacheHelpJoined"
}

$bucketHelp = & $ScoExe help bucket 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help bucket failed with exit code ${LASTEXITCODE}: $bucketHelp"
}
$bucketHelpJoined = $bucketHelp -join "`n"
if ($bucketHelpJoined -notmatch 'Usage: sco bucket add\|list\|known\|rm \[<args>\]' -or
    $bucketHelpJoined -notmatch 'Add, list or remove buckets\.' -or
    $bucketHelpJoined -notmatch 'Buckets are repositories of apps available to install' -or
    $bucketHelpJoined -notmatch 'sco bucket add <name> \[<repo>\]' -or
    $bucketHelpJoined -notmatch 'sco bucket known') {
    throw "help bucket should include Scoop-style bucket documentation: $bucketHelpJoined"
}

$listHelp = & $ScoExe help list 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help list failed with exit code ${LASTEXITCODE}: $listHelp"
}
$listHelpJoined = $listHelp -join "`n"
if ($listHelpJoined -notmatch 'Usage: sco list \[query\]' -or
    $listHelpJoined -notmatch 'Lists all installed apps, or the apps matching the supplied query\.') {
    throw "help list should include Scoop-style list documentation: $listHelpJoined"
}

$whichHelp = & $ScoExe help which 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help which failed with exit code ${LASTEXITCODE}: $whichHelp"
}
$whichHelpJoined = $whichHelp -join "`n"
if ($whichHelpJoined -notmatch 'Usage: sco which <command>' -or
    $whichHelpJoined -notmatch 'Locate the path to a shim/executable that was installed with Scoop') {
    throw "help which should include Scoop-style which documentation: $whichHelpJoined"
}

$cleanupHelp = & $ScoExe help cleanup 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help cleanup failed with exit code ${LASTEXITCODE}: $cleanupHelp"
}
$cleanupHelpJoined = $cleanupHelp -join "`n"
if ($cleanupHelpJoined -notmatch 'Usage: sco cleanup <app> \[options\]' -or
    $cleanupHelpJoined -notmatch "'sco cleanup' cleans Scoop apps by removing old versions\." -or
    $cleanupHelpJoined -notmatch "You can use '\*' in place of <app>" -or
    $cleanupHelpJoined -notmatch '-a, --all\s+Cleanup all apps' -or
    $cleanupHelpJoined -notmatch '-k, --cache\s+Remove outdated download cache') {
    throw "help cleanup should include Scoop-style cleanup documentation: $cleanupHelpJoined"
}

$holdHelp = & $ScoExe help hold 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help hold failed with exit code ${LASTEXITCODE}: $holdHelp"
}
$holdHelpJoined = $holdHelp -join "`n"
if ($holdHelpJoined -notmatch 'Usage: sco hold <apps>' -or
    $holdHelpJoined -notmatch 'To hold a user-scoped app:' -or
    $holdHelpJoined -notmatch 'sco hold <app>' -or
    $holdHelpJoined -notmatch 'To hold a global app:' -or
    $holdHelpJoined -notmatch 'sco hold -g <app>') {
    throw "help hold should include Scoop-style hold documentation: $holdHelpJoined"
}

$unholdHelp = & $ScoExe help unhold 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help unhold failed with exit code ${LASTEXITCODE}: $unholdHelp"
}
$unholdHelpJoined = $unholdHelp -join "`n"
if ($unholdHelpJoined -notmatch 'Usage: sco unhold <app>' -or
    $unholdHelpJoined -notmatch 'To unhold a user-scoped app:' -or
    $unholdHelpJoined -notmatch 'sco unhold <app>' -or
    $unholdHelpJoined -notmatch 'To unhold a global app:' -or
    $unholdHelpJoined -notmatch 'sco unhold -g <app>') {
    throw "help unhold should include Scoop-style unhold documentation: $unholdHelpJoined"
}

$importHelp = & $ScoExe help import 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help import failed with exit code ${LASTEXITCODE}: $importHelp"
}
$importHelpJoined = $importHelp -join "`n"
if ($importHelpJoined -notmatch 'Usage: sco import <path/url to scoopfile\.json>' -or
    $importHelpJoined -notmatch 'To replicate a Scoop installation from a file stored on Desktop' -or
    $importHelpJoined -notmatch 'sco import Desktop\\scoopfile\.json') {
    throw "help import should include Scoop-style import documentation: $importHelpJoined"
}

$resetHelp = & $ScoExe help reset 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help reset failed with exit code ${LASTEXITCODE}: $resetHelp"
}
$resetHelpJoined = $resetHelp -join "`n"
if ($resetHelpJoined -notmatch 'Usage: sco reset <app>' -or
    $resetHelpJoined -notmatch 'Used to resolve conflicts in favor of a particular app' -or
    $resetHelpJoined -notmatch "if you've installed 'python' and 'python27'" -or
    $resetHelpJoined -notmatch "You can use '\*' in place of <app>" -or
    $resetHelpJoined -notmatch '-a, --all\s+Reset all installed apps') {
    throw "help reset should include Scoop-style reset documentation: $resetHelpJoined"
}

$uninstallHelp = & $ScoExe help uninstall 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help uninstall failed with exit code ${LASTEXITCODE}: $uninstallHelp"
}
$uninstallHelpJoined = $uninstallHelp -join "`n"
if ($uninstallHelpJoined -notmatch 'Usage: sco uninstall <app> \[options\]' -or
    $uninstallHelpJoined -notmatch 'e\.g\. sco uninstall git' -or
    $uninstallHelpJoined -notmatch '-g, --global\s+Uninstall a globally installed app' -or
    $uninstallHelpJoined -notmatch '-p, --purge\s+Remove all persistent data') {
    throw "help uninstall should include Scoop-style uninstall documentation: $uninstallHelpJoined"
}

$virustotalHelp = & $ScoExe help virustotal 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help virustotal failed with exit code ${LASTEXITCODE}: $virustotalHelp"
}
$virustotalHelpJoined = $virustotalHelp -join "`n"
if ($virustotalHelpJoined -notmatch 'Usage: sco virustotal \[\* \| app1 app2 \.\.\.\] \[options\]' -or
    $virustotalHelpJoined -notmatch "Look for app's hash or url on virustotal\.com" -or
    $virustotalHelpJoined -notmatch "Use a single '\*' or the '-a/--all' switch to check all installed apps\." -or
    $virustotalHelpJoined -notmatch 'sco config virustotal_api_key <your API key: 64 lower case hex digits>' -or
    $virustotalHelpJoined -notmatch 'Exit codes:' -or
    $virustotalHelpJoined -notmatch '16 -> VirusTotal API key is not configured' -or
    $virustotalHelpJoined -notmatch '-s, --scan\s+For packages where VirusTotal has no information, send download URL' -or
    $virustotalHelpJoined -notmatch 'for analysis \(and future retrieval\)\. This requires you to configure' -or
    $virustotalHelpJoined -notmatch '-n, --no-depends\s+By default, all dependencies are checked too\. This flag avoids it\.' -or
    $virustotalHelpJoined -notmatch "-u, --no-update-scoop\s+Don't update Scoop before checking if it's outdated" -or
    $virustotalHelpJoined -notmatch '-p, --passthru\s+Return reports as objects') {
    throw "help virustotal should include Scoop-style virustotal documentation: $virustotalHelpJoined"
}

$updateHelp = & $ScoExe help update 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help update failed with exit code ${LASTEXITCODE}: $updateHelp"
}
$updateHelpJoined = $updateHelp -join "`n"
if ($updateHelpJoined -notmatch 'Usage: sco update <app> \[options\]' -or
    $updateHelpJoined -notmatch "'sco update' updates Scoop to the latest version\." -or
    $updateHelpJoined -notmatch "'sco update <app>' installs a new version of that app, if there is one\." -or
    $updateHelpJoined -notmatch "You can use '\*' in place of <app> to update all apps\." -or
    $updateHelpJoined -notmatch '-s, --skip-hash-check\s+Skip hash validation \(use with caution!\)' -or
    $updateHelpJoined -notmatch '-q, --quiet\s+Hide extraneous messages' -or
    $updateHelpJoined -notmatch "-a, --all\s+Update all apps \(alternative to '\*'\)") {
    throw "help update should include Scoop-style update documentation: $updateHelpJoined"
}

$shimHelp = & $ScoExe help shim 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help shim failed with exit code ${LASTEXITCODE}: $shimHelp"
}
$shimHelpJoined = $shimHelp -join "`n"
if ($shimHelpJoined -notmatch 'Usage: sco shim <subcommand> \[<shim_name>\.\.\.\] \[options\] \[other_args\]' -or
    $shimHelpJoined -notmatch 'Available subcommands: add, rm, list, info, alter\.' -or
    $shimHelpJoined -notmatch 'sco shim add <shim_name> <command_path> \[<args>\.\.\.\]' -or
    $shimHelpJoined -notmatch 'sco shim rm <shim_name> \[<shim_name>\.\.\.\]' -or
    $shimHelpJoined -notmatch 'sco shim list \[<regex_pattern>\.\.\.\]' -or
    $shimHelpJoined -notmatch 'sco shim info <shim_name>' -or
    $shimHelpJoined -notmatch 'sco shim alter <shim_name>' -or
    $shimHelpJoined -notmatch "The FIRST double-hyphen '--'") {
    throw "help shim should include Scoop-style shim documentation: $shimHelpJoined"
}

$infoHelp = & $ScoExe help info 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help info failed with exit code ${LASTEXITCODE}: $infoHelp"
}
$infoHelpJoined = $infoHelp -join "`n"
if ($infoHelpJoined -notmatch 'Usage: sco info <app> \[options\]' -or
    $infoHelpJoined -notmatch '-v, --verbose\s+Show full paths and URLs') {
    throw "help info should include Scoop-style info documentation: $infoHelpJoined"
}

$homeHelp = & $ScoExe help home 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help home failed with exit code ${LASTEXITCODE}: $homeHelp"
}
$homeHelpJoined = $homeHelp -join "`n"
if ($homeHelpJoined -notmatch 'Usage: sco home <app>' -or
    $homeHelpJoined -notmatch 'Opens the app homepage') {
    throw "help home should include Scoop-style home summary: $homeHelpJoined"
}

$prefixHelp = & $ScoExe help prefix 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "help prefix failed with exit code ${LASTEXITCODE}: $prefixHelp"
}
$prefixHelpJoined = $prefixHelp -join "`n"
if ($prefixHelpJoined -notmatch 'Usage: sco prefix <app>' -or
    $prefixHelpJoined -notmatch 'Returns the path to the specified app') {
    throw "help prefix should include Scoop-style prefix summary: $prefixHelpJoined"
}

$expectedUsage = [ordered]@{
    bucket = 'Usage: sco bucket add\|list\|known\|rm \[<args>\]'
    hold = 'Usage: sco hold <apps>'
    home = 'Usage: sco home <app>'
    import = 'Usage: sco import <path/url to scoopfile\.json>'
    init = 'Usage: sco init'
    reset = 'Usage: sco reset <app>'
    unhold = 'Usage: sco unhold <app>'
    update = 'Usage: sco update <app> \[options\]'
}
$legacyUsage = [ordered]@{
    bucket = 'Usage: sco bucket add\|list\|known\|rm \[args\]'
    hold = 'Usage: sco hold <app> \[options\]'
    home = 'Usage: sco home <app> \[options\]'
    import = 'Usage: sco import <path-or-url-to-scoopfile\.json>'
    init = 'Usage: scoop init'
    reset = 'Usage: sco reset <app> \[version\] \[options\]'
    unhold = 'Usage: sco unhold <app> \[options\]'
    update = 'Usage: sco update \[<app>\|\*\] \[options\]'
}
foreach ($entry in $expectedUsage.GetEnumerator()) {
    $commandHelp = & $ScoExe help $entry.Key 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "help $($entry.Key) failed with exit code ${LASTEXITCODE}: $commandHelp"
    }
    $commandHelpJoined = $commandHelp -join "`n"
    if ($commandHelpJoined -notmatch $entry.Value -or $commandHelpJoined -match $legacyUsage[$entry.Key]) {
        throw "help $($entry.Key) should match Scoop usage: $commandHelpJoined"
    }
}

$mainHelp = & $ScoExe help
if ($LASTEXITCODE -ne 0) {
    throw "help failed with exit code ${LASTEXITCODE}: $mainHelp"
}
$mainHelpJoined = $mainHelp -join "`n"
if ($mainHelpJoined -notmatch 'Usage: sco <command> \[<args>\]' -or
    $mainHelpJoined -notmatch 'Available commands are listed below\.' -or
    $mainHelpJoined -notmatch "Type 'sco help <command>' to get more help for a specific command\." -or
    $mainHelpJoined -notmatch 'Command\s+Summary') {
    throw "main help should use Scoop-style heading and summary intro: $mainHelpJoined"
}
if ($mainHelpJoined -notmatch '(?m)^\s*Command\s+Summary\s*$' -or
    $mainHelpJoined -notmatch '(?m)^\s*-{7,}\s+-{7,}\s*$') {
    throw "main help should use the unified table header separator: $mainHelpJoined"
}
if ($mainHelpJoined -notmatch 'bucket\s{2,}Manage Scoop buckets' -or
    $mainHelpJoined -notmatch 'create\s{2,}Create a custom app manifest' -or
    $mainHelpJoined -notmatch 'update\s{2,}Update apps, or Scoop itself' -or
    $mainHelpJoined -notmatch 'which\s{2,}Locate a shim/executable') {
    throw "main help should list Scoop command summaries: $mainHelpJoined"
}
$expectedMainCommands = @(
    'alias', 'bucket', 'cache', 'cat', 'checkup', 'cleanup', 'config', 'create', 'depends',
    'download', 'export', 'help', 'hold', 'home', 'import', 'info', 'install', 'list',
    'prefix', 'reset', 'search', 'shim', 'status', 'unhold', 'uninstall', 'update',
    'virustotal', 'which'
)
$mainCommands = @($mainHelp | ForEach-Object {
    if ($_ -cmatch '^\s{2}([a-z][a-z0-9-]*)\s{2,}') { $matches[1] }
})
if ($mainCommands.Count -ne $expectedMainCommands.Count) {
    throw "main help should list $($expectedMainCommands.Count) Scoop-compatible commands, got $($mainCommands.Count): $mainHelpJoined"
}
foreach ($command in $expectedMainCommands) {
    if ($mainCommands -notcontains $command) {
        throw "main help is missing Scoop command '$command': $mainHelpJoined"
    }
}
if ($mainHelpJoined -match 'bucket add\|list\|known\|rm\|update' -or
    $mainHelpJoined -match 'create <url> \[options\]' -or
    $mainHelpJoined -match 'export \[options\]' -or
    $mainHelpJoined -match 'home <app> \[options\]' -or
    $mainHelpJoined -match 'shim add\|rm\|list') {
    throw "main help should not advertise sco-only usage forms or hidden extensions: $mainHelpJoined"
}
if ($mainCommands -contains 'init' -or
    $mainCommands -contains 'checkhashes' -or
    $mainCommands -contains 'checkurls' -or
    $mainCommands -contains 'checkver' -or
    $mainCommands -contains 'describe' -or
    $mainCommands -contains 'formatjson' -or
    $mainCommands -contains 'manifest' -or
    $mainCommands -contains 'missing-checkver' -or
    $mainCommands -contains 'version') {
    throw "main help should only list commands exposed by Scoop help, not sco-only extensions: $mainHelpJoined"
}

foreach ($hiddenCommand in @('manifest', 'version')) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $hiddenHelp = & $ScoExe help $hiddenCommand 2>&1
    $hiddenExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($hiddenExitCode -ne 0) {
        throw "help $hiddenCommand returned ${hiddenExitCode} instead of 0 like Scoop: $hiddenHelp"
    }
    if (($hiddenHelp -join "`n") -notmatch "WARN  scoop help: no such command '$hiddenCommand'") {
        throw "help $hiddenCommand should not expose sco-only helper command: $hiddenHelp"
    }
}

foreach ($hiddenCommand in @('MANIFEST', 'VERSION')) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $hiddenHelp = & $ScoExe HELP $hiddenCommand 2>&1
    $hiddenExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($hiddenExitCode -ne 0) {
        throw "HELP $hiddenCommand returned ${hiddenExitCode} instead of 0 like Scoop: $hiddenHelp"
    }
    if (($hiddenHelp -join "`n") -notmatch "WARN  scoop help: no such command '$hiddenCommand'") {
        throw "HELP $hiddenCommand should preserve input casing like Scoop: $hiddenHelp"
    }
}

foreach ($versionArg in @('-v', '--version')) {
    $versionOutput = & $ScoExe $versionArg 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$versionArg failed with exit code ${LASTEXITCODE}: $versionOutput"
    }
    $versionJoined = $versionOutput -join "`n"
    if ($versionJoined -notmatch 'Current Scoop version:' -or $versionJoined -notmatch 'sco 0\.1\.0') {
        throw "$versionArg should use Scoop-style version heading: $versionJoined"
    }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$bareVersion = & $ScoExe version 2>&1
$bareVersionExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($bareVersionExitCode -ne 1) {
    throw "bare version command returned ${bareVersionExitCode} instead of 1 like Scoop: $bareVersion"
}
if (($bareVersion -join "`n") -notmatch "WARN  scoop: 'version' isn't a scoop command\. See 'sco help'\.") {
    throw "bare version command should not be accepted as a Scoop command: $bareVersion"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$unknownCommand = & $ScoExe definitely-not-a-command 2>&1
$unknownCommandExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($unknownCommandExitCode -ne 1) {
    throw "unknown command returned ${unknownCommandExitCode} instead of 1: $unknownCommand"
}
if (($unknownCommand -join "`n") -notmatch "WARN  scoop: 'definitely-not-a-command' isn't a scoop command\. See 'sco help'\.") {
    throw "unknown command did not match Scoop warning: $unknownCommand"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$unknownHelp = & $ScoExe help definitely-not-a-command 2>&1
$unknownExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($unknownExitCode -ne 0) {
    throw "help unknown returned ${unknownExitCode} instead of 0: $unknownHelp"
}
if (($unknownHelp -join "`n") -notmatch "WARN  scoop help: no such command 'definitely-not-a-command'") {
    throw "help unknown did not match Scoop warning: $unknownHelp"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$uppercaseUnknownHelp = & $ScoExe help DEFINITELY-NOT-A-COMMAND 2>&1
$uppercaseUnknownExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($uppercaseUnknownExitCode -ne 0) {
    throw "help uppercase unknown returned ${uppercaseUnknownExitCode} instead of 0: $uppercaseUnknownHelp"
}
if (($uppercaseUnknownHelp -join "`n") -notmatch "WARN  scoop help: no such command 'DEFINITELY-NOT-A-COMMAND'") {
    throw "help uppercase unknown should preserve input casing like Scoop: $uppercaseUnknownHelp"
}
