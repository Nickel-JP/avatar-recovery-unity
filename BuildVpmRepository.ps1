param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$PackageId = "com.nickel-jp.avatar-recovery",
    [string]$OutputRoot = $PSScriptRoot,
    [string]$BaseUrl = "",
    [string]$InventoryContractPath = "",
    [string]$MinimumPublishedVersion = "1.1.5",
    [string]$MaximumPublishedVersion = "",
    [ValidateRange(1, 3)]
    [int]$MaximumPublishedVersionCount = 3,
    [ValidateRange(1, 20000)]
    [int]$MaximumPackageFileCount = 10000,
    [long]$MaximumPackageBytes = 536870912L,
    [long]$MaximumPackageFileBytes = 67108864L,
    [switch]$WriteInventoryContract,
    [switch]$IndexOnly
)

$ErrorActionPreference = "Stop"

$PrivateSdkBundledMinimumVersion = [version]"1.3.0"
$PrivateSdkVersion = "3.10.2"
$PrivateResolverVersion = "0.1.29"
$InventoryContractFormat = "AvatarRecovery private SDK-bundled inventory v1"
$FixedZipTimestamp = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

if ($IndexOnly -and [string]::IsNullOrWhiteSpace($MaximumPublishedVersion)) {
    throw "MaximumPublishedVersion is required in IndexOnly mode."
}

function ConvertTo-FileUri {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return ([System.Uri]::new($fullPath)).AbsoluteUri
}

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Value
    )

    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $Object.$Name = $Value
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $normalizedValue = $Value -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $normalizedValue, $utf8NoBom)
}

function ConvertTo-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-PathUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RootPath
    )

    $fullPath = ConvertTo-FullPath -Path $Path
    $fullRoot = (ConvertTo-FullPath -Path $RootPath).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escaped its trusted root: $fullPath"
    }
}

function Assert-SafePackageRelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.Contains('\') -or
        $RelativePath.StartsWith('/', [StringComparison]::Ordinal) -or
        $RelativePath.EndsWith('/', [StringComparison]::Ordinal) -or
        $RelativePath.Contains(':') -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.IndexOfAny([char[]]"`0`r`n`t") -ge 0) {
        throw "Unsafe package-relative path: $RelativePath"
    }

    foreach ($segment in $RelativePath.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or
            $segment -eq '.' -or
            $segment -eq '..') {
            throw "Unsafe package-relative path segment: $RelativePath"
        }
    }
}

function Get-RelativePackagePath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullRoot = (ConvertTo-FullPath -Path $RootPath).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $fullPath = ConvertTo-FullPath -Path $Path
    if (-not $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package file escaped its root: $fullPath"
    }

    $relativePath = $fullPath.Substring($fullRoot.Length).Replace('\', '/')
    Assert-SafePackageRelativePath -RelativePath $relativePath
    return $relativePath
}

function Get-StreamSha256Hex {
    param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha256.ComputeHash($Stream))).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-BytesSha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha256.ComputeHash($Bytes))).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-PackageFileForSecrets {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][long]$Length
    )

    if ([System.IO.Path]::GetExtension($RelativePath) -match '(?i)^\.(pfx|p12|pvk|key|snk|pem|env)$') {
        throw "Package contains a forbidden credential-bearing file type: $RelativePath"
    }

    if ($Length -gt 4194304L) {
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
    if ($ascii -match '-----BEGIN [A-Z ]*PRIVATE KEY-----' -or
        $unicode -match '-----BEGIN [A-Z ]*PRIVATE KEY-----') {
        throw "Package contains private-key material: $RelativePath"
    }
}

function Get-PackageInventory {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $fullRoot = ConvertTo-FullPath -Path $RootPath
    if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) {
        throw "Package inventory root was not found: $fullRoot"
    }

    $rootItem = Get-Item -LiteralPath $fullRoot -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Package inventory root must not be a reparse point: $fullRoot"
    }

    $pathMap = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new(
        [StringComparer]::Ordinal)
    $paths = [System.Collections.Generic.List[string]]::new()
    $caseInsensitivePaths = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)

    foreach ($item in Get-ChildItem -LiteralPath $fullRoot -Recurse -Force) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Package tree contains a reparse point: $($item.FullName)"
        }
        if ($item.PSIsContainer) {
            continue
        }

        $relativePath = Get-RelativePackagePath -RootPath $fullRoot -Path $item.FullName
        if (-not $caseInsensitivePaths.Add($relativePath)) {
            throw "Package tree contains a duplicate or case-colliding path: $relativePath"
        }
        $pathMap.Add($relativePath, [System.IO.FileInfo]$item)
        $paths.Add($relativePath)
    }

    if ($paths.Count -eq 0) {
        throw "Package inventory is empty: $fullRoot"
    }
    if ($paths.Count -gt $MaximumPackageFileCount) {
        throw "Package file count exceeds the limit: $($paths.Count) > $MaximumPackageFileCount"
    }

    $paths.Sort([StringComparer]::Ordinal)
    $records = [System.Collections.Generic.List[object]]::new()
    $digestText = [System.Text.StringBuilder]::new()
    [long]$totalBytes = 0
    foreach ($relativePath in $paths) {
        $file = $pathMap[$relativePath]
        $stream = [System.IO.File]::Open(
            $file.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read)
        try {
            [long]$length = $stream.Length
            if ($length -gt $MaximumPackageFileBytes) {
                throw "Package file exceeds the per-file limit: $relativePath ($length bytes)"
            }
            $sha256 = Get-StreamSha256Hex -Stream $stream
        }
        finally {
            $stream.Dispose()
        }

        Test-PackageFileForSecrets -Path $file.FullName -RelativePath $relativePath -Length $length
        $totalBytes += $length
        if ($totalBytes -gt $MaximumPackageBytes) {
            throw "Package total bytes exceed the limit: $totalBytes > $MaximumPackageBytes"
        }

        [void]$digestText.Append($relativePath)
        [void]$digestText.Append([char]0)
        [void]$digestText.Append($length.ToString([Globalization.CultureInfo]::InvariantCulture))
        [void]$digestText.Append([char]0)
        [void]$digestText.Append($sha256)
        [void]$digestText.Append("`n")
        $records.Add([PSCustomObject]@{
                RelativePath = $relativePath
                SourcePath = $file.FullName
                Length = $length
                Sha256 = $sha256
            })
    }

    $digestBytes = [System.Text.Encoding]::UTF8.GetBytes($digestText.ToString())
    return [PSCustomObject]@{
        RootPath = $fullRoot
        FileCount = $records.Count
        TotalBytes = $totalBytes
        InventorySha256 = Get-BytesSha256Hex -Bytes $digestBytes
        Files = @($records.ToArray())
    }
}

function Assert-InventoryMatchesContractRecord {
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)]$ContractRecord,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    if ([int]$ContractRecord.fileCount -ne [int]$Inventory.FileCount -or
        [long]$ContractRecord.totalBytes -ne [long]$Inventory.TotalBytes -or
        -not [string]::Equals(
            [string]$ContractRecord.inventorySha256,
            [string]$Inventory.InventorySha256,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$DisplayName inventory does not match the reviewed release contract."
    }
}

function Get-RequiredSdkPackageManifest {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ExpectedName,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $manifestPath = Join-Path $PackageRoot ($RelativePath.Replace('/', '\'))
    Assert-PathUnderRoot -Path $manifestPath -RootPath $PackageRoot
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Bundled SDK manifest was not found: $RelativePath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::Equals([string]$manifest.name, $ExpectedName, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$manifest.version, $ExpectedVersion, [StringComparison]::Ordinal)) {
        throw "Bundled SDK manifest identity mismatch: $RelativePath"
    }
    return $manifest
}

function Assert-BundledSdkLayout {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $avatarPrefix = "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Packages"
    $worldPrefix = "Editor/HotSwap/HotSwap_wrld/WorkerTemplate~/Packages"
    foreach ($required in @(
            @($avatarPrefix, "com.vrchat.base", $PrivateSdkVersion),
            @($avatarPrefix, "com.vrchat.avatars", $PrivateSdkVersion),
            @($avatarPrefix, "com.vrchat.core.vpm-resolver", $PrivateResolverVersion),
            @($worldPrefix, "com.vrchat.base", $PrivateSdkVersion),
            @($worldPrefix, "com.vrchat.worlds", $PrivateSdkVersion),
            @($worldPrefix, "com.vrchat.core.vpm-resolver", $PrivateResolverVersion))) {
        $packageName = [string]$required[1]
        [void](Get-RequiredSdkPackageManifest `
                -PackageRoot $PackageRoot `
                -RelativePath "$($required[0])/$packageName/package.json" `
                -ExpectedName $packageName `
                -ExpectedVersion ([string]$required[2]))
    }
}

function Get-TemplateInventory {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$RelativeRoot
    )

    $templateRoot = Join-Path $PackageRoot ($RelativeRoot.Replace('/', '\'))
    Assert-PathUnderRoot -Path $templateRoot -RootPath $PackageRoot
    return Get-PackageInventory -RootPath $templateRoot
}

function Write-InventoryContractFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ManifestPackageId,
        [Parameter(Mandatory = $true)][string]$ManifestVersion,
        [Parameter(Mandatory = $true)]$PackageInventory,
        [Parameter(Mandatory = $true)]$AvatarTemplateInventory,
        [Parameter(Mandatory = $true)]$WorldTemplateInventory
    )

    $contract = [ordered]@{
        format = $InventoryContractFormat
        packageId = $ManifestPackageId
        version = $ManifestVersion
        fileCount = $PackageInventory.FileCount
        totalBytes = $PackageInventory.TotalBytes
        inventorySha256 = $PackageInventory.InventorySha256
        avatarWorkerTemplate = [ordered]@{
            fileCount = $AvatarTemplateInventory.FileCount
            totalBytes = $AvatarTemplateInventory.TotalBytes
            inventorySha256 = $AvatarTemplateInventory.InventorySha256
        }
        worldWorkerTemplate = [ordered]@{
            fileCount = $WorldTemplateInventory.FileCount
            totalBytes = $WorldTemplateInventory.TotalBytes
            inventorySha256 = $WorldTemplateInventory.InventorySha256
        }
    }
    Write-Utf8NoBom -Path $Path -Value (($contract | ConvertTo-Json -Depth 10) + "`n")
}

function Assert-InventoryContract {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ManifestPackageId,
        [Parameter(Mandatory = $true)][string]$ManifestVersion,
        [Parameter(Mandatory = $true)]$PackageInventory,
        [Parameter(Mandatory = $true)]$AvatarTemplateInventory,
        [Parameter(Mandatory = $true)]$WorldTemplateInventory
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Private SDK-bundled inventory contract was not found: $Path"
    }
    $contract = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::Equals([string]$contract.format, $InventoryContractFormat, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$contract.packageId, $ManifestPackageId, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$contract.version, $ManifestVersion, [StringComparison]::Ordinal)) {
        throw "Private SDK-bundled inventory contract identity mismatch: $Path"
    }

    Assert-InventoryMatchesContractRecord -Inventory $PackageInventory -ContractRecord $contract -DisplayName "Package"
    Assert-InventoryMatchesContractRecord `
        -Inventory $AvatarTemplateInventory `
        -ContractRecord $contract.avatarWorkerTemplate `
        -DisplayName "Avatar WorkerTemplate"
    Assert-InventoryMatchesContractRecord `
        -Inventory $WorldTemplateInventory `
        -ContractRecord $contract.worldWorkerTemplate `
        -DisplayName "World WorkerTemplate"
}

function Copy-PackageInventoryToStaging {
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)][string]$StagingRoot
    )

    foreach ($record in $Inventory.Files) {
        $destinationPath = Join-Path $StagingRoot ($record.RelativePath.Replace('/', '\'))
        Assert-PathUnderRoot -Path $destinationPath -RootPath $StagingRoot
        $destinationDirectory = Split-Path -Parent $destinationPath
        [System.IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
        [System.IO.File]::Copy($record.SourcePath, $destinationPath, $false)
    }
}

function New-DeterministicPackageZip {
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)][string]$ZipPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fileStream = [System.IO.File]::Open(
        $ZipPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $fileStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $true)
        try {
            foreach ($record in $Inventory.Files) {
                $entry = $archive.CreateEntry(
                    $record.RelativePath,
                    [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $FixedZipTimestamp
                $source = [System.IO.File]::Open(
                    $record.SourcePath,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::Read)
                try {
                    $destination = $entry.Open()
                    try {
                        $source.CopyTo($destination, 1048576)
                    }
                    finally {
                        $destination.Dispose()
                    }
                }
                finally {
                    $source.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }
}

function Assert-ZipMatchesInventory {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)]$Inventory
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expected = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($record in $Inventory.Files) {
        $expected.Add([string]$record.RelativePath, $record)
    }
    $seenIgnoreCase = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($archive.Entries.Count -ne $Inventory.FileCount) {
            throw "Package ZIP entry count does not match the reviewed inventory."
        }
        [long]$totalBytes = 0
        foreach ($entry in $archive.Entries) {
            $entryPath = ([string]$entry.FullName).Replace('\', '/')
            Assert-SafePackageRelativePath -RelativePath $entryPath
            if (-not $seenIgnoreCase.Add($entryPath)) {
                throw "Package ZIP contains a duplicate or case-colliding entry: $entryPath"
            }
            if (-not $expected.ContainsKey($entryPath)) {
                throw "Package ZIP contains an entry outside the reviewed inventory: $entryPath"
            }
            $record = $expected[$entryPath]
            if ([long]$entry.Length -ne [long]$record.Length) {
                throw "Package ZIP entry length mismatch: $entryPath"
            }
            $totalBytes += [long]$entry.Length
            if ($totalBytes -gt $MaximumPackageBytes) {
                throw "Package ZIP expands beyond the total-byte limit."
            }

            $stream = $entry.Open()
            try {
                $entryHash = Get-StreamSha256Hex -Stream $stream
            }
            finally {
                $stream.Dispose()
            }
            if (-not [string]::Equals($entryHash, [string]$record.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Package ZIP entry hash mismatch: $entryPath"
            }
        }
        if ($totalBytes -ne [long]$Inventory.TotalBytes) {
            throw "Package ZIP expanded size does not match the reviewed inventory."
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-PackageManifestFromZip {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.Entries |
            Where-Object { $_.FullName -eq "package.json" } |
            Select-Object -First 1

        if ($null -eq $entry) {
            throw "package.json was not found in package zip: $ZipPath"
        }

        $stream = $entry.Open()
        try {
            $reader = [System.IO.StreamReader]::new($stream)
            try {
                return ($reader.ReadToEnd() | ConvertFrom-Json)
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-VersionSortKey {
    param([string]$Version)

    try {
        return [version]$Version
    }
    catch {
        return [version]"0.0.0"
    }
}

function Test-VersionIsPublished {
    param([string]$Version)

    try {
        $candidateVersion = [version]$Version
        if (-not [string]::IsNullOrWhiteSpace($MinimumPublishedVersion) -and
            $candidateVersion -lt ([version]$MinimumPublishedVersion)) {
            return $false
        }

        if (-not [string]::IsNullOrWhiteSpace($MaximumPublishedVersion) -and
            $candidateVersion -gt ([version]$MaximumPublishedVersion)) {
            return $false
        }

        return $true
    }
    catch {
        Write-Warning "Skipping package zip with invalid version: $Version"
        return $false
    }
}

$packagesDir = Join-Path $OutputRoot "packages"
New-Item -ItemType Directory -Force -Path $packagesDir | Out-Null

$indexPath = Join-Path $OutputRoot "index.json"
$normalizedBaseUrl = if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    ""
}
else {
    $BaseUrl.TrimEnd("/")
}
$repoUrl = if ([string]::IsNullOrWhiteSpace($normalizedBaseUrl)) {
    ConvertTo-FileUri $indexPath
}
else {
    "$normalizedBaseUrl/index.json"
}

$version = ""
$zipPath = ""
$packageUrl = ""
$zipSha256 = ""
$tempRoot = ""

try {
    if (-not $IndexOnly) {
        $packageRoot = Join-Path $ProjectRoot "Packages\$PackageId"
        $packageJsonPath = Join-Path $packageRoot "package.json"
        if (-not (Test-Path -LiteralPath $packageJsonPath)) {
            throw "Package manifest was not found: $packageJsonPath"
        }

        $manifest = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
        $version = [string]$manifest.version
        if ([string]::IsNullOrWhiteSpace($version)) {
            throw "Package version is empty in $packageJsonPath"
        }

        try {
            $parsedVersion = [version]$version
        }
        catch {
            throw "Package version is invalid in ${packageJsonPath}: $version"
        }

        $sourceInventory = Get-PackageInventory -RootPath $packageRoot
        if ($parsedVersion -ge $PrivateSdkBundledMinimumVersion) {
            Assert-BundledSdkLayout -PackageRoot $packageRoot
            $avatarTemplateInventory = Get-TemplateInventory `
                -PackageRoot $packageRoot `
                -RelativeRoot "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~"
            $worldTemplateInventory = Get-TemplateInventory `
                -PackageRoot $packageRoot `
                -RelativeRoot "Editor/HotSwap/HotSwap_wrld/WorkerTemplate~"
            if ([string]::IsNullOrWhiteSpace($InventoryContractPath)) {
                $InventoryContractPath = Join-Path `
                    $PSScriptRoot `
                    "Build\PrivateSdkBundledInventory-$version.json"
            }
            $InventoryContractPath = ConvertTo-FullPath -Path $InventoryContractPath

            if ($WriteInventoryContract) {
                $contractDirectory = Split-Path -Parent $InventoryContractPath
                [System.IO.Directory]::CreateDirectory($contractDirectory) | Out-Null
                Write-InventoryContractFile `
                    -Path $InventoryContractPath `
                    -ManifestPackageId ([string]$manifest.name) `
                    -ManifestVersion $version `
                    -PackageInventory $sourceInventory `
                    -AvatarTemplateInventory $avatarTemplateInventory `
                    -WorldTemplateInventory $worldTemplateInventory
                Write-Host "Created reviewed inventory candidate: $InventoryContractPath"
                return
            }

            Assert-InventoryContract `
                -Path $InventoryContractPath `
                -ManifestPackageId ([string]$manifest.name) `
                -ManifestVersion $version `
                -PackageInventory $sourceInventory `
                -AvatarTemplateInventory $avatarTemplateInventory `
                -WorldTemplateInventory $worldTemplateInventory
        }
        elseif ($WriteInventoryContract) {
            throw "Inventory contracts are required only for SDK-bundled package versions."
        }

        $packageFileName = "$PackageId-$version.zip"
        $zipPath = Join-Path $packagesDir $packageFileName

        $tempParent = Join-Path $OutputRoot ".work"
        [System.IO.Directory]::CreateDirectory($tempParent) | Out-Null
        $tempRoot = Join-Path $tempParent (
            "avatar-recovery-vpm-" + [System.Guid]::NewGuid().ToString("N"))
        Assert-PathUnderRoot -Path $tempRoot -RootPath $tempParent
        $stagingRoot = Join-Path $tempRoot "package"
        [System.IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
        Copy-PackageInventoryToStaging -Inventory $sourceInventory -StagingRoot $stagingRoot

        $packageUrl = if ([string]::IsNullOrWhiteSpace($normalizedBaseUrl)) {
            ConvertTo-FileUri $zipPath
        }
        else {
            "$normalizedBaseUrl/packages/$packageFileName"
        }

        $stagedManifestPath = Join-Path $stagingRoot "package.json"
        $stagedManifest = Get-Content -LiteralPath $stagedManifestPath -Raw | ConvertFrom-Json
        if (-not [string]::Equals([string]$stagedManifest.url, $packageUrl, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$stagedManifest.repo, $repoUrl, [StringComparison]::Ordinal)) {
            throw (
                "Package manifest URL/repo must already match the selected private repository boundary. " +
                "Expected url=$packageUrl repo=$repoUrl")
        }

        $stagingInventory = Get-PackageInventory -RootPath $stagingRoot
        Assert-InventoryMatchesContractRecord `
            -Inventory $stagingInventory `
            -ContractRecord $sourceInventory `
            -DisplayName "Staged package"
        $sourceInventoryAfterCopy = Get-PackageInventory -RootPath $packageRoot
        Assert-InventoryMatchesContractRecord `
            -Inventory $sourceInventoryAfterCopy `
            -ContractRecord $sourceInventory `
            -DisplayName "Source package after copy"

        $temporaryZipPath = Join-Path $tempRoot $packageFileName
        New-DeterministicPackageZip -Inventory $stagingInventory -ZipPath $temporaryZipPath
        Assert-ZipMatchesInventory -ZipPath $temporaryZipPath -Inventory $stagingInventory
        if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
            $rollbackPath = Join-Path $tempRoot "$packageFileName.rollback"
            [System.IO.File]::Replace($temporaryZipPath, $zipPath, $rollbackPath, $true)
            try {
                Assert-ZipMatchesInventory -ZipPath $zipPath -Inventory $stagingInventory
                [System.IO.File]::Delete($rollbackPath)
            }
            catch {
                if (Test-Path -LiteralPath $rollbackPath -PathType Leaf) {
                    [System.IO.File]::Replace($rollbackPath, $zipPath, $null, $true)
                }
                throw
            }
        }
        else {
            [System.IO.File]::Move($temporaryZipPath, $zipPath)
        }
        Assert-ZipMatchesInventory -ZipPath $zipPath -Inventory $stagingInventory
        $zipSha256 = (
            Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    $versionEntries = @()
    $packageZipPattern = "$PackageId-*.zip"
    foreach ($packageZip in Get-ChildItem -LiteralPath $packagesDir -Filter $packageZipPattern -File) {
        $candidateManifest = Get-PackageManifestFromZip -ZipPath $packageZip.FullName
        if ($candidateManifest.name -ne $PackageId) {
            Write-Warning "Skipping package zip with unexpected package id: $($packageZip.FullName)"
            continue
        }

        $candidateVersion = $candidateManifest.version
        if ([string]::IsNullOrWhiteSpace($candidateVersion)) {
            Write-Warning "Skipping package zip with empty version: $($packageZip.FullName)"
            continue
        }

        if (-not (Test-VersionIsPublished -Version $candidateVersion)) {
            Write-Host (
                "Skipping package outside published version range " +
                "$MinimumPublishedVersion .. $MaximumPublishedVersion`: $candidateVersion")
            continue
        }

        $candidatePackageFileName = Split-Path -Leaf $packageZip.FullName
        $expectedPackageFileName = "$PackageId-$candidateVersion.zip"
        if ($candidatePackageFileName -cne $expectedPackageFileName) {
            throw (
                "Package zip filename does not match its manifest version. " +
                "Expected $expectedPackageFileName, found $candidatePackageFileName.")
        }
        if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
            $candidatePackageUrl = ConvertTo-FileUri $packageZip.FullName
        }
        else {
            $candidatePackageUrl = "$normalizedBaseUrl/packages/$candidatePackageFileName"
        }

        $candidateSha256 = (Get-FileHash -LiteralPath $packageZip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

        Set-JsonProperty -Object $candidateManifest -Name "url" -Value $candidatePackageUrl
        Set-JsonProperty -Object $candidateManifest -Name "repo" -Value $repoUrl
        Set-JsonProperty -Object $candidateManifest -Name "zipSHA256" -Value $candidateSha256

        $versionEntries += [PSCustomObject]@{
            Version = $candidateVersion
            Manifest = $candidateManifest
        }
    }

    if ($versionEntries.Count -eq 0) {
        throw "No valid package versions were found in: $packagesDir"
    }

    $duplicateVersions = @(
        $versionEntries |
            Group-Object -Property Version |
            Where-Object { $_.Count -gt 1 }
    )
    if ($duplicateVersions.Count -gt 0) {
        throw (
            "Duplicate package versions were found: " +
            (($duplicateVersions | ForEach-Object { $_.Name }) -join ", "))
    }

    $selectedVersionEntries = @(
        $versionEntries |
            Sort-Object `
                @{ Expression = { Get-VersionSortKey $_.Version }; Descending = $true },
                @{ Expression = { $_.Version }; Descending = $true } |
            Select-Object -First $MaximumPublishedVersionCount
    )

    $versions = [ordered]@{}
    foreach ($entry in $selectedVersionEntries) {
        $versions[$entry.Version] = $entry.Manifest
    }

    $packages = [ordered]@{}
    $packages[$PackageId] = [ordered]@{
        versions = $versions
    }

    $repo = [ordered]@{
        name = "Avatar Recovery Unity"
        id = "com.nickel-jp.repos.avatar-recovery"
        url = $repoUrl
        author = "Nickel-JP"
        packages = $packages
    }

    Write-Utf8NoBom -Path $indexPath -Value ($repo | ConvertTo-Json -Depth 80)

    Write-Host "Created VPM repository: $indexPath"
    Write-Host "Published versions: $($selectedVersionEntries.Version -join ', ')"
    if (-not $IndexOnly) {
        Write-Host "Created VPM package: $zipPath"
        Write-Host "Package URL: $packageUrl"
        Write-Host "SHA256: $zipSha256"
    }
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($tempRoot) -and
        (Test-Path -LiteralPath $tempRoot)) {
        $tempParent = Join-Path $OutputRoot ".work"
        Assert-PathUnderRoot -Path $tempRoot -RootPath $tempParent
        [System.IO.Directory]::Delete((ConvertTo-FullPath -Path $tempRoot), $true)
    }
}
