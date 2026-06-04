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

$repo = Join-Path $Root '..\bucket-git-source'
if (Test-Path $repo) {
    Remove-Item -LiteralPath $repo -Recurse -Force
}
$repoBucket = Join-Path $repo 'bucket'
New-Item -ItemType Directory -Force -Path $repoBucket | Out-Null

$manifest = [ordered]@{
    version = '1.0.0'
    description = 'Git bucket test app'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $repoBucket 'filetool.json') -Encoding UTF8

git -C $repo init | Out-Null
git -C $repo config user.email sco-test@example.invalid | Out-Null
git -C $repo config user.name sco-test | Out-Null
git -C $repo add bucket/filetool.json | Out-Null
git -C $repo commit -m 'add filetool' | Out-Null

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe bucket add gitlocal $repo
if ($LASTEXITCODE -ne 0) {
    throw "bucket add git failed with exit code $LASTEXITCODE"
}

if (!(Test-Path (Join-Path $Root 'buckets\gitlocal\.git'))) {
    throw 'bucket add git did not clone .git metadata'
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$duplicateRepoOutput = & $ScoExe bucket add othergitlocal $repo 2>&1
$duplicateRepoExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($duplicateRepoExitCode -ne 2) {
    throw "bucket add duplicate git repo returned $duplicateRepoExitCode instead of 2: $duplicateRepoOutput"
}
if (($duplicateRepoOutput -join "`n") -notmatch 'WARN  Bucket gitlocal already exists for .+bucket-git-source') {
    throw "bucket add duplicate git repo did not match Scoop warning: $duplicateRepoOutput"
}
if (Test-Path (Join-Path $Root 'buckets\othergitlocal')) {
    throw 'bucket add duplicate git repo created the requested duplicate bucket'
}

& $ScoExe install gitlocal/filetool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install from git bucket failed with exit code $LASTEXITCODE"
}

if (!(Test-Path (Join-Path $Root 'apps\filetool\current\filetool.exe'))) {
    throw 'install from git bucket did not produce current filetool.exe'
}
