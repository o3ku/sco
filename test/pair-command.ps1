param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$ScoopPs1,
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
$shimDir = Join-Path $Root 'shims'
New-Item -ItemType Directory -Force -Path $bucketDir, $shimDir | Out-Null

$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
}
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'pairtool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:SCOOP_HOME = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ScoopPs1) '..'))
$env:SCOOP_CACHE = Join-Path $Root 'cache'

$artifactPath = [System.IO.Path]::GetFullPath($Artifact)
$legacyCacheName = 'pairtool#1.0.0#' + ($artifactPath -replace '[^\w\.\-]+', '_')
$legacyCachePath = Join-Path $env:SCOOP_CACHE $legacyCacheName
New-Item -ItemType Directory -Force -Path $env:SCOOP_CACHE | Out-Null
Copy-Item -LiteralPath $artifactPath -Destination $legacyCachePath -Force

function Invoke-ReferenceScoop {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScoopPs1 @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "reference scoop $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-Sco {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    & $ScoExe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sco $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-ReferenceScoopListAllowEmpty {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ScoopPs1 list 2>&1
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
        throw "reference scoop list failed with unexpected exit code $LASTEXITCODE"
    }
}

function Invoke-ScoListAllowEmpty {
    & $ScoExe list 2>&1
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
        throw "sco list failed with unexpected exit code $LASTEXITCODE"
    }
}

function Assert-ListContains {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [string[]]$Output
    )

    $joined = $Output -join "`n"
    if ($joined -notmatch 'pairtool\s+1\.0\.0\s+main') {
        throw "$Tool list did not include pairtool after reference scoop install: $joined"
    }
}

function Assert-ListDoesNotContain {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [string[]]$Output
    )

    $joined = $Output -join "`n"
    if ($joined -match 'pairtool\s+1\.0\.0\s+main') {
        throw "$Tool list still included pairtool after sco uninstall: $joined"
    }
}

Invoke-ReferenceScoop install pairtool --no-update-scoop --skip-hash-check

if (!(Test-Path (Join-Path $Root 'apps\pairtool\current\manifest.json'))) {
    throw 'reference scoop install did not create current manifest.json'
}

$scoopListAfterInstall = Invoke-ReferenceScoop list
Assert-ListContains -Tool 'reference scoop' -Output $scoopListAfterInstall

$scoListAfterInstall = Invoke-Sco list
Assert-ListContains -Tool 'sco' -Output $scoListAfterInstall

Invoke-Sco uninstall pairtool

$scoListAfterUninstall = Invoke-ScoListAllowEmpty
Assert-ListDoesNotContain -Tool 'sco' -Output $scoListAfterUninstall

$scoopListAfterUninstall = Invoke-ReferenceScoopListAllowEmpty
Assert-ListDoesNotContain -Tool 'reference scoop' -Output $scoopListAfterUninstall
