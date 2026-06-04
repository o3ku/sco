param(
    [Parameter(Mandatory = $true)][string]$ScoExe
)

$ErrorActionPreference = 'Stop'

$Root = Join-Path (Split-Path -Parent $ScoExe) 'test-bucket-known-home'
$ConfigHome = Join-Path (Split-Path -Parent $ScoExe) 'test-bucket-known-config'

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
New-Item -ItemType Directory -Force -Path $Root | Out-Null

[ordered]@{
    main = 'https://example.invalid/main'
    extras = 'https://example.invalid/extras'
    versions = 'https://example.invalid/versions'
} | ConvertTo-Json | Set-Content -Path (Join-Path $Root 'buckets.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$output = & $ScoExe BUCKET Known
if ($LASTEXITCODE -ne 0) {
    throw "BUCKET Known failed with exit code $LASTEXITCODE`: $output"
}

$lines = @($output | Where-Object { $_ -match '\S' })
if ($lines -notcontains 'main') {
    throw "bucket known did not include main bucket: $($lines -join '; ')"
}
if ($lines -notcontains 'extras') {
    throw "bucket known did not include extras bucket: $($lines -join '; ')"
}
if ($lines.Count -lt 3 -or $lines[0] -ne 'main' -or $lines[1] -ne 'extras' -or $lines[2] -ne 'versions') {
    throw "bucket known did not preserve buckets.json order: $($lines -join '; ')"
}
if ($lines | Where-Object { $_ -match 'github\.com|ScoopInstaller/' }) {
    throw "bucket known should list names only, not repositories: $($lines -join '; ')"
}

[ordered]@{} | ConvertTo-Json | Set-Content -Path (Join-Path $Root 'buckets.json') -Encoding UTF8
$emptyKnownOutput = & $ScoExe bucket known 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "bucket known with no known buckets returned $LASTEXITCODE instead of 0 like Scoop: $emptyKnownOutput"
}
if (($emptyKnownOutput | Where-Object { $_ -match '\S' }).Count -ne 0) {
    throw "bucket known with no known buckets should be quiet like Scoop: $emptyKnownOutput"
}
