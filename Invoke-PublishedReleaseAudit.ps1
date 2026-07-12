param(
    [string]$Version = "1.2.4",
    [string]$PackageId = "com.nickel-jp.avatar-recovery",
    [string]$BaseUrl = "https://nickel-jp.github.io/avatar-recovery-unity",
    [string]$OutputRoot = "",
    [string]$ExpectedCodeSigningCertificateThumbprint = $env:AVATAR_RECOVERY_PUBLISHED_CERTIFICATE_THUMBPRINT,
    [int]$RetryCount = 18,
    [int]$RetryDelaySeconds = 10,
    [switch]$TrustPublishedCertificateForAuthenticode
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepoRoot ".work\PublishedAudit$($Version.Replace('.', ''))"
}

$AssemblyFileName = "EditorTools.AvatarRecovery.Editor.dll"
$RuntimeIntegritySidecarFileName = "$AssemblyFileName.runtime.sig"
$CertificateFileName = "avatar-recovery-self-signed-code-signing.cer"
$CertificatePemFileName = "avatar-recovery-self-signed-code-signing.cer.pem"
$TrustedCertificatePath = Join-Path $RepoRoot "certificates\$CertificateFileName"
$BinaryLeakRulesPath = Join-Path $RepoRoot "Build\BinaryLeakAllowlist.txt"

function ConvertTo-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Normalize-Thumbprint {
    param([AllowNull()][string]$Thumbprint)

    if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
        return ""
    }

    return ($Thumbprint -replace '\s', '').ToUpperInvariant()
}

function Get-CertificateThumbprintFromFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((ConvertTo-FullPath $Path))
    try {
        return (Normalize-Thumbprint $certificate.Thumbprint)
    }
    finally {
        $certificate.Dispose()
    }
}

function Get-ExpectedCodeSigningCertificateThumbprint {
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCodeSigningCertificateThumbprint)) {
        return (Normalize-Thumbprint $ExpectedCodeSigningCertificateThumbprint)
    }

    if (Test-Path -LiteralPath $TrustedCertificatePath) {
        return (Get-CertificateThumbprintFromFile -Path $TrustedCertificatePath)
    }

    throw "Expected code signing certificate thumbprint is required. Set -ExpectedCodeSigningCertificateThumbprint or keep the trusted certificate at: $TrustedCertificatePath"
}

function Assert-UnderPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ParentPath
    )

    $fullPath = ConvertTo-FullPath $Path
    $fullParent = (ConvertTo-FullPath $ParentPath).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "安全でないパスです: $fullPath"
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Remove-SafeAuditDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Assert-UnderPath -Path $Path -ParentPath (Join-Path $RepoRoot ".work")
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Get-CacheBustUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $separator = if ($Url.Contains("?")) { "&" } else { "?" }
    return "$Url${separator}cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
}

function Save-Url {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Ensure-Directory (Split-Path -Parent $Path)
    Invoke-WebRequest `
        -Uri (Get-CacheBustUrl -Url $Url) `
        -OutFile $Path `
        -UseBasicParsing `
        -Headers @{ "Cache-Control" = "no-cache" }
}

function Get-UrlText {
    param([Parameter(Mandatory = $true)][string]$Url)

    $response = Invoke-WebRequest `
        -Uri (Get-CacheBustUrl -Url $Url) `
        -UseBasicParsing `
        -Headers @{ "Cache-Control" = "no-cache" }
    return $response.Content
}

function Import-PublicCertificateIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$CertificatePath,
        [Parameter(Mandatory = $true)][string]$StoreName,
        [Parameter(Mandatory = $true)][string]$Thumbprint
    )

    $storePath = "Cert:\CurrentUser\$StoreName"
    $existing = Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue |
        Where-Object { ($_.Thumbprint -replace '\s', '').ToUpperInvariant() -eq $Thumbprint } |
        Select-Object -First 1
    if ($null -ne $existing) {
        return
    }

    Import-Certificate -FilePath $CertificatePath -CertStoreLocation $storePath | Out-Null
}

function Test-DetachedSignatureFile {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$SignaturePath,
        [Parameter(Mandatory = $true)][string]$CertificatePath
    )

    $signature = Get-Content -LiteralPath $SignaturePath -Raw | ConvertFrom-Json
    if ($signature.format -ne "AvatarRecovery detached signature v1") {
        throw "Unsupported detached signature format: $SignaturePath"
    }
    if ($signature.algorithm -ne "RSA-SHA256-PKCS1") {
        throw "Unsupported detached signature algorithm: $SignaturePath"
    }

    $targetHash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($targetHash -ne $signature.targetSha256) {
        throw "Detached signature hash mismatch: $TargetPath"
    }

    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((ConvertTo-FullPath $CertificatePath))
    try {
        $certificateThumbprint = Normalize-Thumbprint $certificate.Thumbprint
        if ($certificateThumbprint -ne (Normalize-Thumbprint $signature.signerThumbprint)) {
            throw "Detached signature signer mismatch: $SignaturePath"
        }

        $publicKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        if ($null -eq $publicKey) {
            throw "Public key was not available: $CertificatePath"
        }
        try {
            $targetBytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $TargetPath))
            $signatureBytes = [Convert]::FromBase64String($signature.signatureBase64)
            $verified = $publicKey.VerifyData(
                $targetBytes,
                $signatureBytes,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            if (-not $verified) {
                throw "Detached signature verification failed: $SignaturePath"
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

function Test-ForbiddenPublishedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$SecretValue = ""
    )

    $fileName = [System.IO.Path]::GetFileName($Path)
    if ($fileName -match '(?i)\.(pfx|p12|pvk|key|snk)$') {
        throw "公開禁止の秘密鍵/証明書秘密情報ファイルです: $Path"
    }

    $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $Path))
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicodeEven = [System.Text.Encoding]::Unicode.GetString($bytes)
    $unicodeOdd = if ($bytes.Length -gt 1) {
        [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
    } else {
        ""
    }
    $unicode = "$unicodeEven`n$unicodeOdd"
    if ($ascii -match '-----BEGIN [A-Z ]*PRIVATE KEY-----' -or
        $unicode -match '-----BEGIN [A-Z ]*PRIVATE KEY-----') {
        throw "公開禁止の秘密鍵本文が含まれています: $Path"
    }

    if (-not [string]::IsNullOrEmpty($SecretValue)) {
        if ($ascii.Contains($SecretValue) -or $unicode.Contains($SecretValue)) {
            throw "公開禁止の秘密情報値が含まれています: $Path"
        }
    }
}

function Test-DownloadedPublicFiles {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $codeSigningPassword = [Environment]::GetEnvironmentVariable("AVATAR_RECOVERY_CODE_SIGNING_PASSWORD")
    foreach ($path in $Paths) {
        Test-ForbiddenPublishedFile -Path $path -SecretValue $codeSigningPassword
    }
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

function Test-BinaryLeak {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string]$ForbiddenSignerThumbprint = ""
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicodeEven = [System.Text.Encoding]::Unicode.GetString($bytes)
    $unicodeOdd = if ($bytes.Length -gt 1) {
        [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
    } else {
        ""
    }
    $unicode = "$unicodeEven`n$unicodeOdd"
    $userName = [Environment]::UserName
    $checks = @(
        @{ Name = "current user name"; Pattern = $userName },
        @{ Name = "repo source path"; Pattern = "\Packages\com.nickel-jp.avatar-recovery\Editor\" },
        @{ Name = "VrcaExtractor.cs"; Pattern = "VrcaExtractor.cs" },
        @{ Name = "local user path"; Pattern = "C:\Users\" },
        @{ Name = "private key marker"; Pattern = "PRIVATE KEY" },
        @{ Name = "password marker"; Pattern = "Password=" },
        @{ Name = "token marker"; Pattern = "Token=" },
        @{ Name = "api key marker"; Pattern = "ApiKey=" },
        @{ Name = "secret marker"; Pattern = "Secret=" },
        @{ Name = "Unity-incompatible core library reference"; Pattern = "System.Private.CoreLib" },
        @{ Name = "local HTTP URL"; Pattern = "http://localhost" },
        @{ Name = "loopback URL"; Pattern = "127.0.0.1" }
    )

    foreach ($check in $checks) {
        if ($ascii.Contains($check.Pattern) -or $unicode.Contains($check.Pattern)) {
            throw "Binary leak check failed for ${Path}: $($check.Name)"
        }
    }

    foreach ($denyLiteral in Get-BinaryLeakDenyLiterals) {
        if ($ascii.Contains($denyLiteral) -or $unicode.Contains($denyLiteral)) {
            throw "Binary leak check failed for ${Path}: forbidden literal '$denyLiteral'"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ForbiddenSignerThumbprint) -and
        ($ascii.Contains($ForbiddenSignerThumbprint) -or $unicode.Contains($ForbiddenSignerThumbprint))) {
        throw "Binary leak check failed for ${Path}: signer thumbprint is duplicated inside the DLL"
    }
}

function Test-ZipPackage {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$ExtractRoot
    )

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
            throw "配布 zip に含めてはいけないファイルがあります: $($blocked.FullName -join ', ')"
        }

        $dllEntry = $archive.Entries |
            Where-Object { ($_.FullName -replace '\\', '/') -eq "Editor/$AssemblyFileName" } |
            Select-Object -First 1
        if ($null -eq $dllEntry) {
            throw "DLL was not found in package zip."
        }

        Ensure-Directory $ExtractRoot
        $dllPath = Join-Path $ExtractRoot $AssemblyFileName
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($dllEntry, $dllPath, $true)

        $sidecarEntry = $archive.Entries |
            Where-Object { ($_.FullName -replace '\\', '/') -eq "Editor/$RuntimeIntegritySidecarFileName" } |
            Select-Object -First 1
        if ($null -ne $sidecarEntry) {
            $sidecarPath = Join-Path $ExtractRoot $RuntimeIntegritySidecarFileName
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($sidecarEntry, $sidecarPath, $true)
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
                        throw "zip内に公開禁止の秘密鍵本文が含まれています: $($entry.FullName)"
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

        return $dllPath
    }
    finally {
        $archive.Dispose()
    }
}

function Test-IlSpyOutput {
    param(
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $ilspy = Get-Command ilspycmd -ErrorAction SilentlyContinue
    if ($null -eq $ilspy) {
        return [PSCustomObject]@{
            Status = "Skipped"
            Reason = "ilspycmd was not found"
            OutputPath = ""
            SourceFileCount = 0
        }
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Recurse -Force
    }
    Ensure-Directory $OutputPath
    $logPath = Join-Path $OutputPath "ilspycmd.log"

    if ([string]::IsNullOrWhiteSpace($env:DOTNET_ROLL_FORWARD)) {
        $env:DOTNET_ROLL_FORWARD = "Major"
    }

    & $ilspy.Source -p -o $OutputPath $DllPath *> $logPath
    if ($LASTEXITCODE -ne 0) {
        throw "ILSpy decompile failed. Log: $logPath"
    }

    $sourceFiles = @(Get-ChildItem -LiteralPath $OutputPath -Recurse -File -Include "*.cs", "*.csproj")
    $leaks = @()
    if ($sourceFiles.Count -gt 0) {
        $patterns = @(
            "C:\\Users\\",
            "\\Packages\\com\.nickel-jp\.avatar-recovery\\Editor\\",
            "VrcaExtractor\.cs",
            "AvatarRecoverySource/",
            "EditorTools\.AvatarRecovery\|",
            "AvatarRecoveryIntegrityGuard",
            "AvatarRecoveryStringDecryptor",
            "get_IsAttached"
        )
        $leaks = @(Select-String -Path ($sourceFiles | Select-Object -ExpandProperty FullName) -Pattern $patterns -ErrorAction SilentlyContinue)
    }
    if ($leaks.Count -gt 0) {
        throw "ILSpy output leak check failed: $($leaks[0].Path):$($leaks[0].LineNumber)"
    }

    return [PSCustomObject]@{
        Status = "Passed"
        Reason = ""
        OutputPath = $OutputPath
        SourceFileCount = $sourceFiles.Count
    }
}

function Test-DllAuthenticodeIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$CertificatePath,
        [Parameter(Mandatory = $true)][string]$ExpectedThumbprint
    )

    if ($TrustPublishedCertificateForAuthenticode) {
        Import-PublicCertificateIfMissing -CertificatePath $CertificatePath -StoreName "Root" -Thumbprint $ExpectedThumbprint
        Import-PublicCertificateIfMissing -CertificatePath $CertificatePath -StoreName "TrustedPublisher" -Thumbprint $ExpectedThumbprint
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $DllPath
    if ($signature.Status -eq "NotSigned" -or $signature.Status -eq "HashMismatch") {
        throw "DLL Authenticode signature is broken: $($signature.Status) $($signature.StatusMessage)"
    }
    if ($null -eq $signature.SignerCertificate) {
        throw "DLL signer certificate was not available: $DllPath"
    }

    $signerThumbprint = ($signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    if ($signerThumbprint -ne $ExpectedThumbprint) {
        throw "DLL signer does not match published certificate: $signerThumbprint"
    }

    if ($TrustPublishedCertificateForAuthenticode -and $signature.Status -ne "Valid") {
        throw "DLL Authenticode signature is not valid after trust registration: $($signature.Status) $($signature.StatusMessage)"
    }

    return $signature
}

function Test-RuntimeIntegritySidecarFile {
    param(
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$SidecarPath,
        [Parameter(Mandatory = $true)][string]$ExpectedThumbprint
    )

    if ([string]::IsNullOrWhiteSpace($SidecarPath) -or -not (Test-Path -LiteralPath $SidecarPath)) {
        throw "Runtime integrity sidecar was not found: $SidecarPath"
    }

    $sidecar = Get-Content -LiteralPath $SidecarPath -Raw | ConvertFrom-Json
    if ($sidecar.format -ne "AvatarRecovery runtime integrity signature v1") {
        throw "Unsupported runtime integrity sidecar format: $SidecarPath"
    }
    if ($sidecar.algorithm -ne "RSA-SHA256-PKCS1") {
        throw "Unsupported runtime integrity sidecar algorithm: $SidecarPath"
    }

    $actualHash = (Get-FileHash -LiteralPath $DllPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $sidecar.targetSha256) {
        throw "Runtime integrity sidecar target hash mismatch: $SidecarPath"
    }

    $certificateBytes = [Convert]::FromBase64String($sidecar.signerCertificateBase64)
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateBytes)
    try {
        $certificateThumbprint = Normalize-Thumbprint $certificate.Thumbprint
        if ($certificateThumbprint -ne (Normalize-Thumbprint $sidecar.signerThumbprint)) {
            throw "Runtime integrity sidecar signer mismatch: $SidecarPath"
        }
        if ($certificateThumbprint -ne (Normalize-Thumbprint $ExpectedThumbprint)) {
            throw "Runtime integrity sidecar signer does not match published certificate: $certificateThumbprint"
        }

        $publicKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        if ($null -eq $publicKey) {
            throw "Runtime integrity public key was not available: $SidecarPath"
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
                throw "Runtime integrity sidecar signature verification failed: $SidecarPath"
            }
        }
        finally {
            $publicKey.Dispose()
        }
    }
    finally {
        $certificate.Dispose()
    }

    return [PSCustomObject]@{
        Status = "Passed"
        SidecarPath = $SidecarPath
        TargetSHA256 = $actualHash
        SignerThumbprint = $certificateThumbprint
    }
}

function Test-DllTamperDetection {
    param(
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$TamperedPath
    )

    Copy-Item -LiteralPath $DllPath -Destination $TamperedPath -Force
    $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $TamperedPath))
    if ($bytes.Length -lt 4) {
        throw "DLL is too small for tamper test: $DllPath"
    }

    $offset = [Math]::Floor($bytes.Length / 2)
    $bytes[$offset] = $bytes[$offset] -bxor 0x01
    [System.IO.File]::WriteAllBytes((ConvertTo-FullPath $TamperedPath), $bytes)

    $tamperedSignature = Get-AuthenticodeSignature -LiteralPath $TamperedPath
    if ($tamperedSignature.Status -eq "Valid") {
        throw "Tampered DLL signature unexpectedly stayed Valid: $TamperedPath"
    }

    return [PSCustomObject]@{
        Status = [string]$tamperedSignature.Status
        StatusMessage = $tamperedSignature.StatusMessage
        ModifiedOffset = $offset
    }
}

function Test-ZipTamperDetection {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$TamperedPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$ZipSignaturePath,
        [Parameter(Mandatory = $true)][string]$CertificatePath
    )

    Copy-Item -LiteralPath $ZipPath -Destination $TamperedPath -Force
    $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $TamperedPath))
    if ($bytes.Length -lt 4) {
        throw "ZIP is too small for tamper test: $ZipPath"
    }

    $offset = [Math]::Floor($bytes.Length / 2)
    $bytes[$offset] = $bytes[$offset] -bxor 0x01
    [System.IO.File]::WriteAllBytes((ConvertTo-FullPath $TamperedPath), $bytes)

    $tamperedHash = (Get-FileHash -LiteralPath $TamperedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($tamperedHash -eq $ExpectedSha256) {
        throw "Tampered ZIP unexpectedly kept the same SHA-256."
    }

    $signatureFailed = $false
    try {
        Test-DetachedSignatureFile -TargetPath $TamperedPath -SignaturePath $ZipSignaturePath -CertificatePath $CertificatePath
    }
    catch {
        $signatureFailed = $true
    }

    if (-not $signatureFailed) {
        throw "Tampered ZIP detached signature unexpectedly stayed valid."
    }

    return [PSCustomObject]@{
        Status = "HashMismatchAndSignatureRejected"
        ModifiedOffset = $offset
        TamperedSHA256 = $tamperedHash
    }
}

function Invoke-AuditOnce {
    $normalizedBaseUrl = $BaseUrl.TrimEnd("/")
    Remove-SafeAuditDirectory -Path $OutputRoot
    Ensure-Directory $OutputRoot

    $indexPath = Join-Path $OutputRoot "index.json"
    $indexSignaturePath = Join-Path $OutputRoot "index.json.sig"
    $zipPath = Join-Path $OutputRoot "$PackageId-$Version.zip"
    $zipSignaturePath = "$zipPath.sig"
    $checksumPath = Join-Path $OutputRoot "$PackageId-$Version.sha256.txt"
    $checksumSignaturePath = "$checksumPath.sig"
    $certificatePath = Join-Path $OutputRoot $CertificateFileName
    $certificatePemPath = Join-Path $OutputRoot $CertificatePemFileName

    Save-Url -Url "$normalizedBaseUrl/index.json" -Path $indexPath
    Save-Url -Url "$normalizedBaseUrl/index.json.sig" -Path $indexSignaturePath
    Save-Url -Url "$normalizedBaseUrl/packages/$PackageId-$Version.zip" -Path $zipPath
    Save-Url -Url "$normalizedBaseUrl/packages/$PackageId-$Version.zip.sig" -Path $zipSignaturePath
    Save-Url -Url "$normalizedBaseUrl/checksums/$PackageId-$Version.sha256.txt" -Path $checksumPath
    Save-Url -Url "$normalizedBaseUrl/checksums/$PackageId-$Version.sha256.txt.sig" -Path $checksumSignaturePath
    Save-Url -Url "$normalizedBaseUrl/certificates/$CertificateFileName" -Path $certificatePath
    Save-Url -Url "$normalizedBaseUrl/certificates/$CertificatePemFileName" -Path $certificatePemPath

    Test-DownloadedPublicFiles -Paths @(
        $indexPath,
        $indexSignaturePath,
        $zipPath,
        $zipSignaturePath,
        $checksumPath,
        $checksumSignaturePath,
        $certificatePath,
        $certificatePemPath
    )

    $expectedCertificateThumbprint = Get-ExpectedCodeSigningCertificateThumbprint
    $certificateThumbprint = Get-CertificateThumbprintFromFile -Path $certificatePath
    if ($certificateThumbprint -ne $expectedCertificateThumbprint) {
        throw "Published certificate thumbprint mismatch. Expected $expectedCertificateThumbprint but got $certificateThumbprint."
    }

    Test-DetachedSignatureFile -TargetPath $indexPath -SignaturePath $indexSignaturePath -CertificatePath $certificatePath
    Test-DetachedSignatureFile -TargetPath $zipPath -SignaturePath $zipSignaturePath -CertificatePath $certificatePath
    Test-DetachedSignatureFile -TargetPath $checksumPath -SignaturePath $checksumSignaturePath -CertificatePath $certificatePath

    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
    $packageEntry = $index.packages.PSObject.Properties[$PackageId].Value
    if ($null -eq $packageEntry) {
        throw "Package id was not found in index.json: $PackageId"
    }

    $versions = @($packageEntry.versions.PSObject.Properties.Name)
    if ($versions.Count -ne 1 -or $versions[0] -ne $Version) {
        throw "Unexpected published versions: $($versions -join ', ')"
    }

    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($packageEntry.versions.$Version.zipSHA256 -ne $zipHash) {
        throw "index.json zipSHA256 mismatch."
    }

    $certificateHash = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $certificatePemHash = (Get-FileHash -LiteralPath $certificatePemPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumText = Get-Content -LiteralPath $checksumPath -Raw
    foreach ($requiredHash in @($zipHash, $certificateHash, $certificatePemHash)) {
        if ($checksumText -notmatch [regex]::Escape($requiredHash)) {
            throw "Checksum manifest does not include expected hash: $requiredHash"
        }
    }

    $extractRoot = Join-Path $OutputRoot "zip"
    $dllPath = Test-ZipPackage -ZipPath $zipPath -ExtractRoot $extractRoot
    $dllHash = (Get-FileHash -LiteralPath $dllPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($checksumText -notmatch [regex]::Escape($dllHash)) {
        throw "Checksum manifest does not include DLL hash."
    }

    Test-BinaryLeak -Path $dllPath -ForbiddenSignerThumbprint $certificateThumbprint

    $signature = Test-DllAuthenticodeIdentity `
        -DllPath $dllPath `
        -CertificatePath $certificatePath `
        -ExpectedThumbprint $certificateThumbprint
    $signerThumbprint = ($signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    $runtimeIntegrityResult = Test-RuntimeIntegritySidecarFile `
        -DllPath $dllPath `
        -SidecarPath (Join-Path $extractRoot $RuntimeIntegritySidecarFileName) `
        -ExpectedThumbprint $certificateThumbprint
    $tamperResult = Test-DllTamperDetection `
        -DllPath $dllPath `
        -TamperedPath (Join-Path $OutputRoot "tampered-$AssemblyFileName")
    $zipTamperResult = Test-ZipTamperDetection `
        -ZipPath $zipPath `
        -TamperedPath (Join-Path $OutputRoot "tampered-$PackageId-$Version.zip") `
        -ExpectedSha256 $zipHash `
        -ZipSignaturePath $zipSignaturePath `
        -CertificatePath $certificatePath

    $ilspyResult = Test-IlSpyOutput -DllPath $dllPath -OutputPath (Join-Path $OutputRoot "ilspy")

    $report = [PSCustomObject]@{
        Version = $Version
        BaseUrl = $normalizedBaseUrl
        ZipSHA256 = $zipHash
        CertificateSHA256 = $certificateHash
        ExpectedCertificateThumbprint = $expectedCertificateThumbprint
        DetachedSignatures = "Valid"
        DllAuthenticode = [string]$signature.Status
        DllAuthenticodeTrustMode = if ($TrustPublishedCertificateForAuthenticode) { "TrustedStoreRequired" } else { "ThumbprintOnlyAcceptedWhenUntrusted" }
        DllSignerThumbprint = $signerThumbprint
        RuntimeIntegritySidecar = $runtimeIntegrityResult
        TamperedDllAuthenticode = $tamperResult
        TamperedZip = $zipTamperResult
        IlSpy = $ilspyResult
        ReportPath = Join-Path $OutputRoot "published-audit-$Version.json"
    }

    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $report.ReportPath -Encoding UTF8
    return $report
}

$lastError = $null
for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
    try {
        $report = Invoke-AuditOnce
        Write-Host "Published release audit passed."
        $report | Format-List
        exit 0
    }
    catch {
        $lastError = $_
        if ($attempt -ge $RetryCount) {
            break
        }

        Write-Warning "Published release audit attempt $attempt failed: $($_.Exception.Message)"
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

throw $lastError
