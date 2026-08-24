param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePackageRoot,
    [Parameter(Mandatory = $true)]
    [string]$AssetRipperZip
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ExpectedZipSha256 = "FF0517CB3BBB0ECDE46880726B567EC77623C591E88FCE646891AA94DF57A68C"
$ExpectedExecutableSha256 = "FC67650BE0BDE0EC75FFB647132E4C3E7AC8B347C8D9FE1CF5109F022F8A5581"
$ExpectedProductVersion = "1.3.14+cd07b6abbe8602f418630ff0e1b87f3527ff8d56"
$ExpectedLicenseSha256 = "8B1BA204BB69A0ADE2BFCF65EF294A920F6BB361B317DBA43C7EF29D96332B9B"
$AssetRipperCommit = "cd07b6abbe8602f418630ff0e1b87f3527ff8d56"
$LicenseUrl = "https://raw.githubusercontent.com/AssetRipper/AssetRipper/$AssetRipperCommit/LICENSE.md"
$SourceUrl = "https://github.com/AssetRipper/AssetRipper/tree/$AssetRipperCommit"
$SourceArchiveUrl = "https://github.com/AssetRipper/AssetRipper/archive/$AssetRipperCommit.zip"
$RequiredFiles = @(
    "AssetRipper.exe",
    "capstone.dll",
    "crunch.dll",
    "crunchunity.dll",
    "Texture2DDecoderNative.dll"
)

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
}

function Assert-UnderDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ParentPath
    )

    $fullPath = Get-NormalizedFullPath $Path
    $fullParent = Get-NormalizedFullPath $ParentPath
    $prefix = $fullParent + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the allowed directory: $fullPath / $fullParent"
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

$sourcePackageFullPath = Get-NormalizedFullPath $SourcePackageRoot
$assetRipperZipFullPath = Get-NormalizedFullPath $AssetRipperZip
if (-not (Test-Path -LiteralPath $sourcePackageFullPath -PathType Container)) {
    throw "Source package directory was not found: $sourcePackageFullPath"
}
if (-not (Test-Path -LiteralPath $assetRipperZipFullPath -PathType Leaf)) {
    throw "AssetRipper ZIP was not found: $assetRipperZipFullPath"
}

$zipSha256 = Get-Sha256 $assetRipperZipFullPath
if ($zipSha256 -cne $ExpectedZipSha256) {
    throw "AssetRipper ZIP hash mismatch. Expected $ExpectedZipSha256, found $zipSha256"
}

$toolsRoot = Join-Path $sourcePackageFullPath "Tools~"
$targetRoot = Join-Path $toolsRoot "AssetRipper"
$stagingRoot = Join-Path $toolsRoot ".AssetRipper-stage"
$verificationRoot = Join-Path $toolsRoot ".AssetRipper-verify"
Assert-UnderDirectory -Path $targetRoot -ParentPath $sourcePackageFullPath
Assert-UnderDirectory -Path $stagingRoot -ParentPath $sourcePackageFullPath
Assert-UnderDirectory -Path $verificationRoot -ParentPath $sourcePackageFullPath
if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
if (Test-Path -LiteralPath $verificationRoot) {
    Remove-Item -LiteralPath $verificationRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
New-Item -ItemType Directory -Force -Path $verificationRoot | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($assetRipperZipFullPath)
$archiveEntryNames = New-Object 'System.Collections.Generic.HashSet[string]' `
    ([System.StringComparer]::OrdinalIgnoreCase)
try {
    foreach ($entry in $archive.Entries) {
        $relativePath = $entry.FullName.Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }
        if ($relativePath.StartsWith("/", [System.StringComparison]::Ordinal) -or
            $relativePath -match '(^|/)\.\.(/|$)' -or
            [System.IO.Path]::IsPathRooted($relativePath)) {
            throw "AssetRipper ZIP contains an invalid entry path: $relativePath"
        }

        $normalizedEntryName = $relativePath.TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($normalizedEntryName)) {
            continue
        }
        [void]$archiveEntryNames.Add($normalizedEntryName)

        if ($normalizedEntryName.Equals(
                "AssetRipper.exe",
                [System.StringComparison]::OrdinalIgnoreCase)) {
            $destinationPath = Join-Path $verificationRoot "AssetRipper.exe"
            $sourceStream = $entry.Open()
            $destinationStream = [System.IO.File]::Open(
                $destinationPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
            try {
                $sourceStream.CopyTo($destinationStream)
            }
            finally {
                $destinationStream.Dispose()
                $sourceStream.Dispose()
            }
        }
    }
}
finally {
    $archive.Dispose()
}

foreach ($requiredFile in $RequiredFiles) {
    if (-not $archiveEntryNames.Contains($requiredFile)) {
        throw "Required AssetRipper file was not found in the ZIP: $requiredFile"
    }
}

$executablePath = Join-Path $verificationRoot "AssetRipper.exe"
$executableSha256 = Get-Sha256 $executablePath
if ($executableSha256 -cne $ExpectedExecutableSha256) {
    throw "AssetRipper.exe hash mismatch. Expected $ExpectedExecutableSha256, found $executableSha256"
}
$productVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo(
    $executablePath).ProductVersion
if ($productVersion -cne $ExpectedProductVersion) {
    throw "AssetRipper.exe version mismatch. Expected $ExpectedProductVersion, found $productVersion"
}

Copy-Item -LiteralPath $assetRipperZipFullPath `
    -Destination (Join-Path $stagingRoot "AssetRipper.zip") `
    -Force

$licensePath = Join-Path $stagingRoot "AssetRipper.GPL-3.0.txt"
Invoke-WebRequest -UseBasicParsing -Uri $LicenseUrl -OutFile $licensePath
$licenseSha256 = Get-Sha256 $licensePath
if ($licenseSha256 -cne $ExpectedLicenseSha256) {
    throw "AssetRipper license hash mismatch. Expected $ExpectedLicenseSha256, found $licenseSha256"
}

$sourceNotice = @"
# AssetRipper source and license

- Bundled version: AssetRipper 1.3.14
- Product version: $ExpectedProductVersion
- Corresponding source: $SourceUrl
- Corresponding source archive: $SourceArchiveUrl
- License: GNU General Public License v3.0 (`AssetRipper.GPL-3.0.txt`)

AvatarRecovery includes only AssetRipper.exe and the related files required for
it to run. These AssetRipper-related files remain governed by their included
third-party licenses and are not subject to the AvatarRecovery Custom License.
"@
Write-Utf8NoBom -Path (Join-Path $stagingRoot "SOURCE.md") -Value ($sourceNotice + "`n")

Remove-Item -LiteralPath $verificationRoot -Recurse -Force

if (Test-Path -LiteralPath $targetRoot) {
    Remove-Item -LiteralPath $targetRoot -Recurse -Force
}
Move-Item -LiteralPath $stagingRoot -Destination $targetRoot

Write-Host "Staged bundled AssetRipper $ExpectedProductVersion"
Write-Host "AssetRipper ZIP SHA-256: $zipSha256"
Write-Host "AssetRipper.exe SHA-256: $executableSha256"
