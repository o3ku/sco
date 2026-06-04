param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$ScoopPs1,
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

New-Item -ItemType Directory -Force -Path $Root, (Join-Path $Root 'shims') | Out-Null
$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:SCOOP_HOME = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ScoopPs1) '..'))

function Normalize-ToolText {
    param([string]$Text)

    (($Text -replace "`r`n", "`n") -replace "`r", "`n") `
        -replace "`e\[[0-9;?]*[ -/]*[@-~]", '' `
        -replace '\bscoop\b', 'sco'
}

function Normalize-Line {
    param([string]$Line)

    (Normalize-ToolText $Line).Trim() -replace '\s+', ' '
}

function Invoke-PairedTool {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('sco', 'scoop')][string]$Tool,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Tool -eq 'sco') {
            $output = & $ScoExe @Arguments 2>&1
        } else {
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScoopPs1 @Arguments 2>&1
        }
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Lines = @($output | ForEach-Object { [string]$_ })
            Text = (($output | ForEach-Object { [string]$_ }) -join "`n")
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-HelpRows {
    param([string[]]$Lines)

    $rows = [ordered]@{}
    foreach ($line in $Lines) {
        $normalized = Normalize-Line $line
        if ($normalized -match '^([a-z][a-z0-9-]*)\s+(.+)$' -and
            $matches[1] -notin @('Usage', 'Available', 'Type', 'Command')) {
            $command = $matches[1]
            $summary = $matches[2]
        if ($command -notin @('At', 'Cannot', 'Get-ChildItem') -and $summary -notmatch '^-+$') {
            $rows[$command] = $summary
        }
        }
    }
    return $rows
}

function Get-UsageLine {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        $normalized = Normalize-Line $line
        if ($normalized -match '^Usage: ') {
            return $normalized
        }
    }
    return ''
}

$scoHelp = Invoke-PairedTool sco help
$scoopHelp = Invoke-PairedTool scoop help
if ($scoHelp.ExitCode -ne $scoopHelp.ExitCode) {
    throw "help exit codes differ: sco=$($scoHelp.ExitCode), scoop=$($scoopHelp.ExitCode)"
}

$scoRows = Get-HelpRows $scoHelp.Lines
$scoopRows = Get-HelpRows $scoopHelp.Lines
$scoCommands = @($scoRows.Keys)
$scoopCommands = @($scoopRows.Keys)

if (($scoCommands -join ',') -ne ($scoopCommands -join ',')) {
    throw "help command lists differ.`nsco:   $($scoCommands -join ', ')`nscoop: $($scoopCommands -join ', ')"
}

foreach ($command in $scoopCommands) {
    if ($scoRows[$command] -ne $scoopRows[$command]) {
        throw "help summary differs for '$command'.`nsco:   $($scoRows[$command])`nscoop: $($scoopRows[$command])"
    }
}

foreach ($command in $scoopCommands) {
    $scoCommandHelp = Invoke-PairedTool sco help $command
    $scoopCommandHelp = Invoke-PairedTool scoop help $command
    if ($scoCommandHelp.ExitCode -ne $scoopCommandHelp.ExitCode) {
        throw "help $command exit codes differ: sco=$($scoCommandHelp.ExitCode), scoop=$($scoopCommandHelp.ExitCode)"
    }

    $scoUsage = Get-UsageLine $scoCommandHelp.Lines
    $scoopUsage = Get-UsageLine $scoopCommandHelp.Lines
    if ($scoUsage -ne $scoopUsage) {
        throw "help $command usage differs.`nsco:   $scoUsage`nscoop: $scoopUsage"
    }
}

foreach ($command in @('definitely-not-a-command', 'version', 'manifest')) {
    $scoMissing = Invoke-PairedTool sco help $command
    $scoopMissing = Invoke-PairedTool scoop help $command
    if ($scoMissing.ExitCode -ne $scoopMissing.ExitCode) {
        throw "missing help '$command' exit codes differ: sco=$($scoMissing.ExitCode), scoop=$($scoopMissing.ExitCode)"
    }
    $scoMissingText = Normalize-Line $scoMissing.Text
    $scoopMissingText = Normalize-Line $scoopMissing.Text
    if ($scoMissingText -ne $scoopMissingText) {
        throw "missing help '$command' output differs.`nsco:   $scoMissingText`nscoop: $scoopMissingText"
    }
}
