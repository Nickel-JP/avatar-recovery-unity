param(
    [string]$Version = "1.2.7",
    [string]$PackageId = "com.nickel-jp.avatar-recovery",
    [switch]$SkipPrivateProtectionReports
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$WorkRoot = Join-Path $RepoRoot ".work"
$OutputRoot = Join-Path $WorkRoot "ProtectionSelfTests$($Version.Replace('.', ''))"
$AssemblyFileName = "EditorTools.AvatarRecovery.Editor.dll"
$RuntimeIntegritySidecarFileName = "$AssemblyFileName.runtime.sig"
$BinaryLeakRulesPath = Join-Path $RepoRoot "Build\BinaryLeakAllowlist.txt"
$PublishedCertificatePath = Join-Path $RepoRoot "certificates\avatar-recovery-self-signed-code-signing.cer"
$PublishedCertificatePemPath = Join-Path $RepoRoot "certificates\avatar-recovery-self-signed-code-signing.cer.pem"
$PublicBaseUrl = "https://nickel-jp.github.io/avatar-recovery-unity"
$PublishedVersionLimit = 3

function ConvertTo-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Remove-SafeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $fullPath = ConvertTo-FullPath $Path
    $fullWorkRoot = (ConvertTo-FullPath $WorkRoot).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullWorkRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "安全でない削除対象です: $fullPath"
    }

    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Add-ZipEntryText {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $entry = $Archive.CreateEntry($EntryName)
    $stream = $entry.Open()
    try {
        $writer = [System.IO.StreamWriter]::new($stream)
        try {
            $writer.Write($Text)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function New-TestZip {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][string]$Text
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }

    $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Add-ZipEntryText -Archive $archive -EntryName $EntryName -Text $Text
    }
    finally {
        $archive.Dispose()
    }
}

function Test-PackageZipGuard {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $blocked = @($archive.Entries | Where-Object {
            $_.FullName -match '(?i)\.(cs|pdb|mdb)$' -or
            $_.FullName -match '(?i)\.(pfx|p12|pvk|key|snk|pem|map)$' -or
            $_.FullName -match '(?i)(mapping|rename|report)' -or
            $_.FullName -match '(?i)obfuscar'
        })
        if ($blocked.Count -gt 0) {
            throw "blocked zip entries: $($blocked.FullName -join ', ')"
        }

        foreach ($entry in $archive.Entries) {
            if ($entry.Length -gt 1048576 -or [string]::IsNullOrWhiteSpace($entry.Name)) {
                continue
            }

            $stream = $entry.Open()
            try {
                $reader = [System.IO.StreamReader]::new($stream)
                try {
                    $text = $reader.ReadToEnd()
                    if ($text -match '-----BEGIN [A-Z ]*PRIVATE KEY-----') {
                        throw "private key text in zip: $($entry.FullName)"
                    }
                }
                finally {
                    $reader.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Test-PackageReadmeSecurityDisclosure {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.Entries |
            Where-Object { ($_.FullName -replace '\\', '/') -eq "README.md" } |
            Select-Object -First 1
        if ($null -eq $entry) {
            throw "package README was not found"
        }

        $stream = $entry.Open()
        try {
            $reader = [System.IO.StreamReader]::new($stream)
            try {
                $readme = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }

        if (-not $readme.Contains("## v1.2.1 の主な変更") -or
            -not $readme.Contains("## セキュリティモデルと限界") -or
            -not $readme.Contains("独立して信頼できる経路")) {
            throw "package README does not disclose the v1.2.1 security boundary"
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
        $manifestEntry = $archive.Entries |
            Where-Object { ($_.FullName -replace '\\', '/') -eq "package.json" } |
            Select-Object -First 1
        if ($null -eq $manifestEntry) {
            throw "package.json was not found in package zip: $ZipPath"
        }

        $stream = $manifestEntry.Open()
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

function Test-DetachedSignatureFile {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$SignaturePath,
        [Parameter(Mandatory = $true)][string]$CertificatePath
    )

    foreach ($requiredPath in @($TargetPath, $SignaturePath, $CertificatePath)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "detached signature input was not found: $requiredPath"
        }
    }

    $signature = Get-Content -LiteralPath $SignaturePath -Raw | ConvertFrom-Json
    if ([string]$signature.format -cne "AvatarRecovery detached signature v1" -or
        [string]$signature.algorithm -cne "RSA-SHA256-PKCS1") {
        throw "unsupported detached signature: $SignaturePath"
    }

    $targetHash = (
        Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$signature.targetSha256 -cne $targetHash) {
        throw "detached signature target hash mismatch: $TargetPath"
    }

    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        (ConvertTo-FullPath $CertificatePath))
    try {
        $certificateThumbprint = (
            $certificate.Thumbprint -replace '\s', '').ToUpperInvariant()
        $signatureThumbprint = (
            [string]$signature.signerThumbprint -replace '\s', '').ToUpperInvariant()
        if ($certificateThumbprint -cne $signatureThumbprint) {
            throw "detached signature signer mismatch: $SignaturePath"
        }

        $publicKey = (
            [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::
                GetRSAPublicKey($certificate))
        if ($null -eq $publicKey) {
            throw "detached signature public key was unavailable: $CertificatePath"
        }
        try {
            $targetBytes = [System.IO.File]::ReadAllBytes(
                (ConvertTo-FullPath $TargetPath))
            $signatureBytes = [Convert]::FromBase64String(
                [string]$signature.signatureBase64)
            if (-not $publicKey.VerifyData(
                    $targetBytes,
                    $signatureBytes,
                    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
                throw "detached signature verification failed: $SignaturePath"
            }
        }
        finally {
            $publicKey.Dispose()
        }
    }
    finally {
        $certificate.Dispose()
    }
}

function Test-PublishedVersionArtifacts {
    param([Parameter(Mandatory = $true)][string]$IndexPath)

    $index = Get-Content -LiteralPath $IndexPath -Raw | ConvertFrom-Json
    $packageProperty = $index.packages.PSObject.Properties[$PackageId]
    if ($null -eq $packageProperty) {
        throw "package id was not found in VPM index: $PackageId"
    }

    $certificateHash = (
        Get-FileHash -LiteralPath $PublishedCertificatePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $certificatePemHash = (
        Get-FileHash -LiteralPath $PublishedCertificatePemPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    foreach ($versionProperty in $packageProperty.Value.versions.PSObject.Properties) {
        $publishedVersion = [string]$versionProperty.Name
        $indexManifest = $versionProperty.Value
        $zipPath = Join-Path $RepoRoot "packages\$PackageId-$publishedVersion.zip"
        $zipSignaturePath = "$zipPath.sig"
        $checksumPath = Join-Path $RepoRoot "checksums\$PackageId-$publishedVersion.sha256.txt"
        $checksumSignaturePath = "$checksumPath.sig"

        foreach ($requiredPath in @(
                $zipPath,
                $zipSignaturePath,
                $checksumPath,
                $checksumSignaturePath)) {
            if (-not (Test-Path -LiteralPath $requiredPath)) {
                throw "published artifact was not found: $requiredPath"
            }
        }

        $expectedPackageUrl = "$PublicBaseUrl/packages/$PackageId-$publishedVersion.zip"
        if ([string]$indexManifest.url -cne $expectedPackageUrl -or
            [string]$indexManifest.repo -cne "$PublicBaseUrl/index.json") {
            throw "published package URL or repository URL is invalid: $publishedVersion"
        }

        $actualZipHash = (
            Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ([string]$indexManifest.zipSHA256 -cne $actualZipHash) {
            throw "VPM index package hash mismatch: $publishedVersion"
        }

        Test-DetachedSignatureFile `
            -TargetPath $zipPath `
            -SignaturePath $zipSignaturePath `
            -CertificatePath $PublishedCertificatePath
        Test-DetachedSignatureFile `
            -TargetPath $checksumPath `
            -SignaturePath $checksumSignaturePath `
            -CertificatePath $PublishedCertificatePath

        $checksumText = Get-Content -LiteralPath $checksumPath -Raw
        foreach ($requiredHash in @(
                $actualZipHash,
                $certificateHash,
                $certificatePemHash)) {
            if ($checksumText -notmatch [regex]::Escape($requiredHash)) {
                throw (
                    "checksum manifest for $publishedVersion does not include " +
                    "expected hash: $requiredHash")
            }
        }

        $zipManifest = Get-PackageManifestFromZip -ZipPath $zipPath
        $zipPropertyNames = @($zipManifest.PSObject.Properties.Name)
        $indexPropertyNames = @($indexManifest.PSObject.Properties.Name)
        $expectedIndexPropertyNames = @($zipPropertyNames + @("zipSHA256"))
        if ((($indexPropertyNames | Sort-Object) -join "|") -cne
            (($expectedIndexPropertyNames | Sort-Object) -join "|")) {
            throw (
                "VPM index properties do not match package.json: " +
                $publishedVersion)
        }

        foreach ($zipProperty in $zipManifest.PSObject.Properties) {
            $indexProperty = $indexManifest.PSObject.Properties[$zipProperty.Name]
            if ($null -eq $indexProperty) {
                throw (
                    "VPM index is missing package.json property " +
                    "$($zipProperty.Name): $publishedVersion")
            }

            $zipValue = $zipProperty.Value | ConvertTo-Json -Depth 80 -Compress
            $indexValue = $indexProperty.Value | ConvertTo-Json -Depth 80 -Compress
            if ($zipValue -cne $indexValue) {
                throw (
                    "VPM index property $($zipProperty.Name) does not match " +
                    "package.json: $publishedVersion")
            }
        }
    }
}

function Get-Allowlist {
    param([Parameter(Mandatory = $true)][string]$Path)
    return @(Get-Content -LiteralPath $Path |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") } |
        Sort-Object -Unique)
}

function Get-BinaryLeakDenyLiterals {
    $prefix = "DenyLiteral:"
    return @(Get-Content -LiteralPath $BinaryLeakRulesPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } |
        ForEach-Object {
            $value = $_.Substring($prefix.Length)
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "Binary leak deny rule must not be empty: $BinaryLeakRulesPath"
            }
            $value
        })
}

function Test-BinaryLeakDenyRules {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $Path))
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicodeEven = [System.Text.Encoding]::Unicode.GetString($bytes)
    $unicodeOdd = if ($bytes.Length -gt 1) {
        [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
    } else {
        ""
    }
    $unicode = "$unicodeEven`n$unicodeOdd"
    foreach ($denyLiteral in Get-BinaryLeakDenyLiterals) {
        if ($ascii.Contains($denyLiteral) -or $unicode.Contains($denyLiteral)) {
            throw "forbidden binary literal is visible: $denyLiteral"
        }
    }
}

function Assert-PublicApiMatchesAllowlist {
    param([Parameter(Mandatory = $true)][string[]]$CurrentPublicTypes)

    $allowed = Get-Allowlist -Path (Join-Path $RepoRoot "Build\PublicApiAllowlist.txt")
    $difference = @(Compare-Object -ReferenceObject $allowed -DifferenceObject ($CurrentPublicTypes | Sort-Object -Unique))
    if ($difference.Count -gt 0) {
        throw "public API mismatch"
    }
}

function Get-PublicTopLevelTypeNamesFromAssembly {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::OpenRead((ConvertTo-FullPath $Path))
    try {
        $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
        try {
            if (-not $peReader.HasMetadata) {
                throw "assembly does not contain CLR metadata: $Path"
            }

            $metadataReader = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
            $publicTypes = New-Object System.Collections.Generic.List[string]
            foreach ($handle in $metadataReader.TypeDefinitions) {
                $type = $metadataReader.GetTypeDefinition($handle)
                $visibility = $type.Attributes -band [System.Reflection.TypeAttributes]::VisibilityMask
                if ($visibility -ne [System.Reflection.TypeAttributes]::Public) {
                    continue
                }

                $namespace = $metadataReader.GetString($type.Namespace)
                $name = $metadataReader.GetString($type.Name)
                $fullName = if ([string]::IsNullOrWhiteSpace($namespace)) {
                    $name
                } else {
                    "$namespace.$name"
                }
                [void]$publicTypes.Add($fullName)
            }

            return @($publicTypes | Sort-Object -Unique)
        }
        finally {
            $peReader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-NoUnityGlobalLogHandlerReferences {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::OpenRead((ConvertTo-FullPath $Path))
    try {
        $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
        try {
            if (-not $peReader.HasMetadata) {
                throw "assembly does not contain CLR metadata: $Path"
            }

            $reader = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
            $problems = New-Object System.Collections.Generic.List[string]

            foreach ($handle in $reader.TypeReferences) {
                $reference = $reader.GetTypeReference($handle)
                if ($reader.GetString($reference.Namespace) -eq "UnityEngine" -and
                    $reader.GetString($reference.Name) -eq "ILogHandler") {
                    [void]$problems.Add("UnityEngine.ILogHandler type reference")
                }
            }

            foreach ($handle in $reader.MemberReferences) {
                $reference = $reader.GetMemberReference($handle)
                $memberName = $reader.GetString($reference.Name)
                if ($reference.Parent.Kind -ne
                    [System.Reflection.Metadata.HandleKind]::TypeReference) {
                    continue
                }

                $typeReference = $reader.GetTypeReference(
                    [System.Reflection.Metadata.TypeReferenceHandle]$reference.Parent)
                if ($reader.GetString($typeReference.Namespace) -eq "UnityEngine" -and
                    $reader.GetString($typeReference.Name) -eq "ILogger" -and
                    $memberName -in @("get_logHandler", "set_logHandler")) {
                    [void]$problems.Add("UnityEngine.ILogger.$memberName")
                }
            }

            if ($problems.Count -gt 0) {
                throw (
                    "AvatarRecovery must not access Unity global log handler." +
                    [Environment]::NewLine +
                    ($problems -join [Environment]::NewLine))
            }
        }
        finally {
            $peReader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-Fails {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )

    try {
        & $Script
    }
    catch {
        return [PSCustomObject]@{
            Name = $Name
            Status = "Passed"
            ExpectedFailure = $_.Exception.Message
        }
    }

    throw "$Name did not fail as expected."
}

function Assert-Passes {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )

    & $Script
    return [PSCustomObject]@{
        Name = $Name
        Status = "Passed"
    }
}

function Assert-Skipped {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    return [PSCustomObject]@{
        Name = $Name
        Status = "Skipped"
        Reason = $Reason
    }
}

function Get-IndexZipHash {
    $index = Get-Content -LiteralPath (Join-Path $RepoRoot "index.json") -Raw | ConvertFrom-Json
    $packageEntry = $index.packages.PSObject.Properties[$PackageId].Value
    return $packageEntry.versions.PSObject.Properties[$Version].Value.zipSHA256
}

function Get-IndexPublishedVersions {
    param([Parameter(Mandatory = $true)][string]$IndexPath)

    $index = Get-Content -LiteralPath $IndexPath -Raw | ConvertFrom-Json
    $packageProperty = $index.packages.PSObject.Properties[$PackageId]
    if ($null -eq $packageProperty) {
        throw "package id was not found in VPM index: $PackageId"
    }

    return @($packageProperty.Value.versions.PSObject.Properties.Name)
}

function Assert-PublishedVersionWindow {
    param(
        [Parameter(Mandatory = $true)][string]$IndexPath,
        [Parameter(Mandatory = $true)][string]$ExpectedLatestVersion,
        [ValidateRange(1, 3)]
        [int]$ExpectedVersionCount = $PublishedVersionLimit
    )

    $index = Get-Content -LiteralPath $IndexPath -Raw | ConvertFrom-Json
    $packageProperty = $index.packages.PSObject.Properties[$PackageId]
    if ($null -eq $packageProperty) {
        throw "package id was not found in VPM index: $PackageId"
    }

    $versionProperties = @($packageProperty.Value.versions.PSObject.Properties)
    $publishedVersions = @($versionProperties.Name)
    if ($publishedVersions.Count -ne $ExpectedVersionCount) {
        throw (
            "VPM index must publish exactly $ExpectedVersionCount versions, " +
            "found $($publishedVersions.Count).")
    }
    if ($publishedVersions[0] -cne $ExpectedLatestVersion) {
        throw (
            "VPM index latest version mismatch. Expected $ExpectedLatestVersion, " +
            "found $($publishedVersions[0]).")
    }

    $sortedVersions = @($publishedVersions | Sort-Object { [version]$_ } -Descending)
    if (($publishedVersions -join "|") -cne ($sortedVersions -join "|")) {
        throw "VPM index versions are not in descending order."
    }

    foreach ($versionProperty in $versionProperties) {
        $versionKey = [string]$versionProperty.Name
        $manifest = $versionProperty.Value
        if ([string]$manifest.version -cne $versionKey) {
            throw "VPM index version key and manifest version differ: $versionKey"
        }
        if ([string]::IsNullOrWhiteSpace([string]$manifest.url)) {
            throw "VPM index package URL is empty: $versionKey"
        }
        if ([string]$manifest.zipSHA256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "VPM index package hash is invalid: $versionKey"
        }
    }
}

function Get-PackagedDllPath {
    $candidate = Join-Path $RepoRoot ".work\Release$($Version.Replace('.', ''))\ProjectRoot\Packages\$PackageId\Editor\$AssemblyFileName"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    $zipPath = Join-Path $RepoRoot "packages\$PackageId-$Version.zip"
    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "package zip was not found: $zipPath"
    }

    $extractRoot = Join-Path $OutputRoot "extract"
    Ensure-Directory $extractRoot
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entry = $archive.Entries |
            Where-Object { ($_.FullName -replace '\\', '/') -eq "Editor/$AssemblyFileName" } |
            Select-Object -First 1
        if ($null -eq $entry) {
            throw "DLL was not found in package zip."
        }

        $dllPath = Join-Path $extractRoot $AssemblyFileName
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dllPath, $true)
        return $dllPath
    }
    finally {
        $archive.Dispose()
    }
}

function Get-PackagedRuntimeIntegritySidecarPath {
    $candidate = Join-Path $RepoRoot ".work\Release$($Version.Replace('.', ''))\ProjectRoot\Packages\$PackageId\Editor\$RuntimeIntegritySidecarFileName"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    $zipPath = Join-Path $RepoRoot "packages\$PackageId-$Version.zip"
    if (-not (Test-Path -LiteralPath $zipPath)) {
        return ""
    }

    $extractRoot = Join-Path $OutputRoot "extract"
    Ensure-Directory $extractRoot
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entry = $archive.Entries |
            Where-Object { ($_.FullName -replace '\\', '/') -eq "Editor/$RuntimeIntegritySidecarFileName" } |
            Select-Object -First 1
        if ($null -eq $entry) {
            return ""
        }

        $sidecarPath = Join-Path $extractRoot $RuntimeIntegritySidecarFileName
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $sidecarPath, $true)
        return $sidecarPath
    }
    finally {
        $archive.Dispose()
    }
}

function Get-PrivateProtectionReportPath {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $primary = Join-Path $RepoRoot ".work\BackupsPrivate\$Version-protection-private\$FileName"
    if (Test-Path -LiteralPath $primary) {
        return $primary
    }

    $fallback = Join-Path $RepoRoot ".work\Backups\$Version-protection-private\$FileName"
    if (Test-Path -LiteralPath $fallback) {
        return $fallback
    }

    throw "private protection report was not found: $FileName"
}

function Test-RuntimeIntegritySidecarFile {
    param(
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$SidecarPath,
        [Parameter(Mandatory = $true)][string]$ExpectedThumbprint
    )

    if ([string]::IsNullOrWhiteSpace($SidecarPath) -or -not (Test-Path -LiteralPath $SidecarPath)) {
        throw "runtime integrity sidecar not found"
    }

    $sidecar = Get-Content -LiteralPath $SidecarPath -Raw | ConvertFrom-Json
    if ($sidecar.format -ne "AvatarRecovery runtime integrity signature v1") {
        throw "unsupported runtime integrity sidecar format"
    }
    if ($sidecar.algorithm -ne "RSA-SHA256-PKCS1") {
        throw "unsupported runtime integrity sidecar algorithm"
    }

    $actualHash = (Get-FileHash -LiteralPath $DllPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $sidecar.targetSha256) {
        throw "runtime integrity sidecar target hash mismatch"
    }

    $certificateBytes = [Convert]::FromBase64String($sidecar.signerCertificateBase64)
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateBytes)
    try {
        $certificateThumbprint = ($certificate.Thumbprint -replace '\s', '').ToUpperInvariant()
        if ($certificateThumbprint -ne (($sidecar.signerThumbprint -replace '\s', '').ToUpperInvariant())) {
            throw "runtime integrity sidecar signer mismatch"
        }
        if ($certificateThumbprint -ne (($ExpectedThumbprint -replace '\s', '').ToUpperInvariant())) {
            throw "runtime integrity signer does not match the independently pinned certificate"
        }

        $publicKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        if ($null -eq $publicKey) {
            throw "runtime integrity public key was not available"
        }

        try {
            $targetBytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $DllPath))
            $signatureBytes = [Convert]::FromBase64String($sidecar.signatureBase64)
            $verified = $publicKey.VerifyData(
                $targetBytes,
                $signatureBytes,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            if (-not $verified) {
                throw "runtime integrity sidecar signature verification failed"
            }
        }
        finally {
            $publicKey.Dispose()
        }
    }
    finally {
        $certificate.Dispose()
    }
}

function Flip-OneByte {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $Path))
    if ($bytes.Length -lt 4) {
        throw "file is too small: $Path"
    }

    $offset = [Math]::Floor($bytes.Length / 2)
    $bytes[$offset] = $bytes[$offset] -bxor 0x01
    [System.IO.File]::WriteAllBytes((ConvertTo-FullPath $Path), $bytes)
    return $offset
}

Remove-SafeDirectory -Path $OutputRoot
Ensure-Directory $OutputRoot

$results = New-Object System.Collections.Generic.List[object]
$zipPath = Join-Path $RepoRoot "packages\$PackageId-$Version.zip"
$checksumPath = Join-Path $RepoRoot "checksums\$PackageId-$Version.sha256.txt"

[void]$results.Add((Assert-Passes "A normal protected build artifacts" {
    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "package zip not found"
    }
    if (-not (Test-Path -LiteralPath $checksumPath)) {
        throw "checksum manifest not found"
    }
    Test-PackageZipGuard -ZipPath $zipPath
    Test-PackageReadmeSecurityDisclosure -ZipPath $zipPath
    Assert-PublicApiMatchesAllowlist `
        -CurrentPublicTypes (Get-PublicTopLevelTypeNamesFromAssembly -Path (Get-PackagedDllPath))
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumText = Get-Content -LiteralPath $checksumPath -Raw
    if (-not $checksumText.Contains($zipHash)) {
        throw "checksum manifest does not include zip hash"
    }
    if ((Get-IndexZipHash) -ne $zipHash) {
        throw "index zipSHA256 mismatch"
    }
    Assert-PublishedVersionWindow `
        -IndexPath (Join-Path $RepoRoot "index.json") `
        -ExpectedLatestVersion $Version
    Test-DetachedSignatureFile `
        -TargetPath (Join-Path $RepoRoot "index.json") `
        -SignaturePath (Join-Path $RepoRoot "index.json.sig") `
        -CertificatePath $PublishedCertificatePath
    Test-PublishedVersionArtifacts `
        -IndexPath (Join-Path $RepoRoot "index.json")
}))

New-TestZip -Path (Join-Path $OutputRoot "source-injection.zip") -EntryName "Editor/Injected.cs" -Text "class Injected {}"
[void]$results.Add((Assert-Fails "B source .cs injection" { Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "source-injection.zip") }))

New-TestZip -Path (Join-Path $OutputRoot "pdb-injection.zip") -EntryName "Editor/Injected.pdb" -Text "debug symbols"
[void]$results.Add((Assert-Fails "C PDB injection" { Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "pdb-injection.zip") }))

New-TestZip -Path (Join-Path $OutputRoot "pfx-injection.zip") -EntryName "Editor/Injected.pfx" -Text "dummy pfx"
[void]$results.Add((Assert-Fails "D PFX injection" { Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "pfx-injection.zip") }))

New-TestZip -Path (Join-Path $OutputRoot "private-key-injection.zip") -EntryName "Editor/readme.txt" -Text "-----BEGIN PRIVATE KEY-----`nsecret`n-----END PRIVATE KEY-----"
[void]$results.Add((Assert-Fails "E private key text injection" { Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "private-key-injection.zip") }))

[void]$results.Add((Assert-Fails "F unauthorized public API" {
    $packagedPublicTypes = Get-PublicTopLevelTypeNamesFromAssembly -Path (Get-PackagedDllPath)
    Assert-PublicApiMatchesAllowlist -CurrentPublicTypes $packagedPublicTypes
    Assert-PublicApiMatchesAllowlist -CurrentPublicTypes @(
        $packagedPublicTypes + "EditorTools.AvatarRecovery.UnauthorizedPublicType")
}))

$dllPath = Get-PackagedDllPath
[void]$results.Add((Assert-Passes "G signed DLL one-byte tamper rejected" {
    $tamperedDll = Join-Path $OutputRoot "tampered-$AssemblyFileName"
    Copy-Item -LiteralPath $dllPath -Destination $tamperedDll -Force
    [void](Flip-OneByte -Path $tamperedDll)
    $signature = Get-AuthenticodeSignature -LiteralPath $tamperedDll
    if ($signature.Status -eq "Valid") {
        throw "tampered DLL stayed Valid"
    }
}))

[void]$results.Add((Assert-Passes "H zip one-byte tamper causes SHA mismatch" {
    $tamperedZip = Join-Path $OutputRoot "tampered-$PackageId-$Version.zip"
    Copy-Item -LiteralPath $zipPath -Destination $tamperedZip -Force
    [void](Flip-OneByte -Path $tamperedZip)
    $originalHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $tamperedHash = (Get-FileHash -LiteralPath $tamperedZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($tamperedHash -eq $originalHash) {
        throw "tampered ZIP kept original hash"
    }
    if ($tamperedHash -eq (Get-IndexZipHash)) {
        throw "tampered ZIP matched index hash"
    }
}))

[void]$results.Add((Assert-Passes "I forbidden binary literals are absent" {
    Test-BinaryLeakDenyRules -Path $dllPath

    $oddOffsetFixturePath = Join-Path $OutputRoot "odd-offset-utf16-deny.bin"
    $denyLiteral = @(Get-BinaryLeakDenyLiterals | Select-Object -First 1)[0]
    $encodedDenyLiteral = [System.Text.Encoding]::Unicode.GetBytes($denyLiteral)
    $oddOffsetFixture = [byte[]]::new($encodedDenyLiteral.Length + 1)
    $oddOffsetFixture[0] = 0x7F
    [Array]::Copy($encodedDenyLiteral, 0, $oddOffsetFixture, 1, $encodedDenyLiteral.Length)
    [System.IO.File]::WriteAllBytes($oddOffsetFixturePath, $oddOffsetFixture)

    $oddOffsetRejected = $false
    try {
        Test-BinaryLeakDenyRules -Path $oddOffsetFixturePath
    }
    catch {
        $oddOffsetRejected = $true
    }
    if (-not $oddOffsetRejected) {
        throw "odd-offset UTF-16LE deny literal bypassed the binary leak scanner"
    }
}))

[void]$results.Add((Assert-Passes "J externally pinned runtime sidecar accepts valid and rejects invalid input" {
    $sidecarPath = Get-PackagedRuntimeIntegritySidecarPath
    if (-not (Test-Path -LiteralPath $PublishedCertificatePath)) {
        throw "published certificate was not found"
    }

    $trustedCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        (ConvertTo-FullPath $PublishedCertificatePath))
    try {
        $expectedThumbprint = ($trustedCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    }
    finally {
        $trustedCertificate.Dispose()
    }

    Test-RuntimeIntegritySidecarFile `
        -DllPath $dllPath `
        -SidecarPath $sidecarPath `
        -ExpectedThumbprint $expectedThumbprint

    $missingRejected = $false
    try {
        Test-RuntimeIntegritySidecarFile `
            -DllPath $dllPath `
            -SidecarPath (Join-Path $OutputRoot "missing.runtime.sig") `
            -ExpectedThumbprint $expectedThumbprint
    }
    catch {
        $missingRejected = $true
    }
    if (-not $missingRejected) {
        throw "external sidecar verifier accepted a missing sidecar"
    }

    $tamperedSidecarPath = Join-Path $OutputRoot "tampered.runtime.sig"
    $tamperedSidecar = Get-Content -LiteralPath $sidecarPath -Raw | ConvertFrom-Json
    $tamperedSignature = [Convert]::FromBase64String([string]$tamperedSidecar.signatureBase64)
    $tamperedSignature[0] = $tamperedSignature[0] -bxor 0x01
    $tamperedSidecar.signatureBase64 = [Convert]::ToBase64String($tamperedSignature)
    $tamperedSidecar | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tamperedSidecarPath -Encoding UTF8

    $tamperedRejected = $false
    try {
        Test-RuntimeIntegritySidecarFile `
            -DllPath $dllPath `
            -SidecarPath $tamperedSidecarPath `
            -ExpectedThumbprint $expectedThumbprint
    }
    catch {
        $tamperedRejected = $true
    }
    if (-not $tamperedRejected) {
        throw "external sidecar verifier accepted a tampered signature"
    }
}))

if ($SkipPrivateProtectionReports) {
    [void]$results.Add((Assert-Skipped "K custom string encryption is retired" "Private protection reports are not available in CI checkout."))
    [void]$results.Add((Assert-Skipped "L plaintext risk scan is managed" "Private protection reports are not available in CI checkout."))
    [void]$results.Add((Assert-Skipped "M build-only metadata and self-check code are removed" "Private protection reports are not available in CI checkout."))
    [void]$results.Add((Assert-Skipped "N Cecil control-flow report covers allowlist" "Private protection reports are not available in CI checkout."))
    [void]$results.Add((Assert-Skipped "O anti-decompile report covers allowlist" "Private protection reports are not available in CI checkout."))
    [void]$results.Add((Assert-Skipped "P in-process runtime guard is retired" "Private protection reports are not available in CI checkout."))
    [void]$results.Add((Assert-Skipped "Q anti-debug injection is retired" "Private protection reports are not available in CI checkout."))
}
else {
    [void]$results.Add((Assert-Passes "K custom string encryption is retired" {
        $reportPath = Get-PrivateProtectionReportPath -FileName "cecil-string-encryption-$Version.json"
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $allowlist = Get-Allowlist -Path (Join-Path $RepoRoot "Build\StringEncryptionAllowlist.txt")
        if ([bool]$report.Enabled -or [int]$report.EncryptedStringCount -ne 0) {
            throw "custom string encryption unexpectedly remained enabled"
        }
        if ([string]$report.Reason -ne "RetiredIneffectiveLocalEncryption") {
            throw "unexpected string encryption retirement reason"
        }
        if ($allowlist.Count -ne 0) {
            throw "retired string encryption allowlist is not empty"
        }
    }))

    [void]$results.Add((Assert-Passes "L plaintext risk scan is managed" {
        $reportPath = Get-PrivateProtectionReportPath -FileName "hide-strings-impact-$Version.json"
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json

        if (-not [bool]$report.Enabled) {
            throw "HideStrings impact report is disabled"
        }
        if (-not [bool]$report.HideStringsDisabled) {
            throw "HideStrings impact report did not record disabled HideStrings"
        }
        if ([string]$report.ManagedBy -ne "PlaintextRiskScanNoEncryption") {
            throw "HideStrings impact report has unexpected management mode"
        }
        if ([string]$report.StringProtectionProvider -ne "None") {
            throw "string protection provider must be None"
        }
        if ([int]$report.SensitivePlaintextHitCount -ne 0) {
            throw "HideStrings impact scan found sensitive plaintext"
        }
        if ([int]$report.EncryptedBlobLiteralCount -ne 0 -or
            [int]$report.InlineByteArrayStringCount -ne 0 -or
            [int]$report.EncodedBlobStringCount -ne 0) {
            throw "retired string encryption artifacts remain"
        }
    }))

    [void]$results.Add((Assert-Passes "M build-only metadata and self-check code are removed" {
        $reportPath = Get-PrivateProtectionReportPath -FileName "protection-build-report-$Version.json"
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $metadata = $report.BuildMetadataSanitization
        $sizes = @($metadata.RemovedPrivateDataFieldSizes | ForEach-Object { [int]$_ } | Sort-Object)
        if ([int]$metadata.UnityMonoScriptMetadataTypeCount -ne 1 -or
            [int]$metadata.RemovedPrivateDataFieldCount -ne 2 -or
            @($sizes | Where-Object { $_ -le 0 }).Count -ne 0 -or
            [string]$metadata.ExternalReferenceValidation -ne "ComprehensiveCecilReferenceWalk" -or
            -not [bool]$metadata.PostWriteReferenceValidation) {
            throw "Unity MonoScript metadata removal report is unexpected"
        }
        if ([int]$report.StringHidingProbe.NeutralizedMethodCount -ne 1 -or
            -not [bool]$report.StringHidingProbe.ValidatedExpectedCanary) {
            throw "validated string hiding canary was not neutralized"
        }

        Test-BinaryLeakDenyRules -Path $dllPath
        $sidecarPath = Get-PackagedRuntimeIntegritySidecarPath
        $sidecar = Get-Content -LiteralPath $sidecarPath -Raw | ConvertFrom-Json
        $thumbprint = [string]$sidecar.signerThumbprint
        $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $dllPath))
        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
        $unicodeEven = [System.Text.Encoding]::Unicode.GetString($bytes)
        $unicodeOdd = if ($bytes.Length -gt 1) {
            [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
        } else {
            ""
        }
        $unicode = "$unicodeEven`n$unicodeOdd"
        if (-not [string]::IsNullOrWhiteSpace($thumbprint) -and
            ($ascii.Contains($thumbprint) -or $unicode.Contains($thumbprint))) {
            throw "signer thumbprint is duplicated inside the DLL"
        }
    }))

    [void]$results.Add((Assert-Passes "N Cecil control-flow report covers allowlist" {
        $reportPath = Get-PrivateProtectionReportPath -FileName "cecil-control-flow-$Version.json"
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $allowlist = Get-Allowlist -Path (Join-Path $RepoRoot "Build\ControlFlowObfuscationAllowlist.txt")
        $protectedMethods = @($report.ObfuscatedMethods | ForEach-Object { [string]$_.Method })

        if (-not [bool]$report.Enabled) {
            throw "Cecil control-flow report is disabled"
        }
        if ([int]$report.TargetRuleCount -ne $allowlist.Count) {
            throw "Cecil control-flow target count mismatch"
        }
        if (@($report.Skipped).Count -ne 0) {
            throw "Cecil control-flow skipped a protected method"
        }

        foreach ($entry in $allowlist) {
            if ($protectedMethods -notcontains $entry) {
                throw "Cecil control-flow missed allowlist entry: $entry"
            }
        }
    }))

    [void]$results.Add((Assert-Passes "O anti-decompile report covers allowlist" {
        $reportPath = Get-PrivateProtectionReportPath -FileName "anti-decompile-$Version.json"
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $allowlist = Get-Allowlist -Path (Join-Path $RepoRoot "Build\AntiDecompileAllowlist.txt")
        $processedTypes = @($report.ProcessedTypes | ForEach-Object { [string]$_ })
        $processedMethods = @($report.ProcessedMethods | ForEach-Object { [string]$_ })

        if (-not [bool]$report.Enabled) {
            throw "Anti-decompile report is disabled"
        }
        if ([int]$report.TargetRuleCount -ne $allowlist.Count) {
            throw "Anti-decompile target count mismatch"
        }
        if (@($report.Skipped).Count -ne 0) {
            throw "Anti-decompile skipped a protected method"
        }

        foreach ($entry in $allowlist) {
            $parts = $entry.Split("|")
            if ($parts.Count -ne 2) {
                throw "Invalid anti-decompile allowlist entry: $entry"
            }

            if ($parts[1] -eq "*") {
                if ($processedTypes -notcontains $parts[0]) {
                    throw "Anti-decompile missed allowlist type: $entry"
                }
            }
            elseif ($processedMethods -notcontains $entry) {
                throw "Anti-decompile missed allowlist method: $entry"
            }
        }
    }))

    [void]$results.Add((Assert-Passes "P in-process runtime guard is retired" {
        $reportPath = Get-PrivateProtectionReportPath -FileName "runtime-integrity-injection-$Version.json"
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $allowlist = Get-Allowlist -Path (Join-Path $RepoRoot "Build\RuntimeIntegrityGuardTargets.txt")
        if ([bool]$report.Enabled -or [int]$report.InjectedMethodCount -ne 0 -or
            [string]$report.Reason -ne "ExternalSidecarOnly") {
            throw "in-process runtime integrity guard unexpectedly remained enabled"
        }
        if ($allowlist.Count -ne 0) {
            throw "retired runtime integrity target list is not empty"
        }
    }))

    [void]$results.Add((Assert-Passes "Q anti-debug injection is retired" {
        $reportPath = Get-PrivateProtectionReportPath -FileName "anti-debug-$Version.json"
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $allowlist = Get-Allowlist -Path (Join-Path $RepoRoot "Build\AntiDebugTargets.txt")
        if ([bool]$report.Enabled -or [int]$report.InjectedMethodCount -ne 0 -or
            [string]$report.Reason -ne "RemovedIneffectiveDebuggerCheck") {
            throw "anti-debug injection unexpectedly remained enabled"
        }
        if ($allowlist.Count -ne 0) {
            throw "retired anti-debug target list is not empty"
        }
    }))
}

[void]$results.Add((Assert-Passes "R packaged DLL does not replace Unity global log handler" {
    Assert-NoUnityGlobalLogHandlerReferences -Path $dllPath
}))

[void]$results.Add((Assert-Passes "S VPM repository retains three versions without rewriting history" {
    $fixtureRoot = Join-Path $OutputRoot "vpm-version-window"
    $fixturePackagesRoot = Join-Path $fixtureRoot "packages"
    Ensure-Directory $fixturePackagesRoot

    $fixtureVersions = @("1.2.7", "1.2.6", "1.2.5", "1.2.4")
    $hashesBefore = @{}
    foreach ($fixtureVersion in $fixtureVersions) {
        $fixtureManifest = [ordered]@{
            name = $PackageId
            displayName = "Avatar Recovery"
            version = $fixtureVersion
            unity = "2022.3"
            vpmDependencies = [ordered]@{
                "com.vrchat.base" = ">=3.7.0 <3.11.0"
            }
        }
        $fixtureZipPath = Join-Path $fixturePackagesRoot "$PackageId-$fixtureVersion.zip"
        New-TestZip `
            -Path $fixtureZipPath `
            -EntryName "package.json" `
            -Text ($fixtureManifest | ConvertTo-Json -Depth 10)
        $hashesBefore[$fixtureVersion] = (
            Get-FileHash -LiteralPath $fixtureZipPath -Algorithm SHA256).Hash
    }

    $buildOutput = @(
        & powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $RepoRoot "BuildVpmRepository.ps1") `
            -OutputRoot $fixtureRoot `
            -BaseUrl "https://example.invalid/avatar-recovery" `
            -MinimumPublishedVersion "1.0.0" `
            -MaximumPublishedVersion "1.2.7" `
            -MaximumPublishedVersionCount 3 `
            -IndexOnly 2>&1
    )
    $buildExitCode = $LASTEXITCODE
    if ($buildExitCode -ne 0) {
        throw (
            "VPM index-only fixture build failed." +
            [Environment]::NewLine +
            ($buildOutput -join [Environment]::NewLine))
    }

    $fixtureIndexPath = Join-Path $fixtureRoot "index.json"
    Assert-PublishedVersionWindow `
        -IndexPath $fixtureIndexPath `
        -ExpectedLatestVersion "1.2.7"
    $actualVersions = Get-IndexPublishedVersions -IndexPath $fixtureIndexPath
    $expectedVersions = @("1.2.7", "1.2.6", "1.2.5")
    if (($actualVersions -join "|") -cne ($expectedVersions -join "|")) {
        throw "VPM index-only fixture selected unexpected versions."
    }

    foreach ($fixtureVersion in $fixtureVersions) {
        $fixtureZipPath = Join-Path $fixturePackagesRoot "$PackageId-$fixtureVersion.zip"
        $hashAfter = (Get-FileHash -LiteralPath $fixtureZipPath -Algorithm SHA256).Hash
        if ($hashAfter -cne $hashesBefore[$fixtureVersion]) {
            throw "VPM index-only mode modified package ZIP $fixtureVersion."
        }
    }

    $fixtureProjectRoot = Join-Path $fixtureRoot "project"
    $fixturePackageRoot = Join-Path $fixtureProjectRoot "Packages\$PackageId"
    Ensure-Directory $fixturePackageRoot
    $nextVersion = "1.2.8"
    $nextManifest = [ordered]@{
        name = $PackageId
        displayName = "Avatar Recovery"
        version = $nextVersion
        unity = "2022.3"
        vpmDependencies = [ordered]@{
            "com.vrchat.base" = ">=3.7.0 <3.11.0"
        }
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $fixturePackageRoot "package.json"),
        ($nextManifest | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false))

    $normalBuildOutput = @(
        & powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $RepoRoot "BuildVpmRepository.ps1") `
            -ProjectRoot $fixtureProjectRoot `
            -OutputRoot $fixtureRoot `
            -BaseUrl "https://example.invalid/avatar-recovery" `
            -MinimumPublishedVersion "1.0.0" `
            -MaximumPublishedVersion $nextVersion `
            -MaximumPublishedVersionCount 3 2>&1
    )
    $normalBuildExitCode = $LASTEXITCODE
    if ($normalBuildExitCode -ne 0) {
        throw (
            "VPM normal fixture build failed." +
            [Environment]::NewLine +
            ($normalBuildOutput -join [Environment]::NewLine))
    }

    Assert-PublishedVersionWindow `
        -IndexPath $fixtureIndexPath `
        -ExpectedLatestVersion $nextVersion
    $normalBuildVersions = Get-IndexPublishedVersions -IndexPath $fixtureIndexPath
    $expectedNormalBuildVersions = @($nextVersion, "1.2.7", "1.2.6")
    if (($normalBuildVersions -join "|") -cne
        ($expectedNormalBuildVersions -join "|")) {
        throw "VPM normal fixture selected unexpected versions."
    }

    foreach ($fixtureVersion in $fixtureVersions) {
        $fixtureZipPath = Join-Path $fixturePackagesRoot "$PackageId-$fixtureVersion.zip"
        $hashAfter = (Get-FileHash -LiteralPath $fixtureZipPath -Algorithm SHA256).Hash
        if ($hashAfter -cne $hashesBefore[$fixtureVersion]) {
            throw "VPM normal mode modified historical package ZIP $fixtureVersion."
        }
    }
}))

$report = [PSCustomObject]@{
    Version = $Version
    GeneratedAt = (Get-Date).ToString("o")
    Results = @($results.ToArray())
    ReportPath = Join-Path $OutputRoot "protection-self-tests-$Version.json"
}

$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $report.ReportPath -Encoding UTF8
Write-Host "Protection self tests passed."
$report | Format-List
