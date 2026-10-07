#requires -Version 7.2
param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'))

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath($RepositoryRoot)
Import-Module (Join-Path $PSScriptRoot 'UpdateNotificationManifest.psm1') -Force
$packageId = 'com.nickel-jp.avatar-recovery'
$indexPath = Join-Path $repoRoot 'index.json'
$index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
$version = @($index.packages.$packageId.versions.PSObject.Properties.Name | Sort-Object { [version]$_ } -Descending)[0]
$packagePath = Join-Path $repoRoot "packages\$packageId-$version.zip"
$manifestJson = Get-Content -LiteralPath (Join-Path $repoRoot 'update-manifest.json') -Raw
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Join-Path $repoRoot 'certificates\avatar-recovery-self-signed-code-signing.cer'))
try {
    $validationArguments = @{
        TrustedRootCertificate=$certificate
        ExpectedPackageId=$packageId
        ExpectedVersion=$version
        ExpectedSourceIndexSha256=(Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()
        ExpectedPackageSha256=(Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $verified = Test-AvatarRecoveryUpdateManifestDocument -ManifestJson $manifestJson @validationArguments
    # 正常系だけでなく、公開情報だけでは署名を置き換えられないことも検証します。
    foreach ($signatureField in @('authorizationSignatureBase64','payloadSignatureBase64')) {
        $altered = $manifestJson | ConvertFrom-Json
        $bytes = [Convert]::FromBase64String($altered.$signatureField)
        $bytes[0] = $bytes[0] -bxor 1
        $altered.$signatureField = [Convert]::ToBase64String($bytes)
        $rejected = $false
        try {
            $null = Test-AvatarRecoveryUpdateManifestDocument -ManifestJson ($altered | ConvertTo-Json -Compress -Depth 10) @validationArguments
        } catch {
            if ($_.Exception.Message -notmatch 'signature verification failed') { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw "Modified signature was accepted: $signatureField" }
    }
    Write-Output "Update manifest verified: $version; signature rejection checks: 2 passed."
} finally { $certificate.Dispose() }
