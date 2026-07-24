param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$PackageId = "com.nickel-jp.avatar-recovery",
    [string]$OutputRoot = $PSScriptRoot,
    [string]$BaseUrl = "",
    [string]$MinimumPublishedVersion = "1.1.5",
    [string]$MaximumPublishedVersion = "",
    [ValidateRange(1, 3)]
    [int]$MaximumPublishedVersionCount = 3,
    [switch]$IndexOnly
)

$ErrorActionPreference = "Stop"

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

        $packageFileName = "$PackageId-$version.zip"
        $zipPath = Join-Path $packagesDir $packageFileName
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
            "avatar-recovery-vpm-" + [System.Guid]::NewGuid().ToString("N"))
        $stagingRoot = Join-Path $tempRoot "package"
        New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
        Copy-Item -Path (Join-Path $packageRoot "*") -Destination $stagingRoot -Recurse -Force

        $packageUrl = if ([string]::IsNullOrWhiteSpace($normalizedBaseUrl)) {
            ConvertTo-FileUri $zipPath
        }
        else {
            "$normalizedBaseUrl/packages/$packageFileName"
        }

        $stagedManifestPath = Join-Path $stagingRoot "package.json"
        $stagedManifest = Get-Content -LiteralPath $stagedManifestPath -Raw | ConvertFrom-Json
        Set-JsonProperty -Object $stagedManifest -Name "url" -Value $packageUrl
        Set-JsonProperty -Object $stagedManifest -Name "repo" -Value $repoUrl
        Write-Utf8NoBom -Path $stagedManifestPath -Value (
            $stagedManifest | ConvertTo-Json -Depth 50)

        Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath $zipPath -Force
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
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
