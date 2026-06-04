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

$sourceDir = Join-Path $Root 'sources'
New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
$v1Source = Join-Path $sourceDir 'autotool-1.0.0.exe'
$v2Source = Join-Path $sourceDir 'autotool-2.0.0.exe'
$hashFile = Join-Path $sourceDir 'autotool-2.0.0.sha256'
$jsonSource = Join-Path $sourceDir 'jsontool-3.0.0.exe'
$jsonMeta = Join-Path $sourceDir 'jsontool-3.0.0.json'
$xmlSource = Join-Path $sourceDir 'xmltool-3.5.0.exe'
$xmlMeta = Join-Path $sourceDir 'xmltool-3.5.0.xml'
$base64Source = Join-Path $sourceDir 'base64auto-3.6.0.exe'
$base64HashFile = Join-Path $sourceDir 'base64auto-3.6.0.hash'
$remoteSource = Join-Path $sourceDir 'remoteauto-4.0.0.exe'
$remoteHashFile = Join-Path $sourceDir 'remoteauto-4.0.0.sha256'
$remoteHeaderSource = Join-Path $sourceDir 'remoteheaderauto-4.5.0.exe'
$remoteHeaderHashFile = Join-Path $sourceDir 'remoteheaderauto-4.5.0.sha256'
$gzipHashSource = Join-Path $sourceDir 'gziphashauto-4.6.0.exe'
$gzipHashFile = Join-Path $sourceDir 'gziphashauto-4.6.0.sha256.gz'
$multiOneSource = Join-Path $sourceDir 'multiauto-5.0.0-one.exe'
$multiTwoSource = Join-Path $sourceDir 'multiauto-5.0.0-two.exe'
$multiOneHashFile = Join-Path $sourceDir 'multiauto-5.0.0-one.sha256'
$multiTwoHashFile = Join-Path $sourceDir 'multiauto-5.0.0-two.hash'
$computedSource = Join-Path $sourceDir 'computedauto-6.0.0.exe'
$downloadModeSource = Join-Path $sourceDir 'downloadmodeauto-6.5.0.exe'
$downloadModeBadHashFile = Join-Path $sourceDir 'downloadmodeauto-6.5.0.sha256'
$metalinkSource = Join-Path $sourceDir 'metalinkauto-6.6.0.exe'
$metalinkMeta4 = Join-Path $sourceDir 'metalinkauto-6.6.0.exe.meta4'
$metalinkHeaderSource = Join-Path $sourceDir 'metalinkheaderauto-6.6.5.exe'
$rdfSource = Join-Path $sourceDir 'rdfauto-6.7.0.exe'
$rdfMeta = Join-Path $sourceDir 'rdfauto-6.7.0.rdf'
$sha1Source = Join-Path $sourceDir 'sha1auto-6.8.0.exe'
$sha1HashFile = Join-Path $sourceDir 'sha1auto-6.8.0.sha1'
$sourceforgeSource = Join-Path $sourceDir 'sfauto-6.9.0.exe'
$sourceforgeMeta = Join-Path $sourceDir 'sfauto-6.9.0.meta'
$githubDigestSource = Join-Path $sourceDir 'githubdigestauto-6.9.8.exe'
$githubDigestMeta = Join-Path $sourceDir 'githubdigestauto-6.9.8.json'
$archSource = Join-Path $sourceDir 'archauto-7.0.0.exe'
$archHashFile = Join-Path $sourceDir 'archauto-7.0.0.sha256'
$topOnlyArchSource = Join-Path $sourceDir 'toponlyarchauto-7.5.0.exe'
$topOnlyArchOverrideSource = Join-Path $sourceDir 'toponlyarchauto-7.5.0-x64.exe'
$prereleaseSource = Join-Path $sourceDir 'preauto-8.0.0-beta.exe'
$prereleaseHashFile = Join-Path $sourceDir 'preauto-8.0.0-beta.sha256'
Copy-Item -LiteralPath $ArtifactV1 -Destination $v1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $v2Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $jsonSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $xmlSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $base64Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $remoteSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $remoteHeaderSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $gzipHashSource -Force
Copy-Item -LiteralPath $ArtifactV1 -Destination $multiOneSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $multiTwoSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $computedSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $downloadModeSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $metalinkSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $metalinkHeaderSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $rdfSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $sha1Source -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $sourceforgeSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $githubDigestSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $archSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $topOnlyArchSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $topOnlyArchOverrideSource -Force
Copy-Item -LiteralPath $ArtifactV2 -Destination $prereleaseSource -Force
Set-Content -Path $hashFile -Encoding ASCII -Value 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824  autotool-2.0.0.exe'
Set-Content -Path $remoteHashFile -Encoding ASCII -Value 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824  remoteauto-4.0.0.exe'
Set-Content -Path $remoteHeaderHashFile -Encoding ASCII -Value 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824  remoteheaderauto-4.5.0.exe'

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

Write-GzipFile $gzipHashFile 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824  gziphashauto-4.6.0.exe'
Set-Content -Path $multiOneHashFile -Encoding ASCII -Value '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b  multiauto-5.0.0-one.exe'
Set-Content -Path $multiTwoHashFile -Encoding ASCII -Value 'sha256=cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
Set-Content -Path $archHashFile -Encoding ASCII -Value 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824  archauto-7.0.0.exe'
Set-Content -Path $prereleaseHashFile -Encoding ASCII -Value 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824  preauto-8.0.0-beta.exe'
Set-Content -Path $base64HashFile -Encoding ASCII -Value 'sha256=z2dFbOLZGhZcFN0c4kOLPEO3k6i3WTJhdXW+F6boSCQ='
Set-Content -Path $downloadModeBadHashFile -Encoding ASCII -Value '0000000000000000000000000000000000000000000000000000000000000000  downloadmodeauto-6.5.0.exe'
Set-Content -Path $metalinkMeta4 -Encoding ASCII -Value '<metalink><file name="metalinkauto-6.6.0.exe"><hash type="sha-256">cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824</hash></file></metalink>'
Set-Content -Path $rdfMeta -Encoding ASCII -Value '<RDF><Content about="rdfauto-6.7.0.exe"><sha256>cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824</sha256></Content><Content about="ignored.exe"><sha256>0000000000000000000000000000000000000000000000000000000000000000</sha256></Content></RDF>'
$sha1 = [System.Security.Cryptography.SHA1]::Create()
$sha1Stream = [System.IO.File]::OpenRead($sha1Source)
try {
    $sha1Bytes = $sha1.ComputeHash($sha1Stream)
    $sha1Hash = -join ($sha1Bytes | ForEach-Object { $_.ToString('x2') })
    $sha1Base64 = [System.Convert]::ToBase64String($sha1Bytes)
} finally {
    $sha1Stream.Dispose()
    $sha1.Dispose()
}
Set-Content -Path $sha1HashFile -Encoding ASCII -Value "$sha1Hash  sha1auto-6.8.0.exe"
Set-Content -Path $sourceforgeMeta -Encoding ASCII -Value "{`"ignored.exe`":{`"sha1`":`"0000000000000000000000000000000000000000`"},`"sfauto-6.9.0.exe`":{`"sha1`":`"$sha1Hash`"}}"

$githubDigestMetadata = @(
    [ordered]@{
        name = 'v6.9.8'
        assets = @(
            [ordered]@{
                browser_download_url = 'https://github.com/example/repo/releases/download/v0.0.0/ignored.exe'
                digest = 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
            },
            [ordered]@{
                browser_download_url = ([System.IO.Path]::GetFullPath($githubDigestSource))
                digest = "sha1:$sha1Hash"
            }
        )
    }
)
$githubDigestMetadata | ConvertTo-Json -Depth 6 | Set-Content -Path $githubDigestMeta -Encoding UTF8

$bucketDir = Join-Path $Root 'buckets\main\bucket'
New-Item -ItemType Directory -Force -Path $bucketDir | Out-Null
$manifestPath = Join-Path $bucketDir 'autotool.json'

$urlTemplate = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'autotool-$version.exe')))
$manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('autotool-1.0.0.exe', 'autotool'))
    autoupdate = [ordered]@{
        url = $urlTemplate
        hash = [ordered]@{
            url = '$urlNoExt.sha256'
            find = '$sha256\s+$basename'
        }
        bin = @(, @('autotool-$version.exe', 'autotool'))
    }
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

$jsonUrlTemplate = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'jsontool-$version.exe')))
$jsonManifestPath = Join-Path $bucketDir 'jsontool.json'
$jsonManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'jsontool'))
    autoupdate = [ordered]@{
        url = $jsonUrlTemplate
        hash = [ordered]@{
            url = '$urlNoExt.json'
            jsonpath = "`$.assets[?(@.browser_download_url == '`$url')].digest"
        }
        bin = @(, @('jsontool-$version.exe', 'jsontool'))
    }
}
$jsonManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonManifestPath -Encoding UTF8

$jsonMetadata = [ordered]@{
    assets = @(
        [ordered]@{
            browser_download_url = ([System.IO.Path]::GetFullPath($jsonSource))
            digest = 'sha256:cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        }
    )
}
$jsonMetadata | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonMeta -Encoding UTF8

$xmlUrlTemplate = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'xmltool-$version.exe')))
$xmlManifestPath = Join-Path $bucketDir 'xmltool.json'
$xmlManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'xmltool'))
    autoupdate = [ordered]@{
        url = $xmlUrlTemplate
        hash = [ordered]@{
            url = '$urlNoExt.xml'
            xpath = '/m:metadata/m:asset/m:hash'
        }
        bin = @(, @('xmltool-$version.exe', 'xmltool'))
    }
}
$xmlManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $xmlManifestPath -Encoding UTF8

Set-Content -Path $xmlMeta -Encoding ASCII -Value '<m:metadata xmlns:m="urn:sco-test"><m:asset><m:hash>sha256:cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824</m:hash></m:asset></m:metadata>'

$base64ManifestPath = Join-Path $bucketDir 'base64auto.json'
$base64Manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'base64auto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'base64auto-$version.exe')))
        hash = [ordered]@{
            url = '$urlNoExt.hash'
            find = 'sha256=$base64'
        }
        bin = @(, @('base64auto-$version.exe', 'base64auto'))
    }
}
$base64Manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $base64ManifestPath -Encoding UTF8

$remoteManifestPath = Join-Path $sourceDir 'remoteauto.json'
$remoteManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'remoteauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'remoteauto-$version.exe')))
        hash = [ordered]@{
            url = '$urlNoExt.sha256'
            find = '([a-fA-F0-9]{64})\s+$basename'
        }
        bin = @(, @('remoteauto-$version.exe', 'remoteauto'))
    }
}
$remoteManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $remoteManifestPath -Encoding UTF8

$remoteHeaderManifestPath = Join-Path $bucketDir 'remoteheaderauto.json'
$remoteHeaderManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'remoteheaderauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'remoteheaderauto-$version.exe')))
        hash = [ordered]@{
            url = 'http://127.0.0.1:18206/hashes/remoteheaderauto-$version.sha256'
            find = '$sha256\s+$basename'
        }
        bin = @(, @('remoteheaderauto-$version.exe', 'remoteheaderauto'))
    }
}
$remoteHeaderManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $remoteHeaderManifestPath -Encoding UTF8

$gzipHashManifestPath = Join-Path $bucketDir 'gziphashauto.json'
$gzipHashManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'gziphashauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'gziphashauto-$version.exe')))
        hash = [ordered]@{
            url = 'http://127.0.0.1:18207/hashes/gziphashauto-$version.sha256.gz'
            find = '$sha256\s+$basename'
        }
        bin = @(, @('gziphashauto-$version.exe', 'gziphashauto'))
    }
}
$gzipHashManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $gzipHashManifestPath -Encoding UTF8

$multiManifestPath = Join-Path $bucketDir 'multiauto.json'
$multiManifest = [ordered]@{
    version = '1.0.0'
    url = @(
        ([System.IO.Path]::GetFullPath($v1Source)),
        ([System.IO.Path]::GetFullPath($v1Source))
    )
    hash = @(
        '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b',
        '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    )
    bin = 'filetool.exe'
    autoupdate = [ordered]@{
        url = @(
            ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'multiauto-$version-one.exe'))),
            ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'multiauto-$version-two.exe')))
        )
        hash = @(
            [ordered]@{
                url = '$urlNoExt.sha256'
                find = '([a-fA-F0-9]{64})\s+$basename'
            },
            [ordered]@{
                url = '$urlNoExt.hash'
                find = 'sha256=([a-fA-F0-9]{64})'
            }
        )
    }
}
$multiManifest | ConvertTo-Json -Depth 7 | Set-Content -Path $multiManifestPath -Encoding UTF8

$computedManifestPath = Join-Path $bucketDir 'computedauto.json'
$computedManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'computedauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'computedauto-$version.exe')))
        bin = @(, @('computedauto-$version.exe', 'computedauto'))
    }
}
$computedManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $computedManifestPath -Encoding UTF8

$downloadModeManifestPath = Join-Path $bucketDir 'downloadmodeauto.json'
$downloadModeManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'downloadmodeauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'downloadmodeauto-$version.exe')))
        hash = [ordered]@{
            mode = 'download'
            url = '$urlNoExt.sha256'
            find = '$sha256\s+$basename'
        }
        bin = @(, @('downloadmodeauto-$version.exe', 'downloadmodeauto'))
    }
}
$downloadModeManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $downloadModeManifestPath -Encoding UTF8

$metalinkManifestPath = Join-Path $bucketDir 'metalinkauto.json'
$metalinkManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'metalinkauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'metalinkauto-$version.exe')))
        hash = [ordered]@{
            mode = 'metalink'
        }
        bin = @(, @('metalinkauto-$version.exe', 'metalinkauto'))
    }
}
$metalinkManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $metalinkManifestPath -Encoding UTF8

$metalinkHeaderManifestPath = Join-Path $bucketDir 'metalinkheaderauto.json'
$metalinkHeaderManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'metalinkheaderauto'))
    autoupdate = [ordered]@{
        url = 'http://127.0.0.1:18198/metalinkheaderauto-$version.exe'
        hash = [ordered]@{
            mode = 'metalink'
        }
        bin = @(, @('metalinkheaderauto-$version.exe', 'metalinkheaderauto'))
    }
}
$metalinkHeaderManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $metalinkHeaderManifestPath -Encoding UTF8

$rdfManifestPath = Join-Path $bucketDir 'rdfauto.json'
$rdfManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'rdfauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'rdfauto-$version.exe')))
        hash = [ordered]@{
            mode = 'rdf'
            url = '$urlNoExt.rdf'
        }
        bin = @(, @('rdfauto-$version.exe', 'rdfauto'))
    }
}
$rdfManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $rdfManifestPath -Encoding UTF8

$sha1ManifestPath = Join-Path $bucketDir 'sha1auto.json'
$sha1Manifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'sha1auto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'sha1auto-$version.exe')))
        hash = [ordered]@{
            url = '$urlNoExt.sha1'
            find = '$sha1\s+$basename'
        }
        bin = @(, @('sha1auto-$version.exe', 'sha1auto'))
    }
}
$sha1Manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $sha1ManifestPath -Encoding UTF8

$sourceforgeManifestPath = Join-Path $bucketDir 'sfauto.json'
$sourceforgeManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'sfauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'sfauto-$version.exe')))
        hash = [ordered]@{
            mode = 'sourceforge'
            url = ([System.IO.Path]::GetFullPath($sourceforgeMeta))
        }
        bin = @(, @('sfauto-$version.exe', 'sfauto'))
    }
}
$sourceforgeManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $sourceforgeManifestPath -Encoding UTF8

$fosshubManifestPath = Join-Path $bucketDir 'fosshubauto.json'
$fosshubManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'fosshubauto'))
    autoupdate = [ordered]@{
        url = 'http://127.0.0.1:18197/fosshub.com/fosshubauto-$version.exe'
        hash = [ordered]@{
            mode = 'fosshub'
        }
        bin = @(, @('fosshubauto-$version.exe', 'fosshubauto'))
    }
}
$fosshubManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $fosshubManifestPath -Encoding UTF8

$githubDigestManifestPath = Join-Path $bucketDir 'githubdigestauto.json'
$githubDigestMetadataUrl = 'http://127.0.0.1:18210/githubdigestauto-6.9.8.json'
$githubDigestManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'githubdigestauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'githubdigestauto-$version.exe')))
        hash = [ordered]@{
            mode = 'github'
            url = $githubDigestMetadataUrl
        }
        bin = @(, @('githubdigestauto-$version.exe', 'githubdigestauto'))
    }
}
$githubDigestManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $githubDigestManifestPath -Encoding UTF8

$archManifestPath = Join-Path $bucketDir 'archauto.json'
$archManifest = [ordered]@{
    version = '1.0.0'
    architecture = [ordered]@{
        '64bit' = [ordered]@{
            url = ([System.IO.Path]::GetFullPath($v1Source))
            hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        }
        '32bit' = [ordered]@{
            url = ([System.IO.Path]::GetFullPath($v1Source))
            hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
        }
    }
    bin = 'filetool.exe'
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'archauto-$version.exe')))
        hash = [ordered]@{
            url = '$urlNoExt.sha256'
            find = '([a-fA-F0-9]{64})\s+$basename'
        }
        architecture = [ordered]@{
            '64bit' = [ordered]@{}
            '32bit' = [ordered]@{}
        }
    }
}
$archManifest | ConvertTo-Json -Depth 8 | Set-Content -Path $archManifestPath -Encoding UTF8

$topOnlyArchManifestPath = Join-Path $bucketDir 'toponlyarchauto.json'
$topOnlyArchManifest = [ordered]@{
    version = '1.0.0'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'toponlyarchauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath($topOnlyArchSource))
        hash = 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
        architecture = [ordered]@{
            '64bit' = [ordered]@{
                url = ([System.IO.Path]::GetFullPath($topOnlyArchOverrideSource))
            }
        }
    }
}
$topOnlyArchManifest | ConvertTo-Json -Depth 8 | Set-Content -Path $topOnlyArchManifestPath -Encoding UTF8

$prereleaseManifestPath = Join-Path $bucketDir 'preauto.json'
$prereleaseManifest = [ordered]@{
    version = '8.0.0-alpha'
    url = ([System.IO.Path]::GetFullPath($v1Source))
    hash = '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b'
    bin = @(@('filetool.exe', 'preauto'))
    autoupdate = [ordered]@{
        url = ([System.IO.Path]::GetFullPath((Join-Path $sourceDir 'preauto-$version.exe')))
        hash = 'sha512:acdbbedf5a164625d506f8c80045edac033ee5c675bc313858fcbda7a1047d26bc6ea0961a7d082921dc32dd98dc4ff5fcd2876ab5f1b7e0d16f62fbd5597201'
        notes = 'channel=$preReleaseVersion'
        bin = @(, @('preauto-$version.exe', 'preauto'))
    }
}
$prereleaseManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $prereleaseManifestPath -Encoding UTF8

function Start-OneShotJsonServer($Prefix, $File) {
    Start-Job -ScriptBlock {
        param($Prefix, $File)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        try {
            $context = $listener.GetContext()
            $bytes = [System.IO.File]::ReadAllBytes($File)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'application/json'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Prefix, $File
}

function Start-OneShotHeaderServer($Prefix, $File, $ExpectedReferer, $ExpectedPrivateHost) {
    Start-Job -ScriptBlock {
        param($Prefix, $File, $ExpectedReferer, $ExpectedPrivateHost)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        try {
            $context = $listener.GetContext()
            $userAgent = $context.Request.Headers['User-Agent']
            $referer = $context.Request.Headers['Referer']
            $privateHost = $context.Request.Headers['X-Private-Host']
            if ($userAgent -ne 'sco') {
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
    } -ArgumentList $Prefix, $File, $ExpectedReferer, $ExpectedPrivateHost
}

function Start-OneShotGitHubMetadataServer($Prefix, $File, $ExpectedAuthorization) {
    Start-Job -ScriptBlock {
        param($Prefix, $File, $ExpectedAuthorization)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        try {
            $context = $listener.GetContext()
            $authorization = $context.Request.Headers['Authorization']
            if ($authorization -ne $ExpectedAuthorization) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("unexpected authorization: $authorization")
                $context.Response.StatusCode = 403
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
                return
            }

            $bytes = [System.IO.File]::ReadAllBytes($File)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'application/json'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Prefix, $File, $ExpectedAuthorization
}

function Start-TwoShotFossHubServer($Prefix, $Artifact, $Hash) {
    Start-Job -ScriptBlock {
        param($Prefix, $Artifact, $Hash)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        try {
            $metadataContext = $listener.GetContext()
            $metadata = "FossHub data for fosshubauto-6.9.5.exe {`"sha256`":`"$Hash`"}"
            $metadataBytes = [System.Text.Encoding]::ASCII.GetBytes($metadata)
            $metadataContext.Response.StatusCode = 200
            $metadataContext.Response.ContentType = 'text/plain'
            if ($metadataContext.Request.HttpMethod -ne 'HEAD') {
                $metadataContext.Response.OutputStream.Write($metadataBytes, 0, $metadataBytes.Length)
            }
            $metadataContext.Response.OutputStream.Close()

            for ($i = 0; $i -lt 3; $i++) {
                $artifactContext = $listener.GetContext()
                $artifactBytes = [System.IO.File]::ReadAllBytes($Artifact)
                $artifactContext.Response.StatusCode = 200
                $artifactContext.Response.ContentType = 'application/octet-stream'
                if ($artifactContext.Request.HttpMethod -ne 'HEAD') {
                    $artifactContext.Response.OutputStream.Write($artifactBytes, 0, $artifactBytes.Length)
                    $artifactContext.Response.OutputStream.Close()
                    break
                }
                $artifactContext.Response.OutputStream.Close()
            }
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Prefix, $Artifact, $Hash
}

function Start-TwoShotMetalinkHeaderServer($Prefix, $Artifact, $Digest) {
    Start-Job -ScriptBlock {
        param($Prefix, $Artifact, $Digest)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        try {
            for ($i = 0; $i -lt 10; $i++) {
                $context = $listener.GetContext()
                $path = $context.Request.Url.AbsolutePath
                if ($path -eq '/download/metalinkheaderauto-6.6.5.exe') {
                    $artifactBytes = [System.IO.File]::ReadAllBytes($Artifact)
                    $context.Response.StatusCode = 200
                    $context.Response.ContentType = 'application/octet-stream'
                    if ($context.Request.HttpMethod -ne 'HEAD') {
                        $context.Response.OutputStream.Write($artifactBytes, 0, $artifactBytes.Length)
                        $context.Response.OutputStream.Close()
                        break
                    }
                    $context.Response.OutputStream.Close()
                    continue
                }

                $context.Response.StatusCode = 302
                $context.Response.Headers['Digest'] = "SHA=$Digest"
                $context.Response.Headers['Location'] = '/download/metalinkheaderauto-6.6.5.exe'
                $context.Response.ContentLength64 = 0
                $context.Response.OutputStream.Close()
            }
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Prefix, $Artifact, $Digest
}

$env:SCOOP = $Root
$env:XDG_CONFIG_HOME = $ConfigHome
$env:PATH = "$(Join-Path $Root 'shims');$env:PATH"

$configDir = Join-Path $ConfigHome 'scoop'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
$privateHostsConfig = [ordered]@{
    private_hosts = @(
        [ordered]@{
            match = '127\.0\.0\.1:18206'
            headers = 'X-Private-Host=autoupdate'
        }
    )
}
$privateHostsConfig | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $configDir 'config.json') -Encoding UTF8

$sameVersionDownloadOutput = & $ScoExe download autotool@1.0.0 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "download autotool@current version should use the source manifest without autoupdate generation, got exit code $LASTEXITCODE`: $sameVersionDownloadOutput"
}
if (($sameVersionDownloadOutput -join "`n") -notmatch "'autotool' \(1\.0\.0\) was downloaded successfully!") {
    throw "download app@current version did not report the source manifest version: $sameVersionDownloadOutput"
}
$sameVersionGenerated = Join-Path $Root 'cache\generated-manifests\autotool\1.0.0\autotool.json'
if (Test-Path $sameVersionGenerated) {
    throw 'download app@current version generated an autoupdate manifest instead of reusing the source manifest like Scoop'
}

$downloadOutput = & $ScoExe download autotool@2.0.0 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "download autotool@2.0.0 failed with exit code $LASTEXITCODE`: $downloadOutput"
}
if (($downloadOutput -join "`n") -notmatch "'autotool' \(2\.0\.0\) was downloaded successfully!") {
    throw "download output did not use generated version: $downloadOutput"
}

$generated = Join-Path $Root 'cache\generated-manifests\autotool\2.0.0\autotool.json'
if (!(Test-Path $generated)) {
    throw 'download did not write generated autoupdate manifest'
}
$generatedManifest = Get-Content -LiteralPath $generated -Raw | ConvertFrom-Json
if ($generatedManifest.version -ne '2.0.0' -or $generatedManifest.url -notmatch 'autotool-2\.0\.0\.exe') {
    throw 'generated manifest did not substitute version into url'
}
if ($generatedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated manifest did not extract hash from checksum file: $($generatedManifest.hash)"
}

& $ScoExe install autotool@2.0.0 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "install autotool@2.0.0 failed with exit code $LASTEXITCODE"
}

if (!(Test-Path (Join-Path $Root 'apps\autotool\2.0.0\autotool-2.0.0.exe'))) {
    throw 'install did not place substituted artifact in version directory'
}

$which = (& $ScoExe which autotool).Trim().Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or $which -notmatch 'apps/autotool/current/autotool-2\.0\.0\.exe') {
    throw "which autotool did not point at generated bin target: $which"
}

$jsonDownloadOutput = & $ScoExe download jsontool@3.0.0 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "download jsontool@3.0.0 failed with exit code $LASTEXITCODE`: $jsonDownloadOutput"
}

$jsonGenerated = Join-Path $Root 'cache\generated-manifests\jsontool\3.0.0\jsontool.json'
if (!(Test-Path $jsonGenerated)) {
    throw 'download did not write generated json autoupdate manifest'
}
$jsonGeneratedManifest = Get-Content -LiteralPath $jsonGenerated -Raw | ConvertFrom-Json
if ($jsonGeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated JSON manifest did not extract hash through jsonpath: $($jsonGeneratedManifest.hash)"
}

$xmlDownloadOutput = & $ScoExe download xmltool@3.5.0 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "download xmltool@3.5.0 failed with exit code $LASTEXITCODE`: $xmlDownloadOutput"
}

$xmlGenerated = Join-Path $Root 'cache\generated-manifests\xmltool\3.5.0\xmltool.json'
if (!(Test-Path $xmlGenerated)) {
    throw 'download did not write generated XML autoupdate manifest'
}
$xmlGeneratedManifest = Get-Content -LiteralPath $xmlGenerated -Raw | ConvertFrom-Json
if ($xmlGeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated XML manifest did not extract hash through xpath: $($xmlGeneratedManifest.hash)"
}

$base64DownloadOutput = & $ScoExe download base64auto@3.6.0 --no-update-scoop
if ($LASTEXITCODE -ne 0) {
    throw "download base64auto@3.6.0 failed with exit code $LASTEXITCODE`: $base64DownloadOutput"
}

$base64Generated = Join-Path $Root 'cache\generated-manifests\base64auto\3.6.0\base64auto.json'
if (!(Test-Path $base64Generated)) {
    throw 'download did not write generated base64 autoupdate manifest'
}
$base64GeneratedManifest = Get-Content -LiteralPath $base64Generated -Raw | ConvertFrom-Json
if ($base64GeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated manifest did not convert base64 hash: $($base64GeneratedManifest.hash)"
}

$downloadPrefix = 'http://127.0.0.1:18195/'
$downloadJob = Start-OneShotJsonServer $downloadPrefix $remoteManifestPath
Start-Sleep -Milliseconds 300
try {
    $remoteDownloadOutput = & $ScoExe download ($downloadPrefix + 'remoteauto.json@4.0.0') --no-update-scoop
    if ($LASTEXITCODE -ne 0) {
        throw "download remoteauto URL@4.0.0 failed with exit code $LASTEXITCODE`: $remoteDownloadOutput"
    }
    if (($remoteDownloadOutput -join "`n") -notmatch "'remoteauto' \(4\.0\.0\) was downloaded successfully!") {
        throw "remote URL@version download output did not use generated version: $remoteDownloadOutput"
    }
} finally {
    Wait-Job $downloadJob -Timeout 5 | Out-Null
    Receive-Job $downloadJob | Out-Null
    Remove-Job $downloadJob -Force
}

$remoteGenerated = Join-Path $Root 'cache\generated-manifests\remoteauto\4.0.0\remoteauto.json'
if (!(Test-Path $remoteGenerated)) {
    throw 'download URL@version did not write generated remote autoupdate manifest'
}
$remoteGeneratedManifest = Get-Content -LiteralPath $remoteGenerated -Raw | ConvertFrom-Json
if ($remoteGeneratedManifest.version -ne '4.0.0' -or $remoteGeneratedManifest.url -notmatch 'remoteauto-4\.0\.0\.exe') {
    throw 'generated remote manifest did not substitute version into url'
}
if ($remoteGeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated remote manifest did not extract hash: $($remoteGeneratedManifest.hash)"
}

$installPrefix = 'http://127.0.0.1:18196/'
$installJob = Start-OneShotJsonServer $installPrefix $remoteManifestPath
Start-Sleep -Milliseconds 300
try {
    & $ScoExe install ($installPrefix + 'remoteauto.json@4.0.0') --no-update-scoop
    if ($LASTEXITCODE -ne 0) {
        throw "install remoteauto URL@4.0.0 failed with exit code $LASTEXITCODE"
    }
} finally {
    Wait-Job $installJob -Timeout 5 | Out-Null
    Receive-Job $installJob | Out-Null
    Remove-Job $installJob -Force
}

if (!(Test-Path (Join-Path $Root 'apps\remoteauto\4.0.0\remoteauto-4.0.0.exe'))) {
    throw 'install URL@version did not place substituted remote artifact in version directory'
}

$remoteHeaderPrefix = 'http://127.0.0.1:18206/'
$remoteHeaderJob = Start-OneShotHeaderServer $remoteHeaderPrefix $remoteHeaderHashFile 'http://127.0.0.1:18206/hashes' 'autoupdate'
Start-Sleep -Milliseconds 300
try {
    $remoteHeaderOutput = & $ScoExe download remoteheaderauto@4.5.0 --no-update-scoop --force
    if ($LASTEXITCODE -ne 0) {
        throw "download remoteheaderauto@4.5.0 with hash sidecar headers failed with exit code $LASTEXITCODE`: $remoteHeaderOutput"
    }
} finally {
    Wait-Job $remoteHeaderJob -Timeout 5 | Out-Null
    Receive-Job $remoteHeaderJob | Out-Null
    Remove-Job $remoteHeaderJob -Force
}

$remoteHeaderGenerated = Join-Path $Root 'cache\generated-manifests\remoteheaderauto\4.5.0\remoteheaderauto.json'
if (!(Test-Path $remoteHeaderGenerated)) {
    throw 'download did not write generated remote-header autoupdate manifest'
}
$remoteHeaderGeneratedManifest = Get-Content -LiteralPath $remoteHeaderGenerated -Raw | ConvertFrom-Json
if ($remoteHeaderGeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated manifest did not extract hash from remote sidecar with headers: $($remoteHeaderGeneratedManifest.hash)"
}

$gzipHashPrefix = 'http://127.0.0.1:18207/'
$gzipHashJob = Start-OneShotHeaderServer $gzipHashPrefix $gzipHashFile 'http://127.0.0.1:18207/hashes' $null
Start-Sleep -Milliseconds 300
try {
    $gzipHashOutput = & $ScoExe download gziphashauto@4.6.0 --no-update-scoop --force
    if ($LASTEXITCODE -ne 0) {
        throw "download gziphashauto@4.6.0 with gzipped hash sidecar failed with exit code $LASTEXITCODE`: $gzipHashOutput"
    }
} finally {
    Wait-Job $gzipHashJob -Timeout 5 | Out-Null
    Receive-Job $gzipHashJob | Out-Null
    Remove-Job $gzipHashJob -Force
}

$gzipHashGenerated = Join-Path $Root 'cache\generated-manifests\gziphashauto\4.6.0\gziphashauto.json'
if (!(Test-Path $gzipHashGenerated)) {
    throw 'download did not write generated gzip-hash autoupdate manifest'
}
$gzipHashGeneratedManifest = Get-Content -LiteralPath $gzipHashGenerated -Raw | ConvertFrom-Json
if ($gzipHashGeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated manifest did not decompress gzipped hash sidecar: $($gzipHashGeneratedManifest.hash)"
}

$multiDownloadOutput = & $ScoExe download multiauto@5.0.0 --no-update-scoop --force
if ($LASTEXITCODE -ne 0) {
    throw "download multiauto@5.0.0 with autoupdate hash array failed with exit code $LASTEXITCODE`: $multiDownloadOutput"
}
if (($multiDownloadOutput -join "`n") -notmatch "'multiauto' \(5\.0\.0\) was downloaded successfully!") {
    throw "download multiauto output did not use generated version: $multiDownloadOutput"
}

$multiGenerated = Join-Path $Root 'cache\generated-manifests\multiauto\5.0.0\multiauto.json'
if (!(Test-Path $multiGenerated)) {
    throw 'download did not write generated multi-url autoupdate manifest'
}
$multiGeneratedManifest = Get-Content -LiteralPath $multiGenerated -Raw | ConvertFrom-Json
if ($multiGeneratedManifest.hash.Count -ne 2) {
    throw "generated multi-url manifest did not contain two hashes: $($multiGeneratedManifest.hash | ConvertTo-Json -Compress)"
}
if ($multiGeneratedManifest.hash[0] -ne '5f31429cbc87c555998ed7d20ddb645fd0622c6e9591a4e6e6a329d0f6f4957b' -or
    $multiGeneratedManifest.hash[1] -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated multi-url manifest did not apply per-url hash extraction array: $($multiGeneratedManifest.hash | ConvertTo-Json -Compress)"
}
$multiCacheFiles = @(Get-ChildItem (Join-Path $Root 'cache') -Filter 'multiauto#5.0.0#*.exe')
if ($multiCacheFiles.Count -ne 2) {
    throw "multi-url autoupdate download did not cache both artifacts: $($multiCacheFiles.Name -join ', ')"
}

$computedDownloadOutput = & $ScoExe download computedauto@6.0.0 --no-update-scoop --force
if ($LASTEXITCODE -ne 0) {
    throw "download computedauto@6.0.0 with computed autoupdate hash failed with exit code $LASTEXITCODE`: $computedDownloadOutput"
}
if (($computedDownloadOutput -join "`n") -notmatch "'computedauto' \(6\.0\.0\) was downloaded successfully!") {
    throw "download computedauto output did not use generated version: $computedDownloadOutput"
}

$computedGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'computedauto') '6.0.0\computedauto.json'
if (!(Test-Path $computedGenerated)) {
    throw 'download did not write generated computed-hash autoupdate manifest'
}
$computedGeneratedManifest = Get-Content -LiteralPath $computedGenerated -Raw | ConvertFrom-Json
if ($computedGeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated manifest did not compute hash from autoupdate artifact: $($computedGeneratedManifest.hash)"
}

$downloadModeOutput = & $ScoExe download downloadmodeauto@6.5.0 --no-update-scoop --force
if ($LASTEXITCODE -ne 0) {
    throw "download downloadmodeauto@6.5.0 with explicit download hash mode failed with exit code $LASTEXITCODE`: $downloadModeOutput"
}

$downloadModeGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'downloadmodeauto') '6.5.0\downloadmodeauto.json'
if (!(Test-Path $downloadModeGenerated)) {
    throw 'download did not write generated download-mode autoupdate manifest'
}
$downloadModeGeneratedManifest = Get-Content -LiteralPath $downloadModeGenerated -Raw | ConvertFrom-Json
if ($downloadModeGeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated manifest did not compute hash for explicit download mode: $($downloadModeGeneratedManifest.hash)"
}

$metalinkOutput = & $ScoExe download metalinkauto@6.6.0 --no-update-scoop --force
if ($LASTEXITCODE -ne 0) {
    throw "download metalinkauto@6.6.0 with metalink hash mode failed with exit code $LASTEXITCODE`: $metalinkOutput"
}

$metalinkGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'metalinkauto') '6.6.0\metalinkauto.json'
if (!(Test-Path $metalinkGenerated)) {
    throw 'download did not write generated metalink autoupdate manifest'
}
$metalinkGeneratedManifest = Get-Content -LiteralPath $metalinkGenerated -Raw | ConvertFrom-Json
if ($metalinkGeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated manifest did not extract hash from metalink sidecar: $($metalinkGeneratedManifest.hash)"
}

$metalinkHeaderPrefix = 'http://127.0.0.1:18198/'
$metalinkHeaderJob = Start-TwoShotMetalinkHeaderServer $metalinkHeaderPrefix $ArtifactV2 $sha1Base64
Start-Sleep -Milliseconds 300
try {
    $metalinkHeaderOutput = & $ScoExe download metalinkheaderauto@6.6.5 --no-update-scoop --force
    if ($LASTEXITCODE -ne 0) {
        throw "download metalinkheaderauto@6.6.5 with redirect Digest header failed with exit code $LASTEXITCODE`: $metalinkHeaderOutput"
    }
} finally {
    Wait-Job $metalinkHeaderJob -Timeout 5 | Out-Null
    Receive-Job $metalinkHeaderJob | Out-Null
    Remove-Job $metalinkHeaderJob -Force
}

$metalinkHeaderGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'metalinkheaderauto') '6.6.5\metalinkheaderauto.json'
if (!(Test-Path $metalinkHeaderGenerated)) {
    throw 'download did not write generated redirect-Digest metalink autoupdate manifest'
}
$metalinkHeaderGeneratedManifest = Get-Content -LiteralPath $metalinkHeaderGenerated -Raw | ConvertFrom-Json
if ($metalinkHeaderGeneratedManifest.hash -ne "sha1:$sha1Hash") {
    throw "generated manifest did not extract typed SHA1 from redirect Digest header: $($metalinkHeaderGeneratedManifest.hash)"
}

$rdfOutput = & $ScoExe download rdfauto@6.7.0 --no-update-scoop --force
if ($LASTEXITCODE -ne 0) {
    throw "download rdfauto@6.7.0 with rdf hash mode failed with exit code $LASTEXITCODE`: $rdfOutput"
}

$rdfGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'rdfauto') '6.7.0\rdfauto.json'
if (!(Test-Path $rdfGenerated)) {
    throw 'download did not write generated RDF autoupdate manifest'
}
$rdfGeneratedManifest = Get-Content -LiteralPath $rdfGenerated -Raw | ConvertFrom-Json
if ($rdfGeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated manifest did not extract hash from RDF sidecar: $($rdfGeneratedManifest.hash)"
}

$sha1Output = & $ScoExe download sha1auto@6.8.0 --no-update-scoop --force
if ($LASTEXITCODE -ne 0) {
    throw "download sha1auto@6.8.0 with typed SHA1 hash failed with exit code $LASTEXITCODE`: $sha1Output"
}

$sha1Generated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'sha1auto') '6.8.0\sha1auto.json'
if (!(Test-Path $sha1Generated)) {
    throw 'download did not write generated SHA1 autoupdate manifest'
}
$sha1GeneratedManifest = Get-Content -LiteralPath $sha1Generated -Raw | ConvertFrom-Json
if ($sha1GeneratedManifest.hash -ne "sha1:$sha1Hash") {
    throw "generated manifest did not preserve extracted SHA1 hash type: $($sha1GeneratedManifest.hash)"
}

$sourceforgeOutput = & $ScoExe download sfauto@6.9.0 --no-update-scoop --force
if ($LASTEXITCODE -ne 0) {
    throw "download sfauto@6.9.0 with SourceForge hash mode failed with exit code $LASTEXITCODE`: $sourceforgeOutput"
}

$sourceforgeGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'sfauto') '6.9.0\sfauto.json'
if (!(Test-Path $sourceforgeGenerated)) {
    throw 'download did not write generated SourceForge autoupdate manifest'
}
$sourceforgeGeneratedManifest = Get-Content -LiteralPath $sourceforgeGenerated -Raw | ConvertFrom-Json
if ($sourceforgeGeneratedManifest.hash -ne "sha1:$sha1Hash") {
    throw "generated manifest did not extract typed SHA1 from SourceForge metadata: $($sourceforgeGeneratedManifest.hash)"
}

$fosshubPrefix = 'http://127.0.0.1:18197/'
$fosshubJob = Start-TwoShotFossHubServer $fosshubPrefix $ArtifactV2 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824'
Start-Sleep -Milliseconds 300
try {
    $fosshubOutput = & $ScoExe download fosshubauto@6.9.5 --no-update-scoop --force
    if ($LASTEXITCODE -ne 0) {
        throw "download fosshubauto@6.9.5 with FossHub hash mode failed with exit code $LASTEXITCODE`: $fosshubOutput"
    }
} finally {
    Wait-Job $fosshubJob -Timeout 5 | Out-Null
    Receive-Job $fosshubJob | Out-Null
    Remove-Job $fosshubJob -Force
}

$fosshubGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'fosshubauto') '6.9.5\fosshubauto.json'
if (!(Test-Path $fosshubGenerated)) {
    throw 'download did not write generated FossHub autoupdate manifest'
}
$fosshubGeneratedManifest = Get-Content -LiteralPath $fosshubGenerated -Raw | ConvertFrom-Json
if ($fosshubGeneratedManifest.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated manifest did not extract SHA256 from FossHub metadata: $($fosshubGeneratedManifest.hash)"
}

$previousGhToken = $env:SCOOP_GH_TOKEN
$env:SCOOP_GH_TOKEN = 'metadata-token'
$githubDigestJob = Start-OneShotGitHubMetadataServer 'http://127.0.0.1:18210/' $githubDigestMeta 'token metadata-token'
try {
    $githubDigestOutput = & $ScoExe download githubdigestauto@6.9.8 --no-update-scoop --force
    if ($LASTEXITCODE -ne 0) {
        throw "download githubdigestauto@6.9.8 with GitHub asset digest mode failed with exit code $LASTEXITCODE`: $githubDigestOutput"
    }
} finally {
    if ($null -eq $previousGhToken) {
        Remove-Item Env:SCOOP_GH_TOKEN -ErrorAction SilentlyContinue
    } else {
        $env:SCOOP_GH_TOKEN = $previousGhToken
    }
    Wait-Job $githubDigestJob -Timeout 5 | Out-Null
    Receive-Job $githubDigestJob | Out-Null
    Remove-Job $githubDigestJob -Force
}

$githubDigestGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'githubdigestauto') '6.9.8\githubdigestauto.json'
if (!(Test-Path $githubDigestGenerated)) {
    throw 'download did not write generated GitHub digest autoupdate manifest'
}
$githubDigestGeneratedManifest = Get-Content -LiteralPath $githubDigestGenerated -Raw | ConvertFrom-Json
if ($githubDigestGeneratedManifest.hash -ne "sha1:$sha1Hash") {
    throw "generated manifest did not extract typed hash from GitHub asset digest metadata: $($githubDigestGeneratedManifest.hash)"
}

$archDownloadOutput = & $ScoExe download archauto@7.0.0 --no-update-scoop --force --arch 64bit
if ($LASTEXITCODE -ne 0) {
    throw "download archauto@7.0.0 with top-level autoupdate fallback failed with exit code $LASTEXITCODE`: $archDownloadOutput"
}
if (($archDownloadOutput -join "`n") -notmatch "'archauto' \(7\.0\.0\) was downloaded successfully!") {
    throw "download archauto output did not use generated version: $archDownloadOutput"
}

$archGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'archauto') '7.0.0\archauto.json'
if (!(Test-Path $archGenerated)) {
    throw 'download did not write generated architecture autoupdate manifest'
}
$archGeneratedManifest = Get-Content -LiteralPath $archGenerated -Raw | ConvertFrom-Json
if ($archGeneratedManifest.architecture.'64bit'.url -notmatch 'archauto-7\.0\.0\.exe') {
    throw "generated architecture manifest did not inherit top-level url template: $($archGeneratedManifest.architecture.'64bit'.url)"
}
if ($archGeneratedManifest.architecture.'64bit'.hash -ne 'cf67456ce2d91a165c14dd1ce2438b3c43b793a8b75932617575be17a6e84824') {
    throw "generated architecture manifest did not inherit top-level hash extraction: $($archGeneratedManifest.architecture.'64bit'.hash)"
}

$topOnlyArchOutput = & $ScoExe download toponlyarchauto@7.5.0 --no-update-scoop --force --arch 64bit
if ($LASTEXITCODE -ne 0) {
    throw "download toponlyarchauto@7.5.0 failed with exit code $LASTEXITCODE`: $topOnlyArchOutput"
}
$topOnlyArchGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'toponlyarchauto') '7.5.0\toponlyarchauto.json'
if (!(Test-Path $topOnlyArchGenerated)) {
    throw 'download did not write generated top-only architecture autoupdate manifest'
}
$topOnlyArchGeneratedManifest = Get-Content -LiteralPath $topOnlyArchGenerated -Raw | ConvertFrom-Json
if ($topOnlyArchGeneratedManifest.PSObject.Properties.Name -contains 'architecture') {
    throw "generated manifest should not create architecture entries from autoupdate alone: $($topOnlyArchGeneratedManifest | ConvertTo-Json -Depth 8 -Compress)"
}
if ($topOnlyArchGeneratedManifest.url -notmatch 'toponlyarchauto-7\.5\.0\.exe') {
    throw "generated manifest did not keep top-level autoupdate URL: $($topOnlyArchGeneratedManifest.url)"
}

$prereleaseDownloadOutput = & $ScoExe download preauto@8.0.0-beta --no-update-scoop --force
if ($LASTEXITCODE -ne 0) {
    throw "download preauto@8.0.0-beta with prerelease token failed with exit code $LASTEXITCODE`: $prereleaseDownloadOutput"
}

$prereleaseGenerated = Join-Path (Join-Path (Join-Path (Join-Path $Root 'cache') 'generated-manifests') 'preauto') '8.0.0-beta\preauto.json'
if (!(Test-Path $prereleaseGenerated)) {
    throw 'download did not write generated prerelease-token autoupdate manifest'
}
$prereleaseGeneratedManifest = Get-Content -LiteralPath $prereleaseGenerated -Raw | ConvertFrom-Json
if ($prereleaseGeneratedManifest.notes -ne 'channel=beta') {
    throw "generated manifest did not substitute prerelease version token: $($prereleaseGeneratedManifest.notes)"
}
if ($prereleaseGeneratedManifest.hash -ne 'sha512:acdbbedf5a164625d506f8c80045edac033ee5c675bc313858fcbda7a1047d26bc6ea0961a7d082921dc32dd98dc4ff5fcd2876ab5f1b7e0d16f62fbd5597201') {
    throw "generated manifest did not preserve literal autoupdate hash: $($prereleaseGeneratedManifest.hash)"
}
