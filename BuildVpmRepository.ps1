param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$PackageId = "com.nickel-jp.avatar-recovery",
    [string]$OutputRoot = $PSScriptRoot,
    [string]$BaseUrl = "",
    [string]$MinimumPublishedVersion = "1.1.5"
)

$ErrorActionPreference = "Stop"

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

    if ([string]::IsNullOrWhiteSpace($MinimumPublishedVersion)) {
        return $true
    }

    try {
        return ([version]$Version) -ge ([version]$MinimumPublishedVersion)
    }
    catch {
        Write-Warning "Skipping package zip with invalid version: $Version"
        return $false
    }
}

$packageRoot = Join-Path $ProjectRoot "Packages\$PackageId"
$packageJsonPath = Join-Path $packageRoot "package.json"

if (-not (Test-Path $packageJsonPath)) {
    throw "Package manifest was not found: $packageJsonPath"
}

$manifest = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
$version = $manifest.version

if ([string]::IsNullOrWhiteSpace($version)) {
    throw "Package version is empty in $packageJsonPath"
}

$packagesDir = Join-Path $OutputRoot "packages"
New-Item -ItemType Directory -Force -Path $packagesDir | Out-Null

$packageFileName = "$PackageId-$version.zip"
$zipPath = Join-Path $packagesDir $packageFileName
$indexPath = Join-Path $OutputRoot "index.json"

if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("avatar-recovery-vpm-" + [System.Guid]::NewGuid().ToString("N"))
$stagingRoot = Join-Path $tempRoot "package"

try {
    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
    Copy-Item -Path (Join-Path $packageRoot "*") -Destination $stagingRoot -Recurse -Force

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        New-Item -ItemType File -Force -Path $zipPath | Out-Null
        $packageUrl = ConvertTo-FileUri $zipPath
        Remove-Item -LiteralPath $zipPath -Force
        $repoUrl = ConvertTo-FileUri $indexPath
    }
    else {
        $normalizedBaseUrl = $BaseUrl.TrimEnd("/")
        $packageUrl = "$normalizedBaseUrl/packages/$packageFileName"
        $repoUrl = "$normalizedBaseUrl/index.json"
    }

    $stagedManifestPath = Join-Path $stagingRoot "package.json"
    $stagedManifest = Get-Content -LiteralPath $stagedManifestPath -Raw | ConvertFrom-Json

    Set-JsonProperty -Object $stagedManifest -Name "url" -Value $packageUrl
    Set-JsonProperty -Object $stagedManifest -Name "repo" -Value $repoUrl

    Write-Utf8NoBom -Path $stagedManifestPath -Value ($stagedManifest | ConvertTo-Json -Depth 50)

    Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath $zipPath -Force
    $zipSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

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
            Write-Host "Skipping package below published minimum version $MinimumPublishedVersion`: $candidateVersion"
            continue
        }

        $candidatePackageFileName = Split-Path -Leaf $packageZip.FullName
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

    $versions = [ordered]@{}
    foreach ($entry in ($versionEntries | Sort-Object @{ Expression = { Get-VersionSortKey $_.Version }; Descending = $true }, @{ Expression = { $_.Version }; Descending = $true })) {
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

    Write-Host "Created VPM package: $zipPath"
    Write-Host "Created VPM repository: $indexPath"
    Write-Host "Package URL: $packageUrl"
    Write-Host "SHA256: $zipSha256"
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
