Set-StrictMode -Version 3.0

$script:ManifestEnvelopeFormat = "AvatarRecovery update manifest envelope v1"
$script:NotificationPayloadFormat = "AvatarRecovery update notification payload v1"
$script:AuthorizationPayloadFormat = "AvatarRecovery notification signer authorization v1"
$script:PublishedManifestUrl = "https://nickel-jp.github.io/avatar-recovery-unity/update-manifest.json"
$script:MaximumPublicationClockSkew = [TimeSpan]::FromMinutes(15)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function ConvertTo-ExactUtcString {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$FieldName is required."
    }

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString("O", $script:InvariantCulture)
    }
    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]([DateTime]$Value)).ToUniversalTime().ToString("O", $script:InvariantCulture)
    }

    try {
        $parsed = [DateTimeOffset]::ParseExact(
            [string]$Value,
            "O",
            $script:InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        throw "$FieldName must use the round-trip UTC timestamp format."
    }

    if ($parsed.Offset -ne [TimeSpan]::Zero) {
        throw "$FieldName must be UTC."
    }

    return $parsed.ToUniversalTime().ToString("O", $script:InvariantCulture)
}

function ConvertTo-UInt64DecimalString {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [switch]$AllowZero
    )

    if ($Value -notmatch '^(0|[1-9][0-9]*)$') {
        throw "$FieldName must be an unsigned decimal integer without leading zeroes."
    }

    [UInt64]$parsed = 0
    if (-not [UInt64]::TryParse(
            $Value,
            [System.Globalization.NumberStyles]::None,
            $script:InvariantCulture,
            [ref]$parsed)) {
        throw "$FieldName is outside the UInt64 range."
    }

    if (-not $AllowZero -and $parsed -eq [UInt64]0) {
        throw "$FieldName must be greater than zero."
    }

    return $parsed.ToString($script:InvariantCulture)
}

function Assert-StableSemanticVersion {
    param([Parameter(Mandatory = $true)][string]$Version)

    if ($Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "latestStableVersion must be a stable semantic version."
    }
}

function Compare-AvatarRecoveryStableVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    Assert-StableSemanticVersion -Version $Left
    Assert-StableSemanticVersion -Version $Right
    $leftParts = $Left.Split('.')
    $rightParts = $Right.Split('.')
    for ($index = 0; $index -lt 3; $index++) {
        if ($leftParts[$index].Length -lt $rightParts[$index].Length) {
            return -1
        }
        if ($leftParts[$index].Length -gt $rightParts[$index].Length) {
            return 1
        }

        $comparison = [string]::CompareOrdinal(
            $leftParts[$index],
            $rightParts[$index])
        if ($comparison -lt 0) {
            return -1
        }
        if ($comparison -gt 0) {
            return 1
        }
    }

    return 0
}

function Assert-PackageId {
    param([Parameter(Mandatory = $true)][string]$PackageId)

    if ($PackageId -notmatch '^[a-z0-9]+(?:[.-][a-z0-9]+)*$') {
        throw "packageId has an invalid format."
    }
}

function Assert-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$FieldName must be a lowercase SHA-256 hex string."
    }
}

function ConvertTo-CanonicalJsonBytes {
    param([Parameter(Mandatory = $true)]$Value)

    $json = $Value | ConvertTo-Json -Depth 20 -Compress
    return ,$script:Utf8NoBom.GetBytes($json)
}

function ConvertFrom-StrictCanonicalJsonBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPropertyNames,
        [Parameter(Mandatory = $true)][string]$DocumentName
    )

    try {
        $json = $script:Utf8NoBom.GetString($Bytes)
        $value = $json | ConvertFrom-Json
    }
    catch {
        throw "$DocumentName is not valid strict UTF-8 JSON."
    }

    if ($null -eq $value -or $value -is [Array]) {
        throw "$DocumentName must be a JSON object."
    }

    $actualPropertyNames = @($value.PSObject.Properties.Name)
    if ($actualPropertyNames.Count -ne $ExpectedPropertyNames.Count) {
        throw "$DocumentName contains an unexpected property count."
    }

    for ($index = 0; $index -lt $ExpectedPropertyNames.Count; $index++) {
        if ($actualPropertyNames[$index] -cne $ExpectedPropertyNames[$index]) {
            throw "$DocumentName property order or name is invalid at index $index."
        }
    }

    return $value
}

function ConvertFrom-RequiredBase64 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$FieldName is required."
    }

    try {
        return ,([Convert]::FromBase64String($Value))
    }
    catch {
        throw "$FieldName is not valid Base64."
    }
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPropertyNames,
        [Parameter(Mandatory = $true)][string]$DocumentName,
        [switch]$RequireOrder
    )

    if ($null -eq $Value -or $Value -is [Array]) {
        throw "$DocumentName must be a JSON object."
    }

    $actualPropertyNames = @($Value.PSObject.Properties.Name)
    if ($actualPropertyNames.Count -ne $ExpectedPropertyNames.Count) {
        throw "$DocumentName contains an unexpected property count."
    }

    foreach ($expectedName in $ExpectedPropertyNames) {
        if ($actualPropertyNames -cnotcontains $expectedName) {
            throw "$DocumentName is missing property: $expectedName"
        }
    }

    if ($RequireOrder) {
        for ($index = 0; $index -lt $ExpectedPropertyNames.Count; $index++) {
            if ($actualPropertyNames[$index] -cne $ExpectedPropertyNames[$index]) {
                throw "$DocumentName property order is invalid at index $index."
            }
        }
    }
}

function Assert-ByteArraysEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Expected,
        [Parameter(Mandatory = $true)][byte[]]$Actual,
        [Parameter(Mandatory = $true)][string]$DocumentName
    )

    if ($Expected.Length -ne $Actual.Length) {
        throw "$DocumentName is not in canonical JSON form."
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            throw "$DocumentName is not in canonical JSON form."
        }
    }
}

function Get-RsaPrivateKey {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $privateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if ($null -eq $privateKey) {
        throw "$Role certificate does not have an RSA private key."
    }

    if ($privateKey.KeySize -lt 2048) {
        $privateKey.Dispose()
        throw "$Role RSA key must be at least 2048 bits."
    }

    return $privateKey
}

function Get-RsaPublicKey {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $publicKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($Certificate)
    if ($null -eq $publicKey) {
        throw "$Role certificate does not have an RSA public key."
    }

    if ($publicKey.KeySize -lt 2048) {
        $publicKey.Dispose()
        throw "$Role RSA key must be at least 2048 bits."
    }

    return $publicKey
}

function Test-CertificatePublicKeysEqual {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$First,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Second
    )

    $firstKey = Get-RsaPublicKey -Certificate $First -Role "first"
    $secondKey = Get-RsaPublicKey -Certificate $Second -Role "second"
    try {
        $firstParameters = $firstKey.ExportParameters($false)
        $secondParameters = $secondKey.ExportParameters($false)
        return (
            [Convert]::ToBase64String($firstParameters.Modulus) -ceq [Convert]::ToBase64String($secondParameters.Modulus) -and
            [Convert]::ToBase64String($firstParameters.Exponent) -ceq [Convert]::ToBase64String($secondParameters.Exponent))
    }
    finally {
        $firstKey.Dispose()
        $secondKey.Dispose()
    }
}

function ConvertTo-AvatarRecoveryUpdateSequence {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Version)

    Assert-StableSemanticVersion -Version $Version
    $parts = $Version.Split('.')
    [Decimal]$major = [Decimal]::Parse($parts[0], $script:InvariantCulture)
    [Decimal]$minor = [Decimal]::Parse($parts[1], $script:InvariantCulture)
    [Decimal]$patch = [Decimal]::Parse($parts[2], $script:InvariantCulture)
    if ($minor -gt 999 -or $patch -gt 999) {
        throw "Semantic version minor and patch components must be at most 999 for automatic sequence generation."
    }

    [Decimal]$sequenceDecimal = $major * [Decimal]1000000000000 + $minor * [Decimal]1000000000 + $patch * [Decimal]1000000
    if ($sequenceDecimal -gt [Decimal][UInt64]::MaxValue) {
        throw "Semantic version is too large for automatic sequence generation."
    }
    [UInt64]$sequence = [UInt64]$sequenceDecimal
    if ($sequence -eq [UInt64]0) {
        throw "Version 0.0.0 cannot be published as an update notification."
    }

    return $sequence.ToString($script:InvariantCulture)
}

function New-AvatarRecoveryUpdateManifestDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$LatestStableVersion,
        [Parameter(Mandatory = $true)][string]$Sequence,
        [Parameter(Mandatory = $true)][string]$PublishedAtUtc,
        [Parameter(Mandatory = $true)][string]$ExpiresAtUtc,
        [Parameter(Mandatory = $true)][string]$SourceIndexSha256,
        [Parameter(Mandatory = $true)][string]$PackageSha256,
        [Parameter(Mandatory = $true)][string]$AuthorizationNotBeforeUtc,
        [Parameter(Mandatory = $true)][string]$AuthorizationNotAfterUtc,
        [Parameter(Mandatory = $true)][string]$AuthorizationMinimumSequence,
        [Parameter(Mandatory = $true)][string]$AuthorizationMaximumSequence,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$RootSigningCertificate,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$ReleaseSigningCertificate
    )

    Assert-PackageId -PackageId $PackageId
    Assert-StableSemanticVersion -Version $LatestStableVersion
    $Sequence = ConvertTo-UInt64DecimalString -Value $Sequence -FieldName "sequence"
    $AuthorizationMinimumSequence = ConvertTo-UInt64DecimalString -Value $AuthorizationMinimumSequence -FieldName "minimumSequence"
    $AuthorizationMaximumSequence = ConvertTo-UInt64DecimalString -Value $AuthorizationMaximumSequence -FieldName "maximumSequence"
    $PublishedAtUtc = ConvertTo-ExactUtcString -Value $PublishedAtUtc -FieldName "publishedAtUtc"
    $ExpiresAtUtc = ConvertTo-ExactUtcString -Value $ExpiresAtUtc -FieldName "expiresAtUtc"
    $AuthorizationNotBeforeUtc = ConvertTo-ExactUtcString -Value $AuthorizationNotBeforeUtc -FieldName "notBeforeUtc"
    $AuthorizationNotAfterUtc = ConvertTo-ExactUtcString -Value $AuthorizationNotAfterUtc -FieldName "notAfterUtc"
    Assert-Sha256Hex -Value $SourceIndexSha256 -FieldName "sourceIndexSha256"
    Assert-Sha256Hex -Value $PackageSha256 -FieldName "packageSha256"

    [UInt64]$sequenceValue = [UInt64]::Parse($Sequence, $script:InvariantCulture)
    [UInt64]$minimumSequenceValue = [UInt64]::Parse($AuthorizationMinimumSequence, $script:InvariantCulture)
    [UInt64]$maximumSequenceValue = [UInt64]::Parse($AuthorizationMaximumSequence, $script:InvariantCulture)
    if ($minimumSequenceValue -gt $maximumSequenceValue -or
        $sequenceValue -lt $minimumSequenceValue -or
        $sequenceValue -gt $maximumSequenceValue) {
        throw "sequence is outside the authorized sequence range."
    }

    $publishedAt = [DateTimeOffset]::ParseExact($PublishedAtUtc, "O", $script:InvariantCulture)
    $expiresAt = [DateTimeOffset]::ParseExact($ExpiresAtUtc, "O", $script:InvariantCulture)
    $notBefore = [DateTimeOffset]::ParseExact($AuthorizationNotBeforeUtc, "O", $script:InvariantCulture)
    $notAfter = [DateTimeOffset]::ParseExact($AuthorizationNotAfterUtc, "O", $script:InvariantCulture)
    $releaseCertificateNotBefore = ([DateTimeOffset]$ReleaseSigningCertificate.NotBefore).ToUniversalTime()
    $releaseCertificateNotAfter = ([DateTimeOffset]$ReleaseSigningCertificate.NotAfter).ToUniversalTime()
    if ($expiresAt -le $publishedAt) {
        throw "expiresAtUtc must be later than publishedAtUtc."
    }
    if ($expiresAt -gt $notAfter) {
        throw "expiresAtUtc must not exceed notAfterUtc."
    }
    if ($notAfter -le $notBefore -or $publishedAt -lt $notBefore -or $publishedAt -gt $notAfter) {
        throw "publishedAtUtc is outside the signer authorization period."
    }
    if ($notBefore -lt $releaseCertificateNotBefore -or
        $notAfter -gt $releaseCertificateNotAfter) {
        throw "Notification validity is outside the release certificate validity period."
    }

    $releaseCertificateBytes = $ReleaseSigningCertificate.RawData
    $releaseCertificateSha256 = Get-Sha256Hex -Bytes $releaseCertificateBytes

    $payload = [ordered]@{
        format = $script:NotificationPayloadFormat
        packageId = $PackageId
        sequence = $Sequence
        latestStableVersion = $LatestStableVersion
        publishedAtUtc = $PublishedAtUtc
        expiresAtUtc = $ExpiresAtUtc
        sourceIndexSha256 = $SourceIndexSha256
        packageSha256 = $PackageSha256
    }
    $payloadBytes = ConvertTo-CanonicalJsonBytes -Value $payload

    $authorization = [ordered]@{
        format = $script:AuthorizationPayloadFormat
        packageId = $PackageId
        signerCertificateSha256 = $releaseCertificateSha256
        notBeforeUtc = $AuthorizationNotBeforeUtc
        notAfterUtc = $AuthorizationNotAfterUtc
        minimumSequence = $AuthorizationMinimumSequence
        maximumSequence = $AuthorizationMaximumSequence
    }
    $authorizationBytes = ConvertTo-CanonicalJsonBytes -Value $authorization

    $rootPrivateKey = Get-RsaPrivateKey -Certificate $RootSigningCertificate -Role "root signing"
    try {
        $authorizationSignature = $rootPrivateKey.SignData(
            $authorizationBytes,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    }
    finally {
        $rootPrivateKey.Dispose()
    }

    $releasePrivateKey = Get-RsaPrivateKey -Certificate $ReleaseSigningCertificate -Role "release signing"
    try {
        $payloadSignature = $releasePrivateKey.SignData(
            $payloadBytes,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    }
    finally {
        $releasePrivateKey.Dispose()
    }

    $envelope = [ordered]@{
        format = $script:ManifestEnvelopeFormat
        payloadBase64 = [Convert]::ToBase64String($payloadBytes)
        releaseCertificateBase64 = [Convert]::ToBase64String($releaseCertificateBytes)
        authorizationPayloadBase64 = [Convert]::ToBase64String($authorizationBytes)
        authorizationSignatureBase64 = [Convert]::ToBase64String($authorizationSignature)
        payloadSignatureBase64 = [Convert]::ToBase64String($payloadSignature)
    }

    return [PSCustomObject]@{
        Json = ($envelope | ConvertTo-Json -Depth 20 -Compress)
        Envelope = [PSCustomObject]$envelope
        Payload = [PSCustomObject]$payload
        Authorization = [PSCustomObject]$authorization
        PayloadBytes = $payloadBytes
        AuthorizationBytes = $authorizationBytes
    }
}

function Test-AvatarRecoveryUpdateManifestDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ManifestJson,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$TrustedRootCertificate,
        [string]$ExpectedPackageId = "",
        [string]$ExpectedVersion = "",
        [string]$ExpectedSourceIndexSha256 = "",
        [string]$ExpectedPackageSha256 = "",
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::MinValue,
        [switch]$AllowExpired
    )

    try {
        $envelope = $ManifestJson | ConvertFrom-Json
    }
    catch {
        throw "Update notification manifest is not valid JSON."
    }

    $envelopeProperties = @(
        "format",
        "payloadBase64",
        "releaseCertificateBase64",
        "authorizationPayloadBase64",
        "authorizationSignatureBase64",
        "payloadSignatureBase64")
    Assert-ExactProperties -Value $envelope -ExpectedPropertyNames $envelopeProperties -DocumentName "manifest envelope"
    if ([string]$envelope.format -cne $script:ManifestEnvelopeFormat) {
        throw "Unsupported update notification manifest format."
    }

    $canonicalEnvelope = [ordered]@{
        format = [string]$envelope.format
        payloadBase64 = [string]$envelope.payloadBase64
        releaseCertificateBase64 = [string]$envelope.releaseCertificateBase64
        authorizationPayloadBase64 = [string]$envelope.authorizationPayloadBase64
        authorizationSignatureBase64 = [string]$envelope.authorizationSignatureBase64
        payloadSignatureBase64 = [string]$envelope.payloadSignatureBase64
    }
    $canonicalEnvelopeJson = $canonicalEnvelope | ConvertTo-Json -Depth 10 -Compress
    if ($ManifestJson.Trim() -cne $canonicalEnvelopeJson) {
        throw "Manifest envelope is not canonical or contains duplicate properties."
    }

    $payloadBytes = ConvertFrom-RequiredBase64 -Value ([string]$envelope.payloadBase64) -FieldName "payloadBase64"
    $releaseCertificateBytes = ConvertFrom-RequiredBase64 -Value ([string]$envelope.releaseCertificateBase64) -FieldName "releaseCertificateBase64"
    $authorizationBytes = ConvertFrom-RequiredBase64 -Value ([string]$envelope.authorizationPayloadBase64) -FieldName "authorizationPayloadBase64"
    $authorizationSignature = ConvertFrom-RequiredBase64 -Value ([string]$envelope.authorizationSignatureBase64) -FieldName "authorizationSignatureBase64"
    $payloadSignature = ConvertFrom-RequiredBase64 -Value ([string]$envelope.payloadSignatureBase64) -FieldName "payloadSignatureBase64"

    $payloadProperties = @(
        "format",
        "packageId",
        "sequence",
        "latestStableVersion",
        "publishedAtUtc",
        "expiresAtUtc",
        "sourceIndexSha256",
        "packageSha256")
    $payload = ConvertFrom-StrictCanonicalJsonBytes `
        -Bytes $payloadBytes `
        -ExpectedPropertyNames $payloadProperties `
        -DocumentName "notification payload"

    $authorizationProperties = @(
        "format",
        "packageId",
        "signerCertificateSha256",
        "notBeforeUtc",
        "notAfterUtc",
        "minimumSequence",
        "maximumSequence")
    $authorization = ConvertFrom-StrictCanonicalJsonBytes `
        -Bytes $authorizationBytes `
        -ExpectedPropertyNames $authorizationProperties `
        -DocumentName "signer authorization"

    if ([string]$payload.format -cne $script:NotificationPayloadFormat) {
        throw "Unsupported update notification payload format."
    }
    if ([string]$authorization.format -cne $script:AuthorizationPayloadFormat) {
        throw "Unsupported signer authorization format."
    }

    Assert-PackageId -PackageId ([string]$payload.packageId)
    Assert-StableSemanticVersion -Version ([string]$payload.latestStableVersion)
    $sequence = ConvertTo-UInt64DecimalString -Value ([string]$payload.sequence) -FieldName "sequence"
    $publishedAtUtc = ConvertTo-ExactUtcString -Value $payload.publishedAtUtc -FieldName "publishedAtUtc"
    $expiresAtUtc = ConvertTo-ExactUtcString -Value $payload.expiresAtUtc -FieldName "expiresAtUtc"
    Assert-Sha256Hex -Value ([string]$payload.sourceIndexSha256) -FieldName "sourceIndexSha256"
    Assert-Sha256Hex -Value ([string]$payload.packageSha256) -FieldName "packageSha256"

    Assert-PackageId -PackageId ([string]$authorization.packageId)
    Assert-Sha256Hex -Value ([string]$authorization.signerCertificateSha256) -FieldName "signerCertificateSha256"
    $notBeforeUtc = ConvertTo-ExactUtcString -Value $authorization.notBeforeUtc -FieldName "notBeforeUtc"
    $notAfterUtc = ConvertTo-ExactUtcString -Value $authorization.notAfterUtc -FieldName "notAfterUtc"
    $minimumSequence = ConvertTo-UInt64DecimalString -Value ([string]$authorization.minimumSequence) -FieldName "minimumSequence"
    $maximumSequence = ConvertTo-UInt64DecimalString -Value ([string]$authorization.maximumSequence) -FieldName "maximumSequence"

    $canonicalPayload = [ordered]@{
        format = [string]$payload.format
        packageId = [string]$payload.packageId
        sequence = $sequence
        latestStableVersion = [string]$payload.latestStableVersion
        publishedAtUtc = $publishedAtUtc
        expiresAtUtc = $expiresAtUtc
        sourceIndexSha256 = [string]$payload.sourceIndexSha256
        packageSha256 = [string]$payload.packageSha256
    }
    Assert-ByteArraysEqual `
        -Expected (ConvertTo-CanonicalJsonBytes -Value $canonicalPayload) `
        -Actual $payloadBytes `
        -DocumentName "notification payload"
    $canonicalAuthorization = [ordered]@{
        format = [string]$authorization.format
        packageId = [string]$authorization.packageId
        signerCertificateSha256 = [string]$authorization.signerCertificateSha256
        notBeforeUtc = $notBeforeUtc
        notAfterUtc = $notAfterUtc
        minimumSequence = $minimumSequence
        maximumSequence = $maximumSequence
    }
    Assert-ByteArraysEqual `
        -Expected (ConvertTo-CanonicalJsonBytes -Value $canonicalAuthorization) `
        -Actual $authorizationBytes `
        -DocumentName "signer authorization"

    if ([string]$payload.packageId -cne [string]$authorization.packageId) {
        throw "Payload and authorization packageId values do not match."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPackageId) -and [string]$payload.packageId -cne $ExpectedPackageId) {
        throw "Unexpected packageId in notification payload."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and [string]$payload.latestStableVersion -cne $ExpectedVersion) {
        throw "Unexpected latestStableVersion in notification payload."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceIndexSha256) -and
        [string]$payload.sourceIndexSha256 -cne $ExpectedSourceIndexSha256) {
        throw "Unexpected sourceIndexSha256 in notification payload."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPackageSha256) -and
        [string]$payload.packageSha256 -cne $ExpectedPackageSha256) {
        throw "Unexpected packageSha256 in notification payload."
    }

    $actualReleaseCertificateSha256 = Get-Sha256Hex -Bytes $releaseCertificateBytes
    if ($actualReleaseCertificateSha256 -cne [string]$authorization.signerCertificateSha256) {
        throw "Release certificate hash does not match the signer authorization."
    }

    $rootPublicKey = Get-RsaPublicKey -Certificate $TrustedRootCertificate -Role "trusted root"
    try {
        if (-not $rootPublicKey.VerifyData(
                $authorizationBytes,
                $authorizationSignature,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
            throw "Signer authorization signature verification failed."
        }
    }
    finally {
        $rootPublicKey.Dispose()
    }

    $releaseCertificateNotBefore = [DateTimeOffset]::MinValue
    $releaseCertificateNotAfter = [DateTimeOffset]::MinValue
    $releaseCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($releaseCertificateBytes)
    try {
        $releaseCertificateNotBefore = ([DateTimeOffset]$releaseCertificate.NotBefore).ToUniversalTime()
        $releaseCertificateNotAfter = ([DateTimeOffset]$releaseCertificate.NotAfter).ToUniversalTime()
        $releasePublicKey = Get-RsaPublicKey -Certificate $releaseCertificate -Role "release"
        try {
            if (-not $releasePublicKey.VerifyData(
                    $payloadBytes,
                    $payloadSignature,
                    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
                throw "Notification payload signature verification failed."
            }
        }
        finally {
            $releasePublicKey.Dispose()
        }
    }
    finally {
        $releaseCertificate.Dispose()
    }

    [UInt64]$sequenceValue = [UInt64]::Parse($sequence, $script:InvariantCulture)
    [UInt64]$minimumSequenceValue = [UInt64]::Parse($minimumSequence, $script:InvariantCulture)
    [UInt64]$maximumSequenceValue = [UInt64]::Parse($maximumSequence, $script:InvariantCulture)
    if ($minimumSequenceValue -gt $maximumSequenceValue -or
        $sequenceValue -lt $minimumSequenceValue -or
        $sequenceValue -gt $maximumSequenceValue) {
        throw "Notification sequence is outside the authorized range."
    }

    $publishedAt = [DateTimeOffset]::ParseExact($publishedAtUtc, "O", $script:InvariantCulture)
    $expiresAt = [DateTimeOffset]::ParseExact($expiresAtUtc, "O", $script:InvariantCulture)
    $notBefore = [DateTimeOffset]::ParseExact($notBeforeUtc, "O", $script:InvariantCulture)
    $notAfter = [DateTimeOffset]::ParseExact($notAfterUtc, "O", $script:InvariantCulture)
    if ($expiresAt -le $publishedAt) {
        throw "Notification payload expiry is not later than publication."
    }
    if ($expiresAt -gt $notAfter) {
        throw "Notification payload expiry exceeds the signer authorization period."
    }
    if ($notAfter -le $notBefore -or $publishedAt -lt $notBefore -or $publishedAt -gt $notAfter) {
        throw "Notification publication time is outside the signer authorization period."
    }
    if ($notBefore -lt $releaseCertificateNotBefore -or
        $notAfter -gt $releaseCertificateNotAfter) {
        throw "Notification validity is outside the release certificate validity period."
    }

    if ($NowUtc -eq [DateTimeOffset]::MinValue) {
        $NowUtc = [DateTimeOffset]::UtcNow
    }
    else {
        $NowUtc = $NowUtc.ToUniversalTime()
    }
    if ($publishedAt -gt $NowUtc.Add($script:MaximumPublicationClockSkew)) {
        throw "Notification publication time is too far in the future."
    }
    if ($NowUtc -lt $notBefore -or
        (-not $AllowExpired -and $NowUtc -gt $notAfter)) {
        throw "Signer authorization is not active at the verification time."
    }
    if (-not $AllowExpired -and $NowUtc -gt $expiresAt) {
        throw "Update notification manifest has expired."
    }

    return [PSCustomObject]@{
        Status = "Valid"
        Payload = $payload
        Authorization = $authorization
        ReleaseCertificateSha256 = $actualReleaseCertificateSha256
        PayloadBytes = $payloadBytes
        AuthorizationBytes = $authorizationBytes
    }
}

function Get-RemoteManifestResponse {
    param(
        [AllowNull()][scriptblock]$Provider,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    if ($null -ne $Provider) {
        $provided = & $Provider
        if ($null -eq $provided -or $null -eq $provided.PSObject.Properties["StatusCode"]) {
            throw "Remote manifest test provider returned an invalid response."
        }
        return [PSCustomObject]@{
            StatusCode = [int]$provided.StatusCode
            Body = if ($null -eq $provided.PSObject.Properties["Body"]) { "" } else { [string]$provided.Body }
        }
    }

    $separator = if ($script:PublishedManifestUrl.Contains("?")) { "&" } else { "?" }
    $url = "$($script:PublishedManifestUrl)$separator`cb=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    try {
        $response = Invoke-WebRequest `
            -Uri $url `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSeconds `
            -Headers @{ "Cache-Control" = "no-cache" }
        $body = if ($response.Content -is [byte[]]) {
            $script:Utf8NoBom.GetString([byte[]]$response.Content)
        }
        else {
            [string]$response.Content
        }
        return [PSCustomObject]@{
            StatusCode = [int]$response.StatusCode
            Body = $body
        }
    }
    catch {
        $statusCode = 0
        $response = $_.Exception.Response
        if ($null -ne $response -and $null -ne $response.StatusCode) {
            try {
                $statusCode = [int]$response.StatusCode
            }
            catch {
                $statusCode = [int]$response.StatusCode.value__
            }
        }
        if ($statusCode -eq 404) {
            return [PSCustomObject]@{
                StatusCode = 404
                Body = ""
            }
        }
        throw "Published update notification manifest could not be retrieved from the fixed public URL: $($_.Exception.Message)"
    }
}

function Get-VerifiedManifestSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestJson,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$TrustedRootCertificate,
        [Parameter(Mandatory = $true)][string]$ExpectedPackageId,
        [Parameter(Mandatory = $true)][DateTimeOffset]$NowUtc,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    try {
        $verified = Test-AvatarRecoveryUpdateManifestDocument `
            -ManifestJson $ManifestJson `
            -TrustedRootCertificate $TrustedRootCertificate `
            -ExpectedPackageId $ExpectedPackageId `
            -NowUtc $NowUtc `
            -AllowExpired
    }
    catch {
        throw "$SourceName update notification manifest verification failed: $($_.Exception.Message)"
    }

    return [PSCustomObject]@{
        Json = $ManifestJson.Trim()
        Sequence = [UInt64]::Parse([string]$verified.Payload.sequence, $script:InvariantCulture)
        Version = [string]$verified.Payload.latestStableVersion
        Verified = $verified
    }
}

function Get-RemoteManifestSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$TrustedRootCertificate,
        [Parameter(Mandatory = $true)][string]$ExpectedPackageId,
        [Parameter(Mandatory = $true)][DateTimeOffset]$NowUtc,
        [Parameter(Mandatory = $true)][bool]$AllowInitialPublication
    )

    if ([int]$Response.StatusCode -eq 404) {
        if (-not $AllowInitialPublication) {
            throw "The public update notification manifest returned 404. Initial publication requires -AllowInitialPublication."
        }
        return $null
    }
    if ([int]$Response.StatusCode -ne 200) {
        throw "The public update notification manifest returned HTTP $([int]$Response.StatusCode)."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Response.Body)) {
        throw "The public update notification manifest response was empty."
    }

    return Get-VerifiedManifestSnapshot `
        -ManifestJson ([string]$Response.Body) `
        -TrustedRootCertificate $TrustedRootCertificate `
        -ExpectedPackageId $ExpectedPackageId `
        -NowUtc $NowUtc `
        -SourceName "Remote"
}

function Assert-CandidateAgainstManifestFloor {
    param(
        [Parameter(Mandatory = $true)][UInt64]$CandidateSequence,
        [Parameter(Mandatory = $true)][string]$CandidateVersion,
        [Parameter(Mandatory = $true)][string]$CandidateJson,
        [AllowNull()]$Floor,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    if ($null -eq $Floor) {
        return
    }
    if ($CandidateSequence -lt [UInt64]$Floor.Sequence) {
        throw "$SourceName update notification sequence rollback was rejected."
    }
    if ((Compare-AvatarRecoveryStableVersion `
            -Left $CandidateVersion `
            -Right ([string]$Floor.Version)) -lt 0) {
        throw "$SourceName update notification version rollback was rejected."
    }
    if ($CandidateSequence -eq [UInt64]$Floor.Sequence -and $CandidateJson -cne [string]$Floor.Json) {
        throw "$SourceName manifest cannot be replaced by different content at the same sequence."
    }
}

function Enter-ManifestOutputLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            return [System.IO.File]::Open(
                $LockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                throw "Timed out waiting for the update notification manifest output lock."
            }
            Start-Sleep -Milliseconds 100
        }
    }
    while ($true)
}

function New-AvatarRecoveryPublicArtifactTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$WorkRoot,
        [Parameter(Mandatory = $true)][string[]]$ArtifactPaths
    )

    $repositoryFullPath = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $workFullPath = [System.IO.Path]::GetFullPath($WorkRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $repositoryPrefix = $repositoryFullPath + [System.IO.Path]::DirectorySeparatorChar
    if ($workFullPath.Equals($repositoryFullPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not ($workFullPath + [System.IO.Path]::DirectorySeparatorChar).StartsWith(
            $repositoryPrefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Public artifact transaction work root must be inside the repository."
    }

    $uniquePaths = @($ArtifactPaths |
        ForEach-Object { [System.IO.Path]::GetFullPath($_) } |
        Sort-Object -Unique)
    if ($uniquePaths.Count -eq 0) {
        throw "Public artifact transaction requires at least one artifact path."
    }

    $backupRoot = Join-Path $workFullPath (
        "PublicArtifactTransaction-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $entries = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($artifactPath in $uniquePaths) {
            if (-not ($artifactPath + [System.IO.Path]::DirectorySeparatorChar).StartsWith(
                    $repositoryPrefix,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Public artifact transaction path is outside the repository: $artifactPath"
            }
            if (Test-Path -LiteralPath $artifactPath -PathType Container) {
                throw "Public artifact transaction accepts files only: $artifactPath"
            }

            $relativePath = $artifactPath.Substring($repositoryPrefix.Length)
            $backupPath = Join-Path $backupRoot $relativePath
            $existed = Test-Path -LiteralPath $artifactPath -PathType Leaf
            if ($existed) {
                New-Item -ItemType Directory -Force -Path (
                    Split-Path -Parent $backupPath) | Out-Null
                Copy-Item -LiteralPath $artifactPath -Destination $backupPath -Force
            }

            [void]$entries.Add([PSCustomObject]@{
                ArtifactPath = $artifactPath
                BackupPath = $backupPath
                Existed = [bool]$existed
            })
        }

        return [PSCustomObject]@{
            RepositoryRoot = $repositoryFullPath
            WorkRoot = $workFullPath
            BackupRoot = $backupRoot
            Entries = @($entries.ToArray())
            State = "Active"
        }
    }
    catch {
        if (Test-Path -LiteralPath $backupRoot -PathType Container) {
            Remove-Item -LiteralPath $backupRoot -Recurse -Force
        }
        throw
    }
}

function Restore-AvatarRecoveryPublicArtifactTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)

    if ([string]$Transaction.State -cne "Active") {
        throw "Public artifact transaction is not active."
    }

    foreach ($entry in @($Transaction.Entries)) {
        $artifactPath = [string]$entry.ArtifactPath
        if ([bool]$entry.Existed) {
            $backupPath = [string]$entry.BackupPath
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                throw "Public artifact transaction backup is missing: $backupPath"
            }

            $artifactDirectory = Split-Path -Parent $artifactPath
            New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
            $temporaryPath = Join-Path $artifactDirectory (
                ".public-rollback-" + [Guid]::NewGuid().ToString("N") + ".tmp")
            $replacementBackupPath = $temporaryPath + ".bak"
            try {
                Copy-Item -LiteralPath $backupPath -Destination $temporaryPath -Force
                if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
                    [System.IO.File]::Replace(
                        $temporaryPath,
                        $artifactPath,
                        $replacementBackupPath,
                        $true)
                }
                else {
                    [System.IO.File]::Move($temporaryPath, $artifactPath)
                }
            }
            finally {
                foreach ($temporaryFile in @($temporaryPath, $replacementBackupPath)) {
                    if (Test-Path -LiteralPath $temporaryFile -PathType Leaf) {
                        Remove-Item -LiteralPath $temporaryFile -Force
                    }
                }
            }
        }
        elseif (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
            Remove-Item -LiteralPath $artifactPath -Force
        }
    }

    if (Test-Path -LiteralPath $Transaction.BackupRoot -PathType Container) {
        Remove-Item -LiteralPath $Transaction.BackupRoot -Recurse -Force
    }
    $Transaction.State = "Restored"
}

function Complete-AvatarRecoveryPublicArtifactTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)

    if ([string]$Transaction.State -cne "Active") {
        throw "Public artifact transaction is not active."
    }

    if (Test-Path -LiteralPath $Transaction.BackupRoot -PathType Container) {
        Remove-Item -LiteralPath $Transaction.BackupRoot -Recurse -Force
    }
    $Transaction.State = "Completed"
}

function Write-AvatarRecoveryUpdateManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$LatestStableVersion,
        [Parameter(Mandatory = $true)][string]$Sequence,
        [Parameter(Mandatory = $true)][string]$PublishedAtUtc,
        [Parameter(Mandatory = $true)][string]$ExpiresAtUtc,
        [Parameter(Mandatory = $true)][string]$SourceIndexSha256,
        [Parameter(Mandatory = $true)][string]$PackageSha256,
        [Parameter(Mandatory = $true)][string]$AuthorizationNotBeforeUtc,
        [Parameter(Mandatory = $true)][string]$AuthorizationNotAfterUtc,
        [Parameter(Mandatory = $true)][string]$AuthorizationMinimumSequence,
        [Parameter(Mandatory = $true)][string]$AuthorizationMaximumSequence,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$RootSigningCertificate,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$ReleaseSigningCertificate,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$TrustedRootCertificate,
        [switch]$AllowInitialPublication,
        [switch]$AllowRootAsReleaseSignerForBootstrap,
        [AllowNull()][scriptblock]$RemoteManifestProvider = $null,
        [int]$RemoteTimeoutSeconds = 15,
        [int]$LockTimeoutSeconds = 30,
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::MinValue
    )

    if (-not (Test-CertificatePublicKeysEqual -First $RootSigningCertificate -Second $TrustedRootCertificate)) {
        throw "Root signing certificate does not match the independently trusted root certificate."
    }
    if ((Test-CertificatePublicKeysEqual -First $RootSigningCertificate -Second $ReleaseSigningCertificate) -and
        -not $AllowRootAsReleaseSignerForBootstrap) {
        throw "A dedicated release signing certificate is required. Root-as-release use requires explicit bootstrap authorization."
    }
    if ($RemoteTimeoutSeconds -lt 1 -or $RemoteTimeoutSeconds -gt 120) {
        throw "RemoteTimeoutSeconds must be between 1 and 120."
    }
    if ($LockTimeoutSeconds -lt 1 -or $LockTimeoutSeconds -gt 300) {
        throw "LockTimeoutSeconds must be between 1 and 300."
    }
    if ($NowUtc -eq [DateTimeOffset]::MinValue) {
        $NowUtc = [DateTimeOffset]::UtcNow
    }
    else {
        $NowUtc = $NowUtc.ToUniversalTime()
    }

    $fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $fullOutputPath
    if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
        throw "OutputPath must have a parent directory."
    }
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    $lockPath = "$fullOutputPath.lock"
    $lockStream = Enter-ManifestOutputLock -LockPath $lockPath -TimeoutSeconds $LockTimeoutSeconds
    $temporaryPath = ""
    $backupPath = ""
    try {
        $remoteBeforeResponse = Get-RemoteManifestResponse `
            -Provider $RemoteManifestProvider `
            -TimeoutSeconds $RemoteTimeoutSeconds
        $remoteBefore = Get-RemoteManifestSnapshot `
            -Response $remoteBeforeResponse `
            -TrustedRootCertificate $TrustedRootCertificate `
            -ExpectedPackageId $PackageId `
            -NowUtc $NowUtc `
            -AllowInitialPublication ([bool]$AllowInitialPublication)
        $localBeforeJson = if (Test-Path -LiteralPath $fullOutputPath) {
            [System.IO.File]::ReadAllText($fullOutputPath, $script:Utf8NoBom)
        }
        else {
            $null
        }

        $document = New-AvatarRecoveryUpdateManifestDocument `
            -PackageId $PackageId `
            -LatestStableVersion $LatestStableVersion `
            -Sequence $Sequence `
            -PublishedAtUtc $PublishedAtUtc `
            -ExpiresAtUtc $ExpiresAtUtc `
            -SourceIndexSha256 $SourceIndexSha256 `
            -PackageSha256 $PackageSha256 `
            -AuthorizationNotBeforeUtc $AuthorizationNotBeforeUtc `
            -AuthorizationNotAfterUtc $AuthorizationNotAfterUtc `
            -AuthorizationMinimumSequence $AuthorizationMinimumSequence `
            -AuthorizationMaximumSequence $AuthorizationMaximumSequence `
            -RootSigningCertificate $RootSigningCertificate `
            -ReleaseSigningCertificate $ReleaseSigningCertificate
        $candidate = Test-AvatarRecoveryUpdateManifestDocument `
            -ManifestJson $document.Json `
            -TrustedRootCertificate $TrustedRootCertificate `
            -ExpectedPackageId $PackageId `
            -ExpectedVersion $LatestStableVersion `
            -ExpectedSourceIndexSha256 $SourceIndexSha256 `
            -ExpectedPackageSha256 $PackageSha256 `
            -NowUtc $NowUtc
        [UInt64]$candidateSequence = [UInt64]::Parse([string]$candidate.Payload.sequence, $script:InvariantCulture)
        $localBefore = if ($null -eq $localBeforeJson) {
            $null
        }
        else {
            Get-VerifiedManifestSnapshot `
                -ManifestJson $localBeforeJson `
                -TrustedRootCertificate $TrustedRootCertificate `
                -ExpectedPackageId $PackageId `
                -NowUtc $NowUtc `
                -SourceName "Local"
        }
        Assert-CandidateAgainstManifestFloor `
            -CandidateSequence $candidateSequence `
            -CandidateVersion $LatestStableVersion `
            -CandidateJson $document.Json `
            -Floor $remoteBefore `
            -SourceName "Remote"
        Assert-CandidateAgainstManifestFloor `
            -CandidateSequence $candidateSequence `
            -CandidateVersion $LatestStableVersion `
            -CandidateJson $document.Json `
            -Floor $localBefore `
            -SourceName "Local"

        $remoteAfterResponse = Get-RemoteManifestResponse `
            -Provider $RemoteManifestProvider `
            -TimeoutSeconds $RemoteTimeoutSeconds
        if ([int]$remoteBeforeResponse.StatusCode -ne [int]$remoteAfterResponse.StatusCode -or
            [string]$remoteBeforeResponse.Body -cne [string]$remoteAfterResponse.Body) {
            throw "The public update notification manifest changed during generation. Retry from fresh state."
        }
        $remoteAfter = Get-RemoteManifestSnapshot `
            -Response $remoteAfterResponse `
            -TrustedRootCertificate $TrustedRootCertificate `
            -ExpectedPackageId $PackageId `
            -NowUtc $NowUtc `
            -AllowInitialPublication ([bool]$AllowInitialPublication)
        $localAfterJson = if (Test-Path -LiteralPath $fullOutputPath) {
            [System.IO.File]::ReadAllText($fullOutputPath, $script:Utf8NoBom)
        }
        else {
            $null
        }
        if (($null -eq $localBeforeJson) -ne ($null -eq $localAfterJson) -or
            ($null -ne $localBeforeJson -and $localBeforeJson -cne $localAfterJson)) {
            throw "The local update notification manifest changed outside the output lock."
        }
        $localAfter = if ($null -eq $localAfterJson) {
            $null
        }
        else {
            Get-VerifiedManifestSnapshot `
                -ManifestJson $localAfterJson `
                -TrustedRootCertificate $TrustedRootCertificate `
                -ExpectedPackageId $PackageId `
                -NowUtc $NowUtc `
                -SourceName "Local"
        }
        Assert-CandidateAgainstManifestFloor -CandidateSequence $candidateSequence -CandidateVersion $LatestStableVersion -CandidateJson $document.Json -Floor $remoteAfter -SourceName "Remote"
        Assert-CandidateAgainstManifestFloor -CandidateSequence $candidateSequence -CandidateVersion $LatestStableVersion -CandidateJson $document.Json -Floor $localAfter -SourceName "Local"

        if ($null -eq $localAfter -or [string]$localAfter.Json -cne $document.Json) {
            $temporaryPath = "$fullOutputPath.$([Guid]::NewGuid().ToString('N')).tmp"
            $backupPath = "$fullOutputPath.$([Guid]::NewGuid().ToString('N')).bak"
            [System.IO.File]::WriteAllText($temporaryPath, $document.Json + "`n", $script:Utf8NoBom)
            if (Test-Path -LiteralPath $fullOutputPath) {
                [System.IO.File]::Replace($temporaryPath, $fullOutputPath, $backupPath)
            }
            else {
                [System.IO.File]::Move($temporaryPath, $fullOutputPath)
            }
        }
        return $document
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($temporaryPath) -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (-not [string]::IsNullOrWhiteSpace($backupPath) -and (Test-Path -LiteralPath $backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force
        }
        $lockStream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @(
    "Compare-AvatarRecoveryStableVersion",
    "Complete-AvatarRecoveryPublicArtifactTransaction",
    "ConvertTo-AvatarRecoveryUpdateSequence",
    "New-AvatarRecoveryPublicArtifactTransaction",
    "New-AvatarRecoveryUpdateManifestDocument",
    "Restore-AvatarRecoveryPublicArtifactTransaction",
    "Test-AvatarRecoveryUpdateManifestDocument",
    "Test-CertificatePublicKeysEqual",
    "Write-AvatarRecoveryUpdateManifest")
