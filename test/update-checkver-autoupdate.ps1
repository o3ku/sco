param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ConfigHome,
    [Parameter(Mandatory = $true)][string]$ArtifactV1,
    [Parameter(Mandatory = $true)][string]$ArtifactV2
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
$sourceDir = Join-Path $Root 'sources'
$manifestPath = Join-Path $bucketDir 'autotool.json'
$reverseManifestPath = Join-Path $bucketDir 'reverseauto.json'
$replaceManifestPath = Join-Path $bucketDir 'replaceauto.json'
$agentManifestPath = Join-Path $bucketDir 'agentauto.json'
$githubManifestPath = Join-Path $bucketDir 'githubauto.json'
$invalidGithubManifestPath = Join-Path $bucketDir 'invalidgithubauto.json'
$sourceforgeManifestPath = Join-Path $bucketDir 'sourceforgeauto.json'
$xpathManifestPath = Join-Path $bucketDir 'xpathauto.json'
$namespaceXpathManifestPath = Join-Path $bucketDir 'namespacexpathauto.json'
$scriptManifestPath = Join-Path $bucketDir 'scriptauto.json'
$jsonpathManifestPath = Join-Path $bucketDir 'jsonpathauto.json'
$recursiveJsonpathManifestPath = Join-Path $bucketDir 'recursivejsonauto.json'
$redirectManifestPath = Join-Path $bucketDir 'redirectauto.json'
$gzipManifestPath = Join-Path $bucketDir 'gzipauto.json'
$cookieHashManifestPath = Join-Path $bucketDir 'cookiehashauto.json'
$releasePage = Join-Path $sourceDir 'releases.txt'
$reverseReleasePage = Join-Path $sourceDir 'reverse-releases.txt'
$replaceReleasePage = Join-Path $sourceDir 'replace-releases.txt'
$agentReleasePage = Join-Path $sourceDir 'agent-releases.txt'
$githubReleasePage = Join-Path $sourceDir 'github-release.html'
$sourceforgeReleasePage = Join-Path $sourceDir 'sourceforge-rss.xml'
$xpathReleasePage = Join-Path $sourceDir 'xpath-releases.xml'
$namespaceXpathReleasePage = Join-Path $sourceDir 'namespace-xpath-releases.xml'
$jsonpathReleasePage = Join-Path $sourceDir 'jsonpath-releases.json'
$redirectReleasePage = Join-Path $sourceDir 'redirect-releases.txt'
$gzipReleasePage = Join-Path $sourceDir 'gzip-releases.txt.gz'
$cookieHashReleasePage = Join-Path $sourceDir 'cookiehash-releases.txt'
$v1Source = Join-Path $sourceDir 'autotool-1.0.0.exe'
$v2Source = Join-Path $sourceDir 'autotool-1.1.0.exe'
$reverseV1Source = Join-Path $sourceDir 'reverseauto-1.0.0.exe'
$reverseV2Source = Join-Path $sourceDir 'reverseauto-1.2.0.exe'
$replaceV1Source = Join-Path $sourceDir 'replaceauto-1.0.0.exe'
$replaceV2Source = Join-Path $sourceDir 'replaceauto-2.5.0.exe'
$agentV1Source = Join-Path $sourceDir 'agentauto-1.0.0.exe'
$agentV2Source = Join-Path $sourceDir 'agentauto-3.4.5.exe'
$githubV1Source = Join-Path $sourceDir 'githubauto-1.0.0.exe'
$githubV2Source = Join-Path $sourceDir 'githubauto-4.5.6.exe'
$invalidGithubV1Source = Join-Path $sourceDir 'invalidgithubauto-1.0.0.exe'
$sourceforgeV1Source = Join-Path $sourceDir 'sourceforgeauto-1.0.0.exe'
$sourceforgeV2Source = Join-Path $sourceDir 'sourceforgeauto-7.8.9.exe'
$xpathV1Source = Join-Path $sourceDir 'xpathauto-1.0.0.exe'
$xpathV2Source = Join-Path $sourceDir 'xpathauto-6.7.8.exe'
$namespaceXpathV1Source = Join-Path $sourceDir 'namespacexpathauto-1.0.0.exe'
$namespaceXpathV2Source = Join-Path $sourceDir 'namespacexpathauto-14.15.16.exe'
$scriptV1Source = Join-Path $sourceDir 'scriptauto-1.0.0.exe'
$scriptV2Source = Join-Path $sourceDir 'scriptauto-9.8.7.exe'
$jsonpathV1Source = Join-Path $sourceDir 'jsonpathauto-1.0.0.exe'
$jsonpathV2Source = Join-Path $sourceDir 'jsonpathauto-10.11.12.exe'
$recursiveJsonpathV1Source = Join-Path $sourceDir 'recursivejsonauto-1.0.0.exe'
$recursiveJsonpathV2Source = Join-Path $sourceDir 'recursivejsonauto-11.12.13.exe'
$redirectV1Source = Join-Path $sourceDir 'redirectauto-1.0.0.exe'
$redirectV2Source = Join-Path $sourceDir 'redirectauto-12.13.14.exe'
$gzipV1Source = Join-Path $sourceDir 'gzipauto-1.0.0.exe'
$gzipV2Source = Join-Path $sourceDir 'gzipauto-13.14.15.exe'
$cookieHashV1Source = Join-Path $sourceDir 'cookiehashauto-1.0.0.exe'
$cookieHashV2Source = Join-Path $sourceDir 'cookiehashauto-2.2.0.exe'
New-Item -ItemType Directory -Force -Path $bucketDir, $sourceDir | Out-Null
Copy-Item -LiteralPath $ArtifactV1 -Destination $v1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $v2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $reverseV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $reverseV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $replaceV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $replaceV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $agentV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $agentV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $githubV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $githubV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $invalidGithubV1Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $sourceforgeV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $sourceforgeV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $xpathV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $xpathV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $namespaceXpathV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $namespaceXpathV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $scriptV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $scriptV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $jsonpathV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $jsonpathV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $recursiveJsonpathV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $recursiveJsonpathV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $redirectV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $redirectV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $gzipV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $gzipV2Source -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $cookieHashV1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $cookieHashV2Source -Force

function Write-GzipFile($Path, $Text) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Text)
    $stream = [System.IO.File]::Create($Path)
    try {
        $gzip = [System.IO.Compression.GZipStream]::new($stream, [System.IO.Compression.CompressionMode]::Compress)
        try {
            $gzip.Write($bytes, 0, $bytes.Length)
        } finally {
            $gzip.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

Set-Content -Path $releasePage -Value 'Latest release: autotool 1.1.0' -NoNewline -Encoding Ascii
Set-Content -Path $reverseReleasePage -Value @('reverseauto 1.1.0', 'reverseauto 1.2.0') -Encoding Ascii
Set-Content -Path $replaceReleasePage -Value 'replaceauto 2-5-0' -NoNewline -Encoding Ascii
Set-Content -Path $agentReleasePage -Value 'agentauto 3.4.5' -NoNewline -Encoding Ascii
Set-Content -Path $githubReleasePage -Value '<a href="/owner/repo/releases/tag/v4.5.6">latest</a>' -NoNewline -Encoding Ascii
Set-Content -Path $sourceforgeReleasePage -Value '<rss><channel><item><title><![CDATA[/releases/sourceforgeauto-7.8.9.exe]]></title></item><item><title><![CDATA[/ignored/sourceforgeauto-0.1.0.exe]]></title></item></channel></rss>' -NoNewline -Encoding Ascii
Set-Content -Path $xpathReleasePage -Value '<feed xmlns="urn:sco-test"><release><title>xpathauto version 6.7.8</title></release></feed>' -NoNewline -Encoding Ascii
Set-Content -Path $namespaceXpathReleasePage -Value '<feed xmlns="urn:sco-test"><release><title>namespacexpathauto version 14.15.16</title></release></feed>' -NoNewline -Encoding Ascii
Set-Content -Path $jsonpathReleasePage -Value '{"assets":[{"name":"ignored","version":"0.0.1"},{"name":"jsonpathauto","version":"10.11.12"}]}' -NoNewline -Encoding Ascii
Set-Content -Path (Join-Path $sourceDir 'recursive-jsonpath-releases.json') -Value '{"groups":[{"channel":"stable","payload":{"assets":[{"name":"recursivejsonauto","version":"11.12.13"}]}},{"channel":"old","payload":{"assets":[{"name":"recursivejsonauto","version":"0.0.1"}]}}]}' -NoNewline -Encoding Ascii
Set-Content -Path $redirectReleasePage -Value 'redirectauto 12.13.14' -NoNewline -Encoding Ascii
Write-GzipFile $gzipReleasePage 'gzipauto 13.14.15'
Set-Content -Path $cookieHashReleasePage -Value 'cookiehashauto 2.2.0' -NoNewline -Encoding Ascii

$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'autotool-1.0.0.exe'
    checkver = [ordered]@{
        url = ([System.IO.Path]::GetFullPath($releasePage))
        regex = 'autotool ([\d.]+)'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'autotool-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'autotool-$version.exe'
    }
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8

$reverseManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($reverseV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'reverseauto-1.0.0.exe'
    checkver = [ordered]@{
        url = ([System.IO.Path]::GetFullPath($reverseReleasePage))
        regex = 'reverseauto ([\d.]+)'
        reverse = 'true'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'reverseauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'reverseauto-$version.exe'
    }
}
$reverseManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $reverseManifestPath -Encoding UTF8

$replaceManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($replaceV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'replaceauto-1.0.0.exe'
    checkver = [ordered]@{
        url = ([System.IO.Path]::GetFullPath($replaceReleasePage))
        regex = 'replaceauto (\d+)-(\d+)-(\d+)'
        replace = '$1.$2.$3'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'replaceauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'replaceauto-$version.exe'
    }
}
$replaceManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $replaceManifestPath -Encoding UTF8

$agentManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($agentV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'agentauto-1.0.0.exe'
    checkver = [ordered]@{
        url = 'HTTP://127.0.0.1:18198/releases.txt'
        regex = 'agentauto ([\d.]+)'
        useragent = 'sco-agent/$version'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'agentauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'agentauto-$version.exe'
    }
}
$agentManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $agentManifestPath -Encoding UTF8

$githubManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($githubV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'githubauto-1.0.0.exe'
    checkver = [ordered]@{
        GitHub = 'http://127.0.0.1:18199/owner/repo'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'githubauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'githubauto-$version.exe'
    }
}
$githubManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $githubManifestPath -Encoding UTF8

$invalidGithubManifest = [ordered]@{
    version = '1.0.0'
    homepage = 'http://127.0.0.1:18206/not-github'
    url = ([System.IO.Path]::GetFullPath($invalidGithubV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'invalidgithubauto-1.0.0.exe'
    CheckVer = 'GitHub'
}
$invalidGithubManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $invalidGithubManifestPath -Encoding UTF8

$sourceforgeManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($sourceforgeV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'sourceforgeauto-1.0.0.exe'
    checkver = [ordered]@{
        URL = ([System.IO.Path]::GetFullPath($sourceforgeReleasePage))
        SourceForge = [ordered]@{
            Project = 'sourceforgeauto'
            Path = 'releases'
        }
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'sourceforgeauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'sourceforgeauto-$version.exe'
    }
}
$sourceforgeManifest | ConvertTo-Json -Depth 7 | Set-Content -Path $sourceforgeManifestPath -Encoding UTF8

$xpathManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($xpathV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'xpathauto-1.0.0.exe'
    checkver = [ordered]@{
        url = ([System.IO.Path]::GetFullPath($xpathReleasePage))
        xpath = '/feed/release/title'
        regex = 'xpathauto version ([\d.]+)'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'xpathauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'xpathauto-$version.exe'
    }
}
$xpathManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $xpathManifestPath -Encoding UTF8

$namespaceXpathManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($namespaceXpathV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'namespacexpathauto-1.0.0.exe'
    checkver = [ordered]@{
        url = ([System.IO.Path]::GetFullPath($namespaceXpathReleasePage))
        xpath = '/ns:feed/ns:release/ns:title'
        regex = 'namespacexpathauto version ([\d.]+)'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'namespacexpathauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'namespacexpathauto-$version.exe'
    }
}
$namespaceXpathManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $namespaceXpathManifestPath -Encoding UTF8

$scriptManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($scriptV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'scriptauto-1.0.0.exe'
    checkver = [ordered]@{
        script = @(
            "'scriptauto 9.8.7'"
        )
        regex = 'scriptauto ([\d.]+)'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'scriptauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'scriptauto-$version.exe'
    }
}
$scriptManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $scriptManifestPath -Encoding UTF8

$jsonpathManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($jsonpathV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'jsonpathauto-1.0.0.exe'
    checkver = [ordered]@{
        url = ([System.IO.Path]::GetFullPath($jsonpathReleasePage))
        jsonpath = 'Assets[1].Version'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'jsonpathauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'jsonpathauto-$version.exe'
    }
}
$jsonpathManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonpathManifestPath -Encoding UTF8

$recursiveJsonpathManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($recursiveJsonpathV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'recursivejsonauto-1.0.0.exe'
    checkver = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'recursive-jsonpath-releases.json')))
        jsonpath = "`$..assets[?(@.name == 'recursivejsonauto')].version"
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'recursivejsonauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'recursivejsonauto-$version.exe'
    }
}
$recursiveJsonpathManifest | ConvertTo-Json -Depth 7 | Set-Content -Path $recursiveJsonpathManifestPath -Encoding UTF8

$redirectManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($redirectV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'redirectauto-1.0.0.exe'
    checkver = [ordered]@{
        url = 'http://127.0.0.1:18205/releases/latest'
        regex = 'redirectauto ([\d.]+)'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'redirectauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'redirectauto-$version.exe'
    }
}
$redirectManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $redirectManifestPath -Encoding UTF8

$gzipManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($gzipV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'gzipauto-1.0.0.exe'
    checkver = [ordered]@{
        url = 'http://127.0.0.1:18207/releases.txt.gz'
        regex = 'gzipauto ([\d.]+)'
    }
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'gzipauto-$version.exe')))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        bin = 'gzipauto-$version.exe'
    }
}
$gzipManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $gzipManifestPath -Encoding UTF8

$cookieHashManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($cookieHashV1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = 'cookiehashauto-1.0.0.exe'
    cookie = [ordered]@{
        session = 'autoupdate-cookie'
    }
    checkver = [ordered]@{
        url = 'http://127.0.0.1:18218/releases.txt'
        regex = 'cookiehashauto ([\d.]+)'
    }
    autoupdate = [ordered]@{
        url = 'http://127.0.0.1:18218/cookiehashauto-$version.exe'
        hash = [ordered]@{
            mode = 'download'
        }
        bin = 'cookiehashauto-$version.exe'
    }
}
$cookieHashManifest | ConvertTo-Json -Depth 7 | Set-Content -Path $cookieHashManifestPath -Encoding UTF8

function Start-OneShotCheckverServer($Prefix, $File, $ExpectedUserAgent, $ExpectedReferer, $ExpectedPrivateHost) {
    Start-Job -ScriptBlock {
        param($Prefix, $File, $ExpectedUserAgent, $ExpectedReferer, $ExpectedPrivateHost)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        try {
            $context = $listener.GetContext()
            $userAgent = $context.Request.Headers['User-Agent']
            $referer = $context.Request.Headers['Referer']
            $privateHost = $context.Request.Headers['X-Private-Host']
            if ($userAgent -ne $ExpectedUserAgent) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected user-agent: $userAgent")
                $context.Response.StatusCode = 403
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                return
            }
            if ($referer -ne $ExpectedReferer) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected referer: $referer")
                $context.Response.StatusCode = 403
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                return
            }
            if ($privateHost -ne $ExpectedPrivateHost) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected private host header: $privateHost")
                $context.Response.StatusCode = 403
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                return
            }

            $bytes = [System.IO.File]::ReadAllBytes($File)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'text/plain'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Prefix, $File, $ExpectedUserAgent, $ExpectedReferer, $ExpectedPrivateHost
}

function Start-OneShotFileServer($Prefix, $File, $ExpectedAuthorization = $null) {
    Start-Job -ScriptBlock {
        param($Prefix, $File, $ExpectedAuthorization)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        try {
            $context = $listener.GetContext()
            if ($ExpectedAuthorization) {
                $authorization = $context.Request.Headers['Authorization']
                if ($authorization -ne $ExpectedAuthorization) {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected authorization: $authorization")
                    $context.Response.StatusCode = 403
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $context.Response.OutputStream.Close()
                    return
                }
            }
            $bytes = [System.IO.File]::ReadAllBytes($File)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'text/html'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Prefix, $File, $ExpectedAuthorization
}

function Start-TwoShotRedirectServer($Prefix, $File) {
    Start-Job -ScriptBlock {
        param($Prefix, $File)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        try {
            $redirectContext = $listener.GetContext()
            $redirectContext.Response.StatusCode = 302
            $redirectContext.Response.Headers['Location'] = '/downloads/latest.txt'
            $redirectContext.Response.OutputStream.Close()

            $fileContext = $listener.GetContext()
            $bytes = [System.IO.File]::ReadAllBytes($File)
            $fileContext.Response.StatusCode = 200
            $fileContext.Response.ContentType = 'text/plain'
            $fileContext.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $fileContext.Response.OutputStream.Close()
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Prefix, $File
}

function Start-AutoupdateHashCookieServer($Prefix, $ReleaseFile, $ArtifactFile) {
    Start-Job -ScriptBlock {
        param($Prefix, $ReleaseFile, $ArtifactFile)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        try {
            for ($i = 0; $i -lt 4; $i++) {
                $context = $listener.GetContext()
                $path = $context.Request.Url.AbsolutePath
                if ($path -eq '/releases.txt') {
                    $bytes = [System.IO.File]::ReadAllBytes($ReleaseFile)
                    $context.Response.StatusCode = 200
                    $context.Response.ContentType = 'text/plain'
                    if ($context.Request.HttpMethod -ne 'HEAD') {
                        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                    $context.Response.OutputStream.Close()
                    continue
                }
                if ($path -eq '/cookiehashauto-2.2.0.exe') {
                    $cookie = $context.Request.Headers['Cookie']
                    if ($cookie) {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected cookie during autoupdate hash download: $cookie")
                        $context.Response.StatusCode = 403
                        if ($context.Request.HttpMethod -ne 'HEAD') {
                            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                        }
                        $context.Response.OutputStream.Close()
                        continue
                    }
                    $bytes = [System.IO.File]::ReadAllBytes($ArtifactFile)
                    $context.Response.StatusCode = 200
                    $context.Response.ContentType = 'application/octet-stream'
                    if ($context.Request.HttpMethod -ne 'HEAD') {
                        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                    $context.Response.OutputStream.Close()
                    continue
                }

                $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected path: $path")
                $context.Response.StatusCode = 404
                if ($context.Request.HttpMethod -ne 'HEAD') {
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                $context.Response.OutputStream.Close()
            }
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Prefix, $ReleaseFile, $ArtifactFile
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome

$configDir = Join-Path $ConfigHome 'scoop'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
$privateHostsConfig = [ordered]@{
    private_hosts = @(
        [ordered]@{
            match = '127\.0\.0\.1:18198'
            headers = 'X-Private-Host=checkver'
        }
    )
}
$privateHostsConfig | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $configDir 'config.json') -Encoding UTF8

& $ScoExe install autotool --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install failed with exit code $LASTEXITCODE"
}

$statusOutput = & $ScoExe status
if ($LASTEXITCODE -ne 0) {
    throw "status failed with exit code $LASTEXITCODE"
}
$joined = $statusOutput -join "`n"
if ($joined -notmatch 'autotool') {
    throw "status did not include autotool: $joined"
}
if ($joined -notmatch '1\.0\.0') {
    throw "status did not include installed version: $joined"
}
if ($joined -notmatch '1\.1\.0') {
    throw "status did not include checkver latest version: $joined"
}
if ($joined -match 'Update available') {
    throw "status should not add an Update available info field for checkver updates: $joined"
}

$localStatusOutput = & $ScoExe status --local
if ($LASTEXITCODE -ne 0) {
    throw "status --local failed with exit code $LASTEXITCODE"
}
$localJoined = $localStatusOutput -join "`n"
if ($localJoined -notmatch 'Everything is ok!') {
    throw "status --local should skip checkver remote/local source probing: $localJoined"
}

& $ScoExe update autotool
if ($LASTEXITCODE -ne 0) {
    throw "update failed with exit code $LASTEXITCODE"
}

$generatedManifest = Join-Path $Root 'cache\generated-manifests\autotool\1.1.0\autotool.json'
if (!(Test-Path $generatedManifest)) {
    throw "update did not generate autoupdate manifest: $generatedManifest"
}

$currentManifest = Get-Content (Join-Path $Root 'apps\autotool\current\manifest.json') -Raw | ConvertFrom-Json
if ($currentManifest.version -ne '1.1.0') {
    throw "current manifest did not switch to 1.1.0"
}

$currentContent = Get-Content (Join-Path $Root 'apps\autotool\current\autotool-1.1.0.exe') -Raw
if ($currentContent -ne '@echo filetool-v2') {
    throw "current did not switch to updated artifact: $currentContent"
}

$updatedInstall = Get-Content (Join-Path $Root 'apps\autotool\current\install.json') -Raw | ConvertFrom-Json
if ($updatedInstall.bucket -ne 'main') {
    throw "checkver update from bucket did not preserve bucket source: $($updatedInstall | ConvertTo-Json -Compress)"
}
if ($updatedInstall.PSObject.Properties.Name -contains 'url') {
    throw "checkver update from bucket should not persist generated manifest as standalone url: $($updatedInstall | ConvertTo-Json -Compress)"
}

$listOutput = (& $ScoExe list) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "list after checkver update failed with exit code $LASTEXITCODE`: $listOutput"
}
if ($listOutput -notmatch 'autotool\s+1\.1\.0\s+main') {
    throw "list should show the original bucket source after checkver update: $listOutput"
}
if ($listOutput -match 'autotool\s+1\.1\.0\s+<auto-generated>') {
    throw "list should not show generated manifest as source for bucket-origin checkver update: $listOutput"
}

$exportOutput = (& $ScoExe export) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "export after checkver update failed with exit code $LASTEXITCODE`: $exportOutput"
}
$exportJson = $exportOutput | ConvertFrom-Json
if (-not ($exportJson.apps | Where-Object { $_.Name -eq 'autotool' -and $_.Version -eq '1.1.0' -and $_.Source -eq 'main' })) {
    throw "export should show the original bucket source after checkver update: $exportOutput"
}
if ($exportJson.apps | Where-Object { $_.Name -eq 'autotool' -and $_.Source -eq '<auto-generated>' }) {
    throw "export should not show generated manifest as source for bucket-origin checkver update: $exportOutput"
}

$infoOutput = (& $ScoExe info autotool --verbose) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "info after checkver update failed with exit code $LASTEXITCODE`: $infoOutput"
}
foreach ($pattern in @(
    'Version\s+:\s+1\.1\.0',
    'Source\s+:\s+main',
    'Binaries\s+:\s+autotool-1\.1\.0\.exe',
    'Manifest\s+:\s+.*/apps/autotool/1\.1\.0/manifest\.json'
)) {
    if ($infoOutput -notmatch $pattern) {
        throw "info should describe the installed generated manifest with original bucket source for pattern '$pattern': $infoOutput"
    }
}
if ($infoOutput -match 'Binaries\s+:\s+autotool-1\.0\.0\.exe' -or $infoOutput -match 'Manifest\s+:\s+.*/buckets/main/bucket/autotool\.json') {
    throw "info should not fall back to the old bucket manifest after checkver update: $infoOutput"
}

$catOutput = (& $ScoExe cat autotool) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "cat after checkver update failed with exit code $LASTEXITCODE`: $catOutput"
}
$catJson = $catOutput | ConvertFrom-Json
if ($catJson.version -ne '1.1.0' -or $catJson.bin -ne 'autotool-1.1.0.exe') {
    throw "cat should read the installed generated manifest after checkver update: $catOutput"
}

& $ScoExe install reverseauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install reverseauto failed with exit code $LASTEXITCODE"
}

& $ScoExe update reverseauto
if ($LASTEXITCODE -ne 0) {
    throw "update reverseauto failed with exit code $LASTEXITCODE"
}

$reverseManifestCurrent = Get-Content (Join-Path $Root 'apps\reverseauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($reverseManifestCurrent.version -ne '1.2.0') {
    throw "checkver reverse did not select the last regex match: $($reverseManifestCurrent.version)"
}

& $ScoExe install replaceauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install replaceauto failed with exit code $LASTEXITCODE"
}

& $ScoExe update replaceauto
if ($LASTEXITCODE -ne 0) {
    throw "update replaceauto failed with exit code $LASTEXITCODE"
}

$replaceManifestCurrent = Get-Content (Join-Path $Root 'apps\replaceauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($replaceManifestCurrent.version -ne '2.5.0') {
    throw "checkver replace did not rewrite captured version: $($replaceManifestCurrent.version)"
}

& $ScoExe install agentauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install agentauto failed with exit code $LASTEXITCODE"
}

$agentJob = Start-OneShotCheckverServer 'http://127.0.0.1:18198/' $agentReleasePage 'sco-agent/1.0.0' 'HTTP://127.0.0.1:18198' 'checkver'
Start-Sleep -Milliseconds 300
try {
    & $ScoExe update agentauto
    if ($LASTEXITCODE -ne 0) {
        throw "update agentauto failed with exit code $LASTEXITCODE"
    }
} finally {
    Wait-Job $agentJob -Timeout 5 | Out-Null
    Receive-Job $agentJob | Out-Null
    Remove-Job $agentJob -Force
}

$agentManifestCurrent = Get-Content (Join-Path $Root 'apps\agentauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($agentManifestCurrent.version -ne '3.4.5') {
    throw "checkver useragent did not fetch latest version: $($agentManifestCurrent.version)"
}

& $ScoExe install githubauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install githubauto failed with exit code $LASTEXITCODE"
}

$previousGhToken = $env:SCOOP_GH_TOKEN
$env:SCOOP_GH_TOKEN = 'checkver-token'
$githubJob = Start-OneShotFileServer 'http://127.0.0.1:18199/' $githubReleasePage 'token checkver-token'
Start-Sleep -Milliseconds 300
try {
    & $ScoExe update githubauto
    if ($LASTEXITCODE -ne 0) {
        throw "update githubauto failed with exit code $LASTEXITCODE"
    }
} finally {
    if ($null -eq $previousGhToken) {
        Remove-Item Env:SCOOP_GH_TOKEN -ErrorAction SilentlyContinue
    } else {
        $env:SCOOP_GH_TOKEN = $previousGhToken
    }
    Wait-Job $githubJob -Timeout 5 | Out-Null
    Receive-Job $githubJob | Out-Null
    Remove-Job $githubJob -Force
}

$githubManifestCurrent = Get-Content (Join-Path $Root 'apps\githubauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($githubManifestCurrent.version -ne '4.5.6') {
    throw "checkver github did not parse latest release version: $($githubManifestCurrent.version)"
}

& $ScoExe install invalidgithubauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install invalidgithubauto failed with exit code $LASTEXITCODE"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$invalidGithubOutput = & $ScoExe update invalidgithubauto 2>&1
$invalidGithubExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
$invalidGithubJoined = $invalidGithubOutput -join "`n"
if ($invalidGithubExitCode -eq 0) {
    throw "update invalidgithubauto should have failed for a non-GitHub homepage: $invalidGithubJoined"
}
if ($invalidGithubJoined -notmatch 'invalidgithubauto checkver expects the homepage to be a github repository') {
    throw "update invalidgithubauto did not report Scoop's GitHub homepage validation: $invalidGithubJoined"
}

& $ScoExe install sourceforgeauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install sourceforgeauto failed with exit code $LASTEXITCODE"
}

& $ScoExe update sourceforgeauto
if ($LASTEXITCODE -ne 0) {
    throw "update sourceforgeauto failed with exit code $LASTEXITCODE"
}

$sourceforgeManifestCurrent = Get-Content (Join-Path $Root 'apps\sourceforgeauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($sourceforgeManifestCurrent.version -ne '7.8.9') {
    throw "checkver sourceforge did not parse latest release version: $($sourceforgeManifestCurrent.version)"
}

& $ScoExe install xpathauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install xpathauto failed with exit code $LASTEXITCODE"
}

& $ScoExe update xpathauto
if ($LASTEXITCODE -ne 0) {
    throw "update xpathauto failed with exit code $LASTEXITCODE"
}

$xpathManifestCurrent = Get-Content (Join-Path $Root 'apps\xpathauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($xpathManifestCurrent.version -ne '6.7.8') {
    throw "checkver xpath did not parse latest release version: $($xpathManifestCurrent.version)"
}

& $ScoExe install namespacexpathauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install namespacexpathauto failed with exit code $LASTEXITCODE"
}

& $ScoExe update namespacexpathauto
if ($LASTEXITCODE -ne 0) {
    throw "update namespacexpathauto failed with exit code $LASTEXITCODE"
}

$namespaceXpathManifestCurrent = Get-Content (Join-Path $Root 'apps\namespacexpathauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($namespaceXpathManifestCurrent.version -ne '14.15.16') {
    throw "checkver namespace-prefixed xpath did not parse latest release version: $($namespaceXpathManifestCurrent.version)"
}

& $ScoExe install scriptauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install scriptauto failed with exit code $LASTEXITCODE"
}

& $ScoExe update scriptauto
if ($LASTEXITCODE -ne 0) {
    throw "update scriptauto failed with exit code $LASTEXITCODE"
}

$scriptManifestCurrent = Get-Content (Join-Path $Root 'apps\scriptauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($scriptManifestCurrent.version -ne '9.8.7') {
    throw "checkver script did not parse latest release version: $($scriptManifestCurrent.version)"
}

& $ScoExe install jsonpathauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install jsonpathauto failed with exit code $LASTEXITCODE"
}

& $ScoExe update jsonpathauto
if ($LASTEXITCODE -ne 0) {
    throw "update jsonpathauto failed with exit code $LASTEXITCODE"
}

$jsonpathManifestCurrent = Get-Content (Join-Path $Root 'apps\jsonpathauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($jsonpathManifestCurrent.version -ne '10.11.12') {
    throw "checkver jsonpath filter did not parse latest release version: $($jsonpathManifestCurrent.version)"
}

& $ScoExe install recursivejsonauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install recursivejsonauto failed with exit code $LASTEXITCODE"
}

& $ScoExe update recursivejsonauto
if ($LASTEXITCODE -ne 0) {
    throw "update recursivejsonauto failed with exit code $LASTEXITCODE"
}

$recursiveJsonpathManifestCurrent = Get-Content (Join-Path $Root 'apps\recursivejsonauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($recursiveJsonpathManifestCurrent.version -ne '11.12.13') {
    throw "checkver recursive jsonpath filter did not parse latest release version: $($recursiveJsonpathManifestCurrent.version)"
}

& $ScoExe install redirectauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install redirectauto failed with exit code $LASTEXITCODE"
}

$redirectJob = Start-TwoShotRedirectServer 'http://127.0.0.1:18205/' $redirectReleasePage
Start-Sleep -Milliseconds 300
try {
    & $ScoExe update redirectauto
    if ($LASTEXITCODE -ne 0) {
        throw "update redirectauto failed with exit code $LASTEXITCODE"
    }
} finally {
    Wait-Job $redirectJob -Timeout 5 | Out-Null
    Receive-Job $redirectJob | Out-Null
    Remove-Job $redirectJob -Force
}

$redirectManifestCurrent = Get-Content (Join-Path $Root 'apps\redirectauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($redirectManifestCurrent.version -ne '12.13.14') {
    throw "checkver did not follow redirect to latest version page: $($redirectManifestCurrent.version)"
}

& $ScoExe install gzipauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install gzipauto failed with exit code $LASTEXITCODE"
}

$gzipJob = Start-OneShotFileServer 'http://127.0.0.1:18207/' $gzipReleasePage
Start-Sleep -Milliseconds 300
try {
    & $ScoExe update gzipauto
    if ($LASTEXITCODE -ne 0) {
        throw "update gzipauto failed with exit code $LASTEXITCODE"
    }
} finally {
    Wait-Job $gzipJob -Timeout 5 | Out-Null
    Receive-Job $gzipJob | Out-Null
    Remove-Job $gzipJob -Force
}

$gzipManifestCurrent = Get-Content (Join-Path $Root 'apps\gzipauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($gzipManifestCurrent.version -ne '13.14.15') {
    throw "checkver did not decompress gzip release page: $($gzipManifestCurrent.version)"
}

& $ScoExe install cookiehashauto --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install cookiehashauto failed with exit code $LASTEXITCODE"
}

$cookieHashJob = Start-AutoupdateHashCookieServer 'http://127.0.0.1:18218/' $cookieHashReleasePage $cookieHashV2Source
Start-Sleep -Milliseconds 300
try {
    & $ScoExe update cookiehashauto
    if ($LASTEXITCODE -ne 0) {
        throw "update cookiehashauto failed with exit code $LASTEXITCODE"
    }
} finally {
    Wait-Job $cookieHashJob -Timeout 5 | Out-Null
    Receive-Job $cookieHashJob | Out-Null
    Remove-Job $cookieHashJob -Force
}

$cookieHashManifestCurrent = Get-Content (Join-Path $Root 'apps\cookiehashauto\current\manifest.json') -Raw | ConvertFrom-Json
if ($cookieHashManifestCurrent.version -ne '2.2.0') {
    throw "autoupdate hash download cookie regression did not update version: $($cookieHashManifestCurrent.version)"
}
if ($cookieHashManifestCurrent.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "autoupdate hash download cookie regression did not compute hash: $($cookieHashManifestCurrent.hash)"
}
