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

New-Item -ItemType Directory -Force -Path @(
    $Root,
    (Join-Path $Root 'shims'),
    (Join-Path $Root 'cache'),
    (Join-Path $Root 'buckets'),
    (Join-Path $Root 'buckets\main\bucket')
) | Out-Null

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:SCOOP_HOME = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ScoopPs1) '..'))

function Normalize-Output {
    param([string[]]$Lines)

    $normalized = @($Lines | ForEach-Object {
        ([string]$_ -replace "`r", '') `
            -replace "`e\[[0-9;?]*[ -/]*[@-~]", '' `
            -replace '\bscoop\b', 'sco'
    } | ForEach-Object {
        $_.TrimEnd()
    })

    while ($normalized.Count -gt 0 -and $normalized[-1] -eq '') {
        $normalized = @($normalized[0..($normalized.Count - 2)])
    }
    return ($normalized -join "`n")
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
            @(& $ScoExe @Arguments 2>&1 | ForEach-Object { [string]$_ })
        } else {
            @(& powershell -NoProfile -ExecutionPolicy Bypass -File $ScoopPs1 @Arguments 2>&1 | ForEach-Object { [string]$_ })
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

$cases = @(
    @('alias'),
    @('bucket'),
    @('cache'),
    @('config', 'missing_key'),
    @('list'),
    @('install'),
    @('download'),
    @('uninstall'),
    @('reset'),
    @('which'),
    @('depends'),
    @('cat'),
    @('create'),
    @('home'),
    @('info'),
    @('prefix'),
    @('shim'),
    @('status', '--local'),
    @('virustotal'),
    @('checkup')
)

foreach ($case in $cases) {
    $scoOutput = Normalize-Output (Invoke-PairedTool sco @case)
    $scoopOutput = Normalize-Output (Invoke-PairedTool scoop @case)
    if ($scoOutput -ne $scoopOutput) {
        throw "basic output differs for '$($case -join ' ')'.`nsco:`n$scoOutput`n---`nscoop:`n$scoopOutput"
    }
}
