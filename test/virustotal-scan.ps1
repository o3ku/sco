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

$artifactUrl = 'https://downloads.example.test/filetool setup.exe?channel=stable&build=1'
$hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$bucketDir = Join-Path $Root 'buckets\main\bucket'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
$manifest = [ordered]@{
    version = '1.0.0'
    url = $artifactUrl
    hash = "sha256:$hash"
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'filetool.json') -Encoding UTF8

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

& $ScoExe config virustotal_api_key '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "config virustotal_api_key failed with exit code $LASTEXITCODE"
}

$listenerPrefix = 'http://127.0.0.1:18199/'
$recordPath = Join-Path $Root 'virustotal-requests.json'
$job = Start-Job -ScriptBlock {
    param($Prefix, $RecordPath)
    $ErrorActionPreference = 'Stop'
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    $requests = [System.Collections.Generic.List[object]]::new()
    try {
        for ($i = 0; $i -lt 3; $i++) {
            $context = $listener.GetContext()
            $reader = [System.IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()
            $requests.Add([pscustomobject][ordered]@{
                method = $context.Request.HttpMethod
                path = $context.Request.Url.AbsolutePath
                query = $context.Request.Url.Query
                body = $body
                api_key = $context.Request.Headers['x-apikey']
                content_type = $context.Request.ContentType
            }) | Out-Null

            if ($context.Request.HttpMethod -eq 'POST' -and $context.Request.Url.AbsolutePath -eq '/urls') {
                $responseBody = '{"data":{"id":"u-test-submitted-url-id"}}'
                $context.Response.StatusCode = 200
            } else {
                $responseBody = '{"error":{"code":"NotFoundError"}}'
                $context.Response.StatusCode = 404
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
            $context.Response.ContentType = 'application/json'
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
        }
    } finally {
        ConvertTo-Json -InputObject $requests.ToArray() -Depth 5 | Set-Content -Path $RecordPath -Encoding UTF8
        $listener.Stop()
        $listener.Close()
    }
} -ArgumentList $listenerPrefix, $recordPath

$previousApiUrl = $env:SCO_VIRUSTOTAL_API_URL
$env:SCO_VIRUSTOTAL_API_URL = ($listenerPrefix.TrimEnd('/'))
Start-Sleep -Milliseconds 300
try {
    $output = & $ScoExe virustotal filetool --no-depends --scan --passthru 2>&1
    $exitCode = $LASTEXITCODE
} finally {
    if ($null -eq $previousApiUrl) {
        Remove-Item Env:SCO_VIRUSTOTAL_API_URL -ErrorAction SilentlyContinue
    } else {
        $env:SCO_VIRUSTOTAL_API_URL = $previousApiUrl
    }
    Wait-Job $job -Timeout 5 | Out-Null
    Receive-Job $job | Out-Null
    Remove-Job $job -Force
}

if ($exitCode -ne 4) {
    throw "virustotal --scan returned $exitCode instead of Scoop's exception bit 4 after VT 404 responses: $output"
}

$joined = $output -join "`n"
if ($joined -notmatch 'analysis in progress') {
    throw "virustotal --scan did not report analysis submission: $joined"
}
if ($joined -notmatch 'https://www\.virustotal\.com/gui/url/test-submitted-url-id') {
    throw "virustotal --scan did not print submitted URL report: $joined"
}
if ($joined -notmatch '"UrlReport\.Url"\s*:\s*"https://www\.virustotal\.com/gui/url/test-submitted-url-id"') {
    throw "virustotal passthru JSON missing submitted UrlReport.Url: $joined"
}

if (!(Test-Path $recordPath)) {
    throw 'fake VirusTotal server did not write request record'
}
$requests = @((Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json))
if ($requests.Count -ne 3) {
    throw "expected 3 VirusTotal requests, got $($requests.Count): $($requests | ConvertTo-Json -Depth 5)"
}
if ($requests[0].method -ne 'GET' -or $requests[0].path -ne "/files/$hash") {
    throw "first request was not the file report lookup: $($requests[0] | ConvertTo-Json -Depth 5)"
}
if ($requests[1].method -ne 'GET' -or $requests[1].path -notmatch '^/urls/') {
    throw "second request was not the URL report lookup: $($requests[1] | ConvertTo-Json -Depth 5)"
}
if ($requests[2].method -ne 'POST' -or $requests[2].path -ne '/urls') {
    throw "third request was not the URL submission: $($requests[2] | ConvertTo-Json -Depth 5)"
}
if ($requests[2].api_key -ne '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef') {
    throw "VirusTotal submission did not include API key header: $($requests[2] | ConvertTo-Json -Depth 5)"
}
if ($requests[2].content_type -notmatch 'application/x-www-form-urlencoded') {
    throw "VirusTotal submission used wrong content type: $($requests[2].content_type)"
}
$expectedBody = 'url=' + [System.Uri]::EscapeDataString($artifactUrl).Replace('%20', '+')
if ($requests[2].body -ne $expectedBody) {
    throw "VirusTotal submission body was unexpected. Expected '$expectedBody', got '$($requests[2].body)'"
}
