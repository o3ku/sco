param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$GlobalRoot,
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
if (Test-Path $GlobalRoot) {
    Remove-Item -LiteralPath $GlobalRoot -Recurse -Force
}
if (Test-Path $ConfigHome) {
    Remove-Item -LiteralPath $ConfigHome -Recurse -Force
}

$bucketDir = Join-Path $Root 'buckets\main\bucket'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
$manifestPath = Join-Path $bucketDir 'filetool.json'
$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = 'sha256:5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

$env:SCOOP = $Root
$env:SCOOP_GLOBAL = $GlobalRoot
$env:XDG_CONFIG_HOME = $ConfigHome

function Install-GlobalStandaloneVirusTotalFixture($ManifestPath) {
    $previousScoop = $env:SCOOP
    $previousGlobal = $env:SCOOP_GLOBAL
    try {
        $env:SCOOP = $GlobalRoot
        Remove-Item Env:SCOOP_GLOBAL -ErrorAction SilentlyContinue
        & $ScoExe install $ManifestPath --no-update-scoop
    } finally {
        $env:SCOOP = $previousScoop
        $env:SCOOP_GLOBAL = $previousGlobal
    }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingAppOutput = & $ScoExe virustotal --no-depends 2>&1
$missingAppExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingAppExitCode -ne 1) {
    throw "virustotal without an app returned $missingAppExitCode instead of 1: $missingAppOutput"
}
$missingAppJoined = $missingAppOutput -join "`n"
if ($missingAppJoined.Trim() -ne 'Usage: sco virustotal [* | app1 app2 ...] [options]') {
    throw "virustotal without an app did not match Scoop usage output: $missingAppJoined"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$unknownOptionOutput = & $ScoExe virustotal -z filetool 2>&1
$unknownOptionExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($unknownOptionExitCode -ne 1) {
    throw "virustotal -z returned $unknownOptionExitCode instead of 1: $unknownOptionOutput"
}
if (($unknownOptionOutput -join "`n") -notmatch 'sco virustotal: Option -z not recognized\.') {
    throw "virustotal -z did not match Scoop getopt error: $unknownOptionOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$unknownLongOptionOutput = & $ScoExe virustotal --unknown filetool 2>&1
$unknownLongOptionExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($unknownLongOptionExitCode -ne 1) {
    throw "virustotal --unknown returned $unknownLongOptionExitCode instead of 1: $unknownLongOptionOutput"
}
if (($unknownLongOptionOutput -join "`n") -notmatch 'sco virustotal: Option --unknown not recognized\.') {
    throw "virustotal --unknown did not match Scoop getopt error: $unknownLongOptionOutput"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$missingKeyOutput = & $ScoExe virustotal filetool --no-depends 2>&1
$missingKeyExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($missingKeyExitCode -ne 16) {
    throw "virustotal without API key returned $missingKeyExitCode instead of 16: $missingKeyOutput"
}
if (($missingKeyOutput -join "`n") -notmatch 'VirusTotal API key is not configured') {
    throw "virustotal missing key output was unexpected: $missingKeyOutput"
}

$dryRunOutput = & $ScoExe virustotal filetool --no-depends --dry-run --passthru
if ($LASTEXITCODE -ne 0) {
    throw "virustotal dry-run failed with exit code $LASTEXITCODE`: $dryRunOutput"
}
$joined = $dryRunOutput -join "`n"
if ($joined -notmatch 'would query 5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b') {
    throw "virustotal dry-run did not report hash lookup: $joined"
}
if ($joined -notmatch '"App.Name"\s*:\s*"filetool"' -or $joined -notmatch '"App.Hash"\s*:\s*"5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b"') {
    throw "virustotal passthru JSON missing expected fields: $joined"
}

$localScopeDir = Join-Path (Split-Path -Parent $Root) 'virustotal-local-source'
$globalScopeDir = Join-Path (Split-Path -Parent $Root) 'virustotal-global-source'
New-Item -ItemType Directory -Force -Path $localScopeDir, $globalScopeDir | Out-Null
$localScopeManifest = Join-Path $localScopeDir 'vtbothscope.json'
$globalScopeManifest = Join-Path $globalScopeDir 'vtbothscope.json'
$scopeManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = 'sha256:5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$scopeManifest | ConvertTo-Json | Set-Content -Path $localScopeManifest -Encoding UTF8
& $ScoExe install $localScopeManifest --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "local virustotal both-scope fixture install failed with exit code $LASTEXITCODE"
}
$scopeManifest | ConvertTo-Json | Set-Content -Path $globalScopeManifest -Encoding UTF8
Install-GlobalStandaloneVirusTotalFixture $globalScopeManifest
if ($LASTEXITCODE -ne 0) {
    throw "global virustotal both-scope fixture install failed with exit code $LASTEXITCODE"
}

$scopeManifest.url = 'https://downloads.example.test/vt-local-scope.exe'
$scopeManifest.hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$scopeManifest | ConvertTo-Json | Set-Content -Path $localScopeManifest -Encoding UTF8
$scopeManifest.url = 'https://downloads.example.test/vt-global-scope.exe'
$scopeManifest.hash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$scopeManifest | ConvertTo-Json | Set-Content -Path $globalScopeManifest -Encoding UTF8

$bothScopeDryRun = & $ScoExe virustotal vtbothscope --no-depends --dry-run --passthru
if ($LASTEXITCODE -ne 0) {
    throw "virustotal both-scope dry-run failed with exit code $LASTEXITCODE`: $bothScopeDryRun"
}
$bothScopeJoined = $bothScopeDryRun -join "`n"
if ($bothScopeJoined -notmatch 'would query bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -or
    $bothScopeJoined -notmatch 'https://downloads\.example\.test/vt-global-scope\.exe' -or
    $bothScopeJoined -match 'vt-local-scope') {
    throw "virustotal should prefer global installed manifest when both scopes exist like Scoop: $bothScopeJoined"
}

$clusteredDryRunOutput = & $ScoExe virustotal -np --dry-run filetool
if ($LASTEXITCODE -ne 0) {
    throw "virustotal clustered -np dry-run failed with exit code $LASTEXITCODE`: $clusteredDryRunOutput"
}
$clusteredJoined = $clusteredDryRunOutput -join "`n"
if ($clusteredJoined -notmatch 'would query 5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b' -or $clusteredJoined -notmatch '"App.Name"\s*:\s*"filetool"') {
    throw "virustotal clustered -np did not parse Scoop-style short option cluster: $clusteredJoined"
}

$terminatorDryRunOutput = & $ScoExe virustotal --dry-run -- filetool
if ($LASTEXITCODE -ne 0) {
    throw "virustotal -- terminator dry-run failed with exit code $LASTEXITCODE`: $terminatorDryRunOutput"
}
if (($terminatorDryRunOutput -join "`n") -notmatch 'would query 5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b') {
    throw "virustotal -- terminator did not treat filetool as positional: $terminatorDryRunOutput"
}

$multiUrlManifest = [ordered]@{
    version = '1.0.0'
    url = @(
        'https://downloads.example.test/multi-1.exe',
        'https://downloads.example.test/multi-2.exe'
    )
    hash = @(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    )
    bin = 'filetool.exe'
}
$multiUrlManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'multiurl.json') -Encoding UTF8
$multiUrlOutput = & $ScoExe virustotal multiurl --no-depends --dry-run 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "virustotal multi-url dry-run failed with exit code $LASTEXITCODE`: $multiUrlOutput"
}
$multiUrlJoined = $multiUrlOutput -join "`n"
$urlOneIndex = $multiUrlJoined.IndexOf('multiurl: url 1')
$hashOneIndex = $multiUrlJoined.IndexOf('multiurl: would query aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
$urlTwoIndex = $multiUrlJoined.IndexOf('multiurl: url 2')
$hashTwoIndex = $multiUrlJoined.IndexOf('multiurl: would query bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')
if ($urlOneIndex -lt 0 -or $hashOneIndex -lt 0 -or $urlTwoIndex -lt 0 -or $hashTwoIndex -lt 0 -or
    $urlOneIndex -gt $hashOneIndex -or $hashOneIndex -gt $urlTwoIndex -or $urlTwoIndex -gt $hashTwoIndex) {
    throw "virustotal multi-url output should include Scoop-style per-url progress lines: $multiUrlJoined"
}

$depManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = 'sha256:5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'filetool.exe'
}
$depManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'deptool.json') -Encoding UTF8
$appManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($Artifact))
    hash = 'sha256:5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    depends = 'deptool'
    bin = 'filetool.exe'
}
$appManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'apptool.json') -Encoding UTF8

$dependsDryRunOutput = & $ScoExe virustotal apptool --dry-run --passthru
if ($LASTEXITCODE -ne 0) {
    throw "virustotal dry-run with dependencies failed with exit code $LASTEXITCODE`: $dependsDryRunOutput"
}
$dependsDryRunJoined = $dependsDryRunOutput -join "`n"
$depIndex = $dependsDryRunJoined.IndexOf('main/deptool: would query')
$appIndex = $dependsDryRunJoined.IndexOf('main/apptool: would query')
if ($depIndex -lt 0 -or $appIndex -lt 0 -or $depIndex -gt $appIndex) {
    throw "virustotal did not check dependencies before the requested app like Scoop: $dependsDryRunJoined"
}

$noDependsDryRunOutput = & $ScoExe virustotal apptool --dry-run --no-depends --passthru
if ($LASTEXITCODE -ne 0) {
    throw "virustotal --no-depends dry-run failed with exit code $LASTEXITCODE`: $noDependsDryRunOutput"
}
$noDependsDryRunJoined = $noDependsDryRunOutput -join "`n"
if ($noDependsDryRunJoined -match 'deptool' -or $noDependsDryRunJoined -notmatch 'apptool: would query') {
    throw "virustotal --no-depends did not limit checks to the requested app: $noDependsDryRunJoined"
}

function Invoke-FakeVirusTotalOnce {
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$RelatedHash = 'relatedhash'
    )

    $listenerPrefix = "http://127.0.0.1:$Port/"
    $recordPath = Join-Path $Root "virustotal-$App-request.json"
    $readyPath = Join-Path $Root "virustotal-$App-ready.txt"
    Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
    $job = Start-Job -ScriptBlock {
        param($Prefix, $RecordPath, $ReadyPath, $RelatedHash)
        $ErrorActionPreference = 'Stop'
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        $requests = [System.Collections.Generic.List[object]]::new()
        Set-Content -Path $ReadyPath -Value 'ready' -Encoding ASCII
        try {
            for ($i = 0; $i -lt 2; $i++) {
                $context = $listener.GetContext()
                $requests.Add([pscustomobject][ordered]@{
                    method = $context.Request.HttpMethod
                    path = $context.Request.Url.AbsolutePath
                }) | Out-Null

                if ($context.Request.Url.AbsolutePath -like '/urls/*') {
                    $responseBody = @{
                        data = @{
                            id = 'url-report-id'
                            attributes = @{
                                last_http_response_content_sha256 = $RelatedHash
                            }
                        }
                    } | ConvertTo-Json -Depth 6 -Compress
                    $context.Response.StatusCode = 200
                } elseif ($context.Request.Url.AbsolutePath -eq "/files/$RelatedHash") {
                    $responseBody = @{
                        data = @{
                            attributes = @{
                                sha256 = $RelatedHash
                                last_analysis_stats = @{
                                    malicious = 0
                                    suspicious = 0
                                    timeout = 0
                                    undetected = 1
                                }
                            }
                        }
                    } | ConvertTo-Json -Depth 6 -Compress
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
    } -ArgumentList $listenerPrefix, $recordPath, $readyPath, $RelatedHash

    & $ScoExe config virustotal_api_key '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "config virustotal_api_key failed with exit code $LASTEXITCODE"
    }

    $previousApiUrl = $env:SCO_VIRUSTOTAL_API_URL
    $env:SCO_VIRUSTOTAL_API_URL = ($listenerPrefix.TrimEnd('/'))
    $readyDeadline = (Get-Date).AddSeconds(5)
    while (!(Test-Path $readyPath) -and (Get-Date) -lt $readyDeadline) {
        if ($job.State -ne 'Running') {
            $jobOutput = Receive-Job $job 2>&1
            Remove-Job $job -Force
            throw "fake VirusTotal server for $App did not start: $jobOutput"
        }
        Start-Sleep -Milliseconds 100
    }
    if (!(Test-Path $readyPath)) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force
        throw "fake VirusTotal server for $App did not become ready"
    }
    try {
        $output = & $ScoExe virustotal $App --no-depends --passthru 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $previousApiUrl) {
            Remove-Item Env:SCO_VIRUSTOTAL_API_URL -ErrorAction SilentlyContinue
        } else {
            $env:SCO_VIRUSTOTAL_API_URL = $previousApiUrl
        }
        if (!(Wait-Job $job -Timeout 5)) {
            Stop-Job $job -ErrorAction SilentlyContinue
        }
        Receive-Job $job | Out-Null
        Remove-Job $job -Force
    }

    if ($exitCode -ne 0) {
        throw "virustotal URL fallback for $App returned $exitCode instead of 0: $output"
    }
    if (($output -join "`n") -notmatch 'url report found') {
        throw "virustotal URL fallback for $App did not report URL lookup success: $output"
    }
    if (!(Test-Path $recordPath)) {
        throw "fake VirusTotal server did not record a request for $App"
    }
    $requests = @((Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json))
    if ($requests.Count -ne 2) {
        throw "expected URL report and related file report requests for $App, got $($requests.Count): $($requests | ConvertTo-Json -Depth 5)"
    }
    if ($requests[0].method -ne 'GET' -or $requests[0].path -ne $ExpectedPath) {
        throw "virustotal URL fallback for $App sent unexpected first request: $($requests | ConvertTo-Json -Compress), expected GET $ExpectedPath"
    }
    if ($requests[1].method -ne 'GET' -or $requests[1].path -ne "/files/$RelatedHash") {
        throw "virustotal URL fallback for $App did not query the related file report: $($requests | ConvertTo-Json -Compress)"
    }
}

$noHashUrl = 'https://downloads.example.test/nohash.exe'
$noHashManifest = [ordered]@{
    version = '1.0.0'
    url = $noHashUrl
    bin = 'filetool.exe'
}
$noHashManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'nohash.json') -Encoding UTF8
$expectedNoHashPath = '/urls/' + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($noHashUrl)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
Invoke-FakeVirusTotalOnce -App 'nohash' -ExpectedPath $expectedNoHashPath -Port 18201

$unsupportedUrl = 'https://downloads.example.test/unsupported.exe'
$unsupportedManifest = [ordered]@{
    version = '1.0.0'
    url = $unsupportedUrl
    hash = 'sha512:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    bin = 'filetool.exe'
}
$unsupportedManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'unsupportedhash.json') -Encoding UTF8
$expectedUnsupportedPath = '/urls/' + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($unsupportedUrl)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
Invoke-FakeVirusTotalOnce -App 'unsupportedhash' -ExpectedPath $expectedUnsupportedPath -Port 18202

function Invoke-Hash404UrlRelatedHash {
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$OriginalHash,
        [Parameter(Mandatory = $true)][string]$RelatedHash,
        [Parameter(Mandatory = $true)][string]$ExpectedUrlPath,
        [Parameter(Mandatory = $true)][string]$ExpectedPattern,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $listenerPrefix = "http://127.0.0.1:$Port/"
    $recordPath = Join-Path $Root "virustotal-$App-hash404-request.json"
    $readyPath = Join-Path $Root "virustotal-$App-hash404-ready.txt"
    Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
    $job = Start-Job -ScriptBlock {
        param($Prefix, $RecordPath, $ReadyPath, $OriginalHash, $RelatedHash)
        $ErrorActionPreference = 'Stop'
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        $requests = [System.Collections.Generic.List[object]]::new()
        Set-Content -Path $ReadyPath -Value 'ready' -Encoding ASCII
        try {
            for ($i = 0; $i -lt 2; $i++) {
                $context = $listener.GetContext()
                $requests.Add([pscustomobject][ordered]@{
                    method = $context.Request.HttpMethod
                    path = $context.Request.Url.AbsolutePath
                }) | Out-Null

                if ($context.Request.Url.AbsolutePath -eq "/files/$OriginalHash") {
                    $responseBody = '{"error":{"code":"NotFoundError"}}'
                    $context.Response.StatusCode = 404
                } elseif ($context.Request.Url.AbsolutePath -like '/urls/*') {
                    $responseBody = @{
                        data = @{
                            id = 'url-report-id'
                            attributes = @{
                                last_http_response_content_sha256 = $RelatedHash
                            }
                        }
                    } | ConvertTo-Json -Depth 6 -Compress
                    $context.Response.StatusCode = 200
                } else {
                    $responseBody = '{"error":{"code":"UnexpectedRequest"}}'
                    $context.Response.StatusCode = 500
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
    } -ArgumentList $listenerPrefix, $recordPath, $readyPath, $OriginalHash, $RelatedHash

    $previousApiUrl = $env:SCO_VIRUSTOTAL_API_URL
    $env:SCO_VIRUSTOTAL_API_URL = ($listenerPrefix.TrimEnd('/'))
    $readyDeadline = (Get-Date).AddSeconds(5)
    while (!(Test-Path $readyPath) -and (Get-Date) -lt $readyDeadline) {
        if ($job.State -ne 'Running') {
            $jobOutput = Receive-Job $job 2>&1
            Remove-Job $job -Force
            throw "fake VirusTotal server for $App did not start: $jobOutput"
        }
        Start-Sleep -Milliseconds 100
    }
    if (!(Test-Path $readyPath)) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force
        throw "fake VirusTotal server for $App did not become ready"
    }
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & $ScoExe virustotal $App --no-depends --passthru 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
    } finally {
        if ($null -eq $previousApiUrl) {
            Remove-Item Env:SCO_VIRUSTOTAL_API_URL -ErrorAction SilentlyContinue
        } else {
            $env:SCO_VIRUSTOTAL_API_URL = $previousApiUrl
        }
        if (!(Wait-Job $job -Timeout 5)) {
            Stop-Job $job -ErrorAction SilentlyContinue
        }
        Receive-Job $job | Out-Null
        Remove-Job $job -Force
    }

    if ($exitCode -ne 4) {
        throw "virustotal hash-404 URL fallback for $App returned $exitCode instead of 4: $output"
    }
    $joined = $output -join "`n"
    if ($joined -notmatch $ExpectedPattern) {
        throw "virustotal hash-404 URL fallback for $App missed expected diagnostic '$ExpectedPattern': $joined"
    }
    $requests = @((Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json))
    if ($requests.Count -ne 2) {
        throw "expected hash and URL requests for $App, got $($requests.Count): $($requests | ConvertTo-Json -Depth 5)"
    }
    if ($requests[0].method -ne 'GET' -or $requests[0].path -ne "/files/$OriginalHash") {
        throw "virustotal hash-404 fallback for $App sent unexpected first request: $($requests | ConvertTo-Json -Compress)"
    }
    if ($requests[1].method -ne 'GET' -or $requests[1].path -ne $ExpectedUrlPath) {
        throw "virustotal hash-404 fallback for $App sent unexpected URL request: $($requests | ConvertTo-Json -Compress), expected GET $ExpectedUrlPath"
    }
}

$matchedHashUrl = 'https://downloads.example.test/matchedhash.exe'
$matchedHash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
$matchedHashManifest = [ordered]@{
    version = '1.0.0'
    url = $matchedHashUrl
    hash = "sha256:$matchedHash"
    bin = 'filetool.exe'
}
$matchedHashManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'matchedhash.json') -Encoding UTF8
$expectedMatchedHashUrlPath = '/urls/' + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($matchedHashUrl)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
Invoke-Hash404UrlRelatedHash -App 'matchedhash' -OriginalHash $matchedHash -RelatedHash $matchedHash -ExpectedUrlPath $expectedMatchedHashUrlPath -ExpectedPattern 'Manual file upload is required \(instead of url submission\) for https://downloads\.example\.test/matchedhash\.exe' -Port 18203

$mismatchedHashUrl = 'https://downloads.example.test/mismatchedhash.exe'
$mismatchedHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$relatedMismatchHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$mismatchedHashManifest = [ordered]@{
    version = '1.0.0'
    url = $mismatchedHashUrl
    hash = "sha256:$mismatchedHash"
    bin = 'filetool.exe'
}
$mismatchedHashManifest | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'mismatchedhash.json') -Encoding UTF8
$expectedMismatchedHashUrlPath = '/urls/' + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($mismatchedHashUrl)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
Invoke-Hash404UrlRelatedHash -App 'mismatchedhash' -OriginalHash $mismatchedHash -RelatedHash $relatedMismatchHash -ExpectedUrlPath $expectedMismatchedHashUrlPath -ExpectedPattern 'ERROR mismatchedhash: Hash not matched for https://downloads\.example\.test/mismatchedhash\.exe' -Port 18204

function Invoke-RateLimitedVirusTotal {
    param(
        [Parameter(Mandatory = $true)][string]$FirstHash,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $listenerPrefix = "http://127.0.0.1:$Port/"
    $recordPath = Join-Path $Root 'virustotal-rate-limit-requests.json'
    $readyPath = Join-Path $Root 'virustotal-rate-limit-ready.txt'
    Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
    $job = Start-Job -ScriptBlock {
        param($Prefix, $RecordPath, $ReadyPath, $FirstHash)
        $ErrorActionPreference = 'Stop'
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        $requests = [System.Collections.Generic.List[object]]::new()
        Set-Content -Path $ReadyPath -Value 'ready' -Encoding ASCII
        try {
            for ($i = 0; $i -lt 2; $i++) {
                $task = $listener.GetContextAsync()
                if (-not $task.Wait(3000)) {
                    break
                }
                $context = $task.Result
                $requests.Add([pscustomobject][ordered]@{
                    method = $context.Request.HttpMethod
                    path = $context.Request.Url.AbsolutePath
                }) | Out-Null

                if ($context.Request.Url.AbsolutePath -eq "/files/$FirstHash") {
                    $responseBody = '{"error":{"code":"QuotaExceededError"}}'
                    $context.Response.StatusCode = 429
                } else {
                    $responseBody = @{
                        data = @{
                            attributes = @{
                                sha256 = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
                                last_analysis_stats = @{
                                    malicious = 0
                                    suspicious = 0
                                    timeout = 0
                                    undetected = 1
                                }
                            }
                        }
                    } | ConvertTo-Json -Depth 6 -Compress
                    $context.Response.StatusCode = 200
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
    } -ArgumentList $listenerPrefix, $recordPath, $readyPath, $FirstHash

    $previousApiUrl = $env:SCO_VIRUSTOTAL_API_URL
    $env:SCO_VIRUSTOTAL_API_URL = ($listenerPrefix.TrimEnd('/'))
    $readyDeadline = (Get-Date).AddSeconds(5)
    while (!(Test-Path $readyPath) -and (Get-Date) -lt $readyDeadline) {
        if ($job.State -ne 'Running') {
            $jobOutput = Receive-Job $job 2>&1
            Remove-Job $job -Force
            throw "fake VirusTotal rate-limit server did not start: $jobOutput"
        }
        Start-Sleep -Milliseconds 100
    }
    if (!(Test-Path $readyPath)) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force
        throw 'fake VirusTotal rate-limit server did not become ready'
    }
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & $ScoExe virustotal ratelimitfirst ratelimitsecond --no-depends --passthru 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
    } finally {
        if ($null -eq $previousApiUrl) {
            Remove-Item Env:SCO_VIRUSTOTAL_API_URL -ErrorAction SilentlyContinue
        } else {
            $env:SCO_VIRUSTOTAL_API_URL = $previousApiUrl
        }
        if (!(Wait-Job $job -Timeout 5)) {
            Stop-Job $job -ErrorAction SilentlyContinue
        }
        Receive-Job $job | Out-Null
        Remove-Job $job -Force
    }

    if ($exitCode -ne 4) {
        throw "virustotal rate-limit response returned $exitCode instead of 4: $output"
    }
    $joined = $output -join "`n"
    if ($joined -notmatch 'ratelimitfirst: VirusTotal request failed: 429') {
        throw "virustotal rate-limit response did not report the failed first app: $joined"
    }
    if ($joined -match 'ratelimitsecond') {
        throw "virustotal should abort after a 429 response instead of querying later apps: $joined"
    }
    $requests = @((Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json))
    if ($requests.Count -ne 1 -or $requests[0].path -ne "/files/$FirstHash") {
        throw "virustotal did not stop after first rate-limited request: $($requests | ConvertTo-Json -Depth 5)"
    }
}

$rateLimitFirstHash = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
$rateLimitSecondHash = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
@{
    version = '1.0.0'
    url = 'https://downloads.example.test/ratelimitfirst.exe'
    hash = "sha256:$rateLimitFirstHash"
    bin = 'filetool.exe'
} | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'ratelimitfirst.json') -Encoding UTF8
@{
    version = '1.0.0'
    url = 'https://downloads.example.test/ratelimitsecond.exe'
    hash = "sha256:$rateLimitSecondHash"
    bin = 'filetool.exe'
} | ConvertTo-Json | Set-Content -Path (Join-Path $bucketDir 'ratelimitsecond.json') -Encoding UTF8
Invoke-RateLimitedVirusTotal -FirstHash $rateLimitFirstHash -Port 18205
