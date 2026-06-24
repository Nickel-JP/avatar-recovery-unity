param(
    [string]$Version = "1.1.16",
    [string]$PreviousVersion = "1.1.15",
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
    [ValidateSet("SelfSigned", "SignPath", "Manual")]
    [string]$SigningMode = "SelfSigned",
    [string]$SignPathOrganizationId = $env:SIGNPATH_ORGANIZATION_ID,
    [string]$SignPathProjectSlug = $env:SIGNPATH_PROJECT_SLUG,
    [string]$SignPathSigningPolicySlug = $env:SIGNPATH_SIGNING_POLICY_SLUG,
    [string]$SignPathApiToken = $env:SIGNPATH_API_TOKEN,
    [string]$SignPathExpectedCertificateThumbprint = $env:SIGNPATH_CERTIFICATE_THUMBPRINT,
    [switch]$DisableSelfSignedCertificate,
    [switch]$TrustSelfSignedCertificateForAuthenticode,
    [switch]$SkipUnityCompile,
    [switch]$AllowUnsignedPackage,
    [switch]$DisableRuntimeIntegrityGuard,
    [switch]$DisableAntiDebug,
    [switch]$DisableCecilStringEncryption,
    [switch]$DisableCecilControlFlowObfuscation,
    [switch]$DisableAntiDecompile
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
$PublicApiAllowlistPath = Join-Path $RepoRoot "Build\PublicApiAllowlist.txt"
$ReflectionSerializationAllowlistPath = Join-Path $RepoRoot "Build\ReflectionSerializationAllowlist.txt"
$BinaryLeakAllowlistPath = Join-Path $RepoRoot "Build\BinaryLeakAllowlist.txt"
$RuntimeIntegrityGuardTargetsPath = Join-Path $RepoRoot "Build\RuntimeIntegrityGuardTargets.txt"
$AntiDebugTargetsPath = Join-Path $RepoRoot "Build\AntiDebugTargets.txt"
$StringEncryptionAllowlistPath = Join-Path $RepoRoot "Build\StringEncryptionAllowlist.txt"
$ControlFlowObfuscationAllowlistPath = Join-Path $RepoRoot "Build\ControlFlowObfuscationAllowlist.txt"
$AntiDecompileAllowlistPath = Join-Path $RepoRoot "Build\AntiDecompileAllowlist.txt"
$StringHidingProbe = "AVATAR_RECOVERY_STRING_HIDING_TEST_8D1C4C55"
$SelfSignedCertificateSubject = "CN=Nickel-JP AvatarRecovery Self-Signed Code Signing"
$RuntimeIntegrityGuardTypeName = "EditorTools.AvatarRecovery.AvatarRecoveryIntegrityGuard"
$RuntimeIntegrityGuardMethodName = "EnsureTrustedForRuntimeFeature"
$RuntimeIntegritySignatureTypeName = "$RuntimeIntegrityGuardTypeName/RuntimeIntegritySignature"
$RuntimeIntegritySidecarFileName = "$AssemblyFileName.runtime.sig"
$StringDecryptorTypeName = "EditorTools.AvatarRecovery.AvatarRecoveryStringDecryptor"
$StringDecryptorMethodName = "D"
$StringEncryptionInlineByteArrayThreshold = 32
$StringEncryptionBlobPrefix = "ARX1:"
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
    "\.GetEvent\s*\(",
    "\.GetMember\s*\(",
    "\.Invoke\s*\(",
    "Activator\.CreateInstance\s*\(",
    "Assembly\.GetTypes\s*\(",
    "TypeCache\.",
    "FindProperty\s*\(",
    "FindPropertyRelative\s*\(",
    "nameof\s*\(",
    "JsonUtility",
    "XmlSerializer",
    "SerializeField",
    "SerializeReference",
    "FormerlySerializedAs"
)
$AttributeContractPatterns = @(
    "MenuItem",
    "InitializeOnLoad",
    "InitializeOnLoadMethod",
    "CustomEditor",
    "CustomPropertyDrawer",
    "DidReloadScripts",
    "OnOpenAsset",
    "SettingsProvider"
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
    $normalizedValue = $Value -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $normalizedValue, $utf8NoBom)
}

function Read-StringEncryptionKeyBytesFromSource {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "String decryptor source was not found: $Path"
    }

    $source = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($source, '_key\s*=\s*new\s+byte\[\]\s*\{\s*(?<Bytes>[^}]*)\s*\}')
    if (-not $match.Success) {
        throw "String decryptor key literal was not found: $Path"
    }

    $tokens = @([regex]::Matches($match.Groups["Bytes"].Value, '0x[0-9A-Fa-f]{2}|\d+') | ForEach-Object { $_.Value })
    if ($tokens.Count -le 0) {
        throw "String decryptor key literal was empty: $Path"
    }

    $keyBytes = [byte[]]::new($tokens.Count)
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        $keyBytes[$i] = if ($token.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) {
            [Convert]::ToByte($token.Substring(2), 16)
        } else {
            [Convert]::ToByte($token, 10)
        }
    }

    return $keyBytes
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

    if ($TrustSelfSignedCertificateForAuthenticode) {
        # 明示指定された場合だけ CurrentUser の信頼ストアへ登録する。
        Import-PublicCertificateIfMissing -CertificatePath $publicCertificatePath -StoreName "Root" -Thumbprint $thumbprint
        Import-PublicCertificateIfMissing -CertificatePath $publicCertificatePath -StoreName "TrustedPublisher" -Thumbprint $thumbprint
    }

    $script:CodeSigningMode = "SelfSigned"
    return $thumbprint
}

function Get-ConfiguredCertificateThumbprint {
    if (-not [string]::IsNullOrWhiteSpace($CodeSigningCertificateThumbprint)) {
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

        $thumbprint = ($cert.Thumbprint -replace '\s', '').ToUpperInvariant()
        $storePath = "Cert:\$CodeSigningCertificateStoreLocation\$CodeSigningCertificateStoreName"
        try {
            $securePassword = if ([string]::IsNullOrEmpty($password)) {
                $null
            } else {
                ConvertTo-SecureString -String $password -AsPlainText -Force
            }

            if ($null -eq $securePassword) {
                Import-PfxCertificate `
                    -FilePath (ConvertTo-FullPath $CodeSigningCertificatePath) `
                    -CertStoreLocation $storePath | Out-Null
            }
            else {
                Import-PfxCertificate `
                    -FilePath (ConvertTo-FullPath $CodeSigningCertificatePath) `
                    -CertStoreLocation $storePath `
                    -Password $securePassword | Out-Null
            }

            $imported = Get-Item -LiteralPath (Join-Path $storePath $thumbprint) -ErrorAction SilentlyContinue
            if ($null -ne $imported -and $imported.HasPrivateKey) {
                $script:CodeSigningMode = "CertificateStore"
            }
        }
        catch {
            Write-Warning "PFX certificate could not be imported into the certificate store. Falling back to signtool /f mode: $($_.Exception.Message)"
            $script:CodeSigningMode = "CertificateFile"
        }

        return $thumbprint
    }

    if ([string]::IsNullOrWhiteSpace($CodeSigningCertificateThumbprint)) {
        if (-not $DisableSelfSignedCertificate) {
            return (Ensure-SelfSignedCodeSigningCertificate)
        }

        throw "Code signing is required. Set -CodeSigningCertificateThumbprint or -CodeSigningCertificatePath, or set AVATAR_RECOVERY_CODE_SIGNING_THUMBPRINT / AVATAR_RECOVERY_CODE_SIGNING_CERT_PATH."
    }
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
        UseStore = ($script:CodeSigningMode -ne "CertificateFile")
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

    if ($SigningMode -eq "SignPath") {
        foreach ($requiredValue in @(
            @{ Name = "SignPathOrganizationId"; Value = $SignPathOrganizationId },
            @{ Name = "SignPathProjectSlug"; Value = $SignPathProjectSlug },
            @{ Name = "SignPathSigningPolicySlug"; Value = $SignPathSigningPolicySlug },
            @{ Name = "SignPathApiToken"; Value = $SignPathApiToken }
        )) {
            if ([string]::IsNullOrWhiteSpace($requiredValue.Value)) {
                throw "SignPath signing requires -$($requiredValue.Name) or the matching SIGNPATH_* environment variable."
            }
        }

        $command = Get-Command -Name Submit-SigningRequest -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            throw "SignPath PowerShell command Submit-SigningRequest was not found. Install and import the SignPath module before using -SigningMode SignPath."
        }

        Submit-SigningRequest `
            -OrganizationId $SignPathOrganizationId `
            -ProjectSlug $SignPathProjectSlug `
            -SigningPolicySlug $SignPathSigningPolicySlug `
            -ApiToken $SignPathApiToken `
            -InputArtifactPath (ConvertTo-FullPath $Path) `
            -OutputArtifactPath (ConvertTo-FullPath $Path) `
            -WaitForCompletion
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

    if ($Context.UseStore) {
        [void]$arguments.Add("/s")
        [void]$arguments.Add($CodeSigningCertificateStoreName)
        if ($CodeSigningCertificateStoreLocation -eq "LocalMachine") {
            [void]$arguments.Add("/sm")
        }
        [void]$arguments.Add("/sha1")
        [void]$arguments.Add($Context.ExpectedThumbprint)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CodeSigningCertificatePath)) {
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
    if ($signature.Status -eq "NotSigned" -or $signature.Status -eq "HashMismatch" -or $signature.Status -eq "NotSupportedFileFormat") {
        throw "Authenticode signature is broken for ${Path}: $($signature.Status) $($signature.StatusMessage)"
    }

    if ($null -eq $signature.SignerCertificate) {
        throw "Authenticode signer certificate was not found for: $Path"
    }

    $actualThumbprint = ($signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    $expectedAuthenticodeThumbprint = if ($SigningMode -eq "SignPath" -and -not [string]::IsNullOrWhiteSpace($SignPathExpectedCertificateThumbprint)) {
        ($SignPathExpectedCertificateThumbprint -replace '\s', '').ToUpperInvariant()
    } else {
        $Context.ExpectedThumbprint
    }
    if (-not [string]::IsNullOrWhiteSpace($expectedAuthenticodeThumbprint) -and $actualThumbprint -ne $expectedAuthenticodeThumbprint) {
        throw "Unexpected signer certificate for ${Path}: $actualThumbprint"
    }

    if ($SigningMode -eq "SignPath" -and $signature.Status -ne "Valid") {
        throw "SignPath certificate requires a full trust chain for ${Path}: $($signature.Status) $($signature.StatusMessage)"
    }

    if ($signature.Status -ne "Valid") {
        Write-Warning "Authenticode trust chain is not Valid for ${Path}: $($signature.Status). The signer thumbprint was verified instead."
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

    $publicCertificatePath = Get-PublicCertificatePath
    Export-Certificate -Cert $certificate -FilePath $publicCertificatePath -Force | Out-Null
    Write-CertificatePem -Certificate $certificate -Path (Get-PublicCertificatePemPath)

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
        [AllowNull()][string]$RuntimeIntegritySidecarPath = "",
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

    if ($Context.Required) {
        $certificate = Get-CodeSigningCertificateFromContext -Context $Context
        $publicCertificatePath = Get-PublicCertificatePath
        Export-Certificate -Cert $certificate -FilePath $publicCertificatePath -Force | Out-Null
        Write-CertificatePem -Certificate $certificate -Path (Get-PublicCertificatePemPath)
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
    if (-not [string]::IsNullOrWhiteSpace($RuntimeIntegritySidecarPath) -and
        (Test-Path -LiteralPath $RuntimeIntegritySidecarPath)) {
        $sidecarHash = (Get-FileHash -LiteralPath $RuntimeIntegritySidecarPath -Algorithm SHA256).Hash.ToLowerInvariant()
        [void]$lines.Add("$sidecarHash  packages/$PackageId-$Version.zip!/Editor/$RuntimeIntegritySidecarFileName")
    }

    Write-TextUtf8NoBom -Path $manifestPath -Value (($lines -join "`n") + "`n")
    Write-Host "Created public checksum manifest: $manifestPath"
}

function Get-CSharpBoolLiteral {
    param([bool]$Value)

    if ($Value) {
        return "true"
    }

    return "false"
}

function Ensure-RuntimeIntegrityGuardSource {
    param([Parameter(Mandatory = $true)]$Context)

    $utilsDir = Join-Path $SourcePackageRoot "Editor\Utils"
    Ensure-Directory $utilsDir

    $sourcePath = Join-Path $utilsDir "AvatarRecoveryIntegrityGuard.cs"
    $required = -not $DisableRuntimeIntegrityGuard -and $Context.Required
    $expectedThumbprint = if ($required) { ($Context.ExpectedThumbprint -replace '\s', '').ToUpperInvariant() } else { "" }
    $requiredLiteral = Get-CSharpBoolLiteral -Value $required

    $source = @"
using System;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

using UnityEditor;
using UnityEngine;

namespace EditorTools.AvatarRecovery
{
    [InitializeOnLoad]
    internal static class AvatarRecoveryIntegrityGuard
    {
        private const bool RuntimeIntegrityRequired = $requiredLiteral;
        private const string SidecarFileName = "$RuntimeIntegritySidecarFileName";
        private const string ExpectedSignerThumbprint = "$expectedThumbprint";
        private const string ExpectedFormat = "AvatarRecovery runtime integrity signature v1";
        private const string ExpectedAlgorithm = "RSA-SHA256-PKCS1";

        private static bool _verified;
        private static bool _trusted;
        private static string _failureReason = string.Empty;

        static AvatarRecoveryIntegrityGuard()
        {
            RefreshTrustCache();
        }

        internal static bool IsTrusted
        {
            get
            {
                RefreshTrustCache();
                return _trusted;
            }
        }

        internal static string FailureReason
        {
            get
            {
                RefreshTrustCache();
                return _failureReason ?? string.Empty;
            }
        }

        internal static void EnsureTrustedForRuntimeFeature()
        {
            RefreshTrustCache();
            if (_trusted) return;

            throw new InvalidOperationException(
                "[AvatarRecovery] Runtime integrity check failed: " +
                (string.IsNullOrEmpty(_failureReason) ? "unknown" : _failureReason));
        }

        private static void RefreshTrustCache()
        {
            if (_verified) return;
            _verified = true;

            if (!RuntimeIntegrityRequired)
            {
                _trusted = true;
                _failureReason = string.Empty;
                return;
            }

            try
            {
                var assemblyPath = Assembly.GetExecutingAssembly().Location;
                if (string.IsNullOrEmpty(assemblyPath) || !File.Exists(assemblyPath))
                {
                    Fail("assembly path was not available");
                    return;
                }

                var directory = Path.GetDirectoryName(assemblyPath) ?? string.Empty;
                var sidecarPath = Path.Combine(directory, SidecarFileName);
                if (!File.Exists(sidecarPath))
                {
                    Fail("runtime integrity sidecar was not found");
                    return;
                }

                var sidecarText = File.ReadAllText(sidecarPath);
                var sidecar = JsonUtility.FromJson<RuntimeIntegritySignature>(sidecarText);
                if (sidecar == null)
                {
                    Fail("runtime integrity sidecar could not be parsed");
                    return;
                }

                if (!string.Equals(sidecar.format, ExpectedFormat, StringComparison.Ordinal))
                {
                    Fail("runtime integrity sidecar format mismatch");
                    return;
                }

                if (!string.Equals(sidecar.algorithm, ExpectedAlgorithm, StringComparison.Ordinal))
                {
                    Fail("runtime integrity sidecar algorithm mismatch");
                    return;
                }

                var assemblyBytes = File.ReadAllBytes(assemblyPath);
                var actualHash = ComputeSha256Hex(assemblyBytes);
                if (!string.Equals(actualHash, sidecar.targetSha256, StringComparison.OrdinalIgnoreCase))
                {
                    Fail("assembly SHA-256 mismatch");
                    return;
                }

                var certificateBytes = Convert.FromBase64String(sidecar.signerCertificateBase64);
                using (var certificate = new X509Certificate2(certificateBytes))
                {
                    var actualThumbprint = NormalizeThumbprint(certificate.Thumbprint);
                    if (!string.Equals(actualThumbprint, ExpectedSignerThumbprint, StringComparison.OrdinalIgnoreCase))
                    {
                        Fail("signer certificate thumbprint mismatch");
                        return;
                    }

                    var signatureBytes = Convert.FromBase64String(sidecar.signatureBase64);
                    using (var publicKey = certificate.GetRSAPublicKey())
                    {
                        if (publicKey == null ||
                            !publicKey.VerifyData(
                                assemblyBytes,
                                signatureBytes,
                                HashAlgorithmName.SHA256,
                                RSASignaturePadding.Pkcs1))
                        {
                            Fail("runtime integrity signature verification failed");
                            return;
                        }
                    }
                }

                _trusted = true;
                _failureReason = string.Empty;
            }
            catch (Exception ex)
            {
                Fail("Exception: " + ex.Message);
            }
        }

        private static string ComputeSha256Hex(byte[] bytes)
        {
            using (var sha256 = SHA256.Create())
            {
                var hash = sha256.ComputeHash(bytes);
                var chars = new char[hash.Length * 2];
                for (int i = 0; i < hash.Length; i++)
                {
                    var b = hash[i];
                    chars[i * 2] = GetHexChar(b >> 4);
                    chars[i * 2 + 1] = GetHexChar(b & 0x0F);
                }

                return new string(chars);
            }
        }

        private static char GetHexChar(int value)
        {
            return (char)(value < 10 ? '0' + value : 'a' + value - 10);
        }

        private static string NormalizeThumbprint(string thumbprint)
        {
            return string.IsNullOrEmpty(thumbprint)
                ? string.Empty
                : thumbprint.Replace(" ", string.Empty).ToUpperInvariant();
        }

        private static void Fail(string reason)
        {
            _trusted = false;
            _failureReason = reason ?? string.Empty;
            Debug.LogError("[AvatarRecovery] Runtime integrity check failed: " + _failureReason);
        }

        [Serializable]
        private sealed class RuntimeIntegritySignature
        {
            public string format;
            public string algorithm;
            public string target;
            public string targetSha256;
            public string signerThumbprint;
            public string signerCertificateBase64;
            public string signatureBase64;
        }
    }
}
"@

    Write-TextUtf8NoBom -Path $sourcePath -Value $source
    return [PSCustomObject]@{
        Enabled = $required
        SourcePath = ConvertTo-FullPath $sourcePath
        ExpectedThumbprint = $expectedThumbprint
        SidecarFileName = $RuntimeIntegritySidecarFileName
    }
}

function Ensure-StringDecryptorSource {
    $utilsDir = Join-Path $SourcePackageRoot "Editor\Utils"
    Ensure-Directory $utilsDir

    $sourcePath = Join-Path $utilsDir "AvatarRecoveryStringDecryptor.cs"
    if ($DisableCecilStringEncryption) {
        if (Test-Path -LiteralPath $sourcePath) {
            Remove-Item -LiteralPath $sourcePath -Force
        }
        $script:StringEncryptionKeyBytes = $null
        return [PSCustomObject]@{
            Enabled = $false
            SourcePath = ConvertTo-FullPath $sourcePath
            KeyLength = 0
            Reason = "DisabledBySwitch"
        }
    }

    if ($SkipUnityCompile) {
        $compiledSourcePath = Join-Path $CompileProjectRoot "Packages\$PackageId\Editor\Utils\AvatarRecoveryStringDecryptor.cs"
        if (-not (Test-Path -LiteralPath $compiledSourcePath)) {
            throw "SkipUnityCompile with Cecil string encryption requires an existing compiled string decryptor source. Rebuild without -SkipUnityCompile or use -DisableCecilStringEncryption."
        }

        $keyBytes = Read-StringEncryptionKeyBytesFromSource -Path $compiledSourcePath
        $script:StringEncryptionKeyBytes = $keyBytes
        Copy-Item -LiteralPath $compiledSourcePath -Destination $sourcePath -Force
        return [PSCustomObject]@{
            Enabled = $true
            SourcePath = ConvertTo-FullPath $sourcePath
            KeyLength = $keyBytes.Length
            KeySource = "ExistingCompileProject"
        }
    }

    $keyBytes = [byte[]]::new(32)
    $rngProvider = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rngProvider.GetBytes($keyBytes)
    }
    finally {
        $rngProvider.Dispose()
    }
    $script:StringEncryptionKeyBytes = $keyBytes
    $keyLiteral = ($keyBytes | ForEach-Object { "0x{0:X2}" -f $_ }) -join ", "

    $source = @"
using System;
using System.Text;

namespace EditorTools.AvatarRecovery
{
    internal static class AvatarRecoveryStringDecryptor
    {
        private const string BlobPrefix = "$StringEncryptionBlobPrefix";
        private static readonly byte[] _key = new byte[] { $keyLiteral };

        internal static string D(string encryptedBlob)
        {
            if (string.IsNullOrEmpty(encryptedBlob))
            {
                return string.Empty;
            }

            if (!encryptedBlob.StartsWith(BlobPrefix, StringComparison.Ordinal))
            {
                return string.Empty;
            }

            return D(Convert.FromBase64String(encryptedBlob.Substring(BlobPrefix.Length)));
        }

        internal static string D(byte[] encrypted)
        {
            if (encrypted == null || encrypted.Length == 0)
            {
                return string.Empty;
            }

            var result = new byte[encrypted.Length];
            for (int i = 0; i < encrypted.Length; i++)
            {
                result[i] = (byte)((encrypted[i] ^ _key[i % _key.Length]) - (i & 0xFF));
            }

            return Encoding.UTF8.GetString(result);
        }
    }
}
"@

    Write-TextUtf8NoBom -Path $sourcePath -Value $source
    return [PSCustomObject]@{
        Enabled = $true
        SourcePath = ConvertTo-FullPath $sourcePath
        KeyLength = $keyBytes.Length
    }
}

function Test-RuntimeIntegritySidecarFile {
    param(
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$SidecarPath,
        [Parameter(Mandatory = $true)][string]$ExpectedThumbprint
    )

    if (-not (Test-Path -LiteralPath $DllPath)) {
        throw "Runtime integrity DLL target was not found: $DllPath"
    }
    if (-not (Test-Path -LiteralPath $SidecarPath)) {
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
        $actualThumbprint = ($certificate.Thumbprint -replace '\s', '').ToUpperInvariant()
        if ($actualThumbprint -ne (($ExpectedThumbprint -replace '\s', '').ToUpperInvariant())) {
            throw "Runtime integrity signer thumbprint mismatch: $SidecarPath"
        }
        if ($actualThumbprint -ne (($sidecar.signerThumbprint -replace '\s', '').ToUpperInvariant())) {
            throw "Runtime integrity sidecar signer mismatch: $SidecarPath"
        }

        $publicKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        if ($null -eq $publicKey) {
            throw "Runtime integrity public key was not available: $SidecarPath"
        }

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
        $certificate.Dispose()
    }
}

function Write-RuntimeIntegritySidecar {
    param(
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$SidecarPath,
        [Parameter(Mandatory = $true)]$Context
    )

    if ($DisableRuntimeIntegrityGuard -or -not $Context.Required) {
        return [PSCustomObject]@{
            Enabled = $false
            Created = $false
            SidecarPath = ""
            Reason = if ($DisableRuntimeIntegrityGuard) { "DisabledBySwitch" } else { "UnsignedBuild" }
        }
    }

    $certificate = Get-CodeSigningCertificateFromContext -Context $Context
    if ($null -eq $certificate -or -not $certificate.HasPrivateKey) {
        throw "Runtime integrity sidecar certificate does not have a private key."
    }

    $privateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    if ($null -eq $privateKey) {
        throw "Runtime integrity private key was not available."
    }

    $targetBytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $DllPath))
    $signatureBytes = $privateKey.SignData(
        $targetBytes,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $targetHash = (Get-FileHash -LiteralPath $DllPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $certificateBytes = $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)

    $sidecar = [ordered]@{
        format = "AvatarRecovery runtime integrity signature v1"
        algorithm = "RSA-SHA256-PKCS1"
        signedAtUtc = [DateTime]::UtcNow.ToString("o")
        target = "Editor/$AssemblyFileName"
        targetSha256 = $targetHash
        signerThumbprint = (($certificate.Thumbprint -replace '\s', '').ToUpperInvariant())
        signerCertificateBase64 = [Convert]::ToBase64String($certificateBytes)
        signatureBase64 = [Convert]::ToBase64String($signatureBytes)
    }

    Write-TextUtf8NoBom -Path $SidecarPath -Value (($sidecar | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    Test-RuntimeIntegritySidecarFile -DllPath $DllPath -SidecarPath $SidecarPath -ExpectedThumbprint $Context.ExpectedThumbprint

    return [PSCustomObject]@{
        Enabled = $true
        Created = $true
        SidecarPath = ConvertTo-FullPath $SidecarPath
        TargetSHA256 = $targetHash
        SignerThumbprint = (($certificate.Thumbprint -replace '\s', '').ToUpperInvariant())
    }
}

function Get-XmlEscaped {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return [System.Security.SecurityElement]::Escape($Value)
}

function Get-RelativePathForReport {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $root = (ConvertTo-FullPath $RootPath).TrimEnd('\') + '\'
    $rootUri = [Uri]$root
    $pathUri = [Uri](ConvertTo-FullPath $Path)
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function New-SourceScanHit {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][int]$Line,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Text,
        [AllowNull()][string]$Type = "",
        [AllowNull()][string]$Method = ""
    )

    $relativePath = Get-RelativePathForReport -RootPath $SourceRoot -Path $File
    $normalizedText = ($Text -replace '\s+', ' ').Trim()
    $key = "$relativePath|$Category|$Pattern|$normalizedText"
    return [PSCustomObject]@{
        File = $File
        RelativePath = $relativePath
        Line = $Line
        Category = $Category
        Pattern = $Pattern
        Text = $normalizedText
        Type = $Type
        Method = $Method
        Key = $key
    }
}

function Get-AllowlistSet {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Allowlist file was not found: $Path"
    }

    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    Get-Content -LiteralPath $Path |
        ForEach-Object {
            $line = $_.Trim()
            if ($line.Length -gt 0 -and -not $line.StartsWith("#")) {
                [void]$set.Add($line)
            }
        }

    return $set
}

function Assert-SourceScanAllowlist {
    param(
        [Parameter(Mandatory = $true)][object]$Scan,
        [Parameter(Mandatory = $true)][string]$AllowlistPath
    )

    $allowed = Get-AllowlistSet -Path $AllowlistPath
    $hits = @(
        @($Scan.AttributeUsages) +
        @($Scan.ReflectionHits) +
        @($Scan.EditorPrefsHits) +
        @($Scan.SerializedObjectHits) +
        @($Scan.EnumToStringHits) +
        @($Scan.UiToolkitNameHits)
    )

    $unhandled = @($hits | Where-Object {
        $key = $_.Key
        $matched = $allowed.Contains($key)
        if (-not $matched) {
            foreach ($entry in $allowed) {
                if ($entry.Contains("*") -and $key -like $entry) {
                    $matched = $true
                    break
                }
            }
        }
        -not $matched
    })
    if ($unhandled.Count -gt 0) {
        $message = ($unhandled |
            Select-Object -First 25 |
            ForEach-Object { $_.Key }) -join [Environment]::NewLine
        throw "Reflection/Serialization allowlist に未登録の検出結果があります。Build\ReflectionSerializationAllowlist.txt に理由付きで登録してください。$([Environment]::NewLine)$message"
    }
}

function Get-SourceScan {
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    $sourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Filter "*.cs" -File
    $uiToolkitFiles = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Include "*.uxml", "*.uss" -ErrorAction SilentlyContinue)
    $attributeMethods = New-Object System.Collections.Generic.List[object]
    $attributeUsages = New-Object System.Collections.Generic.List[object]
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

            foreach ($pattern in $AttributeContractPatterns) {
                if ($line -match "^\s*\[\s*$pattern\b") {
                    [void]$attributeUsages.Add((New-SourceScanHit `
                        -SourceRoot $SourceRoot `
                        -File $file.FullName `
                        -Line $lineNumber `
                        -Category "AttributeContract" `
                        -Pattern $pattern `
                        -Text $line `
                        -Type $currentType `
                        -Method ""))
                    break
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
                        RelativePath = Get-RelativePathForReport -RootPath $SourceRoot -Path $file.FullName
                        Line = $lineNumber
                        Type = $currentType
                        Method = $methodName
                    })
                }

                if ($pendingAttributes.Count -gt 0 -and $currentType) {
                    [void]$attributeMethods.Add([PSCustomObject]@{
                        File = $file.FullName
                        RelativePath = Get-RelativePathForReport -RootPath $SourceRoot -Path $file.FullName
                        Line = $lineNumber
                        Type = $currentType
                        Method = $methodName
                        Attributes = @($pendingAttributes)
                    })
                }
            }

            foreach ($pattern in $ReflectionPatterns) {
                if ($line -match $pattern) {
                    [void]$reflectionHits.Add((New-SourceScanHit `
                        -SourceRoot $SourceRoot `
                        -File $file.FullName `
                        -Line $lineNumber `
                        -Category "Reflection" `
                        -Pattern $pattern `
                        -Text $line `
                        -Type $currentType `
                        -Method ""))
                    break
                }
            }

            if ($line -match '\bEditorPrefs\b|EditorPrefsHelper') {
                [void]$editorPrefsHits.Add((New-SourceScanHit `
                    -SourceRoot $SourceRoot `
                    -File $file.FullName `
                    -Line $lineNumber `
                    -Category "EditorPrefs" `
                    -Pattern "EditorPrefs" `
                    -Text $line `
                    -Type $currentType `
                    -Method ""))
            }

            if ($line -match '\bSerializedObject\b|\bScriptableObject\b|\bSerializedProperty\b|\bFindProperty\s*\(|\bFindPropertyRelative\s*\(|SerializeField|SerializeReference|FormerlySerializedAs') {
                [void]$serializedObjectHits.Add((New-SourceScanHit `
                    -SourceRoot $SourceRoot `
                    -File $file.FullName `
                    -Line $lineNumber `
                    -Category "Serialization" `
                    -Pattern "SerializedContract" `
                    -Text $line `
                    -Type $currentType `
                    -Method ""))
            }

            if ($line -match '\b(Enum|Policy|Mode|Type|Platform|Version)\b.*\.ToString\s*\(\s*\)') {
                [void]$enumToStringHits.Add((New-SourceScanHit `
                    -SourceRoot $SourceRoot `
                    -File $file.FullName `
                    -Line $lineNumber `
                    -Category "EnumToString" `
                    -Pattern ".ToString" `
                    -Text $line `
                    -Type $currentType `
                    -Method ""))
            }

            if ($line.Trim().Length -gt 0 -and -not ($line -match '^\s*\[[^\]]+\]')) {
                $pendingAttributes.Clear()
            }
        }
    }

    $uiToolkitNameHits = New-Object System.Collections.Generic.List[object]
    foreach ($file in $uiToolkitFiles) {
        $lines = Get-Content -LiteralPath $file.FullName
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            foreach ($pattern in @("binding-path=", "name=", "type=")) {
                if ($line -match $pattern) {
                    [void]$uiToolkitNameHits.Add((New-SourceScanHit `
                        -SourceRoot $SourceRoot `
                        -File $file.FullName `
                        -Line ($i + 1) `
                        -Category "UiToolkitNameReference" `
                        -Pattern $pattern `
                        -Text $line `
                        -Type "" `
                        -Method ""))
                    break
                }
            }
        }
    }

    return [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToString("o")
        SourceRoot = (ConvertTo-FullPath $SourceRoot)
        UnityMagicMethods = @($unityMessageHits.ToArray())
        AttributeMethods = @($attributeMethods.ToArray())
        AttributeUsages = @($attributeUsages.ToArray())
        VrcSdkCallbackTypes = @($vrcSdkCallbackTypes | Sort-Object -Unique)
        EditorWindowTypes = @($editorWindowTypes | Sort-Object -Unique)
        EnumTypes = @($enumTypes | Sort-Object -Unique)
        ReflectionHits = @($reflectionHits.ToArray())
        EditorPrefsHits = @($editorPrefsHits.ToArray())
        SerializedObjectHits = @($serializedObjectHits.ToArray())
        EnumToStringHits = @($enumToStringHits.ToArray())
        UiToolkitNameHits = @($uiToolkitNameHits.ToArray())
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

function Test-PublicApiAllowlist {
    param(
        [Parameter(Mandatory = $true)][string]$DllPath,
        [Parameter(Mandatory = $true)][string]$AllowlistPath,
        [Parameter(Mandatory = $true)][string[]]$AssemblySearchPaths
    )

    $allowed = @(Get-AllowlistSet -Path $AllowlistPath | Sort-Object)

    $cecilPath = Get-ChildItem -LiteralPath (Join-Path $WorkRoot "tools\obfuscar") -Recurse -Filter "Mono.Cecil.dll" |
        Where-Object { $_.FullName -match '\\net8\.0\\' } |
        Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($cecilPath)) {
        $cecilPath = Get-ChildItem -LiteralPath (Join-Path $WorkRoot "tools\obfuscar") -Recurse -Filter "Mono.Cecil.dll" |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrWhiteSpace($cecilPath)) {
        throw "Mono.Cecil.dll was not found under Obfuscar tool directory."
    }
    if ($null -eq ("Mono.Cecil.AssemblyDefinition" -as [type])) {
        Add-Type -Path $cecilPath
    }

    $readerParameters = [Mono.Cecil.ReaderParameters]::new()
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $DllPath), $readerParameters)
    try {
        $allTypes = New-Object System.Collections.Generic.List[object]
        function Add-CecilType {
            param([Parameter(Mandatory = $true)][object]$TypeDefinition)
            [void]$allTypes.Add($TypeDefinition)
            foreach ($nestedType in $TypeDefinition.NestedTypes) {
                Add-CecilType -TypeDefinition $nestedType
            }
        }

        foreach ($type in $assembly.MainModule.Types) {
            Add-CecilType -TypeDefinition $type
        }

        $exportedTypes = @($allTypes |
            Where-Object { $_.IsPublic -and $_.FullName -ne "<Module>" } |
            ForEach-Object { $_.FullName -replace '/', '+' } |
            Sort-Object -Unique)

        $comparison = @(Compare-Object -ReferenceObject $allowed -DifferenceObject $exportedTypes)
        if ($comparison.Count -gt 0) {
            $details = ($comparison |
                ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join [Environment]::NewLine
            throw "公開APIが許可リストと一致しません。Build\PublicApiAllowlist.txt を確認してください。$([Environment]::NewLine)$details"
        }

        $publicMethodCount = 0
        foreach ($type in $allTypes | Where-Object { $_.IsPublic }) {
            $publicMethodCount += @($type.Methods | Where-Object { $_.IsPublic }).Count
        }

        return [PSCustomObject]@{
            PublicTypes = $exportedTypes
            PublicTypeCount = $exportedTypes.Count
            PublicMethodCount = $publicMethodCount
            NonPublicTypeCount = @($allTypes | Where-Object { -not $_.IsPublic -and -not $_.IsNestedPublic }).Count
        }
    }
    finally {
        $assembly.Dispose()
    }
}

function Get-MonoCecilPath {
    $cecilPath = Get-ChildItem -LiteralPath (Join-Path $WorkRoot "tools\obfuscar") -Recurse -Filter "Mono.Cecil.dll" |
        Where-Object { $_.FullName -match '\\net8\.0\\' } |
        Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($cecilPath)) {
        $cecilPath = Get-ChildItem -LiteralPath (Join-Path $WorkRoot "tools\obfuscar") -Recurse -Filter "Mono.Cecil.dll" |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrWhiteSpace($cecilPath)) {
        throw "Mono.Cecil.dll was not found under Obfuscar tool directory."
    }
    return $cecilPath
}

function Ensure-MonoCecilLoaded {
    if ($null -eq ("Mono.Cecil.AssemblyDefinition" -as [type])) {
        Add-Type -Path (Get-MonoCecilPath)
    }
}

function Get-CecilTypeDefinitions {
    param([Parameter(Mandatory = $true)][object]$Assembly)

    $allTypes = New-Object System.Collections.Generic.List[object]

    function Add-CecilTypeDefinition {
        param([Parameter(Mandatory = $true)][object]$TypeDefinition)

        [void]$allTypes.Add($TypeDefinition)
        foreach ($nestedType in $TypeDefinition.NestedTypes) {
            Add-CecilTypeDefinition -TypeDefinition $nestedType
        }
    }

    foreach ($type in $Assembly.MainModule.Types) {
        Add-CecilTypeDefinition -TypeDefinition $type
    }

    return @($allTypes.ToArray())
}

function Repair-SystemPrivateCoreLibReference {
    param([Parameter(Mandatory = $true)][string]$Path)

    Ensure-MonoCecilLoaded
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $Path))
    $changed = $false
    $tempPath = "$Path.tmp"
    $privateCoreLibReferenceCount = 0
    try {
        $module = $assembly.MainModule
        $mscorlibReference = $module.AssemblyReferences |
            Where-Object { $_.Name -eq "mscorlib" } |
            Select-Object -First 1
        if ($null -eq $mscorlibReference) {
            throw "mscorlib reference was not found in: $Path"
        }

        foreach ($typeReference in $module.GetTypeReferences()) {
            if ($typeReference.Scope -ne $null -and $typeReference.Scope.Name -eq "System.Private.CoreLib") {
                $typeReference.Scope = $mscorlibReference
                $changed = $true
            }
        }

        $privateCoreLibReferences = @($module.AssemblyReferences |
            Where-Object { $_.Name -eq "System.Private.CoreLib" })
        $privateCoreLibReferenceCount = $privateCoreLibReferences.Count
        foreach ($reference in $privateCoreLibReferences) {
            [void]$module.AssemblyReferences.Remove($reference)
            $changed = $true
        }

        $assembly.Write((ConvertTo-FullPath $tempPath))
    }
    finally {
        $assembly.Dispose()
    }

    Move-Item -LiteralPath $tempPath -Destination $Path -Force

    return $privateCoreLibReferenceCount
}

function Test-ForbiddenAssemblyReferences {
    param([Parameter(Mandatory = $true)][string]$Path)

    Ensure-MonoCecilLoaded
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $Path))
    try {
        $blocked = @($assembly.MainModule.AssemblyReferences |
            Where-Object { $_.Name -eq "System.Private.CoreLib" })
        if ($blocked.Count -gt 0) {
            throw "Unity 2022 で解決できない参照が残っています: System.Private.CoreLib"
        }
    }
    finally {
        $assembly.Dispose()
    }
}

function Test-UnityEditorWindowFieldNameCollisions {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Scan
    )

    Ensure-MonoCecilLoaded
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $Path))
    try {
        $typeMap = @{}
        foreach ($type in Get-CecilTypeDefinitions -Assembly $assembly) {
            $normalizedName = $type.FullName -replace '/', '+'
            if (-not $typeMap.ContainsKey($normalizedName)) {
                $typeMap[$normalizedName] = $type
            }
        }

        $problems = New-Object System.Collections.Generic.List[string]
        foreach ($typeName in @($Scan.EditorWindowTypes | Sort-Object -Unique)) {
            if (-not $typeMap.ContainsKey($typeName)) {
                [void]$problems.Add("${typeName}: protected DLL に型が見つかりません。")
                continue
            }

            $type = $typeMap[$typeName]
            $duplicateFields = @($type.Fields |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } |
                Group-Object -Property Name |
                Where-Object { $_.Count -gt 1 } |
                Sort-Object Name)

            foreach ($fieldGroup in $duplicateFields) {
                [void]$problems.Add("${typeName}: field '$($fieldGroup.Name)' が $($fieldGroup.Count) 回定義されています。")
            }
        }

        if ($problems.Count -gt 0) {
            $details = ($problems | Select-Object -First 40) -join [Environment]::NewLine
            throw "Unity EditorWindow のフィールド名が保護後 DLL で重複しています。Unity シリアライズ警告や Domain Reload 復元破損を避けるため、EditorWindow 型のフィールド名を rename 除外してください。$([Environment]::NewLine)$details"
        }
    }
    finally {
        $assembly.Dispose()
    }
}

function Get-ProtectionTargetRules {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Protection target allowlist was not found: $Path"
    }

    $rules = New-Object System.Collections.Generic.List[object]
    Get-Content -LiteralPath $Path |
        ForEach-Object {
            $line = $_.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
                return
            }

            $parts = $line.Split("|")
            if ($parts.Count -ne 2 -or
                [string]::IsNullOrWhiteSpace($parts[0]) -or
                [string]::IsNullOrWhiteSpace($parts[1])) {
                throw "Invalid protection target allowlist entry: $line"
            }

            [void]$rules.Add([PSCustomObject]@{
                Type = $parts[0].Trim()
                Method = $parts[1].Trim()
                Raw = $line
            })
        }

    return @($rules.ToArray())
}

function Test-ProtectionTargetRuleMatch {
    param(
        [Parameter(Mandatory = $true)]$Rule,
        [Parameter(Mandatory = $true)][string]$TypeName,
        [Parameter(Mandatory = $true)][string]$MethodName
    )

    $typeMatches = if ($Rule.Type.Contains("*")) {
        $TypeName -like $Rule.Type
    } else {
        [string]::Equals($TypeName, $Rule.Type, [StringComparison]::Ordinal)
    }

    if (-not $typeMatches) {
        return $false
    }

    if ($Rule.Method.Contains("*")) {
        return $MethodName -like $Rule.Method
    }

    return [string]::Equals($MethodName, $Rule.Method, [StringComparison]::Ordinal)
}

function Test-CecilMethodIsInjectable {
    param([Parameter(Mandatory = $true)]$Method)

    if (-not $Method.HasBody) {
        return $false
    }
    if ($Method.IsConstructor -or $Method.IsAbstract -or $Method.IsPInvokeImpl) {
        return $false
    }
    if ($Method.Body.Instructions.Count -eq 0) {
        return $false
    }

    return $true
}

function Inject-RuntimeIntegrityGuardCalls {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetListPath
    )

    if ($DisableRuntimeIntegrityGuard) {
        return [PSCustomObject]@{
            Enabled = $false
            InjectedMethodCount = 0
            Skipped = @()
            Reason = "DisabledBySwitch"
        }
    }

    Ensure-MonoCecilLoaded
    $rules = Get-ProtectionTargetRules -Path $TargetListPath
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $Path))
    $changed = $false
    $tempPath = "$Path.runtime-integrity.tmp"
    $injected = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[object]

    try {
        $module = $assembly.MainModule
        $guardType = Get-CecilTypeDefinitions -Assembly $assembly |
            Where-Object { ($_.FullName -replace '/', '+') -eq $RuntimeIntegrityGuardTypeName } |
            Select-Object -First 1
        if ($null -eq $guardType) {
            throw "Runtime integrity guard type was not found in compiled DLL. Rebuild without -SkipUnityCompile: $RuntimeIntegrityGuardTypeName"
        }

        $guardMethod = $guardType.Methods |
            Where-Object { $_.Name -eq $RuntimeIntegrityGuardMethodName -and $_.Parameters.Count -eq 0 } |
            Select-Object -First 1
        if ($null -eq $guardMethod) {
            throw "Runtime integrity guard method was not found: $RuntimeIntegrityGuardTypeName.$RuntimeIntegrityGuardMethodName"
        }

        $guardReference = $module.ImportReference($guardMethod)
        foreach ($type in Get-CecilTypeDefinitions -Assembly $assembly) {
            $typeName = $type.FullName -replace '/', '+'
            foreach ($method in $type.Methods) {
                $matched = $false
                foreach ($rule in $rules) {
                    if (Test-ProtectionTargetRuleMatch -Rule $rule -TypeName $typeName -MethodName $method.Name) {
                        $matched = $true
                        break
                    }
                }
                if (-not $matched) {
                    continue
                }

                $methodKey = "$typeName|$($method.Name)"
                if (-not (Test-CecilMethodIsInjectable -Method $method)) {
                    [void]$skipped.Add([PSCustomObject]@{
                        Method = $methodKey
                        Reason = "NotInjectable"
                    })
                    continue
                }

                $alreadyInjected = $false
                foreach ($instruction in $method.Body.Instructions) {
                    if ($instruction.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Call -and
                        $instruction.Operand -ne $null -and
                        $instruction.Operand.FullName -eq $guardReference.FullName) {
                        $alreadyInjected = $true
                        break
                    }
                }
                if ($alreadyInjected) {
                    [void]$skipped.Add([PSCustomObject]@{
                        Method = $methodKey
                        Reason = "AlreadyInjected"
                    })
                    continue
                }

                $processor = $method.Body.GetILProcessor()
                $first = $method.Body.Instructions[0]
                $processor.InsertBefore(
                    $first,
                    [Mono.Cecil.Cil.Instruction]::Create(
                        [Mono.Cecil.Cil.OpCodes]::Call,
                        $guardReference))
                [void](Expand-CecilShortBranches -Method $method)
                $method.Body.MaxStackSize = [Math]::Max($method.Body.MaxStackSize, 1)
                [void]$injected.Add($methodKey)
                $changed = $true
            }
        }

        if ($changed) {
            $assembly.Write((ConvertTo-FullPath $tempPath))
        }
    }
    finally {
        $assembly.Dispose()
    }

    if ($changed) {
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }

    return [PSCustomObject]@{
        Enabled = $true
        TargetRuleCount = $rules.Count
        InjectedMethodCount = $injected.Count
        InjectedMethods = @($injected.ToArray())
        Skipped = @($skipped.ToArray())
    }
}

function Inject-AntiDebugChecks {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetListPath
    )

    if ($DisableAntiDebug) {
        return [PSCustomObject]@{
            Enabled = $false
            InjectedMethodCount = 0
            Skipped = @()
            Reason = "DisabledBySwitch"
        }
    }

    Ensure-MonoCecilLoaded
    $rules = Get-ProtectionTargetRules -Path $TargetListPath
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $Path))
    $changed = $false
    $tempPath = "$Path.anti-debug.tmp"
    $injected = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[object]

    try {
        $module = $assembly.MainModule
        $isAttachedGetter = $module.ImportReference([System.Diagnostics.Debugger].GetProperty("IsAttached").GetGetMethod())
        $invalidOperationCtor = $module.ImportReference([InvalidOperationException].GetConstructor([System.Type]::EmptyTypes))

        foreach ($type in Get-CecilTypeDefinitions -Assembly $assembly) {
            $typeName = $type.FullName -replace '/', '+'
            foreach ($method in $type.Methods) {
                $matched = $false
                foreach ($rule in $rules) {
                    if (Test-ProtectionTargetRuleMatch -Rule $rule -TypeName $typeName -MethodName $method.Name) {
                        $matched = $true
                        break
                    }
                }
                if (-not $matched) {
                    continue
                }

                $methodKey = "$typeName|$($method.Name)"
                if (-not (Test-CecilMethodIsInjectable -Method $method)) {
                    [void]$skipped.Add([PSCustomObject]@{
                        Method = $methodKey
                        Reason = "NotInjectable"
                    })
                    continue
                }

                $alreadyInjected = $false
                foreach ($instruction in $method.Body.Instructions) {
                    if ($instruction.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Call -and
                        $null -ne $instruction.Operand -and
                        $instruction.Operand.ToString().Contains("System.Diagnostics.Debugger::get_IsAttached")) {
                        $alreadyInjected = $true
                        break
                    }
                }
                if ($alreadyInjected) {
                    [void]$skipped.Add([PSCustomObject]@{
                        Method = $methodKey
                        Reason = "AlreadyInjected"
                    })
                    continue
                }

                $processor = $method.Body.GetILProcessor()
                $first = $method.Body.Instructions[0]
                $skipLabel = [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Nop)

                $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $isAttachedGetter))
                $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $skipLabel))
                $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Newobj, $invalidOperationCtor))
                $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Throw))
                $processor.InsertBefore($first, $skipLabel)

                [void](Expand-CecilShortBranches -Method $method)
                $method.Body.MaxStackSize = [Math]::Max($method.Body.MaxStackSize, 2)
                [void]$injected.Add($methodKey)
                $changed = $true
            }
        }

        if ($changed) {
            $assembly.Write((ConvertTo-FullPath $tempPath))
        }
    }
    finally {
        $assembly.Dispose()
    }

    if ($changed) {
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }

    return [PSCustomObject]@{
        Enabled = $true
        TargetRuleCount = $rules.Count
        InjectedMethodCount = $injected.Count
        InjectedMethods = @($injected.ToArray())
        Skipped = @($skipped.ToArray())
    }
}

function Invoke-CecilControlFlowObfuscation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetListPath
    )

    if ($DisableCecilControlFlowObfuscation) {
        return [PSCustomObject]@{
            Enabled = $false
            ObfuscatedMethodCount = 0
            Skipped = @()
            Reason = "DisabledBySwitch"
        }
    }

    Ensure-MonoCecilLoaded
    $rules = Get-ProtectionTargetRules -Path $TargetListPath
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $Path))
    $changed = $false
    $tempPath = "$Path.control-flow.tmp"
    $obfuscated = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]

    try {
        $module = $assembly.MainModule
        $processorCountGetter = $module.ImportReference([Environment].GetProperty("ProcessorCount").GetGetMethod())
        $tickCountGetter = $module.ImportReference([Environment].GetProperty("TickCount").GetGetMethod())
        $threadIdGetter = $module.ImportReference([Environment].GetProperty("CurrentManagedThreadId").GetGetMethod())
        $invalidOperationCtor = $module.ImportReference([InvalidOperationException].GetConstructor([System.Type]::EmptyTypes))
        $predicatePatterns = @(
            "ProcessorCountLtZero",
            "TickCountEqMinValueAndProcessorCountLtZero",
            "ProcessorCountMulZeroNeZero",
            "ThreadIdLtZero"
        )
        $seedBytes = [byte[]]::new(4)
        $rngProvider = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $rngProvider.GetBytes($seedBytes)
        }
        finally {
            $rngProvider.Dispose()
        }
        $rng = [System.Random]::new([BitConverter]::ToInt32($seedBytes, 0))

        foreach ($type in Get-CecilTypeDefinitions -Assembly $assembly) {
            $typeName = $type.FullName -replace '/', '+'
            foreach ($method in $type.Methods) {
                $matched = $false
                foreach ($rule in $rules) {
                    if (Test-ProtectionTargetRuleMatch -Rule $rule -TypeName $typeName -MethodName $method.Name) {
                        $matched = $true
                        break
                    }
                }
                if (-not $matched) {
                    continue
                }

                $methodKey = "$typeName|$($method.Name)"
                if (-not (Test-CecilMethodIsInjectable -Method $method)) {
                    [void]$skipped.Add([PSCustomObject]@{
                        Method = $methodKey
                        Reason = "NotInjectable"
                    })
                    continue
                }
                if ($method.Body.ExceptionHandlers.Count -gt 0) {
                    [void]$skipped.Add([PSCustomObject]@{
                        Method = $methodKey
                        Reason = "HasExceptionHandlers"
                    })
                    continue
                }

                $processor = $method.Body.GetILProcessor()
                $first = $method.Body.Instructions[0]
                $pattern = $predicatePatterns[$rng.Next($predicatePatterns.Count)]
                $stateStart = [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Nop)
                $throwNew = [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Newobj, $invalidOperationCtor)
                $throwInstruction = [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Throw)
                $deadLabel1 = [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Br, $throwNew)
                $deadLabel2 = [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Br, $throwNew)
                $switchTargets = [Mono.Cecil.Cil.Instruction[]]@($first, $deadLabel1, $deadLabel2)

                switch ($pattern) {
                    "ProcessorCountLtZero" {
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $processorCountGetter))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Clt))
                    }
                    "TickCountEqMinValueAndProcessorCountLtZero" {
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $tickCountGetter))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4, [int]::MinValue))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ceq))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $processorCountGetter))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Clt))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::And))
                    }
                    "ProcessorCountMulZeroNeZero" {
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $processorCountGetter))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Mul))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ceq))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ceq))
                    }
                    "ThreadIdLtZero" {
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $threadIdGetter))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
                        $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Clt))
                    }
                    default {
                        throw "Unknown control-flow predicate pattern: $pattern"
                    }
                }
                $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $stateStart))
                $processor.InsertBefore($first, $throwNew)
                $processor.InsertBefore($first, $throwInstruction)
                $processor.InsertBefore($first, $stateStart)
                $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
                $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Switch, $switchTargets))
                $processor.InsertBefore($first, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Br, $first))
                $processor.InsertBefore($first, $deadLabel1)
                $processor.InsertBefore($first, $deadLabel2)

                [void](Expand-CecilShortBranches -Method $method)
                $method.Body.MaxStackSize = [Math]::Max($method.Body.MaxStackSize, 3)
                [void]$obfuscated.Add([PSCustomObject]@{
                    Method = $methodKey
                    PredicatePattern = $pattern
                })
                $changed = $true
            }
        }

        if ($changed) {
            $assembly.Write((ConvertTo-FullPath $tempPath))
        }
    }
    finally {
        $assembly.Dispose()
    }

    if ($changed) {
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }

    return [PSCustomObject]@{
        Enabled = $true
        TargetRuleCount = $rules.Count
        ObfuscatedMethodCount = $obfuscated.Count
        ObfuscatedMethods = @($obfuscated.ToArray())
        Skipped = @($skipped.ToArray())
    }
}

function ConvertTo-EncryptedStringBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][byte[]]$Key
    )

    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $encrypted = [byte[]]::new($plainBytes.Length)
    for ($i = 0; $i -lt $plainBytes.Length; $i++) {
        $encrypted[$i] = (($plainBytes[$i] + ($i -band 0xFF)) -band 0xFF) -bxor $Key[$i % $Key.Length]
    }

    return $encrypted
}

function Get-ObfuscarMappedStringEncryptionTargets {
    param(
        [Parameter(Mandatory = $true)][string]$MappingPath,
        [Parameter(Mandatory = $true)][object[]]$Rules
    )

    $targets = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($MappingPath) -or -not (Test-Path -LiteralPath $MappingPath)) {
        return @($targets.ToArray())
    }

    $currentOriginalType = ""
    $currentObfuscatedType = ""
    foreach ($line in Get-Content -LiteralPath $MappingPath) {
        $typeMatch = [regex]::Match($line, '^\[[^\]]+\](?<Original>[^ ]+) -> \[[^\]]+\](?<Obfuscated>[^ ]+)$')
        if ($typeMatch.Success) {
            $currentOriginalType = $typeMatch.Groups["Original"].Value -replace '/', '+'
            $currentObfuscatedType = $typeMatch.Groups["Obfuscated"].Value -replace '/', '+'
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentOriginalType) -or [string]::IsNullOrWhiteSpace($currentObfuscatedType)) {
            continue
        }

        $methodMatch = [regex]::Match($line, '^\s+\[[^\]]+\](?<OriginalType>[^:]+)::(?<OriginalMethod>[^\[]+)\[(?<ParameterCount>\d+)\].* -> (?<ObfuscatedMethod>\S+)$')
        if (-not $methodMatch.Success) {
            continue
        }

        $originalType = $methodMatch.Groups["OriginalType"].Value -replace '/', '+'
        $originalMethod = $methodMatch.Groups["OriginalMethod"].Value
        foreach ($rule in $Rules) {
            if (Test-ProtectionTargetRuleMatch -Rule $rule -TypeName $originalType -MethodName $originalMethod) {
                [void]$targets.Add([PSCustomObject]@{
                    Type = $currentObfuscatedType
                    Method = $methodMatch.Groups["ObfuscatedMethod"].Value
                    ParameterCount = [int]$methodMatch.Groups["ParameterCount"].Value
                    Original = "$originalType|$originalMethod"
                })
                break
            }
        }
    }

    return @($targets.ToArray())
}

function Expand-CecilShortBranches {
    param(
        [Parameter(Mandatory = $true)][object]$Method
    )

    if ($null -eq $Method.Body -or $Method.Body.Instructions.Count -le 0) {
        return 0
    }

    $expanded = 0
    foreach ($instruction in $Method.Body.Instructions) {
        $code = $instruction.OpCode.Code
        if ($code -eq [Mono.Cecil.Cil.Code]::Br_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Br
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Brfalse_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Brfalse
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Brtrue_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Brtrue
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Beq_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Beq
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Bge_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Bge
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Bge_Un_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Bge_Un
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Bgt_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Bgt
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Bgt_Un_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Bgt_Un
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Ble_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Ble
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Ble_Un_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Ble_Un
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Blt_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Blt
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Blt_Un_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Blt_Un
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Bne_Un_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Bne_Un
            $expanded++
        }
        elseif ($code -eq [Mono.Cecil.Cil.Code]::Leave_S) {
            $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Leave
            $expanded++
        }
    }

    return $expanded
}

function Invoke-CecilStringEncryption {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetListPath,
        [Parameter(Mandatory = $true)][object]$SourceReport,
        [AllowNull()][string]$MappingPath = ""
    )

    if ($DisableCecilStringEncryption) {
        return [PSCustomObject]@{
            Enabled = $false
            EncryptedStringCount = 0
            Skipped = @()
            Reason = "DisabledBySwitch"
        }
    }
    if ($null -eq $script:StringEncryptionKeyBytes -or $script:StringEncryptionKeyBytes.Length -eq 0) {
        throw "String encryption key was not initialized."
    }

    Ensure-MonoCecilLoaded
    $rules = Get-ProtectionTargetRules -Path $TargetListPath
    $mappedTargets = Get-ObfuscarMappedStringEncryptionTargets -MappingPath $MappingPath -Rules $rules
    if (-not [string]::IsNullOrWhiteSpace($MappingPath) -and
        (Test-Path -LiteralPath $MappingPath) -and
        $rules.Count -gt 0 -and
        $mappedTargets.Count -eq 0) {
        throw "String encryption mapping produced no targets from allowlist: $MappingPath"
    }
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $Path))
    $changed = $false
    $tempPath = "$Path.string-encryption.tmp"
    $encryptedMethods = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]

    try {
        $module = $assembly.MainModule
        $decryptorType = Get-CecilTypeDefinitions -Assembly $assembly |
            Where-Object { ($_.FullName -replace '/', '+') -eq $StringDecryptorTypeName } |
            Select-Object -First 1
        if ($null -eq $decryptorType) {
            throw "String decryptor type was not found in compiled DLL: $StringDecryptorTypeName"
        }

        $decryptorByteArrayMethod = $decryptorType.Methods |
            Where-Object {
                $_.Name -eq $StringDecryptorMethodName -and
                $_.Parameters.Count -eq 1 -and
                $_.Parameters[0].ParameterType.FullName -eq "System.Byte[]"
            } |
            Select-Object -First 1
        if ($null -eq $decryptorByteArrayMethod) {
            throw "String decryptor byte-array method was not found: $StringDecryptorTypeName.$StringDecryptorMethodName"
        }

        $decryptorBlobMethod = $decryptorType.Methods |
            Where-Object {
                $_.Name -eq $StringDecryptorMethodName -and
                $_.Parameters.Count -eq 1 -and
                $_.Parameters[0].ParameterType.FullName -eq "System.String"
            } |
            Select-Object -First 1
        if ($null -eq $decryptorBlobMethod) {
            throw "String decryptor blob method was not found: $StringDecryptorTypeName.$StringDecryptorMethodName"
        }

        $decryptorByteArrayReference = $module.ImportReference($decryptorByteArrayMethod)
        $decryptorBlobReference = $module.ImportReference($decryptorBlobMethod)
        $byteTypeReference = $module.TypeSystem.Byte
        $inlineByteArrayStringCount = 0
        $encodedBlobStringCount = 0
        $expandedShortBranchCount = 0

        foreach ($type in Get-CecilTypeDefinitions -Assembly $assembly) {
            $typeName = $type.FullName -replace '/', '+'
            foreach ($method in $type.Methods) {
                $matched = $false
                $matchedOriginal = "$typeName|$($method.Name)"
                if ($mappedTargets.Count -gt 0) {
                    foreach ($target in $mappedTargets) {
                        if ([string]::Equals($typeName, $target.Type, [StringComparison]::Ordinal) -and
                            [string]::Equals($method.Name, $target.Method, [StringComparison]::Ordinal) -and
                            $method.Parameters.Count -eq $target.ParameterCount) {
                            $matched = $true
                            $matchedOriginal = $target.Original
                            break
                        }
                    }
                }
                else {
                    foreach ($rule in $rules) {
                        if (Test-ProtectionTargetRuleMatch -Rule $rule -TypeName $typeName -MethodName $method.Name) {
                            $matched = $true
                            break
                        }
                    }
                }
                if (-not $matched) {
                    continue
                }

                $methodKey = "$typeName|$($method.Name)"
                if (-not (Test-CecilMethodIsInjectable -Method $method)) {
                    [void]$skipped.Add([PSCustomObject]@{
                        Method = $methodKey
                        Reason = "NotInjectable"
                    })
                    continue
                }

                $alreadyEncrypted = $false
                foreach ($instruction in $method.Body.Instructions) {
                    if ($instruction.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Call -and
                        $null -ne $instruction.Operand -and
                        ($instruction.Operand.FullName -eq $decryptorByteArrayReference.FullName -or
                            $instruction.Operand.FullName -eq $decryptorBlobReference.FullName)) {
                        $alreadyEncrypted = $true
                        break
                    }
                }
                if ($alreadyEncrypted) {
                    [void]$skipped.Add([PSCustomObject]@{
                        Method = $methodKey
                        Reason = "AlreadyEncrypted"
                    })
                    continue
                }

                $ldstrInstructions = @(
                    $method.Body.Instructions |
                        Where-Object {
                            $_.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ldstr -and
                            $null -ne $_.Operand -and
                            -not [string]::IsNullOrEmpty([string]$_.Operand)
                        }
                )
                if ($ldstrInstructions.Count -eq 0) {
                    [void]$skipped.Add([PSCustomObject]@{
                        Method = $methodKey
                        Reason = "NoStringLiterals"
                    })
                    continue
                }

                $processor = $method.Body.GetILProcessor()
                $encryptedStringCount = 0
                $methodInlineByteArrayStringCount = 0
                $methodEncodedBlobStringCount = 0
                foreach ($instruction in $ldstrInstructions) {
                    $plainText = [string]$instruction.Operand
                    $encryptedBytes = ConvertTo-EncryptedStringBytes -Value $plainText -Key $script:StringEncryptionKeyBytes
                    if ($encryptedBytes.Length -eq 0) {
                        continue
                    }

                    $cursor = $instruction
                    $tail = New-Object System.Collections.Generic.List[object]
                    if ($encryptedBytes.Length -gt $StringEncryptionInlineByteArrayThreshold) {
                        $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Ldstr
                        $instruction.Operand = "$StringEncryptionBlobPrefix$([Convert]::ToBase64String($encryptedBytes))"
                        [void]$tail.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $decryptorBlobReference))
                        $encodedBlobStringCount++
                        $methodEncodedBlobStringCount++
                    }
                    else {
                        $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Ldc_I4
                        $instruction.Operand = [int]$encryptedBytes.Length
                        [void]$tail.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Newarr, $byteTypeReference))
                        for ($i = 0; $i -lt $encryptedBytes.Length; $i++) {
                            [void]$tail.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Dup))
                            [void]$tail.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4, [int]$i))
                            [void]$tail.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4, [int]$encryptedBytes[$i]))
                            [void]$tail.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Stelem_I1))
                        }
                        [void]$tail.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $decryptorByteArrayReference))
                        $inlineByteArrayStringCount++
                        $methodInlineByteArrayStringCount++
                    }

                    foreach ($newInstruction in $tail) {
                        $processor.InsertAfter($cursor, $newInstruction)
                        $cursor = $newInstruction
                    }

                    $encryptedStringCount++
                }

                if ($encryptedStringCount -gt 0) {
                    $methodExpandedShortBranchCount = Expand-CecilShortBranches -Method $method
                    $expandedShortBranchCount += $methodExpandedShortBranchCount
                    $method.Body.MaxStackSize = [Math]::Max($method.Body.MaxStackSize, 4)
                    [void]$encryptedMethods.Add([PSCustomObject]@{
                        Method = $methodKey
                        OriginalMethod = $matchedOriginal
                        EncryptedStringCount = $encryptedStringCount
                        InlineByteArrayStringCount = $methodInlineByteArrayStringCount
                        EncodedBlobStringCount = $methodEncodedBlobStringCount
                        ExpandedShortBranchCount = $methodExpandedShortBranchCount
                    })
                    $changed = $true
                }
            }
        }

        if ($changed) {
            $assembly.Write((ConvertTo-FullPath $tempPath))
        }
    }
    finally {
        $assembly.Dispose()
    }

    if ($changed) {
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }

    $totalCount = 0
    foreach ($entry in $encryptedMethods) {
        $totalCount += [int]$entry.EncryptedStringCount
    }

    return [PSCustomObject]@{
        Enabled = $true
        TargetRuleCount = $rules.Count
        MappedTargetCount = $mappedTargets.Count
        EncryptedMethodCount = $encryptedMethods.Count
        EncryptedStringCount = $totalCount
        InlineByteArrayThreshold = $StringEncryptionInlineByteArrayThreshold
        InlineByteArrayStringCount = $inlineByteArrayStringCount
        EncodedBlobStringCount = $encodedBlobStringCount
        ExpandedShortBranchCount = $expandedShortBranchCount
        EncryptedBlobPrefix = $StringEncryptionBlobPrefix
        Source = $SourceReport
        EncryptedMethods = @($encryptedMethods.ToArray())
        Skipped = @($skipped.ToArray())
    }
}

function Invoke-CecilAntiDecompile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetListPath
    )

    if ($DisableAntiDecompile) {
        return [PSCustomObject]@{
            Enabled = $false
            ProcessedTypeCount = 0
            Reason = "DisabledBySwitch"
        }
    }

    Ensure-MonoCecilLoaded
    $rules = Get-ProtectionTargetRules -Path $TargetListPath
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $Path))
    $changed = $false
    $tempPath = "$Path.anti-decompile.tmp"
    $processed = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[object]
    $adjustedMethodCount = 0

    try {
        foreach ($type in Get-CecilTypeDefinitions -Assembly $assembly) {
            $typeName = $type.FullName -replace '/', '+'
            $typeMatched = $false
            foreach ($rule in $rules) {
                if (Test-ProtectionTargetRuleMatch -Rule $rule -TypeName $typeName -MethodName "*") {
                    $typeMatched = $true
                    break
                }
            }
            if (-not $typeMatched) {
                continue
            }

            $methodCountForType = 0
            foreach ($method in $type.Methods) {
                if (-not $method.HasBody) {
                    continue
                }
                if ($method.Body.Instructions.Count -eq 0) {
                    continue
                }

                $method.Body.MaxStackSize = [Math]::Min([Math]::Max($method.Body.MaxStackSize + 2, 4), 16)
                $methodCountForType++
                $adjustedMethodCount++
            }

            if ($methodCountForType -gt 0) {
                [void]$processed.Add($typeName)
                $changed = $true
            }
            else {
                [void]$skipped.Add([PSCustomObject]@{
                    Type = $typeName
                    Reason = "NoMethodBodies"
                })
            }
        }

        if ($changed) {
            $assembly.Write((ConvertTo-FullPath $tempPath))
        }
    }
    finally {
        $assembly.Dispose()
    }

    if ($changed) {
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }

    return [PSCustomObject]@{
        Enabled = $true
        TargetRuleCount = $rules.Count
        ProcessedTypeCount = $processed.Count
        AdjustedMethodCount = $adjustedMethodCount
        ProcessedTypes = @($processed.ToArray())
        Skipped = @($skipped.ToArray())
    }
}

function Invoke-CecilBranchSanitization {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    Ensure-MonoCecilLoaded
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $Path))
    $tempPath = "$Path.branch-sanitize.tmp"
    $totalExpanded = 0
    $sanitizedMethodCount = 0
    $invalidTargets = New-Object System.Collections.Generic.List[string]

    try {
        foreach ($type in Get-CecilTypeDefinitions -Assembly $assembly) {
            $typeName = $type.FullName -replace '/', '+'
            foreach ($method in $type.Methods) {
                if (-not $method.HasBody -or $method.Body.Instructions.Count -eq 0) {
                    continue
                }

                $expanded = Expand-CecilShortBranches -Method $method
                if ($expanded -gt 0) {
                    $totalExpanded += $expanded
                    $sanitizedMethodCount++
                }

                $instructionOffsets = [System.Collections.Generic.HashSet[int]]::new()
                foreach ($instr in $method.Body.Instructions) {
                    [void]$instructionOffsets.Add($instr.Offset)
                }

                foreach ($instr in $method.Body.Instructions) {
                    $flow = $instr.OpCode.FlowControl
                    if ($flow -ne [Mono.Cecil.Cil.FlowControl]::Branch -and
                        $flow -ne [Mono.Cecil.Cil.FlowControl]::Cond_Branch) {
                        continue
                    }

                    if ($instr.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Switch) {
                        $targets = $instr.Operand
                        for ($i = 0; $i -lt $targets.Length; $i++) {
                            if (-not $instructionOffsets.Contains($targets[$i].Offset)) {
                                [void]$invalidTargets.Add("$typeName|$($method.Name) IL_$($instr.Offset.ToString('x4')) switch[$i] -> IL_$($targets[$i].Offset.ToString('x4'))")
                            }
                        }
                    }
                    else {
                        $target = $instr.Operand
                        if ($null -eq $target -or -not $instructionOffsets.Contains($target.Offset)) {
                            $targetOffset = if ($null -ne $target) { "IL_$($target.Offset.ToString('x4'))" } else { "null" }
                            [void]$invalidTargets.Add("$typeName|$($method.Name) IL_$($instr.Offset.ToString('x4')) $($instr.OpCode.Name) -> $targetOffset")
                        }
                    }
                }
            }
        }

        if ($invalidTargets.Count -gt 0) {
            throw "IL branch target validation failed ($($invalidTargets.Count) invalid targets):`n$($invalidTargets -join "`n")"
        }

        if ($totalExpanded -gt 0) {
            $assembly.Write((ConvertTo-FullPath $tempPath))
        }
    }
    finally {
        $assembly.Dispose()
    }

    if ($totalExpanded -gt 0) {
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }

    return [PSCustomObject]@{
        ExpandedShortBranchCount = $totalExpanded
        SanitizedMethodCount = $sanitizedMethodCount
        InvalidTargetCount = $invalidTargets.Count
    }
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
    $hideStrings = if ($DisableCecilStringEncryption) { "true" } else { "false" }
    [void]$lines.Add("  <Var name=""HideStrings"" value=""$hideStrings"" />")
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
        [void]$lines.Add("    <SkipType name=""$(Get-XmlEscaped $typeName)"" skipMethods=""true"" skipProperties=""true"" skipFields=""true"" skipEvents=""true"" />")
    }

    foreach ($typeName in $Scan.VrcSdkCallbackTypes) {
        [void]$lines.Add("    <SkipType name=""$(Get-XmlEscaped $typeName)"" skipMethods=""true"" skipProperties=""true"" skipFields=""true"" skipEvents=""true"" />")
    }

    foreach ($typeName in $Scan.EnumTypes) {
        [void]$lines.Add("    <SkipType name=""$(Get-XmlEscaped $typeName)"" skipFields=""true"" />")
    }

    [void]$lines.Add("    <SkipType name=""$(Get-XmlEscaped $RuntimeIntegritySignatureTypeName)"" skipFields=""true"" />")

    if (-not $DisableCecilStringEncryption) {
        [void]$lines.Add("    <SkipType name=""$(Get-XmlEscaped $StringDecryptorTypeName)"" skipMethods=""true"" skipProperties=""true"" skipFields=""true"" skipEvents=""true"" />")
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
    $tempPath = [System.IO.Path]::GetTempPath()
    $configuredCertificatePath = if ([string]::IsNullOrWhiteSpace($CodeSigningCertificatePath)) { "" } else { ConvertTo-FullPath $CodeSigningCertificatePath }
    $allowlist = Get-AllowlistSet -Path $BinaryLeakAllowlistPath
    $literalChecks = @(
        @{ Name = "current user name"; Pattern = $userName; AllowKey = "" },
        @{ Name = "repo absolute path"; Pattern = (ConvertTo-FullPath $RepoRoot); AllowKey = "" },
        @{ Name = "CI workspace path"; Pattern = $env:GITHUB_WORKSPACE; AllowKey = "" },
        @{ Name = "PFX/certificate private path"; Pattern = $configuredCertificatePath; AllowKey = "" },
        @{ Name = "temporary directory path"; Pattern = $tempPath; AllowKey = "" },
        @{ Name = "repo source path"; Pattern = "\Packages\com.nickel-jp.avatar-recovery\Editor\"; AllowKey = "" },
        @{ Name = "C drive user path"; Pattern = "C:\Users\"; AllowKey = "" },
        @{ Name = "macOS user path"; Pattern = "/Users/"; AllowKey = "" },
        @{ Name = "VS Code workspace marker"; Pattern = ".vscode"; AllowKey = "" },
        @{ Name = "IDEA workspace marker"; Pattern = ".idea"; AllowKey = "" },
        @{ Name = "object build folder"; Pattern = "obj\"; AllowKey = "" },
        @{ Name = "binary build folder"; Pattern = "bin\"; AllowKey = "" },
        @{ Name = "PDB extension"; Pattern = ".pdb"; AllowKey = "" },
        @{ Name = "MDB extension"; Pattern = ".mdb"; AllowKey = "" },
        @{ Name = "PFX extension"; Pattern = ".pfx"; AllowKey = "" },
        @{ Name = "P12 extension"; Pattern = ".p12"; AllowKey = "" },
        @{ Name = "private key marker"; Pattern = "PRIVATE KEY"; AllowKey = "" },
        @{ Name = "RSA private key marker"; Pattern = "BEGIN RSA PRIVATE KEY"; AllowKey = "" },
        @{ Name = "generic private key marker"; Pattern = "BEGIN PRIVATE KEY"; AllowKey = "" },
        @{ Name = "password marker"; Pattern = "Password="; AllowKey = "" },
        @{ Name = "token marker"; Pattern = "Token="; AllowKey = "" },
        @{ Name = "api key marker"; Pattern = "ApiKey="; AllowKey = "" },
        @{ Name = "secret marker"; Pattern = "Secret="; AllowKey = "" },
        @{ Name = "Unity-incompatible core library reference"; Pattern = "System.Private.CoreLib"; AllowKey = "" },
        @{ Name = "local HTTP URL"; Pattern = "http://localhost"; AllowKey = "" },
        @{ Name = "local HTTPS URL"; Pattern = "https://localhost"; AllowKey = "" },
        @{ Name = "loopback URL"; Pattern = "127.0.0.1"; AllowKey = "" },
        @{ Name = "Unity Assets path"; Pattern = "Assets/"; AllowKey = "Literal:Assets/" },
        @{ Name = "Unity Assets path"; Pattern = "Assets\"; AllowKey = "Literal:Assets\" },
        @{ Name = "Unity Packages path"; Pattern = "Packages/"; AllowKey = "Literal:Packages/" },
        @{ Name = "Unity Packages path"; Pattern = "Packages\"; AllowKey = "Literal:Packages\" },
        @{ Name = "VRCA extension"; Pattern = ".vrca"; AllowKey = "Literal:.vrca" },
        @{ Name = "VRCW extension"; Pattern = ".vrcw"; AllowKey = "Literal:.vrcw" },
        @{ Name = "VRCP extension"; Pattern = ".vrcp"; AllowKey = "Literal:.vrcp" }
    )

    foreach ($check in $literalChecks) {
        if ([string]::IsNullOrWhiteSpace($check.Pattern)) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($check.AllowKey) -and $allowlist.Contains($check.AllowKey)) {
            continue
        }

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

    if ($ascii -match '[A-Za-z0-9_./\\-]+\.cs(\x00|\s|$)' -or
        $unicode -match '[A-Za-z0-9_./\\-]+\.cs(\x00|\s|$)') {
        [void]$problems.Add("source file name")
    }

    $codeSigningPassword = Get-CodeSigningPassword
    if (-not [string]::IsNullOrEmpty($codeSigningPassword)) {
        if ($ascii.Contains($codeSigningPassword) -or $unicode.Contains($codeSigningPassword)) {
            [void]$problems.Add("code signing password value")
        }
    }

    if ($problems.Count -gt 0) {
        throw "DLL leak check failed for ${Path}: $($problems -join ', ')"
    }
}

function Test-StringHidingProbeAbsent {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
    if ($ascii.Contains($StringHidingProbe) -or $unicode.Contains($StringHidingProbe)) {
        throw "String hiding protection did not remove the plaintext marker: $StringHidingProbe"
    }
}

function ConvertTo-LiteralPreview {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Replace("`r", "\r").Replace("`n", "\n").Replace("`t", "\t")
    if ($normalized.Length -le 120) {
        return $normalized
    }

    return $normalized.Substring(0, 120) + "..."
}

function Get-HideStringsImpactReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$StringEncryptionReport
    )

    Ensure-MonoCecilLoaded

    $sensitivePlaintexts = @(
        $StringHidingProbe,
        "runtime integrity sidecar was not found",
        "runtime integrity signature verification failed",
        "AVATAR_RECOVERY_CODE_SIGNING_PASSWORD",
        "SIGNPATH_API_TOKEN",
        "System.Private.CoreLib"
    )
    $sensitiveRegexRules = @(
        [PSCustomObject]@{ Name = "PrivateKey"; Pattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
        [PSCustomObject]@{ Name = "WindowsRepoPath"; Pattern = '(?i)[A-Z]:\\Users\\[^\\]+\\avatar-recovery-unity' },
        [PSCustomObject]@{ Name = "PackageSourcePath"; Pattern = '\\Packages\\com\.nickel-jp\.avatar-recovery\\Editor\\' },
        [PSCustomObject]@{ Name = "CredentialMarker"; Pattern = '(?i)(Password=|ApiKey=|Secret=|Token=)' }
    )

    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((ConvertTo-FullPath $Path))
    $uniqueLiterals = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $samples = New-Object System.Collections.Generic.List[object]
    $sensitiveHits = New-Object System.Collections.Generic.List[object]
    $literalCount = 0
    $encryptedBlobLiteralCount = 0
    $longPlaintextLiteralCount = 0

    try {
        foreach ($type in Get-CecilTypeDefinitions -Assembly $assembly) {
            $typeName = $type.FullName -replace '/', '+'
            foreach ($method in $type.Methods) {
                if (-not $method.HasBody) {
                    continue
                }

                $methodKey = "$typeName|$($method.Name)"
                foreach ($instruction in $method.Body.Instructions) {
                    if ($instruction.OpCode.Code -ne [Mono.Cecil.Cil.Code]::Ldstr -or $null -eq $instruction.Operand) {
                        continue
                    }

                    $literal = [string]$instruction.Operand
                    if ([string]::IsNullOrEmpty($literal)) {
                        continue
                    }

                    $literalCount++
                    [void]$uniqueLiterals.Add($literal)
                    $isEncryptedBlob = $literal.StartsWith($StringEncryptionBlobPrefix, [StringComparison]::Ordinal)
                    if ($isEncryptedBlob) {
                        $encryptedBlobLiteralCount++
                        continue
                    }

                    if ($literal.Length -ge 80) {
                        $longPlaintextLiteralCount++
                    }
                    if ($samples.Count -lt 25) {
                        [void]$samples.Add([PSCustomObject]@{
                            Method = $methodKey
                            Length = $literal.Length
                            Preview = ConvertTo-LiteralPreview -Value $literal
                        })
                    }

                    foreach ($sensitivePlaintext in $sensitivePlaintexts) {
                        if ($literal.Contains($sensitivePlaintext)) {
                            [void]$sensitiveHits.Add([PSCustomObject]@{
                                Rule = "Literal:$sensitivePlaintext"
                                Method = $methodKey
                                Length = $literal.Length
                                Preview = ConvertTo-LiteralPreview -Value $literal
                            })
                        }
                    }

                    foreach ($rule in $sensitiveRegexRules) {
                        if ([regex]::IsMatch($literal, $rule.Pattern)) {
                            [void]$sensitiveHits.Add([PSCustomObject]@{
                                Rule = $rule.Name
                                Method = $methodKey
                                Length = $literal.Length
                                Preview = ConvertTo-LiteralPreview -Value $literal
                            })
                        }
                    }
                }
            }
        }
    }
    finally {
        $assembly.Dispose()
    }

    if ($sensitiveHits.Count -gt 0) {
        throw "HideStrings disabled impact scan found sensitive plaintext: $($sensitiveHits[0].Rule) in $($sensitiveHits[0].Method)"
    }

    return [PSCustomObject]@{
        Enabled = $true
        HideStringsDisabled = (-not [bool]$DisableCecilStringEncryption)
        ManagedBy = if ($DisableCecilStringEncryption) { "ObfuscarHideStrings" } else { "CecilStringEncryptionAllowlistAndRiskScan" }
        StringProtectionProvider = if ($DisableCecilStringEncryption) { "ObfuscarHideStrings" } else { "CecilStringEncryption" }
        LdstrLiteralCount = $literalCount
        UniqueLdstrLiteralCount = $uniqueLiterals.Count
        EncryptedBlobLiteralCount = $encryptedBlobLiteralCount
        PlaintextLiteralCount = ($literalCount - $encryptedBlobLiteralCount)
        LongPlaintextLiteralCount = $longPlaintextLiteralCount
        SensitivePlaintextHitCount = $sensitiveHits.Count
        InlineByteArrayStringCount = if ($StringEncryptionReport.PSObject.Properties["InlineByteArrayStringCount"]) { [int]$StringEncryptionReport.InlineByteArrayStringCount } else { 0 }
        EncodedBlobStringCount = if ($StringEncryptionReport.PSObject.Properties["EncodedBlobStringCount"]) { [int]$StringEncryptionReport.EncodedBlobStringCount } else { 0 }
        Samples = @($samples.ToArray())
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

function ConvertTo-SafeDebugSymbolName {
    param(
        [Parameter(Mandatory = $true)][int]$Length
    )

    $name = "AvatarRecoveryBuild/symbols.bin"
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

function Clear-DebugSymbolPaths {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $matches = [regex]::Matches(
        $ascii,
        '[A-Za-z0-9_.:\\/\-]+\.pdb')

    foreach ($match in $matches) {
        $replacement = ConvertTo-SafeDebugSymbolName -Length $match.Value.Length
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
                $_.FullName -match '(?i)\.(cs|pdb|mdb)$' -or
                $_.FullName -match '(?i)\.(pfx|p12|pvk|key|snk|pem|map)$' -or
                $_.FullName -match '(?i)(mapping|rename|report)' -or
                $_.FullName -match '(?i)obfuscar'
            }

        if ($blocked) {
            throw "配布 zip に含めてはいけないファイルがあります: $($blocked.FullName -join ', ')"
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
                        throw "配布 zip 内に秘密鍵本文が含まれています: $($entry.FullName)"
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

function Test-PublicFileForSecrets {
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
    $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
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

function Test-PublicReleaseSecrets {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($filePath in @(
        (Join-Path $RepoRoot "index.json"),
        (Join-Path $RepoRoot "index.json.sig")
    )) {
        if (Test-Path -LiteralPath $filePath) {
            [void]$paths.Add($filePath)
        }
    }

    foreach ($directoryPath in @(
        (Join-Path $RepoRoot "packages"),
        (Join-Path $RepoRoot "checksums"),
        (Join-Path $RepoRoot "certificates")
    )) {
        if (Test-Path -LiteralPath $directoryPath) {
            Get-ChildItem -LiteralPath $directoryPath -File -Recurse |
                ForEach-Object { [void]$paths.Add($_.FullName) }
        }
    }

    $codeSigningPassword = Get-CodeSigningPassword
    foreach ($path in $paths) {
        Test-PublicFileForSecrets -Path $path -SecretValue $codeSigningPassword
    }
}

function Get-UnityVersionLabel {
    $match = [regex]::Match($UnityExe, '\\Editor\\([^\\]+)\\Editor\\Unity\.exe$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    try {
        $versionOutput = & $UnityExe -version 2>$null | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($versionOutput)) {
            return [string]$versionOutput
        }
    }
    catch {
        return ""
    }

    return ""
}

function Get-BuildEnvironmentReport {
    Ensure-MonoCecilLoaded

    $gitCommit = git -C $RepoRoot rev-parse HEAD 2>$null
    $gitBranch = git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null
    $gitDirty = ((git -C $RepoRoot status --porcelain 2>$null | Measure-Object).Count -gt 0)
    $dotNetVersion = try {
        [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    }
    catch {
        [Environment]::Version.ToString()
    }

    return [PSCustomObject]@{
        MachineName = [Environment]::MachineName
        OSVersion = [Environment]::OSVersion.VersionString
        ProcessorArchitecture = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
        DotNetVersion = $dotNetVersion
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        UnityVersion = Get-UnityVersionLabel
        ObfuscarVersion = $ObfuscarToolVersion
        MonoCecilVersion = ([Mono.Cecil.AssemblyDefinition].Assembly.GetName().Version.ToString())
        BuildTimestampUtc = [DateTime]::UtcNow.ToString("o")
        TimeZone = [TimeZoneInfo]::Local.Id
        CI = if ($env:CI) { $true } else { $false }
        GitCommit = if ($gitCommit) { [string]$gitCommit } else { "" }
        GitBranch = if ($gitBranch) { [string]$gitBranch } else { "" }
        GitDirty = $gitDirty
    }
}

function Write-ProtectionBuildReport {
    param(
        [Parameter(Mandatory = $true)][object]$Scan,
        [Parameter(Mandatory = $true)][object]$PublicApiReport,
        [Parameter(Mandatory = $true)][object]$RuntimeIntegritySourceReport,
        [Parameter(Mandatory = $true)][object]$RuntimeIntegrityInjectionReport,
        [Parameter(Mandatory = $true)][object]$AntiDebugReport,
        [Parameter(Mandatory = $true)][object]$StringEncryptionReport,
        [Parameter(Mandatory = $true)][object]$HideStringsImpactReport,
        [Parameter(Mandatory = $true)][object]$AntiDecompileReport,
        [Parameter(Mandatory = $true)][object]$BranchSanitizationReport,
        [Parameter(Mandatory = $true)][object]$RuntimeIntegritySidecarReport,
        [Parameter(Mandatory = $true)][object]$ControlFlowObfuscationReport,
        [Parameter(Mandatory = $true)][string]$InputDll,
        [Parameter(Mandatory = $true)][string]$ObfuscatedDll,
        [Parameter(Mandatory = $true)][string]$SignedDll,
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$ChecksumPath,
        [Parameter(Mandatory = $true)][string]$ObfuscarConfigPath,
        [Parameter(Mandatory = $true)][object]$CodeSigningContext
    )

    $zipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumText = Get-Content -LiteralPath $ChecksumPath -Raw
    $index = Get-Content -LiteralPath (Join-Path $RepoRoot "index.json") -Raw | ConvertFrom-Json
    $packageEntry = $index.packages.PSObject.Properties[$PackageId].Value
    $indexZipHash = $packageEntry.versions.PSObject.Properties[$Version].Value.zipSHA256
    $signature = Get-AuthenticodeSignature -LiteralPath $SignedDll
    $skipRuleCount = @(Select-String -LiteralPath $ObfuscarConfigPath -Pattern '<Skip' -ErrorAction SilentlyContinue).Count

    $report = [PSCustomObject]@{
        Version = $Version
        GeneratedAt = (Get-Date).ToString("o")
        Pipeline = @(
            "UnityCompile",
            "PreObfuscarCoreLibRepair",
            "PublicApiAllowlist",
            "RuntimeIntegrityGuardInjection",
            "AntiDebugInjection",
            "CecilControlFlowObfuscation",
            "AntiDecompileMetadata",
            "Obfuscar",
            "CecilStringEncryption",
            "HideStringsImpactScan",
            "CoreLibReferenceRepair",
            "BranchSanitization",
            "UnityEditorWindowFieldCollisionCheck",
            "LeakCheck",
            "AuthenticodeSign",
            "SignatureVerify",
            "RuntimeIntegritySidecar",
            "Zip",
            "ZipContentCheck",
            "Checksum",
            "VpmIndex",
            "DetachedSignatures",
            "PublicSecretScan"
        )
        Obfuscar = [PSCustomObject]@{
            KeepPublicApi = $true
            HidePrivateApi = $true
            HideStrings = [bool]$DisableCecilStringEncryption
            StringProtectionProvider = if ($DisableCecilStringEncryption) { "ObfuscarHideStrings" } else { "CecilStringEncryption" }
            HideStringsImpactManagedBy = $HideStringsImpactReport.ManagedBy
            RenameProperties = $false
            RenameEvents = $false
            UseUnicodeNames = $false
            SuppressIldasm = $true
            ExclusionRuleCount = $skipRuleCount
        }
        BuildEnvironment = Get-BuildEnvironmentReport
        ControlFlowObfuscation = $ControlFlowObfuscationReport
        AntiDebug = $AntiDebugReport
        StringEncryption = $StringEncryptionReport
        HideStringsImpact = $HideStringsImpactReport
        AntiDecompile = $AntiDecompileReport
        BranchSanitization = $BranchSanitizationReport
        Metrics = [PSCustomObject]@{
            InputDllSize = (Get-Item -LiteralPath $InputDll).Length
            ObfuscatedDllSize = (Get-Item -LiteralPath $ObfuscatedDll).Length
            SignedDllSize = (Get-Item -LiteralPath $SignedDll).Length
            PublicTypeCount = $PublicApiReport.PublicTypeCount
            PublicMethodCount = $PublicApiReport.PublicMethodCount
            NonPublicTypeCount = $PublicApiReport.NonPublicTypeCount
            AttributeUsageCount = @($Scan.AttributeUsages).Count
            ReflectionUsageCount = @($Scan.ReflectionHits).Count
            EditorPrefsUsageCount = @($Scan.EditorPrefsHits).Count
            SerializationUsageCount = @($Scan.SerializedObjectHits).Count
            EnumToStringUsageCount = @($Scan.EnumToStringHits).Count
            UiToolkitNameReferenceCount = @($Scan.UiToolkitNameHits).Count
        }
        PublicApi = $PublicApiReport.PublicTypes
        Integrity = [PSCustomObject]@{
            ZipSHA256 = $zipHash
            ChecksumContainsZipSHA256 = $checksumText.Contains($zipHash)
            IndexZipSHA256 = $indexZipHash
            IndexMatchesZipSHA256 = ($indexZipHash -eq $zipHash)
            ChecksumSignature = "Created"
            ZipSignature = "Created"
            IndexSignature = "Created"
        }
        Authenticode = [PSCustomObject]@{
            Status = [string]$signature.Status
            SigningMode = $SigningMode
            CertificateContextMode = $CodeSigningContext.Mode
            SignerSubject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { "" }
            SignerThumbprint = if ($signature.SignerCertificate) { ($signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant() } else { "" }
            ExpectedThumbprint = $CodeSigningContext.ExpectedThumbprint
            SignPathExpectedThumbprint = if ($SigningMode -eq "SignPath") { (($SignPathExpectedCertificateThumbprint -replace '\s', '').ToUpperInvariant()) } else { "" }
        }
        RuntimeIntegrity = [PSCustomObject]@{
            Source = $RuntimeIntegritySourceReport
            Injection = $RuntimeIntegrityInjectionReport
            Sidecar = $RuntimeIntegritySidecarReport
        }
        LeakChecks = [PSCustomObject]@{
            StringHidingProbePlaintextAbsent = $true
            HideStringsImpactSensitivePlaintextScan = "Passed"
            PfxOrP12PublicFileScan = "Passed"
            PrivateKeyPublicFileScan = "Passed"
            CodeSigningPasswordPublicFileScan = "Passed"
        }
    }

    $reportPath = Join-Path $PrivateBackupRoot "protection-build-report-$Version.json"
    $report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Copy-Item -LiteralPath $reportPath -Destination $LocalPrivateBackupRoot -Force
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
$runtimeIntegritySourceReport = Ensure-RuntimeIntegrityGuardSource -Context $codeSigningContext
$stringDecryptorSourceReport = Ensure-StringDecryptorSource

$scan = Get-SourceScan -SourceRoot (Join-Path $SourcePackageRoot "Editor")
$scanPath = Join-Path $PrivateBackupRoot "static-scan-$Version.json"
$scan | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $scanPath -Encoding UTF8
Copy-Item -LiteralPath $scanPath -Destination $LocalPrivateBackupRoot -Force
Assert-SourceScanAllowlist -Scan $scan -AllowlistPath $ReflectionSerializationAllowlistPath

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
$patchedDebugSymbols = Clear-DebugSymbolPaths -Path $protectedInputDll
Write-Host "Debug symbol paths sanitized before Obfuscar: $patchedDebugSymbols"
$repairToolProject = Join-Path $RepoRoot "Build\RepairCoreLibReference\RepairCoreLibReference.csproj"
$repairOutput = & dotnet run --project $repairToolProject -- (ConvertTo-FullPath $protectedInputDll) 2>&1
if ($LASTEXITCODE -ne 0) { throw "RepairCoreLibReference failed: $repairOutput" }
Write-Host "System.Private.CoreLib repair (pre-Obfuscar): $repairOutput"
Test-BinaryLeak -Path $protectedInputDll

$assemblySearchPaths = Get-AssemblySearchPaths -UnityProjectRoot $CompileProjectRoot
$publicApiReport = Test-PublicApiAllowlist `
    -DllPath $protectedInputDll `
    -AllowlistPath $PublicApiAllowlistPath `
    -AssemblySearchPaths $assemblySearchPaths
$runtimeIntegrityInjectionReport = Inject-RuntimeIntegrityGuardCalls `
    -Path $protectedInputDll `
    -TargetListPath $RuntimeIntegrityGuardTargetsPath
$runtimeIntegrityInjectionPath = Join-Path $PrivateBackupRoot "runtime-integrity-injection-$Version.json"
$runtimeIntegrityInjectionReport | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $runtimeIntegrityInjectionPath -Encoding UTF8
Copy-Item -LiteralPath $runtimeIntegrityInjectionPath -Destination $LocalPrivateBackupRoot -Force

$antiDebugReport = Inject-AntiDebugChecks `
    -Path $protectedInputDll `
    -TargetListPath $AntiDebugTargetsPath
$antiDebugReportPath = Join-Path $PrivateBackupRoot "anti-debug-$Version.json"
$antiDebugReport | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $antiDebugReportPath -Encoding UTF8
Copy-Item -LiteralPath $antiDebugReportPath -Destination $LocalPrivateBackupRoot -Force

$controlFlowObfuscationReport = Invoke-CecilControlFlowObfuscation `
    -Path $protectedInputDll `
    -TargetListPath $ControlFlowObfuscationAllowlistPath
$controlFlowReportPath = Join-Path $PrivateBackupRoot "cecil-control-flow-$Version.json"
$controlFlowObfuscationReport | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $controlFlowReportPath -Encoding UTF8
Copy-Item -LiteralPath $controlFlowReportPath -Destination $LocalPrivateBackupRoot -Force

$antiDecompileReport = Invoke-CecilAntiDecompile `
    -Path $protectedInputDll `
    -TargetListPath $AntiDecompileAllowlistPath
$antiDecompileReportPath = Join-Path $PrivateBackupRoot "anti-decompile-$Version.json"
$antiDecompileReport | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $antiDecompileReportPath -Encoding UTF8
Copy-Item -LiteralPath $antiDecompileReportPath -Destination $LocalPrivateBackupRoot -Force
$repairOutput2 = & dotnet run --project $repairToolProject -- (ConvertTo-FullPath $protectedInputDll) 2>&1
if ($LASTEXITCODE -ne 0) { throw "RepairCoreLibReference failed (post-Cecil): $repairOutput2" }
Write-Host "System.Private.CoreLib repair (post-Cecil): $repairOutput2"
Test-BinaryLeak -Path $protectedInputDll

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

$stringEncryptionReport = Invoke-CecilStringEncryption `
    -Path $obfuscatedDll `
    -TargetListPath $StringEncryptionAllowlistPath `
    -SourceReport $stringDecryptorSourceReport `
    -MappingPath (Join-Path $outputDir "Mapping.txt")
if (-not $DisableCecilStringEncryption -and [int]$stringEncryptionReport.EncryptedStringCount -le 0) {
    throw "Cecil string encryption did not encrypt any string literals."
}
$stringEncryptionReportPath = Join-Path $PrivateBackupRoot "cecil-string-encryption-$Version.json"
$stringEncryptionReport | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $stringEncryptionReportPath -Encoding UTF8
Copy-Item -LiteralPath $stringEncryptionReportPath -Destination $LocalPrivateBackupRoot -Force

$hideStringsImpactReport = Get-HideStringsImpactReport `
    -Path $obfuscatedDll `
    -StringEncryptionReport $stringEncryptionReport
$hideStringsImpactReportPath = Join-Path $PrivateBackupRoot "hide-strings-impact-$Version.json"
$hideStringsImpactReport | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $hideStringsImpactReportPath -Encoding UTF8
Copy-Item -LiteralPath $hideStringsImpactReportPath -Destination $LocalPrivateBackupRoot -Force

$repairOutputPostObfuscar = & dotnet run --project $repairToolProject -- (ConvertTo-FullPath $obfuscatedDll) 2>&1
if ($LASTEXITCODE -ne 0) { throw "RepairCoreLibReference failed (post-Obfuscar): $repairOutputPostObfuscar" }
Write-Host "System.Private.CoreLib repair (post-Obfuscar): $repairOutputPostObfuscar"
$branchSanitizationReport = Invoke-CecilBranchSanitization -Path $obfuscatedDll
Write-Host "Post-pipeline branch sanitization: expanded=$($branchSanitizationReport.ExpandedShortBranchCount) methods=$($branchSanitizationReport.SanitizedMethodCount)"
Test-ForbiddenAssemblyReferences -Path $obfuscatedDll
Test-UnityEditorWindowFieldNameCollisions -Path $obfuscatedDll -Scan $scan
$patchedAfterObfuscar = Clear-SourceDocumentPaths -Path $obfuscatedDll
Write-Host "Source document paths sanitized after Obfuscar: $patchedAfterObfuscar"
$patchedDebugSymbolsAfterObfuscar = Clear-DebugSymbolPaths -Path $obfuscatedDll
Write-Host "Debug symbol paths sanitized after Obfuscar: $patchedDebugSymbolsAfterObfuscar"
Test-BinaryLeak -Path $obfuscatedDll
Test-StringHidingProbeAbsent -Path $obfuscatedDll
Invoke-CodeSign -Path $obfuscatedDll -Context $codeSigningContext
Test-CodeSignature -Path $obfuscatedDll -Context $codeSigningContext
Save-CodeSignatureReport -Path $obfuscatedDll -ReportName "signature-obfuscated-$Version.json" -Context $codeSigningContext
$runtimeIntegritySidecarPath = Join-Path $outputDir $RuntimeIntegritySidecarFileName
$runtimeIntegritySidecarReport = Write-RuntimeIntegritySidecar `
    -DllPath $obfuscatedDll `
    -SidecarPath $runtimeIntegritySidecarPath `
    -Context $codeSigningContext
Test-BinaryLeak -Path $obfuscatedDll
Test-StringHidingProbeAbsent -Path $obfuscatedDll

Get-ChildItem -LiteralPath $outputDir -Force |
    Where-Object { $_.Name -match 'Mapping|rename|report|obfuscar' } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $PrivateBackupRoot -Force
        Copy-Item -LiteralPath $_.FullName -Destination $LocalPrivateBackupRoot -Force
    }

Initialize-ProjectPackage
$packagedDll = Join-Path $ProjectPackageRoot "Editor\$AssemblyFileName"
Copy-Item -LiteralPath $obfuscatedDll -Destination $packagedDll -Force
$packagedRuntimeIntegritySidecar = Join-Path $ProjectPackageRoot "Editor\$RuntimeIntegritySidecarFileName"
if ($runtimeIntegritySidecarReport.Created) {
    Copy-Item -LiteralPath $runtimeIntegritySidecarPath -Destination $packagedRuntimeIntegritySidecar -Force
    Test-RuntimeIntegritySidecarFile `
        -DllPath $packagedDll `
        -SidecarPath $packagedRuntimeIntegritySidecar `
        -ExpectedThumbprint $codeSigningContext.ExpectedThumbprint
}
elseif (Test-Path -LiteralPath $packagedRuntimeIntegritySidecar) {
    Remove-Item -LiteralPath $packagedRuntimeIntegritySidecar -Force
}
Test-CodeSignature -Path $packagedDll -Context $codeSigningContext
Test-ForbiddenAssemblyReferences -Path $packagedDll
Test-UnityEditorWindowFieldNameCollisions -Path $packagedDll -Scan $scan

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "BuildVpmRepository.ps1") -ProjectRoot $ProjectRoot -BaseUrl $BaseUrl -MinimumPublishedVersion $Version
if ($LASTEXITCODE -ne 0) {
    throw "VPM repository build failed."
}

$zipPath = Join-Path $RepoRoot "packages\$PackageId-$Version.zip"
Test-PackageZip -ZipPath $zipPath
Test-CodeSignature -Path $packagedDll -Context $codeSigningContext
Save-CodeSignatureReport -Path $packagedDll -ReportName "signature-packaged-$Version.json" -Context $codeSigningContext
Test-BinaryLeak -Path $packagedDll
Test-StringHidingProbeAbsent -Path $packagedDll
Write-PublicChecksumManifest `
    -ZipPath $zipPath `
    -DllPath $packagedDll `
    -RuntimeIntegritySidecarPath $packagedRuntimeIntegritySidecar `
    -Context $codeSigningContext
Write-PublicDetachedSignatures `
    -ZipPath $zipPath `
    -ChecksumPath (Join-Path $RepoRoot "checksums\$PackageId-$Version.sha256.txt") `
    -IndexPath (Join-Path $RepoRoot "index.json") `
    -Context $codeSigningContext
Test-PublicReleaseSecrets
Write-ProtectionBuildReport `
    -Scan $scan `
    -PublicApiReport $publicApiReport `
    -RuntimeIntegritySourceReport $runtimeIntegritySourceReport `
    -RuntimeIntegrityInjectionReport $runtimeIntegrityInjectionReport `
    -AntiDebugReport $antiDebugReport `
    -StringEncryptionReport $stringEncryptionReport `
    -HideStringsImpactReport $hideStringsImpactReport `
    -AntiDecompileReport $antiDecompileReport `
    -BranchSanitizationReport $branchSanitizationReport `
    -RuntimeIntegritySidecarReport $runtimeIntegritySidecarReport `
    -ControlFlowObfuscationReport $controlFlowObfuscationReport `
    -InputDll $protectedInputDll `
    -ObfuscatedDll $obfuscatedDll `
    -SignedDll $packagedDll `
    -ZipPath $zipPath `
    -ChecksumPath (Join-Path $RepoRoot "checksums\$PackageId-$Version.sha256.txt") `
    -ObfuscarConfigPath $configPath `
    -CodeSigningContext $codeSigningContext

Write-Host "Protected package created: $zipPath"
Write-Host "Private backup root: $PrivateBackupRoot"
Write-Host "Local private backup root: $LocalPrivateBackupRoot"
