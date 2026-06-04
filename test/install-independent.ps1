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
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null

function Write-Manifest($Name, $Depends) {
    $manifest = [ordered]@{
        version = '1.0.0'
        url = ([System.IO.Path]::GetFullPath($Artifact))
        hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        bin = 'filetool.exe'
    }
    if ($Depends) {
        $manifest.depends = $Depends
    }
    $manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir "$Name.json") -Encoding UTF8
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

Write-Manifest 'deptool' $null
Write-Manifest 'apptool' 'deptool'

& $ScoExe install apptool --independent --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install --independent failed with exit code $LASTEXITCODE"
}

if (!(Test-Path (Join-Path $Root 'apps\apptool\current\filetool.exe'))) {
    throw 'independent install did not install requested app'
}
if (Test-Path (Join-Path $Root 'apps\deptool')) {
    throw 'independent install should not install dependency'
}
