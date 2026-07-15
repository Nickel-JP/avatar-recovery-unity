param(
    [string]$Version = "1.2.5",
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

$report = [PSCustomObject]@{
    Version = $Version
    GeneratedAt = (Get-Date).ToString("o")
    Results = @($results.ToArray())
    ReportPath = Join-Path $OutputRoot "protection-self-tests-$Version.json"
}

$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $report.ReportPath -Encoding UTF8
Write-Host "Protection self tests passed."
$report | Format-List
