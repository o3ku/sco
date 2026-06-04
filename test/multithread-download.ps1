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

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$manifestPath = Join-Path (Split-Path -Parent $Root) 'download-range-filetool.json'
$payloadLength = 11 * 1024 * 1024
@{
    version = '1.0.0'
    url = 'http://127.0.0.1:18223/filetool.exe'
    hash = ''
    bin = 'filetool.exe'
} | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

$job = Start-Job -ScriptBlock {
    param($Prefix, $PayloadLength)

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    $headCount = 0
    $rangeCount = 0
    $fullCount = 0
    $transientFailures = 0

    try {
        while ($true) {
            $task = $listener.GetContextAsync()
            if (-not $task.Wait(3000)) {
                break
            }

            $context = $task.Result
            $request = $context.Request
            $response = $context.Response
            $response.Headers['Accept-Ranges'] = 'bytes'

            if ($request.HttpMethod -eq 'HEAD') {
                $headCount += 1
                $response.StatusCode = 200
                $response.ContentLength64 = $PayloadLength
                $response.OutputStream.Close()
                continue
            }

            $range = $request.Headers['Range']
            if ($range -match '^bytes=(\d+)-(\d+)$') {
                $rangeCount += 1
                if ($transientFailures -eq 0) {
                    $transientFailures += 1
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('transient range failure')
                    $response.StatusCode = 503
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Close()
                    continue
                }
                $start = [int64]$Matches[1]
                $end = [int64]$Matches[2]
                if ($start -lt 0 -or $end -lt $start -or $end -ge $PayloadLength) {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("bad range: $range")
                    $response.StatusCode = 416
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Close()
                    continue
                }

                $count = [int]($end - $start + 1)
                $bytes = [byte[]]::new($count)
                $response.StatusCode = 206
                $response.Headers['Content-Range'] = "bytes $start-$end/$PayloadLength"
                $response.ContentLength64 = $count
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.OutputStream.Close()
            } else {
                $fullCount += 1
                $bytes = [byte[]]::new($PayloadLength)
                $response.StatusCode = 200
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.OutputStream.Close()
            }

            if ($headCount -ge 1 -and $rangeCount -ge 3) {
                break
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }

    [pscustomobject]@{
        Head = $headCount
        Range = $rangeCount
        Full = $fullCount
        TransientFailures = $transientFailures
    }
} -ArgumentList 'http://127.0.0.1:18223/', $payloadLength

Start-Sleep -Milliseconds 300
try {
    $output = & $ScoExe download $manifestPath --force
    if ($LASTEXITCODE -ne 0) {
        throw "download with Range support failed with exit code $LASTEXITCODE`: $output"
    }
    if (($output -join "`n") -notmatch "'download-range-filetool' \(1\.0\.0\) was downloaded successfully!") {
        throw "download with Range support did not include success line: $output"
    }
} finally {
    Wait-Job $job -Timeout 10 | Out-Null
    $serverStats = Receive-Job $job
    Remove-Job $job -Force
}

if ($serverStats.Head -lt 1) {
    throw "download did not probe the artifact with HEAD"
}
if ($serverStats.Range -lt 3) {
    throw "download did not use multiple Range requests: $($serverStats | ConvertTo-Json -Compress)"
}
if ($serverStats.TransientFailures -ne 1) {
    throw "download test did not exercise a transient Range failure: $($serverStats | ConvertTo-Json -Compress)"
}
if ($serverStats.Full -ne 0) {
    throw "download unexpectedly fell back to a full GET: $($serverStats | ConvertTo-Json -Compress)"
}

$cacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'download-range-filetool#1.0.0#*.exe')
if ($cacheFiles.Count -ne 1) {
    throw "Expected one cached artifact, found $($cacheFiles.Count)"
}
if ($cacheFiles[0].Length -ne $payloadLength) {
    throw "Expected cached artifact size $payloadLength, got $($cacheFiles[0].Length)"
}

$stream = [System.IO.File]::OpenRead($cacheFiles[0].FullName)
try {
    $first = $stream.ReadByte()
    $stream.Position = $payloadLength - 1
    $last = $stream.ReadByte()
} finally {
    $stream.Dispose()
}

if ($first -ne 0 -or $last -ne 0) {
    throw "cached artifact content was not assembled in the expected order"
}
