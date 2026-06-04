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
$bucketScriptDir = Join-Path $Root 'buckets\main\scripts\hooktool'
$manifestPath = Join-Path $bucketDir 'hooktool.json'
New-Item -ItemType Directory -Force -Path $bucketDir,$bucketScriptDir | Out-Null
Set-Content -Path (Join-Path $bucketScriptDir 'resource.txt') -Value 'bucket script resource' -NoNewline -Encoding Ascii

$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    pre_install = @(
        "New-Item -ItemType Directory -Force -Path (Join-Path `$dir 'generated') | Out-Null",
        "Set-Content -Path (Join-Path `$dir 'generated\pre.txt') -Value `$architecture -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path `$dir 'generated\pre_global.txt') -Value `$global -NoNewline -Encoding Ascii"
    )
    post_install = @(
        "Set-Content -Path (Join-Path `$dir 'generated\post.txt') -Value `$app -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path `$dir 'generated\post_dir.txt') -Value `$dir -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path `$dir 'generated\post_original_dir.txt') -Value `$original_dir -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path `$dir 'generated\post_version.txt') -Value `$version -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path `$dir 'generated\post_bucket.txt') -Value `$bucket -NoNewline -Encoding Ascii",
        "Set-Content -Path (Join-Path `$dir 'generated\post_bucketsdir.txt') -Value `$bucketsdir -NoNewline -Encoding Ascii",
        "`$resource = Get-Content -Path (Join-Path `$bucketsdir ""`$bucket\scripts\hooktool\resource.txt"") -Raw",
        "Set-Content -Path (Join-Path `$dir 'generated\post_bucket_resource.txt') -Value `$resource -NoNewline -Encoding Ascii"
    )
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe install hooktool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$versionDir = Join-Path $Root 'apps\hooktool\1.0.0'
$pre = Get-Content (Join-Path $versionDir 'generated\pre.txt') -Raw
if ($pre -ne '64bit') {
    throw "pre_install did not run with architecture context: $pre"
}
$preGlobal = Get-Content (Join-Path $versionDir 'generated\pre_global.txt') -Raw
if ($preGlobal -ne 'False') {
    throw "pre_install did not expose Scoop-style global context: $preGlobal"
}

$post = Get-Content (Join-Path $versionDir 'generated\post.txt') -Raw
if ($post -ne 'hooktool') {
    throw "post_install did not run with app context: $post"
}

if (!(Test-Path (Join-Path $Root 'apps\hooktool\current\generated\post.txt'))) {
    throw 'post_install output is not visible through current link'
}

$postDir = Get-Content (Join-Path $versionDir 'generated\post_dir.txt') -Raw
$expectedCurrentDir = [System.IO.Path]::GetFullPath((Join-Path $Root 'apps\hooktool\current'))
if ([System.IO.Path]::GetFullPath($postDir) -ne $expectedCurrentDir) {
    throw "post_install did not expose current as `$dir: $postDir"
}

$postOriginalDir = Get-Content (Join-Path $versionDir 'generated\post_original_dir.txt') -Raw
if ([System.IO.Path]::GetFullPath($postOriginalDir) -ne [System.IO.Path]::GetFullPath($versionDir)) {
    throw "post_install did not keep original version directory: $postOriginalDir"
}

$postVersion = Get-Content (Join-Path $versionDir 'generated\post_version.txt') -Raw
if ($postVersion -ne '1.0.0') {
    throw "post_install did not expose effective version: $postVersion"
}

$postBucket = Get-Content (Join-Path $versionDir 'generated\post_bucket.txt') -Raw
if ($postBucket -ne 'main') {
    throw "post_install did not expose manifest source bucket: $postBucket"
}

$postBucketsDir = Get-Content (Join-Path $versionDir 'generated\post_bucketsdir.txt') -Raw
if ([System.IO.Path]::GetFullPath($postBucketsDir) -ne [System.IO.Path]::GetFullPath((Join-Path $Root 'buckets'))) {
    throw "post_install did not expose Scoop-style `$bucketsdir: $postBucketsDir"
}

$postBucketResource = Get-Content (Join-Path $versionDir 'generated\post_bucket_resource.txt') -Raw
if ($postBucketResource -ne 'bucket script resource') {
    throw "post_install could not read bucket script resource through `$bucketsdir/`$bucket: $postBucketResource"
}
