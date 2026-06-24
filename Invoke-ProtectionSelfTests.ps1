param(
    [string]$Version = "1.1.17",
    [string]$PackageId = "com.nickel-jp.avatar-recovery",
    [switch]$SkipPrivateProtectionReports
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$WorkRoot = Join-Path $RepoRoot ".work"
$OutputRoot = Join-Path $WorkRoot "ProtectionSelfTests$($Version.Replace('.', ''))"
$AssemblyFileName = "EditorTools.AvatarRecovery.Editor.dll"
$RuntimeIntegritySidecarFileName = "$AssemblyFileName.runtime.sig"
$StringHidingProbe = "AVATAR_RECOVERY_STRING_HIDING_TEST_8D1C4C55"

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

function Get-Allowlist {
    param([Parameter(Mandatory = $true)][string]$Path)
    return @(Get-Content -LiteralPath $Path |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") } |
        Sort-Object -Unique)
}

function Assert-PublicApiMatchesAllowlist {
    param([Parameter(Mandatory = $true)][string[]]$CurrentPublicTypes)

    $allowed = Get-Allowlist -Path (Join-Path $RepoRoot "Build\PublicApiAllowlist.txt")
    $difference = @(Compare-Object -ReferenceObject $allowed -DifferenceObject ($CurrentPublicTypes | Sort-Object -Unique))
    if ($difference.Count -gt 0) {
        throw "public API mismatch"
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
        [Parameter(Mandatory = $true)][string]$SidecarPath
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

        $publicKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        if ($null -eq $publicKey) {
            throw "runtime integrity public key was not available"
        }

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
    $allowed = Get-Allowlist -Path (Join-Path $RepoRoot "Build\PublicApiAllowlist.txt")
    Assert-PublicApiMatchesAllowlist -CurrentPublicTypes @($allowed + "EditorTools.AvatarRecovery.UnauthorizedPublicType")
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

[void]$results.Add((Assert-Passes "I string hiding marker is not plaintext" {
    $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-FullPath $dllPath))
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicode = [System.Text.Encoding]::Unicode.GetString($bytes)
    if ($ascii.Contains($StringHidingProbe) -or $unicode.Contains($StringHidingProbe)) {
        throw "string hiding marker is visible"
    }
}))

[void]$results.Add((Assert-Passes "J runtime integrity sidecar verifies when present" {
    $sidecarPath = Get-PackagedRuntimeIntegritySidecarPath
    Test-RuntimeIntegritySidecarFile -DllPath $dllPath -SidecarPath $sidecarPath
}))

if ($SkipPrivateProtectionReports) {
    [void]$results.Add((Assert-Skipped "K Cecil string encryption report covers allowlist" "Private protection reports are not available in CI checkout."))
    [void]$results.Add((Assert-Skipped "L HideStrings disabled impact scan is managed" "Private protection reports are not available in CI checkout."))
    [void]$results.Add((Assert-Skipped "M runtime integrity JSON fields are preserved" "Private protection reports are not available in CI checkout."))
}
else {
    [void]$results.Add((Assert-Passes "K Cecil string encryption report covers allowlist" {
        $reportPath = Get-PrivateProtectionReportPath -FileName "cecil-string-encryption-$Version.json"
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $allowlist = Get-Allowlist -Path (Join-Path $RepoRoot "Build\StringEncryptionAllowlist.txt")
        $encryptedOriginalMethods = @($report.EncryptedMethods | ForEach-Object { [string]$_.OriginalMethod })

        if (-not [bool]$report.Enabled) {
            throw "Cecil string encryption report is disabled"
        }
        if ([int]$report.TargetRuleCount -ne $allowlist.Count) {
            throw "Cecil string encryption target count mismatch"
        }
        if ([int]$report.MappedTargetCount -lt $allowlist.Count) {
            throw "Cecil string encryption did not map every allowlist entry"
        }
        if ([int]$report.EncryptedMethodCount -lt $allowlist.Count) {
            throw "Cecil string encryption did not encrypt every allowlist entry"
        }
        if ([int]$report.EncryptedStringCount -le 0) {
            throw "Cecil string encryption did not encrypt any string"
        }
        if ([int]$report.EncodedBlobStringCount -le 0) {
            throw "Cecil string encryption blob optimization was not exercised"
        }
        if ([int]$report.InlineByteArrayThreshold -le 0) {
            throw "Cecil string encryption inline threshold is not recorded"
        }
        if ([int]$report.InlineByteArrayStringCount -gt 0 -and [int]$report.ExpandedShortBranchCount -le 0) {
            throw "Cecil string encryption did not expand short branches after inline byte-array rewriting"
        }

        foreach ($entry in $allowlist) {
            if ($encryptedOriginalMethods -notcontains $entry) {
                throw "Cecil string encryption missed allowlist entry: $entry"
            }
        }
    }))

    [void]$results.Add((Assert-Passes "L HideStrings disabled impact scan is managed" {
        $reportPath = Get-PrivateProtectionReportPath -FileName "hide-strings-impact-$Version.json"
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json

        if (-not [bool]$report.Enabled) {
            throw "HideStrings impact report is disabled"
        }
        if (-not [bool]$report.HideStringsDisabled) {
            throw "HideStrings impact report did not record disabled HideStrings"
        }
        if ([string]$report.ManagedBy -ne "CecilStringEncryptionAllowlistAndRiskScan") {
            throw "HideStrings impact report has unexpected management mode"
        }
        if ([int]$report.SensitivePlaintextHitCount -ne 0) {
            throw "HideStrings impact scan found sensitive plaintext"
        }
        if ([int]$report.EncryptedBlobLiteralCount -lt [int]$report.EncodedBlobStringCount) {
            throw "HideStrings impact report lost encrypted blob literals"
        }
    }))

    [void]$results.Add((Assert-Passes "M runtime integrity JSON fields are preserved" {
        $mappingPath = Get-PrivateProtectionReportPath -FileName "Mapping.txt"
        $mappingText = Get-Content -LiteralPath $mappingPath -Raw
        $jsonFields = @(
            "format",
            "algorithm",
            "target",
            "targetSha256",
            "signerThumbprint",
            "signerCertificateBase64",
            "signatureBase64"
        )

        foreach ($fieldName in $jsonFields) {
            $pattern = "AvatarRecoveryIntegrityGuard/RuntimeIntegritySignature::$([regex]::Escape($fieldName)).* -> "
            if ($mappingText -match $pattern) {
                throw "Runtime integrity JSON field was renamed: $fieldName"
            }
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
