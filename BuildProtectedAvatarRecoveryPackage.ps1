param(
    [string]$Version = "1.1.5",
    [string]$PreviousVersion = "1.1.4",
    [string]$PackageId = "com.nickel-jp.avatar-recovery",
    [string]$BaseUrl = "https://nickel-jp.github.io/avatar-recovery-unity",
    [string]$UnityExe = "C:\Program Files\Unity\Hub\Editor\2022.3.22f1\Editor\Unity.exe",
    [string]$BackupRoot = "",
    [string]$ObfuscarToolVersion = "2.2.50",
    [string]$ObfuscarExe = "",
    [string]$SignToolExe = "",
    [string]$CodeSigningCertificateThumbprint = $env:AVATAR_RECOVERY_CODE_SIGNING_THUMBPRINT,
    [string]$CodeSigningCertificatePath = $env:AVATAR_RECOVERY_CODE_SIGNING_CERT_PATH,
    [string]$CodeSigningCertificatePasswordEnv = "AVATAR_RECOVERY_CODE_SIGNING_PASSWORD",
    [ValidateSet("CurrentUser", "LocalMachine")]
    [string]$CodeSigningCertificateStoreLocation = "CurrentUser",
    [string]$CodeSigningCertificateStoreName = "My",
    [string]$TimestampUrl = "http://timestamp.digicert.com",
    [switch]$DisableSelfSignedCertificate,
    [switch]$SkipUnityCompile,
    [switch]$AllowUnsignedPackage
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
    $Global:PSNativeCommandUseErrorActionPreference = $false
}

$RepoRoot = $PSScriptRoot
$WorkRoot = Join-Path $RepoRoot ".work"
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $envBackupRoot = [Environment]::GetEnvironmentVariable("AVATAR_RECOVERY_BACKUP_ROOT")
    $BackupRoot = if ([string]::IsNullOrWhiteSpace($envBackupRoot)) {
        Join-Path $WorkRoot "BackupsPrivate"
    } else {
        $envBackupRoot
    }
}
$ReleaseRoot = Join-Path $WorkRoot "Release$($Version.Replace('.', ''))"
$SourcePackageRoot = Join-Path $ReleaseRoot "SourcePackage\$PackageId"
$ProjectRoot = Join-Path $ReleaseRoot "ProjectRoot"
$ProjectPackageRoot = Join-Path $ProjectRoot "Packages\$PackageId"
$CompileProjectRoot = Join-Path $WorkRoot "UnityCompile$($Version.Replace('.', ''))"
$ProtectionRoot = Join-Path $WorkRoot "Protection$($Version.Replace('.', ''))"
$PrivateBackupRoot = Join-Path $BackupRoot "$Version-protection-private"
$LocalPrivateBackupRoot = Join-Path $WorkRoot "Backups\$Version-protection-private"
$AssemblyName = "EditorTools.AvatarRecovery.Editor"
$AssemblyFileName = "$AssemblyName.dll"
$SelfSignedCertificateSubject = "CN=Nickel-JP AvatarRecovery Self-Signed Code Signing"
$UnityMagicMethods = @(
    "OnGUI",
    "OnEnable",
    "OnDisable",
    "OnDestroy",
    "OnFocus",
    "OnLostFocus",
    "OnHierarchyChange",
    "OnProjectChange",
    "OnSelectionChange",
    "OnInspectorUpdate",
    "CreateGUI",
    "Update",
    "Awake",
    "OnValidate",
    "Reset"
)
$ReflectionPatterns = @(
    "typeof\s*\(",
    "\.GetType\s*\(",
    "Type\.GetType\s*\(",
    "\.GetMethod\s*\(",
    "\.GetProperty\s*\(",
    "\.GetField\s*\(",
    "\.Invoke\s*\(",
    "Activator\.CreateInstance\s*\(",
    "Assembly\.GetTypes\s*\(",
    "TypeCache\."
)
$script:CodeSigningMode = "Configured"

function ConvertTo-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
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

function Remove-SafeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    Assert-UnderPath -Path $Path -ParentPath $WorkRoot
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Write-TextUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
}

function Install-ObfuscarIfNeeded {
    if (-not [string]::IsNullOrWhiteSpace($ObfuscarExe)) {
        if (-not (Test-Path $ObfuscarExe)) {
            throw "Obfuscar executable was not found: $ObfuscarExe"
        }
        return (ConvertTo-FullPath $ObfuscarExe)
    }

    $toolPath = Join-Path $WorkRoot "tools\obfuscar"
    $exePath = Join-Path $toolPath "obfuscar.console.exe"
    if (-not (Test-Path $exePath)) {
        Ensure-Directory $toolPath
        & dotnet tool install obfuscar.globaltool --version $ObfuscarToolVersion --tool-path $toolPath
        if ($LASTEXITCODE -ne 0) {
            throw "Obfuscar のインストールに失敗しました。"
        }
    }

    return (ConvertTo-FullPath $exePath)
}

function Resolve-SignTool {
    if (-not [string]::IsNullOrWhiteSpace($SignToolExe)) {
        if (-not (Test-Path $SignToolExe)) {
            throw "SignTool executable was not found: $SignToolExe"
        }
        return (ConvertTo-FullPath $SignToolExe)
    }

    $candidatePatterns = @(
        (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin\*\x64\signtool.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\App Certification Kit\signtool.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft SDKs\ClickOnce\SignTool\signtool.exe")
    )

    foreach ($pattern in $candidatePatterns) {
        $candidate = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($null -ne $candidate) {
            return (ConvertTo-FullPath $candidate.FullName)
        }
    }

    throw "SignTool executable was not found. Install Windows SDK or pass -SignToolExe."
}

function Get-CodeSigningPassword {
    if ([string]::IsNullOrWhiteSpace($CodeSigningCertificatePasswordEnv)) {
        return ""
    }

    $password = [Environment]::GetEnvironmentVariable($CodeSigningCertificatePasswordEnv)
    if ($null -eq $password) {
        return ""
    }

    return $password
}

function Assert-CertificatePathIsPrivate {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = ConvertTo-FullPath $Path
    $repoRoot = (ConvertTo-FullPath $RepoRoot).TrimEnd('\') + '\'
    $privateRoot = (ConvertTo-FullPath (Join-Path $WorkRoot "BackupsPrivate")).TrimEnd('\') + '\'
    if ($fullPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.StartsWith($privateRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Code signing certificate must not be stored in the public repository tree: $fullPath"
    }
}

function Test-CertificateHasCodeSigningUsage {
    param([Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    foreach ($extension in $Certificate.Extensions) {
        if ($extension.Oid.Value -ne "2.5.29.37") {
            continue
        }

        $eku = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$extension
        foreach ($usage in $eku.EnhancedKeyUsages) {
            if ($usage.Value -eq "1.3.6.1.5.5.7.3.3") {
                return $true
            }
        }

        return $false
    }

    return $true
}

function Get-PublicCertificatePath {
    $certificateDir = Join-Path $RepoRoot "certificates"
    Ensure-Directory $certificateDir
    return (Join-Path $certificateDir "avatar-recovery-self-signed-code-signing.cer")
}

function Get-PublicCertificatePemPath {
    $certificateDir = Join-Path $RepoRoot "certificates"
    Ensure-Directory $certificateDir
    return (Join-Path $certificateDir "avatar-recovery-self-signed-code-signing.cer.pem")
}

function Write-CertificatePem {
    param(
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $base64 = [Convert]::ToBase64String($Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine("-----BEGIN CERTIFICATE-----")
    for ($index = 0; $index -lt $base64.Length; $index += 64) {
        $length = [Math]::Min(64, $base64.Length - $index)
        [void]$builder.AppendLine($base64.Substring($index, $length))
    }
    [void]$builder.AppendLine("-----END CERTIFICATE-----")

    Write-TextUtf8NoBom -Path $Path -Value $builder.ToString()
}

function Get-ExistingSelfSignedCodeSigningCertificate {
    $minimumExpiry = (Get-Date).AddMonths(3)
    Get-ChildItem -Path "Cert:\CurrentUser\My" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Subject -eq $SelfSignedCertificateSubject -and
            $_.HasPrivateKey -and
            $_.NotAfter -gt $minimumExpiry -and
            (Test-CertificateHasCodeSigningUsage -Certificate $_)
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
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

function Ensure-SelfSignedCodeSigningCertificate {
    $certificate = Get-ExistingSelfSignedCodeSigningCertificate
    if ($null -eq $certificate) {
        Write-Host "Creating AvatarRecovery self-signed code signing certificate."
        $certificate = New-SelfSignedCertificate `
            -Type CodeSigningCert `
            -Subject $SelfSignedCertificateSubject `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -KeyAlgorithm RSA `
            -KeyLength 3072 `
            -HashAlgorithm SHA256 `
            -KeyExportPolicy NonExportable `
            -NotAfter (Get-Date).AddYears(5)
    }

    if ($null -eq $certificate -or -not $certificate.HasPrivateKey) {
        throw "Self-signed code signing certificate could not be created."
    }

    $thumbprint = ($certificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    $publicCertificatePath = Get-PublicCertificatePath
    Export-Certificate -Cert $certificate -FilePath $publicCertificatePath -Force | Out-Null
    Write-CertificatePem -Certificate $certificate -Path (Get-PublicCertificatePemPath)

    # CurrentUser のみへ登録し、ビルド時の Authenticode 検証を Valid にする。
    Import-PublicCertificateIfMissing -CertificatePath $publicCertificatePath -StoreName "Root" -Thumbprint $thumbprint
    Import-PublicCertificateIfMissing -CertificatePath $publicCertificatePath -StoreName "TrustedPublisher" -Thumbprint $thumbprint

    $script:CodeSigningMode = "SelfSigned"
    return $thumbprint
}

function Get-ConfiguredCertificateThumbprint {
    if (-not [string]::IsNullOrWhiteSpace($CodeSigningCertificatePath)) {
        $script:CodeSigningMode = "CertificateFile"
        if (-not (Test-Path $CodeSigningCertificatePath)) {
            throw "Code signing certificate file was not found: $CodeSigningCertificatePath"
        }

        Assert-CertificatePathIsPrivate -Path $CodeSigningCertificatePath
        $password = Get-CodeSigningPassword
        try {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                (ConvertTo-FullPath $CodeSigningCertificatePath),
                $password)
        }
        catch {
            throw "Code signing certificate file could not be opened. Check $CodeSigningCertificatePasswordEnv."
        }

        if (-not $cert.HasPrivateKey) {
            throw "Code signing certificate file does not include a private key."
        }
        if (-not (Test-CertificateHasCodeSigningUsage -Certificate $cert)) {
            throw "Certificate is not valid for code signing."
        }

        return $cert.Thumbprint
    }

    if ([string]::IsNullOrWhiteSpace($CodeSigningCertificateThumbprint)) {
        if (-not $DisableSelfSignedCertificate) {
            return (Ensure-SelfSignedCodeSigningCertificate)
        }

        throw "Code signing is required. Set -CodeSigningCertificateThumbprint or -CodeSigningCertificatePath, or set AVATAR_RECOVERY_CODE_SIGNING_THUMBPRINT / AVATAR_RECOVERY_CODE_SIGNING_CERT_PATH."
    }

    $script:CodeSigningMode = "CertificateStore"
    $thumbprint = ($CodeSigningCertificateThumbprint -replace '\s', '').ToUpperInvariant()
    $certPath = "Cert:\$CodeSigningCertificateStoreLocation\$CodeSigningCertificateStoreName\$thumbprint"
    $cert = Get-Item -LiteralPath $certPath -ErrorAction SilentlyContinue
    if ($null -eq $cert) {
        throw "Code signing certificate was not found in ${CodeSigningCertificateStoreLocation}\${CodeSigningCertificateStoreName}: $thumbprint"
    }
    if (-not $cert.HasPrivateKey) {
        throw "Code signing certificate does not have a private key: $thumbprint"
    }
    if (-not (Test-CertificateHasCodeSigningUsage -Certificate $cert)) {
        throw "Certificate is not valid for code signing: $thumbprint"
    }

    return $thumbprint
}

function Get-CodeSigningContext {
    if ($AllowUnsignedPackage) {
        Write-Warning "Unsigned package build is explicitly allowed. Do not publish this build."
        return [PSCustomObject]@{
            Required = $false
            SignTool = ""
            ExpectedThumbprint = ""
            Mode = "Unsigned"
        }
    }

    $signTool = Resolve-SignTool
    $expectedThumbprint = Get-ConfiguredCertificateThumbprint

    return [PSCustomObject]@{
        Required = $true
        SignTool = $signTool
        ExpectedThumbprint = $expectedThumbprint
        Mode = $script:CodeSigningMode
    }
}

function Invoke-CodeSign {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Context
    )

    if (-not $Context.Required) {
        return
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    [void]$arguments.Add("sign")
    [void]$arguments.Add("/fd")
    [void]$arguments.Add("SHA256")
    [void]$arguments.Add("/v")

    if (-not [string]::IsNullOrWhiteSpace($TimestampUrl)) {
        [void]$arguments.Add("/tr")
        [void]$arguments.Add($TimestampUrl)
        [void]$arguments.Add("/td")
        [void]$arguments.Add("SHA256")
    }

    if (-not [string]::IsNullOrWhiteSpace($CodeSigningCertificatePath)) {
        [void]$arguments.Add("/f")
        [void]$arguments.Add((ConvertTo-FullPath $CodeSigningCertificatePath))
        $password = Get-CodeSigningPassword
        if (-not [string]::IsNullOrEmpty($password)) {
            [void]$arguments.Add("/p")
            [void]$arguments.Add($password)
        }
    }
    else {
        [void]$arguments.Add("/s")
        [void]$arguments.Add($CodeSigningCertificateStoreName)
        if ($CodeSigningCertificateStoreLocation -eq "LocalMachine") {
            [void]$arguments.Add("/sm")
        }
        [void]$arguments.Add("/sha1")
        [void]$arguments.Add($Context.ExpectedThumbprint)
    }

    [void]$arguments.Add((ConvertTo-FullPath $Path))

    & $Context.SignTool @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Authenticode signing failed for: $Path"
    }
}

function Test-CodeSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Context
    )

    if (-not $Context.Required) {
        return
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne "Valid") {
        throw "Authenticode signature is not valid for ${Path}: $($signature.Status) $($signature.StatusMessage)"
    }

    if ($null -eq $signature.SignerCertificate) {
        throw "Authenticode signer certificate was not found for: $Path"
    }

    $actualThumbprint = ($signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    if ($actualThumbprint -ne $Context.ExpectedThumbprint) {
        throw "Unexpected signer certificate for ${Path}: $actualThumbprint"
    }
}

function Save-CodeSignatureReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ReportName,
        [Parameter(Mandatory = $true)]$Context
    )

    if (-not $Context.Required) {
        return
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $report = [PSCustomObject]@{
        Path = ConvertTo-FullPath $Path
        Status = [string]$signature.Status
        StatusMessage = $signature.StatusMessage
        SigningMode = $Context.Mode
        SignerSubject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { "" }
        SignerThumbprint = if ($signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { "" }
        TimeStamperSubject = if ($signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Subject } else { "" }
        TimeStamperThumbprint = if ($signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Thumbprint } else { "" }
    }

    $reportPath = Join-Path $PrivateBackupRoot $ReportName
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Copy-Item -LiteralPath $reportPath -Destination $LocalPrivateBackupRoot -Force
}

function Get-CodeSigningCertificateFromContext {
    param([Parameter(Mandatory = $true)]$Context)

    if (-not $Context.Required) {
        return $null
    }

    if ($Context.Mode -eq "CertificateFile") {
        $password = Get-CodeSigningPassword
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            (ConvertTo-FullPath $CodeSigningCertificatePath),
            $password)
    }

    $thumbprint = ($Context.ExpectedThumbprint -replace '\s', '').ToUpperInvariant()
    $certPath = "Cert:\$CodeSigningCertificateStoreLocation\$CodeSigningCertificateStoreName\$thumbprint"
    $certificate = Get-Item -LiteralPath $certPath -ErrorAction SilentlyContinue
    if ($null -eq $certificate) {
        throw "Code signing certificate was not found for detached signatures: $thumbprint"
    }

    return $certificate
}

function Test-DetachedSignatureFile {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$SignaturePath,
        [Parameter(Mandatory = $true)][string]$CertificatePath
    )

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        throw "Detached signature target was not found: $TargetPath"
    }
    if (-not (Test-Path -LiteralPath $SignaturePath)) {
        throw "Detached signature file was not found: $SignaturePath"
    }
    if (-not (Test-Path -LiteralPath $CertificatePath)) {
        throw "Detached signature certificate was not found: $CertificatePath"
    }

    $signature = Get-Content -LiteralPath $SignaturePath -Raw | ConvertFrom-Json
    if ($signature.format -ne "AvatarRecovery detached signature v1") {
        throw "Unsupported detached signature format: $SignaturePath"
    }
    if ($signature.algorithm -ne "RSA-SHA256-PKCS1") {
        throw "Unsupported detached signature algorithm: $SignaturePath"
    }

    $actualHash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $signature.targetSha256) {
        throw "Detached signature target hash mismatch: $TargetPath"
    }

    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((ConvertTo-FullPath $CertificatePath))
    $actualThumbprint = ($certificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    if ($actualThumbprint -ne (($signature.signerThumbprint -replace '\s', '').ToUpperInvariant())) {
        throw "Detached signature certificate mismatch: $SignaturePath"
    }

    $publicKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
    if ($null -eq $publicKey) {
        throw "Detached signature public key was not available: $CertificatePath"
    }

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

function Write-DetachedSignatureFile {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$SignaturePath,
        [Parameter(Mandatory = $true)][string]$TargetRelativePath,
        [Parameter(Mandatory = $true)]$Context
    )

    if (-not $Context.Required) {
        return
    }

    $certificate = Get-CodeSigningCertificateFromContext -Context $Context
    if ($null -eq $certificate -or -not $certificate.HasPrivateKey) {
        throw "Detached signature certificate does not have a private key."
    }

    Write-CertificatePem -Certificate $certificate -Path (Get-PublicCertificatePemPath)
    $publicCertificatePath = Get-PublicCertificatePath
    if (-not (Test-Path -LiteralPath $publicCertificatePath)) {
        Export-Certificate -Cert $certificate -FilePath $publicCertificatePath -Force | Out-Null
    }

    $privateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    if ($null -eq $privateKey) {
        throw "Detached signature private key was not available."
    }

    $targetBytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $TargetPath))
    $signatureBytes = $privateKey.SignData(
        $targetBytes,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $targetHash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $signature = [ordered]@{
        format = "AvatarRecovery detached signature v1"
        algorithm = "RSA-SHA256-PKCS1"
        signedAtUtc = [DateTime]::UtcNow.ToString("o")
        target = $TargetRelativePath
        targetSha256 = $targetHash
        signerCertificate = "certificates/avatar-recovery-self-signed-code-signing.cer"
        signerCertificatePem = "certificates/avatar-recovery-self-signed-code-signing.cer.pem"
        signerThumbprint = (($certificate.Thumbprint -replace '\s', '').ToUpperInvariant())
        signatureBase64 = [Convert]::ToBase64String($signatureBytes)
    }

    Write-TextUtf8NoBom -Path $SignaturePath -Value (($signature | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    Test-DetachedSignatureFile -TargetPath $TargetPath -SignaturePath $SignaturePath -CertificatePath $publicCertificatePath
    Write-Host "Created detached signature: $SignaturePath"
}

function Write-PublicDetachedSignatures {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$ChecksumPath,
        [Parameter(Mandatory = $true)][string]$IndexPath,
        [Parameter(Mandatory = $true)]$Context
    )

    if (-not $Context.Required) {
        return
    }

    Write-DetachedSignatureFile `
        -TargetPath $ZipPath `
        -SignaturePath "$ZipPath.sig" `
        -TargetRelativePath "packages/$PackageId-$Version.zip" `
        -Context $Context

    Write-DetachedSignatureFile `
        -TargetPath $ChecksumPath `
        -SignaturePath "$ChecksumPath.sig" `
        -TargetRelativePath "checksums/$PackageId-$Version.sha256.txt" `
        -Context $Context

    Write-DetachedSignatureFile `
        -TargetPath $IndexPath `
        -SignaturePath "$IndexPath.sig" `
        -TargetRelativePath "index.json" `
        -Context $Context
}

function Write-PublicChecksumManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)]$Context
    )

    $checksumsDir = Join-Path $RepoRoot "checksums"
    Ensure-Directory $checksumsDir
    $manifestPath = Join-Path $checksumsDir "$PackageId-$Version.sha256.txt"

    $zipRelativePath = "packages/$PackageId-$Version.zip"
    $dllRelativePath = "packages/$PackageId-$Version.zip!/Editor/$AssemblyFileName"
    $zipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $dllHash = (Get-FileHash -LiteralPath $DllPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $signature = Get-AuthenticodeSignature -LiteralPath $DllPath

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# AvatarRecovery $Version public checksums")
    [void]$lines.Add("# GeneratedAtUtc: $([DateTime]::UtcNow.ToString("o"))")
    [void]$lines.Add("# PackageId: $PackageId")
    [void]$lines.Add("# SigningMode: $($Context.Mode)")
    [void]$lines.Add("# SignerSubject: $($signature.SignerCertificate.Subject)")
    [void]$lines.Add("# SignerThumbprint: $(($signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant())")
    [void]$lines.Add("# SignatureStatus: $($signature.Status)")

    if ($Context.Mode -eq "SelfSigned") {
        $publicCertificatePath = Get-PublicCertificatePath
        $certificateRelativePath = "certificates/avatar-recovery-self-signed-code-signing.cer"
        $certificateHash = (Get-FileHash -LiteralPath $publicCertificatePath -Algorithm SHA256).Hash.ToLowerInvariant()
        [void]$lines.Add("$certificateHash  $certificateRelativePath")

        $publicCertificatePemPath = Get-PublicCertificatePemPath
        if (Test-Path -LiteralPath $publicCertificatePemPath) {
            $certificatePemRelativePath = "certificates/avatar-recovery-self-signed-code-signing.cer.pem"
            $certificatePemHash = (Get-FileHash -LiteralPath $publicCertificatePemPath -Algorithm SHA256).Hash.ToLowerInvariant()
            [void]$lines.Add("$certificatePemHash  $certificatePemRelativePath")
        }
    }

    [void]$lines.Add("$zipHash  $zipRelativePath")
    [void]$lines.Add("$dllHash  $dllRelativePath")

    Write-TextUtf8NoBom -Path $manifestPath -Value (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    Write-Host "Created public checksum manifest: $manifestPath"
}

function Get-XmlEscaped {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return [System.Security.SecurityElement]::Escape($Value)
}

function Get-SourceScan {
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    $sourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Filter "*.cs" -File
    $attributeMethods = New-Object System.Collections.Generic.List[object]
    $vrcSdkCallbackTypes = New-Object System.Collections.Generic.List[string]
    $editorWindowTypes = New-Object System.Collections.Generic.List[string]
    $enumTypes = New-Object System.Collections.Generic.List[string]
    $unityMessageHits = New-Object System.Collections.Generic.List[object]
    $reflectionHits = New-Object System.Collections.Generic.List[object]
    $editorPrefsHits = New-Object System.Collections.Generic.List[object]
    $serializedObjectHits = New-Object System.Collections.Generic.List[object]
    $enumToStringHits = New-Object System.Collections.Generic.List[object]

    foreach ($file in $sourceFiles) {
        $lines = Get-Content -LiteralPath $file.FullName
        $namespace = "EditorTools.AvatarRecovery"
        $currentType = $null
        $pendingAttributes = New-Object System.Collections.Generic.List[string]

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $lineNumber = $i + 1

            if ($line -match '^\s*namespace\s+([A-Za-z0-9_.]+)') {
                $namespace = $Matches[1]
            }

            if ($line -match '\b(class|struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)') {
                $typeKind = $Matches[1]
                $typeName = "$namespace.$($Matches[2])"
                if ($typeKind -eq "enum") {
                    [void]$enumTypes.Add($typeName)
                    continue
                }

                $currentType = $typeName
                if ($line -match '\bEditorWindow\b') {
                    [void]$editorWindowTypes.Add($typeName)
                }

                if ($line -match 'IVRCSDK[A-Za-z0-9_]*Callback') {
                    [void]$vrcSdkCallbackTypes.Add($typeName)
                }
            }

            if ($line -match '^\s*\[[^\]]+\]') {
                [void]$pendingAttributes.Add($line.Trim())
                continue
            }

            $methodMatch = [regex]::Match(
                $line,
                '^\s*(?:public|private|internal|protected|static|sealed|override|virtual|new|async|\s)+\s+(?:[A-Za-z_][A-Za-z0-9_<>,\[\].?\s]*\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(')
            if ($methodMatch.Success) {
                $methodName = $methodMatch.Groups[1].Value
                if ($UnityMagicMethods -contains $methodName) {
                    [void]$unityMessageHits.Add([PSCustomObject]@{
                        File = $file.FullName
                        Line = $lineNumber
                        Type = $currentType
                        Method = $methodName
                    })
                }

                if ($pendingAttributes.Count -gt 0 -and $currentType) {
                    [void]$attributeMethods.Add([PSCustomObject]@{
                        File = $file.FullName
                        Line = $lineNumber
                        Type = $currentType
                        Method = $methodName
                        Attributes = @($pendingAttributes)
                    })
                }
            }

            foreach ($pattern in $ReflectionPatterns) {
                if ($line -match $pattern) {
                    [void]$reflectionHits.Add([PSCustomObject]@{
                        File = $file.FullName
                        Line = $lineNumber
                        Pattern = $pattern
                        Text = $line.Trim()
                    })
                    break
                }
            }

            if ($line -match '\bEditorPrefs\b|EditorPrefsHelper') {
                [void]$editorPrefsHits.Add([PSCustomObject]@{
                    File = $file.FullName
                    Line = $lineNumber
                    Text = $line.Trim()
                })
            }

            if ($line -match '\bSerializedObject\b|\bScriptableObject\b|\bSerializedProperty\b') {
                [void]$serializedObjectHits.Add([PSCustomObject]@{
                    File = $file.FullName
                    Line = $lineNumber
                    Text = $line.Trim()
                })
            }

            if ($line -match '\.ToString\s*\(') {
                [void]$enumToStringHits.Add([PSCustomObject]@{
                    File = $file.FullName
                    Line = $lineNumber
                    Text = $line.Trim()
                })
            }

            if ($line.Trim().Length -gt 0 -and -not ($line -match '^\s*\[[^\]]+\]')) {
                $pendingAttributes.Clear()
            }
        }
    }

    return [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToString("o")
        SourceRoot = (ConvertTo-FullPath $SourceRoot)
        UnityMagicMethods = @($unityMessageHits.ToArray())
        AttributeMethods = @($attributeMethods.ToArray())
        VrcSdkCallbackTypes = @($vrcSdkCallbackTypes | Sort-Object -Unique)
        EditorWindowTypes = @($editorWindowTypes | Sort-Object -Unique)
        EnumTypes = @($enumTypes | Sort-Object -Unique)
        ReflectionHits = @($reflectionHits.ToArray())
        EditorPrefsHits = @($editorPrefsHits.ToArray())
        SerializedObjectHits = @($serializedObjectHits.ToArray())
        EnumToStringHits = @($enumToStringHits.ToArray())
    }
}

function Get-AssemblySearchPaths {
    param([Parameter(Mandatory = $true)][string]$UnityProjectRoot)

    $paths = New-Object System.Collections.Generic.List[string]
    $unityManaged = Join-Path (Split-Path -Parent $UnityExe) "Data\Managed"
    foreach ($path in @(
        (Join-Path $UnityProjectRoot "Library\ScriptAssemblies"),
        $unityManaged,
        (Join-Path $unityManaged "UnityEngine"),
        (Join-Path $unityManaged "UnityEditor")
    )) {
        if (Test-Path $path) {
            [void]$paths.Add((ConvertTo-FullPath $path))
        }
    }

    $packagesPath = Join-Path $UnityProjectRoot "Packages"
    if (Test-Path $packagesPath) {
        Get-ChildItem -LiteralPath $packagesPath -Recurse -Filter "*.dll" -File |
            Select-Object -ExpandProperty DirectoryName -Unique |
            ForEach-Object {
                [void]$paths.Add((ConvertTo-FullPath $_))
            }
    }

    return @($paths | Sort-Object -Unique)
}

function New-ObfuscarConfig {
    param(
        [Parameter(Mandatory = $true)][string]$InputDll,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][object]$Scan,
        [Parameter(Mandatory = $true)][string[]]$AssemblySearchPaths,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('<?xml version="1.0" encoding="utf-8" ?>')
    [void]$lines.Add('<Obfuscator>')
    [void]$lines.Add("  <Var name=""InPath"" value=""$(Get-XmlEscaped (Split-Path -Parent $InputDll))"" />")
    [void]$lines.Add("  <Var name=""OutPath"" value=""$(Get-XmlEscaped $OutputDir)"" />")
    [void]$lines.Add('  <Var name="KeepPublicApi" value="true" />')
    [void]$lines.Add('  <Var name="HidePrivateApi" value="true" />')
    [void]$lines.Add('  <Var name="HideStrings" value="false" />')
    [void]$lines.Add('  <Var name="RenameProperties" value="false" />')
    [void]$lines.Add('  <Var name="RenameEvents" value="false" />')
    [void]$lines.Add('  <Var name="ReuseNames" value="true" />')
    [void]$lines.Add('  <Var name="UseUnicodeNames" value="false" />')
    [void]$lines.Add('  <Var name="SuppressIldasm" value="true" />')

    foreach ($path in $AssemblySearchPaths) {
        [void]$lines.Add("  <AssemblySearchPath path=""$(Get-XmlEscaped $path)"" />")
    }

    [void]$lines.Add("  <Module file=""$(Get-XmlEscaped $InputDll)"">")

    foreach ($method in $UnityMagicMethods) {
        [void]$lines.Add("    <SkipMethod type=""*"" name=""$(Get-XmlEscaped $method)"" />")
    }

    foreach ($method in $Scan.AttributeMethods) {
        $typeName = if ([string]::IsNullOrWhiteSpace($method.Type)) { "*" } else { $method.Type }
        [void]$lines.Add("    <SkipMethod type=""$(Get-XmlEscaped $typeName)"" name=""$(Get-XmlEscaped $method.Method)"" />")
    }

    foreach ($typeName in $Scan.EditorWindowTypes) {
        [void]$lines.Add("    <SkipType name=""$(Get-XmlEscaped $typeName)"" />")
    }

    foreach ($typeName in $Scan.VrcSdkCallbackTypes) {
        [void]$lines.Add("    <SkipType name=""$(Get-XmlEscaped $typeName)"" skipMethods=""true"" skipProperties=""true"" skipFields=""true"" skipEvents=""true"" />")
    }

    foreach ($typeName in $Scan.EnumTypes) {
        [void]$lines.Add("    <SkipType name=""$(Get-XmlEscaped $typeName)"" skipFields=""true"" />")
    }

    [void]$lines.Add('  </Module>')
    [void]$lines.Add('</Obfuscator>')

    Set-Content -LiteralPath $ConfigPath -Value $lines -Encoding UTF8
}

function Test-BinaryLeak {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowDocumentNames
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)

    $problems = New-Object System.Collections.Generic.List[string]
    $userName = [Environment]::UserName
    $checks = @(
        @{ Name = "current user name"; Pattern = $userName },
        @{ Name = "repo source path"; Pattern = "\Packages\com.nickel-jp.avatar-recovery\Editor\" },
        @{ Name = "VrcaExtractor.cs"; Pattern = "VrcaExtractor.cs" }
    )

    foreach ($check in $checks) {
        if ($ascii.Contains($check.Pattern) -or $unicode.Contains($check.Pattern)) {
            [void]$problems.Add($check.Name)
        }
    }

    if (-not $AllowDocumentNames) {
        if ($ascii -match '\\Packages\\com\.nickel-jp\.avatar-recovery\\Editor\\[^\x00-\x1F]+?\.cs' -or
            $unicode -match '\\Packages\\com\.nickel-jp\.avatar-recovery\\Editor\\[^\x00-\x1F]+?\.cs') {
            [void]$problems.Add("source document path")
        }
    }

    if ($problems.Count -gt 0) {
        throw "DLL leak check failed for ${Path}: $($problems -join ', ')"
    }
}

function ConvertTo-SafeDocumentName {
    param(
        [Parameter(Mandatory = $true)][string]$Original,
        [Parameter(Mandatory = $true)][int]$Length
    )

    $name = $Original -replace '^\\Packages\\com\.nickel-jp\.avatar-recovery\\Editor\\', 'AvatarRecoverySource\'
    $name = $name -replace '\.cs$', '.src'
    $name = $name -replace '\\', '/'
    if ($name.Length -gt $Length) {
        $name = "AvatarRecoverySource/source.src"
    }
    while ($name.Length -lt $Length) {
        $name += "_"
    }
    return $name.Substring(0, $Length)
}

function Clear-SourceDocumentPaths {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $matches = [regex]::Matches(
        $ascii,
        '\\Packages\\com\.nickel-jp\.avatar-recovery\\Editor\\[^\x00-\x1F]+?\.cs')

    foreach ($match in $matches) {
        $replacement = ConvertTo-SafeDocumentName -Original $match.Value -Length $match.Value.Length
        $replacementBytes = [System.Text.Encoding]::ASCII.GetBytes($replacement)
        [Array]::Copy($replacementBytes, 0, $bytes, $match.Index, $replacementBytes.Length)
    }

    if ($matches.Count -gt 0) {
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    }

    return $matches.Count
}

function Test-PackageZip {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $blocked = $archive.Entries |
            Where-Object {
                $_.FullName -match '\.(cs|pdb|mdb)$' -or
                $_.FullName -match '(Mapping|rename|report)' -or
                $_.FullName -match 'obfuscar'
            }

        if ($blocked) {
            throw "配布 zip に含めてはいけないファイルがあります: $($blocked.FullName -join ', ')"
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Invoke-UnityCompile {
    param([Parameter(Mandatory = $true)][string]$UnityProjectRoot)

    $logPath = Join-Path $ProtectionRoot "unity-compile-$Version.log"
    $argumentList = @(
        "-batchmode",
        "-quit",
        "-projectPath",
        "`"$UnityProjectRoot`"",
        "-logFile",
        "`"$logPath`""
    )
    $process = Start-Process -FilePath $UnityExe -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    $exitCode = $process.ExitCode
    $logText = if (Test-Path $logPath) { Get-Content -LiteralPath $logPath -Raw } else { "" }
    if ($exitCode -ne 0 -or $logText -match 'error CS|Compilation failed|Scripts have compiler errors|Package Manager.*Error|Unhandled Exception') {
        throw "Unity compile failed. Log: $logPath"
    }

    return $logPath
}

function Initialize-CompileProject {
    if ($SkipUnityCompile -and (Test-Path $CompileProjectRoot)) {
        return
    }

    Remove-SafeDirectory $CompileProjectRoot
    Ensure-Directory $CompileProjectRoot
    Copy-Item -LiteralPath (Join-Path $WorkRoot "UnityCompile$($PreviousVersion.Replace('.', ''))\Packages") -Destination $CompileProjectRoot -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $WorkRoot "UnityCompile$($PreviousVersion.Replace('.', ''))\ProjectSettings") -Destination $CompileProjectRoot -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $WorkRoot "UnityCompile$($PreviousVersion.Replace('.', ''))\Assets") -Destination $CompileProjectRoot -Recurse -Force

    $targetPackage = Join-Path $CompileProjectRoot "Packages\$PackageId"
    if (Test-Path $targetPackage) {
        Remove-Item -LiteralPath $targetPackage -Recurse -Force
    }
    Copy-Item -LiteralPath $SourcePackageRoot -Destination $targetPackage -Recurse -Force

    # Unity/Bee は PDB 出力を前提にするため、csc.rsp で debug を無効化しない。
    # 配布前の DLL からソースドキュメント文字列を別工程で除去する。
    $cscRsp = Join-Path $CompileProjectRoot "Assets\csc.rsp"
    if (Test-Path $cscRsp) {
        Remove-Item -LiteralPath $cscRsp -Force
    }
}

function Initialize-ProjectPackage {
    $editorDir = Join-Path $ProjectPackageRoot "Editor"
    Ensure-Directory $editorDir
    Get-ChildItem -LiteralPath $ProjectPackageRoot -Force |
        Where-Object { $_.Name -ne "Editor" } |
        Remove-Item -Recurse -Force

    foreach ($item in Get-ChildItem -LiteralPath $SourcePackageRoot -Force) {
        if ($item.Name -eq "Editor") {
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination $ProjectPackageRoot -Recurse -Force
    }

    $dllMeta = Join-Path $WorkRoot "Release$($PreviousVersion.Replace('.', ''))\ProjectRoot\Packages\$PackageId\Editor\$AssemblyFileName.meta"
    Copy-Item -LiteralPath $dllMeta -Destination (Join-Path $editorDir "$AssemblyFileName.meta") -Force
}

if (-not (Test-Path $SourcePackageRoot)) {
    throw "Source package was not found: $SourcePackageRoot"
}
if (-not (Test-Path $UnityExe)) {
    throw "Unity executable was not found: $UnityExe"
}

$ObfuscarExe = Install-ObfuscarIfNeeded
Ensure-Directory $ProtectionRoot
Ensure-Directory $PrivateBackupRoot
Ensure-Directory $LocalPrivateBackupRoot
$codeSigningContext = Get-CodeSigningContext

$scan = Get-SourceScan -SourceRoot (Join-Path $SourcePackageRoot "Editor")
$scanPath = Join-Path $PrivateBackupRoot "static-scan-$Version.json"
$scan | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $scanPath -Encoding UTF8
Copy-Item -LiteralPath $scanPath -Destination $LocalPrivateBackupRoot -Force

Initialize-CompileProject
if (-not $SkipUnityCompile) {
    $compileLog = Invoke-UnityCompile -UnityProjectRoot $CompileProjectRoot
    Copy-Item -LiteralPath $compileLog -Destination $PrivateBackupRoot -Force
    Copy-Item -LiteralPath $compileLog -Destination $LocalPrivateBackupRoot -Force
}

$compiledDll = Join-Path $CompileProjectRoot "Library\ScriptAssemblies\$AssemblyFileName"
if (-not (Test-Path $compiledDll)) {
    throw "Compiled DLL was not found: $compiledDll"
}

$inputDir = Join-Path $ProtectionRoot "input"
$outputDir = Join-Path $ProtectionRoot "obfuscated"
Remove-SafeDirectory $inputDir
Remove-SafeDirectory $outputDir
Ensure-Directory $inputDir
Ensure-Directory $outputDir

$protectedInputDll = Join-Path $inputDir $AssemblyFileName
Copy-Item -LiteralPath $compiledDll -Destination $protectedInputDll -Force

$patchedCount = Clear-SourceDocumentPaths -Path $protectedInputDll
Write-Host "Source document paths sanitized before Obfuscar: $patchedCount"
Test-BinaryLeak -Path $protectedInputDll

$assemblySearchPaths = Get-AssemblySearchPaths -UnityProjectRoot $CompileProjectRoot
$configPath = Join-Path $PrivateBackupRoot "obfuscar-$Version.xml"
New-ObfuscarConfig -InputDll $protectedInputDll -OutputDir $outputDir -Scan $scan -AssemblySearchPaths $assemblySearchPaths -ConfigPath $configPath
Copy-Item -LiteralPath $configPath -Destination $LocalPrivateBackupRoot -Force

& $ObfuscarExe $configPath
if ($LASTEXITCODE -ne 0) {
    throw "Obfuscar failed."
}

$obfuscatedDll = Join-Path $outputDir $AssemblyFileName
if (-not (Test-Path $obfuscatedDll)) {
    throw "Obfuscated DLL was not found: $obfuscatedDll"
}

$patchedAfterObfuscar = Clear-SourceDocumentPaths -Path $obfuscatedDll
Write-Host "Source document paths sanitized after Obfuscar: $patchedAfterObfuscar"
Test-BinaryLeak -Path $obfuscatedDll
Invoke-CodeSign -Path $obfuscatedDll -Context $codeSigningContext
Test-CodeSignature -Path $obfuscatedDll -Context $codeSigningContext
Save-CodeSignatureReport -Path $obfuscatedDll -ReportName "signature-obfuscated-$Version.json" -Context $codeSigningContext
Test-BinaryLeak -Path $obfuscatedDll

Get-ChildItem -LiteralPath $outputDir -Force |
    Where-Object { $_.Name -match 'Mapping|rename|report|obfuscar' } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $PrivateBackupRoot -Force
        Copy-Item -LiteralPath $_.FullName -Destination $LocalPrivateBackupRoot -Force
    }

Initialize-ProjectPackage
$packagedDll = Join-Path $ProjectPackageRoot "Editor\$AssemblyFileName"
Copy-Item -LiteralPath $obfuscatedDll -Destination $packagedDll -Force
Test-CodeSignature -Path $packagedDll -Context $codeSigningContext

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "BuildVpmRepository.ps1") -ProjectRoot $ProjectRoot -BaseUrl $BaseUrl
if ($LASTEXITCODE -ne 0) {
    throw "VPM repository build failed."
}

$zipPath = Join-Path $RepoRoot "packages\$PackageId-$Version.zip"
Test-PackageZip -ZipPath $zipPath
Test-CodeSignature -Path $packagedDll -Context $codeSigningContext
Save-CodeSignatureReport -Path $packagedDll -ReportName "signature-packaged-$Version.json" -Context $codeSigningContext
Test-BinaryLeak -Path $packagedDll
Write-PublicChecksumManifest -ZipPath $zipPath -DllPath $packagedDll -Context $codeSigningContext
Write-PublicDetachedSignatures `
    -ZipPath $zipPath `
    -ChecksumPath (Join-Path $RepoRoot "checksums\$PackageId-$Version.sha256.txt") `
    -IndexPath (Join-Path $RepoRoot "index.json") `
    -Context $codeSigningContext

Write-Host "Protected package created: $zipPath"
Write-Host "Private backup root: $PrivateBackupRoot"
Write-Host "Local private backup root: $LocalPrivateBackupRoot"
