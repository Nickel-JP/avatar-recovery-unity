param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ここでは公開版情報と配布物一覧の整合性を調べる。署名はCIの別手順で検証する。
$PackageId = 'com.nickel-jp.avatar-recovery'
$RepositoryBaseUrl = 'https://nickel-jp.github.io/avatar-recovery-unity'
$LegacyRepositoryBaseUrl = 'https://raw.githubusercontent.com/Nickel-JP/avatar-recovery-unity/main'
$MaximumDistributionBytes = 800000000L
$MaximumManifestBytes = 1048576L
$StableVersionPattern = '(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'

$resolvedRoot = Get-Item -LiteralPath $RepoRoot -Force
if (-not $resolvedRoot.PSIsContainer -or
    ($resolvedRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'REPOSITORY_ROOT: リポジトリはリンクではないディレクトリを指定してください。'
}
$RepoRoot = $resolvedRoot.FullName

function Get-RepositoryPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $current = $RepoRoot
    foreach ($segment in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or
            $segment.IndexOfAny([char[]]"\:`0`r`n`t") -ge 0) {
            throw "UNSAFE_PATH: リポジトリ外のパスは参照できません: $RelativePath"
        }
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            throw "MISSING_FILE: 必須ファイルまたはディレクトリがありません: $RelativePath"
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "UNSAFE_PATH: リンクは参照できません: $RelativePath"
        }
    }
    return $current
}

function Read-RepositoryText {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    return [IO.File]::ReadAllText((Get-RepositoryPath $RelativePath), [Text.Encoding]::UTF8)
}

function Assert-StableVersion {
    param([Parameter(Mandatory = $true)][string]$Version)
    if ($Version -cnotmatch "^$StableVersionPattern`$") {
        throw "INVALID_VERSION: 安定版のバージョン形式ではありません: $Version"
    }
    try { [void][version]$Version }
    catch { throw "INVALID_VERSION: バージョン番号が範囲外です: $Version" }
}

function Read-PackageManifest {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $manifestEntry = $null
        foreach ($entry in $archive.Entries) {
            $entryPath = $entry.FullName
            $segments = $entryPath.TrimEnd('/').Split('/')
            if ([string]::IsNullOrWhiteSpace($entryPath) -or $entryPath.StartsWith('/') -or
                $entryPath.IndexOfAny([char[]]"\:`0`r`n`t") -ge 0 -or
                @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') }).Count -gt 0) {
                throw "ZIP_PATH: ZIPに不正なパスが含まれています: $entryPath"
            }
            if (-not $seen.Add($entryPath.TrimEnd('/'))) {
                throw "ZIP_DUPLICATE: ZIPに重複したパスがあります: $entryPath"
            }
            if ($entryPath -ieq 'package.json') {
                if ($entryPath -cne 'package.json' -or $null -ne $manifestEntry) {
                    throw 'ZIP_MANIFEST: package.json の名前または定義数が不正です。'
                }
                $manifestEntry = $entry
            }
        }
        if ($null -eq $manifestEntry -or $manifestEntry.Length -gt $MaximumManifestBytes) {
            throw 'ZIP_MANIFEST: ルートの package.json がないか、サイズ上限を超えています。'
        }
        $reader = [IO.StreamReader]::new($manifestEntry.Open(), [Text.Encoding]::UTF8)
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
        finally { $reader.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Assert-PackageManifestMatchesIndex {
    param($Manifest, $IndexManifest, [string]$Version, [string]$LatestVersion)

    if ([string]$Manifest.name -cne $PackageId -or [string]$Manifest.version -cne $Version) {
        throw "ZIP_IDENTITY: ZIP内のパッケージ名またはバージョンが一致しません: $Version"
    }
    $expectedNames = @($Manifest.PSObject.Properties.Name) + @('zipSHA256')
    if ((($expectedNames | Sort-Object) -join '|') -cne
        ((@($IndexManifest.PSObject.Properties.Name) | Sort-Object) -join '|')) {
        throw "ZIP_MANIFEST: index と package.json の項目が一致しません: $Version"
    }
    foreach ($property in $Manifest.PSObject.Properties) {
        $indexProperty = $IndexManifest.PSObject.Properties[$property.Name]
        $packageValue = $property.Value | ConvertTo-Json -Depth 80 -Compress
        $indexValue = $indexProperty.Value | ConvertTo-Json -Depth 80 -Compress
        if ($packageValue -ceq $indexValue) { continue }

        # 旧版のZIPは公開時のURLを保持する。最新ZIPには現在のURLを要求する。
        if ($Version -cne $LatestVersion -and $property.Name -in @('url', 'repo') -and
            [string]$Manifest.url -ceq "$LegacyRepositoryBaseUrl/packages/$PackageId-$Version.zip" -and
            [string]$Manifest.repo -ceq "$LegacyRepositoryBaseUrl/index.json") {
            continue
        }
        throw "ZIP_MANIFEST: index と package.json の $($property.Name) が一致しません: $Version"
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$indexPath = Get-RepositoryPath 'index.json'
$index = Read-RepositoryText 'index.json' | ConvertFrom-Json
$packageProperty = $index.packages.PSObject.Properties[$PackageId]
if ($null -eq $packageProperty) { throw 'INDEX_PACKAGE: index に対象パッケージがありません。' }
$versions = @($packageProperty.Value.versions.PSObject.Properties)
if ($versions.Count -lt 1 -or $versions.Count -gt 3) {
    throw 'INDEX_COUNT: index の公開版数は1件以上3件以下にしてください。'
}
foreach ($entry in $versions) { Assert-StableVersion $entry.Name }
$latestVersion = ($versions | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).Name

$readme = Read-RepositoryText 'README.md'
if ($readme -match '(?m)^#{1,6}\s+Current Public Version\b') {
    throw 'README_HEADING: 最新版の見出しは ### Version で始めてください。'
}
$firstVersionHeading = [regex]::Match($readme, '(?m)^### Version\b[^\r\n]*').Value
$readmeVersion = [regex]::Match($firstVersionHeading, "^### Version ($StableVersionPattern)(?=\s|`$)")
if (-not $readmeVersion.Success -or $readmeVersion.Groups[1].Value -cne $latestVersion) {
    throw "README_VERSION: README先頭の Version 見出しが最新安定版 $latestVersion と一致しません。"
}
$workflow = Read-RepositoryText '.github/workflows/verify-build.yml'
$ciVersions = [regex]::Matches($workflow, "(?m)^  VERSION: ['`"]?($StableVersionPattern)['`"]?\s*(?:#.*)?`$")
if ($ciVersions.Count -ne 1 -or $ciVersions[0].Groups[1].Value -cne $latestVersion) {
    throw "CI_VERSION: CIのVERSIONが最新安定版 $latestVersion と一致しません。"
}

# ZIPのサイズは展開せずに調べる。撤回版は署名だけ残っていても失敗にする。
$packagesPath = Get-RepositoryPath 'packages'
$packageItems = @(Get-ChildItem -LiteralPath $packagesPath -Force -Recurse)
$zipBytes = 0L
$zipCount = 0
$withdrawnPattern = '^' + [regex]::Escape($PackageId) + '-1\.3\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?\.zip(?:\.sig)?$'
foreach ($item in $packageItems) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'UNSAFE_PATH: packages にリンクが含まれています。'
    }
    if ($item.Name -imatch $withdrawnPattern) {
        throw "WITHDRAWN_PACKAGE: 撤回版の配布ファイルが残っています: $($item.Name)"
    }
    if (-not $item.PSIsContainer -and $item.Extension -ieq '.zip') {
        $zipBytes += $item.Length
        $zipCount++
    }
}
if ($zipBytes -gt $MaximumDistributionBytes) {
    throw "DISTRIBUTION_SIZE: ZIP合計 $zipBytes bytes が上限 $MaximumDistributionBytes bytes を超えています。"
}

foreach ($entry in $versions) {
    $version = [string]$entry.Name
    $manifest = $entry.Value
    if ([string]$manifest.name -cne $PackageId -or [string]$manifest.version -cne $version) {
        throw "INDEX_IDENTITY: index のパッケージ名またはバージョンが一致しません: $version"
    }
    $expectedUrl = "$RepositoryBaseUrl/packages/$PackageId-$version.zip"
    if ([string]$manifest.url -cne $expectedUrl -or
        [string]$manifest.repo -cne "$RepositoryBaseUrl/index.json") {
        throw "INDEX_URL: index の公開URLが一致しません: $version"
    }
    $zipPath = Get-RepositoryPath "packages/$PackageId-$version.zip"
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$manifest.zipSHA256 -cne $zipHash) {
        throw "ZIP_HASH: index とZIPのSHA256が一致しません: $version"
    }
    $zipManifest = Read-PackageManifest $zipPath
    Assert-PackageManifestMatchesIndex $zipManifest $manifest $version $latestVersion
}

$envelope = Read-RepositoryText 'update-manifest.json' | ConvertFrom-Json
if ([string]$envelope.format -cne 'AvatarRecovery update manifest envelope v1') {
    throw 'UPDATE_FORMAT: 更新マニフェストの形式が一致しません。'
}
$payloadBytes = [Convert]::FromBase64String([string]$envelope.payloadBase64)
if ($payloadBytes.Length -gt $MaximumManifestBytes) { throw 'UPDATE_SIZE: 更新マニフェストがサイズ上限を超えています。' }
$payload = [Text.UTF8Encoding]::new($false, $true).GetString($payloadBytes) | ConvertFrom-Json
if ([string]$payload.format -cne 'AvatarRecovery update notification payload v1' -or
    [string]$payload.packageId -cne $PackageId) {
    throw 'UPDATE_FORMAT: 更新通知のパッケージ名または形式が一致しません。'
}
if ([string]$payload.latestStableVersion -cne $latestVersion) {
    throw "UPDATE_VERSION: 更新マニフェストが最新安定版 $latestVersion と一致しません。"
}
$indexHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string]$payload.sourceIndexSha256 -cne $indexHash) {
    throw 'UPDATE_INDEX_HASH: 更新マニフェストとindexのSHA256が一致しません。'
}
$latestManifest = $packageProperty.Value.versions.PSObject.Properties[$latestVersion].Value
if ([string]$payload.packageSha256 -cne [string]$latestManifest.zipSHA256) {
    throw 'UPDATE_PACKAGE_HASH: 更新マニフェストと最新ZIPのSHA256が一致しません。'
}

[PSCustomObject]@{
    LatestStableVersion = $latestVersion
    IndexedVersions = @($versions.Name)
    DistributionZipCount = $zipCount
    DistributionZipBytes = $zipBytes
    MaximumDistributionBytes = $MaximumDistributionBytes
    Result = 'Passed'
}
