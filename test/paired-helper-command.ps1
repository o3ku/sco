param(
    [Parameter(Mandatory = $true)][string]$ScoExe,
    [Parameter(Mandatory = $true)][string]$ScoopPs1,
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

$scoRoot = Join-Path $Root 'sco'
$refRoot = Join-Path $Root 'ref'
$scoConfigHome = Join-Path $ConfigHome 'sco'
$refConfigHome = Join-Path $ConfigHome 'ref'
$scoopHome = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ScoopPs1) '..'))
$defaultPsModulePath = 'C:\Program Files\WindowsPowerShell\Modules;C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules'

foreach ($toolRoot in @($scoRoot, $refRoot)) {
    New-Item -ItemType Directory -Force -Path @(
        $toolRoot,
        (Join-Path $toolRoot 'shims'),
        (Join-Path $toolRoot 'cache'),
        (Join-Path $toolRoot 'sources'),
        (Join-Path $toolRoot 'buckets\main\bucket')
    ) | Out-Null
}

function Write-ManifestBoth {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Manifest,
        [string]$LiteralJson
    )

    foreach ($toolRoot in @($scoRoot, $refRoot)) {
        $path = Join-Path $toolRoot "buckets\main\bucket\$Name.json"
        if ($LiteralJson) {
            Set-Content -LiteralPath $path -Value $LiteralJson -Encoding UTF8
        } else {
            $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
        }
    }
}

function Write-SourceBoth {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Content
    )

    foreach ($toolRoot in @($scoRoot, $refRoot)) {
        Set-Content -LiteralPath (Join-Path $toolRoot "sources\$Name") -Value $Content -Encoding UTF8
    }
}

function Source-PathFor {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$Name
    )

    [System.IO.Path]::GetFullPath((Join-Path $ToolRoot "sources\$Name"))
}

function Normalize-Output {
    param(
        [string[]]$Lines,
        [string]$ToolRoot,
        [string]$ToolConfigHome
    )

    $rootPath = ([System.IO.Path]::GetFullPath($ToolRoot)).TrimEnd('\')
    $configPath = ([System.IO.Path]::GetFullPath($ToolConfigHome)).TrimEnd('\')
    $rootPattern = [regex]::Escape($rootPath)
    $rootSlashPattern = [regex]::Escape(($rootPath -replace '\\', '/'))
    $configPattern = [regex]::Escape($configPath)
    $configSlashPattern = [regex]::Escape(($configPath -replace '\\', '/'))

    $normalized = @($Lines | ForEach-Object {
        ([string]$_ -replace "`r", '') `
            -replace "`e\[[0-9;?]*[ -/]*[@-~]", '' `
            -replace $rootPattern, '<ROOT>' `
            -replace $rootSlashPattern, '<ROOT>' `
            -replace $configPattern, '<CONFIG>' `
            -replace $configSlashPattern, '<CONFIG>' `
            -replace '\bscoop\b', 'sco' `
            -replace '\\', '/'
    } | ForEach-Object {
        $_.TrimEnd()
    })

    while ($normalized.Count -gt 0 -and $normalized[-1] -eq '') {
        $normalized = @($normalized[0..($normalized.Count - 2)])
    }
    return ($normalized -join "`n")
}

function Invoke-PairedHelper {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('sco', 'ref')][string]$Tool,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    if ($Tool -eq 'sco') {
        $toolRoot = $scoRoot
        $toolConfigHome = $scoConfigHome
    } else {
        $toolRoot = $refRoot
        $toolConfigHome = $refConfigHome
    }

    $env:SCOOP = $toolRoot
    $env:XDG_CONFIG_HOME = $toolConfigHome
    $env:SCOOP_HOME = $scoopHome
    $env:PSModulePath = $defaultPsModulePath

    $resolvedArguments = @($Arguments | ForEach-Object {
        if ($_ -eq '<BUCKET>') {
            Join-Path $toolRoot 'buckets\main\bucket'
        } else {
            $_
        }
    })

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Tool -eq 'sco') {
            $output = & $ScoExe $Command @resolvedArguments 2>&1
            $exitCode = $LASTEXITCODE
        } else {
            $script = Join-Path $scoopHome "bin\$Command.ps1"
            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $script @resolvedArguments 2>&1
            $exitCode = $LASTEXITCODE
        }

        [pscustomobject]@{
            ExitCode = $exitCode
            Text = Normalize-Output -Lines @($output | ForEach-Object { [string]$_ }) -ToolRoot $toolRoot -ToolConfigHome $toolConfigHome
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Assert-PairedHelper {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    $sco = Invoke-PairedHelper sco $Command @Arguments
    $ref = Invoke-PairedHelper ref $Command @Arguments
    $display = "$Command $($Arguments -join ' ')".TrimEnd()

    if ($sco.ExitCode -ne $ref.ExitCode) {
        throw "'$display' exit codes differ: sco=$($sco.ExitCode), ref=$($ref.ExitCode)`nsco:`n$($sco.Text)`n---`nref:`n$($ref.Text)"
    }
    if ($sco.Text -ne $ref.Text) {
        throw "'$display' output differs.`nsco:`n$($sco.Text)`n---`nref:`n$($ref.Text)"
    }
}

function Assert-ManifestContentEqual {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $scoText = (Get-Content -LiteralPath (Join-Path $scoRoot $RelativePath) -Raw) -replace "`r`n", "`n"
    $refText = (Get-Content -LiteralPath (Join-Path $refRoot $RelativePath) -Raw) -replace "`r`n", "`n"
    if ($scoText -ne $refText) {
        throw "manifest content differs for $RelativePath`nsco:`n$scoText`n---`nref:`n$refText"
    }
}

Write-ManifestBoth 'supportedtool' ([ordered]@{
    version = '1.0.0'
    url = 'https://example.invalid/supported.exe'
    hash = ''
    checkver = 'supported ([\d.]+)'
    autoupdate = [ordered]@{
        url = 'https://example.invalid/supported-$version.exe'
    }
})
Write-ManifestBoth 'checkveronly' ([ordered]@{
    version = '1.0.0'
    url = 'https://example.invalid/checkver.exe'
    hash = ''
    checkver = 'checkveronly ([\d.]+)'
})
Write-ManifestBoth 'autoupdateonly' ([ordered]@{
    version = '1.0.0'
    url = 'https://example.invalid/autoupdate.exe'
    hash = ''
    autoupdate = [ordered]@{
        url = 'https://example.invalid/autoupdate-$version.exe'
    }
})
Write-ManifestBoth 'plaintool' ([ordered]@{
    version = '1.0.0'
    url = 'https://example.invalid/plain.exe'
    hash = ''
})

Assert-PairedHelper missing-checkver -Dir '<BUCKET>'
Assert-PairedHelper missing-checkver -Dir '<BUCKET>' -SkipSupported
Assert-PairedHelper missing-checkver '*only' -Dir '<BUCKET>'
Assert-PairedHelper missing-checkver 'checkver?nly' -Dir '<BUCKET>'

Write-ManifestBoth 'formatme' $null '{"version":"1.0.0","url":"https://example.invalid/format.exe","hash":"","architecture":{"64bit":{"url":"https://example.invalid/format-x64.exe","hash":""}}}'
Write-ManifestBoth 'skipme' $null '{"version":"1.0.0","url":"https://example.invalid/skip.exe","hash":""}'

Assert-PairedHelper formatjson 'format*' -Dir '<BUCKET>'
Assert-ManifestContentEqual 'buckets\main\bucket\formatme.json'
Assert-ManifestContentEqual 'buckets\main\bucket\skipme.json'

Assert-PairedHelper formatjson skipme -Dir '<BUCKET>'
Assert-ManifestContentEqual 'buckets\main\bucket\skipme.json'

Write-SourceBoth 'latest.html' '<html><body>paircheck 1.2.0</body></html>'
Write-SourceBoth 'same.html' '<html><body>pairsame 2.0.0</body></html>'

foreach ($toolRoot in @($scoRoot, $refRoot)) {
    $bucketDir = Join-Path $toolRoot 'buckets\main\bucket'
    [ordered]@{
        version = '1.0.0'
        url = 'https://example.invalid/paircheck-1.0.0.exe'
        hash = ''
        checkver = [ordered]@{
            url = Source-PathFor $toolRoot 'latest.html'
            regex = 'paircheck ([\d.]+)'
        }
        autoupdate = [ordered]@{
            url = 'https://example.invalid/paircheck-$version.exe'
            hash = ''
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $bucketDir 'paircheck.json') -Encoding UTF8

    [ordered]@{
        version = '2.0.0'
        url = 'https://example.invalid/pairsame-2.0.0.exe'
        hash = ''
        checkver = [ordered]@{
            url = Source-PathFor $toolRoot 'same.html'
            regex = 'pairsame ([\d.]+)'
        }
        autoupdate = [ordered]@{
            url = 'https://example.invalid/pairsame-$version.exe'
            hash = ''
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $bucketDir 'pairsame.json') -Encoding UTF8
}

Assert-PairedHelper checkver paircheck -Dir '<BUCKET>'
Assert-PairedHelper checkver pairsame -Dir '<BUCKET>'
Assert-PairedHelper checkver pairsame -Dir '<BUCKET>' -SkipUpdated
