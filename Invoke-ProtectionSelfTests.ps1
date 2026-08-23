param(
    [string]$Version = "1.2.9",
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
$ExpectedRepositoryBaseUrl = "https://nickel-jp.github.io/avatar-recovery-unity"
$LegacyRepositoryBaseUrl = "https://raw.githubusercontent.com/Nickel-JP/avatar-recovery-unity/main"
$PublishedVersionLimit = 3
$BundledWorkerSdkMinimumVersion = [version]"1.3.0"
$BundledWorkerSdkMaximumVersion = [version]"1.3.4"
try {
    $ParsedReleaseVersion = [version]$Version
}
catch {
    throw "Package version is invalid: $Version"
}
$SupportsBundledWorkerSdk = (
    $ParsedReleaseVersion -ge $BundledWorkerSdkMinimumVersion -and
    $ParsedReleaseVersion -le $BundledWorkerSdkMaximumVersion)
$RequiresHotSwapRemoval = $ParsedReleaseVersion -gt $BundledWorkerSdkMaximumVersion

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

function Test-IsBundledWorkerSdkEntry {
    param([Parameter(Mandatory = $true)][string]$EntryName)

    if (-not $SupportsBundledWorkerSdk) {
        return $false
    }

    $normalizedName = $EntryName.Replace('\', '/')
    $segments = $normalizedName.Split(
        [char[]]@('/'),
        [System.StringSplitOptions]::None)
    if ($segments.Count -lt 7 -or
        @($segments | Where-Object { $_ -in @("", ".", "..") }).Count -gt 0 -or
        $segments[0] -cne "Editor" -or
        $segments[1] -cne "HotSwap" -or
        $segments[3] -cne "WorkerTemplate~" -or
        $segments[4] -cne "Packages") {
        return $false
    }

    $allowedPackageIds = if ($segments[2] -ceq "HotSwap_Avtr") {
        @("com.vrchat.avatars", "com.vrchat.base", "com.vrchat.core.vpm-resolver")
    }
    elseif ($segments[2] -ceq "HotSwap_wrld") {
        @("com.vrchat.base", "com.vrchat.core.vpm-resolver", "com.vrchat.worlds")
    }
    else {
        @()
    }

    return ($allowedPackageIds -ccontains $segments[5])
}

function Test-PackageZipGuard {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($RequiresHotSwapRemoval) {
            $hotSwapEntries = @($archive.Entries | Where-Object {
                $normalizedName = $_.FullName.Replace('\', '/')
                [string]::Equals(
                    $normalizedName,
                    "Editor/HotSwap",
                    [StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals(
                    $normalizedName,
                    "Editor/HotSwap.meta",
                    [StringComparison]::OrdinalIgnoreCase) -or
                $normalizedName.StartsWith(
                    "Editor/HotSwap/",
                    [StringComparison]::OrdinalIgnoreCase)
            })
            if ($hotSwapEntries.Count -gt 0) {
                throw "HotSwap entries remain after separation: $($hotSwapEntries.FullName -join ', ')"
            }
        }

        $blocked = @($archive.Entries | Where-Object {
            $normalizedName = $_.FullName.Replace('\', '/')
            $isBundledWorkerSdkEntry = Test-IsBundledWorkerSdkEntry -EntryName $normalizedName
            $isBlockedSourceOrReport = (
                $normalizedName -match '(?i)\.cs$' -or
                $normalizedName -match '(?i)(mapping|rename|report)') -and
                -not $isBundledWorkerSdkEntry

            $isBlockedSourceOrReport -or
            $normalizedName -match '(?i)\.(pdb|mdb)$' -or
            $normalizedName -match '(?i)\.(pfx|p12|pvk|key|snk|pem|map)$' -or
            $normalizedName -match '(?i)obfuscar'
        })
        if ($blocked.Count -gt 0) {
            throw "blocked zip entries: $($blocked.FullName -join ', ')"
        }

        $runtimeSidecarEntryName = "Editor/$RuntimeIntegritySidecarFileName"
        $runtimeSidecarMetaEntryName = "$runtimeSidecarEntryName.meta"
        $runtimeSidecarEntries = @($archive.Entries | Where-Object {
            [string]::Equals(
                $_.FullName.Replace('\', '/'),
                $runtimeSidecarEntryName,
                [StringComparison]::Ordinal)
        })
        $runtimeSidecarMetaEntries = @($archive.Entries | Where-Object {
            [string]::Equals(
                $_.FullName.Replace('\', '/'),
                $runtimeSidecarMetaEntryName,
                [StringComparison]::Ordinal)
        })
        if ($runtimeSidecarEntries.Count -gt 1 -or
            $runtimeSidecarMetaEntries.Count -gt 1 -or
            (($runtimeSidecarEntries.Count -eq 1) -ne
                ($runtimeSidecarMetaEntries.Count -eq 1))) {
            throw (
                "runtime sidecar and Unity metadata do not match: " +
                "$runtimeSidecarEntryName / $runtimeSidecarMetaEntryName")
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

function Test-NoOrphanUnityMetaEntriesInZip {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead((ConvertTo-FullPath $ZipPath))
    try {
        $materializedPaths = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        $filePaths = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.Name)) {
                continue
            }

            $entryPath = $entry.FullName.Replace('\', '/')
            [void]$filePaths.Add($entryPath)
            [void]$materializedPaths.Add($entryPath)

            $separatorIndex = $entryPath.IndexOf('/')
            while ($separatorIndex -ge 0) {
                [void]$materializedPaths.Add($entryPath.Substring(0, $separatorIndex))
                $separatorIndex = $entryPath.IndexOf('/', $separatorIndex + 1)
            }
        }

        $orphanMetaPaths = [System.Collections.Generic.List[string]]::new()
        foreach ($entryPath in $filePaths) {
            if (-not $entryPath.EndsWith('.meta', [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $assetPath = $entryPath.Substring(0, $entryPath.Length - '.meta'.Length)
            if (-not $materializedPaths.Contains($assetPath)) {
                [void]$orphanMetaPaths.Add($entryPath)
            }
        }

        if ($orphanMetaPaths.Count -gt 0) {
            throw (
                "Package ZIP contains Unity .meta entries without their assets or " +
                "directories: " +
                ($orphanMetaPaths -join ', '))
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-ExactZipEntry {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    $normalizedEntryName = $EntryName.Replace('\', '/')
    $matches = @($Archive.Entries | Where-Object {
        $_.FullName.Replace('\', '/') -ceq $normalizedEntryName
    })
    if ($matches.Count -ne 1 -or [string]::IsNullOrWhiteSpace($matches[0].Name)) {
        throw "ZIP entry must exist exactly once: $normalizedEntryName"
    }

    return $matches[0]
}

function Get-SortedZipFileNames {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    $normalizedPrefix = $Prefix.Replace('\', '/').TrimEnd('/') + '/'
    $windowsNames = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Archive.Entries) {
        $normalizedName = $entry.FullName.Replace('\', '/')
        if (-not [string]::IsNullOrWhiteSpace($entry.Name) -and
            $normalizedName.StartsWith(
                $normalizedPrefix,
                [StringComparison]::OrdinalIgnoreCase)) {
            [void]$windowsNames.Add($normalizedName.Replace('/', '\'))
        }
    }

    $windowsNames.Sort([StringComparer]::OrdinalIgnoreCase)
    return @($windowsNames | ForEach-Object { $_.Replace('\', '/') })
}

function Get-StreamSha256 {
    param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Stream))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($Text)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Add-ZipInventoryEntry {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Inventory,
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][string]$InventoryRelativePath
    )

    $entry = Get-ExactZipEntry -Archive $Archive -EntryName $EntryName
    $stream = $entry.Open()
    try {
        $sha256 = Get-StreamSha256 -Stream $stream
    }
    finally {
        $stream.Dispose()
    }

    [void]$Inventory.Append($InventoryRelativePath.Replace('\', '/'))
    [void]$Inventory.Append("`n")
    [void]$Inventory.Append($entry.Length)
    [void]$Inventory.Append("`n")
    [void]$Inventory.Append($sha256)
    [void]$Inventory.Append("`n")
}

function Get-AvatarWorkerSdkInventorySha256 {
    param([Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive)

    $workerRoot = "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~"
    $workerPackageName = "com.nickel-jp.avatar-recovery-hotswap-worker"
    $workerPackageRoot = "$workerRoot/Packages/$workerPackageName"
    $inventory = [System.Text.StringBuilder]::new()
    [void]$inventory.Append("AvatarRecoveryHotSwapSdkInventory/v2`n")

    foreach ($fileName in @("manifest.json", "packages-lock.json", "vpm-manifest.json")) {
        Add-ZipInventoryEntry `
            -Inventory $inventory `
            -Archive $Archive `
            -EntryName "$workerRoot/Packages/$fileName" `
            -InventoryRelativePath "Packages/$fileName"
    }

    foreach ($directoryName in @("Assets", "ProjectSettings")) {
        $prefix = "$workerRoot/$directoryName"
        foreach ($entryName in Get-SortedZipFileNames -Archive $Archive -Prefix $prefix) {
            $relative = $entryName.Substring($prefix.Length + 1)
            Add-ZipInventoryEntry `
                -Inventory $inventory `
                -Archive $Archive `
                -EntryName $entryName `
                -InventoryRelativePath "$directoryName/$relative"
        }
    }

    foreach ($fileName in @("package.json", "worker-template.json")) {
        Add-ZipInventoryEntry `
            -Inventory $inventory `
            -Archive $Archive `
            -EntryName "$workerPackageRoot/$fileName" `
            -InventoryRelativePath "$workerPackageName/$fileName"
    }

    Add-ZipInventoryEntry `
        -Inventory $inventory `
        -Archive $Archive `
        -EntryName "$workerPackageRoot/Editor/SdkAutomation.meta" `
        -InventoryRelativePath "$workerPackageName/Editor/SdkAutomation.meta"
    $automationPrefix = "$workerPackageRoot/Editor/SdkAutomation"
    foreach ($entryName in Get-SortedZipFileNames -Archive $Archive -Prefix $automationPrefix) {
        $relative = $entryName.Substring($automationPrefix.Length + 1)
        Add-ZipInventoryEntry `
            -Inventory $inventory `
            -Archive $Archive `
            -EntryName $entryName `
            -InventoryRelativePath "$workerPackageName/Editor/SdkAutomation/$relative"
    }

    foreach ($packageName in @(
            "com.vrchat.avatars",
            "com.vrchat.base",
            "com.vrchat.core.vpm-resolver")) {
        $packagePrefix = "$workerRoot/Packages/$packageName"
        foreach ($entryName in Get-SortedZipFileNames -Archive $Archive -Prefix $packagePrefix) {
            $relative = $entryName.Substring($packagePrefix.Length + 1)
            Add-ZipInventoryEntry `
                -Inventory $inventory `
                -Archive $Archive `
                -EntryName $entryName `
                -InventoryRelativePath "$packageName/$relative"
        }
    }

    return Get-TextSha256 -Text $inventory.ToString()
}

function Get-AvatarWorkerTemplateSha256 {
    param([Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive)

    $templateRoot = (
        "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Packages/" +
        "com.nickel-jp.avatar-recovery-hotswap-worker/Editor/BackgroundWorkerClient")
    $inventory = [System.Text.StringBuilder]::new()
    foreach ($entryName in Get-SortedZipFileNames -Archive $Archive -Prefix $templateRoot) {
        $relative = $entryName.Substring($templateRoot.Length + 1)
        $normalizedRelative = $relative.Replace('\', '/')
        $isDirectRuntimeFile = $normalizedRelative -cin @(
            "NickelJP.AvatarRecovery.HotSwap.BackgroundWorkerClient.Editor.asmdef",
            "NickelJP.AvatarRecovery.HotSwap.BackgroundWorkerClient.Editor.dll",
            "NickelJP.AvatarRecovery.HotSwap.BackgroundWorkerClient.Editor.dll.meta")
        $isRuntimeDirectory = @("Infrastructure/", "JobStore/", "Protocol/", "Worker/") |
            Where-Object {
                $normalizedRelative.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
            }
        $extension = [System.IO.Path]::GetExtension($normalizedRelative)
        $isInventoryExtension = $extension -iin @(".cs", ".asmdef", ".dll", ".meta", ".json")
        if (($isDirectRuntimeFile -or $null -ne $isRuntimeDirectory) -and
            $isInventoryExtension) {
            Add-ZipInventoryEntry `
                -Inventory $inventory `
                -Archive $Archive `
                -EntryName $entryName `
                -InventoryRelativePath $normalizedRelative
        }
    }

    if ($inventory.Length -eq 0) {
        throw "Avatar Worker template inventory is empty"
    }

    return Get-TextSha256 -Text $inventory.ToString()
}

function Test-ZipEntryContainsText {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][string]$ExpectedText
    )

    $entry = Get-ExactZipEntry -Archive $Archive -EntryName $EntryName
    $stream = $entry.Open()
    try {
        $memory = [System.IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $unicodeEven = [System.Text.Encoding]::Unicode.GetString($bytes)
    $unicodeOdd = if ($bytes.Length -gt 1) {
        [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
    }
    else {
        ""
    }
    if (-not $ascii.Contains($ExpectedText) -and
        -not $unicodeEven.Contains($ExpectedText) -and
        -not $unicodeOdd.Contains($ExpectedText)) {
        throw "ZIP entry does not contain the completed-artifact expectation: $EntryName"
    }
}

function Test-AvatarHotSwapCompletedArtifactConsistency {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead((ConvertTo-FullPath $ZipPath))
    try {
        $sdkInventorySha256 = Get-AvatarWorkerSdkInventorySha256 -Archive $archive
        $workerTemplateSha256 = Get-AvatarWorkerTemplateSha256 -Archive $archive
        $controllerEntry = (
            "Editor/HotSwap/HotSwap_Avtr/" +
            "NickelJP.AvatarRecovery.HotSwap.BackgroundWorkerClient.Editor.dll")
        $workerEntry = (
            "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Packages/" +
            "com.nickel-jp.avatar-recovery-hotswap-worker/Editor/BackgroundWorkerClient/" +
            "NickelJP.AvatarRecovery.HotSwap.BackgroundWorkerClient.Editor.dll")

        Test-ZipEntryContainsText `
            -Archive $archive `
            -EntryName $controllerEntry `
            -ExpectedText $sdkInventorySha256
        Test-ZipEntryContainsText `
            -Archive $archive `
            -EntryName $controllerEntry `
            -ExpectedText $workerTemplateSha256
        Test-ZipEntryContainsText `
            -Archive $archive `
            -EntryName $workerEntry `
            -ExpectedText $sdkInventorySha256
    }
    finally {
        $archive.Dispose()
    }
}

function Get-ZipEntryBytes {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    $entry = Get-ExactZipEntry -Archive $Archive -EntryName $EntryName
    $stream = $entry.Open()
    try {
        $memory = [System.IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            return $memory.ToArray()
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Initialize-AvatarWorkerAssemblyLinkageVerifier {
    if ($null -ne ("AvatarRecovery.ReleaseVerification.AvatarWorkerAssemblyLinkageVerifier" -as [type])) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.IO;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;

namespace AvatarRecovery.ReleaseVerification
{
    public static class AvatarWorkerAssemblyLinkageVerifier
    {
        private readonly struct GenericContext
        {
        }

        private sealed class CanonicalTypeProvider : ISignatureTypeProvider<string, GenericContext>
        {
            private readonly MetadataReader _reader;
            private readonly string _providerAssemblyName;
            private readonly string _currentAssemblyName;

            internal CanonicalTypeProvider(
                MetadataReader reader,
                string providerAssemblyName,
                string currentAssemblyName)
            {
                _reader = reader;
                _providerAssemblyName = providerAssemblyName;
                _currentAssemblyName = currentAssemblyName;
            }

            public string GetArrayType(string elementType, ArrayShape shape)
            {
                return elementType + "[rank=" + shape.Rank +
                    ";sizes=" + string.Join(",", shape.Sizes) +
                    ";lower=" + string.Join(",", shape.LowerBounds) + "]";
            }

            public string GetByReferenceType(string elementType)
            {
                return elementType + "&";
            }

            public string GetFunctionPointerType(MethodSignature<string> signature)
            {
                return "fnptr:" + FormatMethodSignature(signature);
            }

            public string GetGenericInstantiation(
                string genericType,
                ImmutableArray<string> typeArguments)
            {
                return genericType + "<" + string.Join(",", typeArguments) + ">";
            }

            public string GetGenericMethodParameter(GenericContext genericContext, int index)
            {
                return "!!" + index;
            }

            public string GetGenericTypeParameter(GenericContext genericContext, int index)
            {
                return "!" + index;
            }

            public string GetModifiedType(
                string modifier,
                string unmodifiedType,
                bool isRequired)
            {
                return (isRequired ? "modreq(" : "modopt(") +
                    modifier + "):" + unmodifiedType;
            }

            public string GetPinnedType(string elementType)
            {
                return "pinned:" + elementType;
            }

            public string GetPointerType(string elementType)
            {
                return elementType + "*";
            }

            public string GetPrimitiveType(PrimitiveTypeCode typeCode)
            {
                return "primitive:" + typeCode;
            }

            public string GetSZArrayType(string elementType)
            {
                return elementType + "[]";
            }

            public string GetTypeFromDefinition(
                MetadataReader reader,
                TypeDefinitionHandle handle,
                byte rawTypeKind)
            {
                return GetTypeDefinitionFullName(reader, handle);
            }

            public string GetTypeFromReference(
                MetadataReader reader,
                TypeReferenceHandle handle,
                byte rawTypeKind)
            {
                string fullName = GetTypeReferenceFullName(reader, handle);
                string assemblyName = GetTypeReferenceAssemblyName(
                    reader,
                    handle,
                    _currentAssemblyName);
                if (string.Equals(
                    assemblyName,
                    _providerAssemblyName,
                    StringComparison.Ordinal))
                {
                    return fullName;
                }

                return "[" + assemblyName + "]" + fullName;
            }

            public string GetTypeFromSpecification(
                MetadataReader reader,
                GenericContext genericContext,
                TypeSpecificationHandle handle,
                byte rawTypeKind)
            {
                return reader.GetTypeSpecification(handle).DecodeSignature(this, genericContext);
            }
        }

        public static int Verify(
            byte[] providerBytes,
            byte[] consumerBytes,
            string providerAssemblyName)
        {
            if (providerBytes == null || providerBytes.Length == 0)
            {
                throw new InvalidDataException("Avatar Worker provider assembly is empty.");
            }

            if (consumerBytes == null || consumerBytes.Length == 0)
            {
                throw new InvalidDataException("Avatar Worker consumer assembly is empty.");
            }

            using (var providerStream = new MemoryStream(providerBytes, writable: false))
            using (var consumerStream = new MemoryStream(consumerBytes, writable: false))
            using (var providerPe = new PEReader(providerStream))
            using (var consumerPe = new PEReader(consumerStream))
            {
                if (!providerPe.HasMetadata || !consumerPe.HasMetadata)
                {
                    throw new InvalidDataException("Avatar Worker assembly does not contain CLR metadata.");
                }

                MetadataReader provider = providerPe.GetMetadataReader();
                MetadataReader consumer = consumerPe.GetMetadataReader();
                string actualProviderName = provider.GetString(provider.GetAssemblyDefinition().Name);
                if (!string.Equals(
                    actualProviderName,
                    providerAssemblyName,
                    StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "Unexpected Avatar Worker provider assembly: " + actualProviderName);
                }

                string consumerAssemblyName = consumer.GetString(
                    consumer.GetAssemblyDefinition().Name);
                var providerTypes = BuildProviderMemberIndex(
                    provider,
                    providerAssemblyName);

                int providerAssemblyReferenceCount = 0;
                foreach (AssemblyReferenceHandle handle in consumer.AssemblyReferences)
                {
                    AssemblyReference reference = consumer.GetAssemblyReference(handle);
                    if (string.Equals(
                        consumer.GetString(reference.Name),
                        providerAssemblyName,
                        StringComparison.Ordinal))
                    {
                        providerAssemblyReferenceCount++;
                    }
                }

                if (providerAssemblyReferenceCount != 1)
                {
                    throw new InvalidDataException(
                        "Avatar Worker consumer must reference exactly one provider assembly; actual=" +
                        providerAssemblyReferenceCount);
                }

                var consumerTypeProvider = new CanonicalTypeProvider(
                    consumer,
                    providerAssemblyName,
                    consumerAssemblyName);
                int referencedProviderTypeCount = ValidateProviderTypeReferences(
                    consumer,
                    providerAssemblyName,
                    consumerAssemblyName,
                    providerTypes);
                int checkedMemberCount = ValidateProviderMemberReferences(
                    consumer,
                    consumerTypeProvider,
                    providerAssemblyName,
                    consumerAssemblyName,
                    providerTypes);

                if (referencedProviderTypeCount == 0 || checkedMemberCount == 0)
                {
                    throw new InvalidDataException(
                        "Avatar Worker linkage validation did not inspect provider references.");
                }

                return checkedMemberCount;
            }
        }

        private static Dictionary<string, HashSet<string>> BuildProviderMemberIndex(
            MetadataReader provider,
            string providerAssemblyName)
        {
            var result = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
            var typeProvider = new CanonicalTypeProvider(
                provider,
                providerAssemblyName,
                providerAssemblyName);
            var context = new GenericContext();

            foreach (TypeDefinitionHandle typeHandle in provider.TypeDefinitions)
            {
                TypeDefinition type = provider.GetTypeDefinition(typeHandle);
                string typeName = GetTypeDefinitionFullName(provider, typeHandle);
                var members = new HashSet<string>(StringComparer.Ordinal);

                foreach (MethodDefinitionHandle methodHandle in type.GetMethods())
                {
                    MethodDefinition method = provider.GetMethodDefinition(methodHandle);
                    string name = provider.GetString(method.Name);
                    string signature = FormatMethodSignature(
                        method.DecodeSignature(typeProvider, context));
                    members.Add("M|" + name + "|" + signature);
                }

                foreach (FieldDefinitionHandle fieldHandle in type.GetFields())
                {
                    FieldDefinition field = provider.GetFieldDefinition(fieldHandle);
                    string name = provider.GetString(field.Name);
                    string signature = field.DecodeSignature(typeProvider, context);
                    members.Add("F|" + name + "|" + signature);
                }

                result.Add(typeName, members);
            }

            return result;
        }

        private static int ValidateProviderTypeReferences(
            MetadataReader consumer,
            string providerAssemblyName,
            string consumerAssemblyName,
            Dictionary<string, HashSet<string>> providerTypes)
        {
            int checkedCount = 0;
            foreach (TypeReferenceHandle handle in consumer.TypeReferences)
            {
                string assemblyName = GetTypeReferenceAssemblyName(
                    consumer,
                    handle,
                    consumerAssemblyName);
                if (!string.Equals(
                    assemblyName,
                    providerAssemblyName,
                    StringComparison.Ordinal))
                {
                    continue;
                }

                string typeName = GetTypeReferenceFullName(consumer, handle);
                if (!providerTypes.ContainsKey(typeName))
                {
                    throw new MissingMemberException(
                        "Avatar Worker provider type is missing: " + typeName);
                }

                checkedCount++;
            }

            return checkedCount;
        }

        private static int ValidateProviderMemberReferences(
            MetadataReader consumer,
            CanonicalTypeProvider typeProvider,
            string providerAssemblyName,
            string consumerAssemblyName,
            Dictionary<string, HashSet<string>> providerTypes)
        {
            int checkedCount = 0;
            var context = new GenericContext();
            foreach (MemberReferenceHandle handle in consumer.MemberReferences)
            {
                MemberReference member = consumer.GetMemberReference(handle);
                string typeName;
                if (!TryGetProviderParentTypeName(
                    consumer,
                    member.Parent,
                    typeProvider,
                    context,
                    providerAssemblyName,
                    consumerAssemblyName,
                    providerTypes,
                    out typeName))
                {
                    continue;
                }

                string memberName = consumer.GetString(member.Name);
                string key;
                switch (member.GetKind())
                {
                    case MemberReferenceKind.Method:
                        key = "M|" + memberName + "|" +
                            FormatMethodSignature(member.DecodeMethodSignature(typeProvider, context));
                        break;
                    case MemberReferenceKind.Field:
                        key = "F|" + memberName + "|" +
                            member.DecodeFieldSignature(typeProvider, context);
                        break;
                    default:
                        throw new BadImageFormatException(
                            "Unsupported Avatar Worker member reference kind.");
                }

                HashSet<string> members;
                if (!providerTypes.TryGetValue(typeName, out members) || !members.Contains(key))
                {
                    throw new MissingMethodException(
                        "Avatar Worker provider member is missing: " + typeName + "." +
                        memberName + " (" + key + ")");
                }

                checkedCount++;
            }

            return checkedCount;
        }

        private static bool TryGetProviderParentTypeName(
            MetadataReader reader,
            EntityHandle parent,
            CanonicalTypeProvider typeProvider,
            GenericContext context,
            string providerAssemblyName,
            string currentAssemblyName,
            Dictionary<string, HashSet<string>> providerTypes,
            out string typeName)
        {
            typeName = null;
            if (parent.Kind == HandleKind.TypeReference)
            {
                var handle = (TypeReferenceHandle)parent;
                string assemblyName = GetTypeReferenceAssemblyName(
                    reader,
                    handle,
                    currentAssemblyName);
                if (!string.Equals(
                    assemblyName,
                    providerAssemblyName,
                    StringComparison.Ordinal))
                {
                    return false;
                }

                typeName = GetTypeReferenceFullName(reader, handle);
                return true;
            }

            if (parent.Kind != HandleKind.TypeSpecification)
            {
                return false;
            }

            string specification = reader.GetTypeSpecification(
                (TypeSpecificationHandle)parent).DecodeSignature(typeProvider, context);
            int genericStart = specification.IndexOf('<');
            string candidate = genericStart >= 0
                ? specification.Substring(0, genericStart)
                : specification;
            if (providerTypes.ContainsKey(candidate))
            {
                typeName = candidate;
                return true;
            }

            return false;
        }

        private static string FormatMethodSignature(MethodSignature<string> signature)
        {
            return "header=" + signature.Header.RawValue +
                ";generic=" + signature.GenericParameterCount +
                ";required=" + signature.RequiredParameterCount +
                ";return=" + signature.ReturnType +
                ";params=(" + string.Join(",", signature.ParameterTypes) + ")";
        }

        private static string GetTypeDefinitionFullName(
            MetadataReader reader,
            TypeDefinitionHandle handle)
        {
            TypeDefinition definition = reader.GetTypeDefinition(handle);
            string name = reader.GetString(definition.Name);
            TypeDefinitionHandle declaringType = definition.GetDeclaringType();
            if (!declaringType.IsNil)
            {
                return GetTypeDefinitionFullName(reader, declaringType) + "+" + name;
            }

            string typeNamespace = reader.GetString(definition.Namespace);
            return string.IsNullOrEmpty(typeNamespace)
                ? name
                : typeNamespace + "." + name;
        }

        private static string GetTypeReferenceFullName(
            MetadataReader reader,
            TypeReferenceHandle handle)
        {
            TypeReference reference = reader.GetTypeReference(handle);
            string name = reader.GetString(reference.Name);
            if (reference.ResolutionScope.Kind == HandleKind.TypeReference)
            {
                return GetTypeReferenceFullName(
                    reader,
                    (TypeReferenceHandle)reference.ResolutionScope) + "+" + name;
            }

            string typeNamespace = reader.GetString(reference.Namespace);
            return string.IsNullOrEmpty(typeNamespace)
                ? name
                : typeNamespace + "." + name;
        }

        private static string GetTypeReferenceAssemblyName(
            MetadataReader reader,
            TypeReferenceHandle handle,
            string currentAssemblyName)
        {
            TypeReference reference = reader.GetTypeReference(handle);
            EntityHandle scope = reference.ResolutionScope;
            while (scope.Kind == HandleKind.TypeReference)
            {
                scope = reader.GetTypeReference((TypeReferenceHandle)scope).ResolutionScope;
            }

            if (scope.Kind == HandleKind.AssemblyReference)
            {
                AssemblyReference assembly = reader.GetAssemblyReference(
                    (AssemblyReferenceHandle)scope);
                return reader.GetString(assembly.Name);
            }

            if (scope.Kind == HandleKind.ModuleDefinition ||
                scope.Kind == HandleKind.ModuleReference)
            {
                return currentAssemblyName;
            }

            throw new BadImageFormatException(
                "Unsupported type reference resolution scope: " + scope.Kind);
        }
    }
}
'@
}

function Test-AvatarWorkerAssemblyLinkage {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Initialize-AvatarWorkerAssemblyLinkageVerifier

    $workerRoot = (
        "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Packages/" +
        "com.nickel-jp.avatar-recovery-hotswap-worker/Editor")
    $providerEntry = (
        "$workerRoot/BackgroundWorkerClient/" +
        "NickelJP.AvatarRecovery.HotSwap.BackgroundWorkerClient.Editor.dll")
    $consumerEntry = (
        "$workerRoot/SdkAutomation/" +
        "NickelJP.AvatarRecovery.HotSwap.WorkerSdkAutomation.Editor.dll")
    $providerAssemblyName = (
        "NickelJP.AvatarRecovery.HotSwap.BackgroundWorkerClient.Editor")

    $archive = [System.IO.Compression.ZipFile]::OpenRead((ConvertTo-FullPath $ZipPath))
    try {
        $providerBytes = Get-ZipEntryBytes -Archive $archive -EntryName $providerEntry
        $consumerBytes = Get-ZipEntryBytes -Archive $archive -EntryName $consumerEntry
    }
    finally {
        $archive.Dispose()
    }

    $checkedMemberCount = (
        [AvatarRecovery.ReleaseVerification.AvatarWorkerAssemblyLinkageVerifier]::Verify(
            $providerBytes,
            $consumerBytes,
            $providerAssemblyName))
    if ($checkedMemberCount -le 0) {
        throw "Avatar Worker assembly linkage check did not inspect any members"
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

        $expectedPackageUrl = "$ExpectedRepositoryBaseUrl/packages/$PackageId-$publishedVersion.zip"
        if ([string]$indexManifest.url -cne $expectedPackageUrl -or
            [string]$indexManifest.repo -cne "$ExpectedRepositoryBaseUrl/index.json") {
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
        $repositoryUrlsMatch = (
            [string]$zipManifest.url -ceq [string]$indexManifest.url -and
            [string]$zipManifest.repo -ceq [string]$indexManifest.repo)
        if (-not $repositoryUrlsMatch) {
            if ($publishedVersion -ceq $Version) {
                throw "latest package.json repository URLs do not match the VPM index"
            }

            $expectedLegacyPackageUrl = (
                "$LegacyRepositoryBaseUrl/packages/" +
                "$PackageId-$publishedVersion.zip")
            $expectedLegacyRepositoryUrl = "$LegacyRepositoryBaseUrl/index.json"
            if ([string]$zipManifest.url -cne $expectedLegacyPackageUrl -or
                [string]$zipManifest.repo -cne $expectedLegacyRepositoryUrl) {
                throw (
                    "historical package.json repository URLs are not the " +
                    "allowed legacy pair: $publishedVersion")
            }
        }

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

            if (-not $repositoryUrlsMatch -and
                $zipProperty.Name -in @("url", "repo")) {
                continue
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
    Test-NoOrphanUnityMetaEntriesInZip -ZipPath $zipPath
    Test-PackageReadmeSecurityDisclosure -ZipPath $zipPath
    if ($SupportsBundledWorkerSdk) {
        Test-AvatarHotSwapCompletedArtifactConsistency -ZipPath $zipPath
        Test-AvatarWorkerAssemblyLinkage -ZipPath $zipPath
    }
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

New-TestZip `
    -Path (Join-Path $OutputRoot "bundled-worker-sdk-source.zip") `
    -EntryName "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Packages/com.vrchat.base/Runtime/Allowed.cs" `
    -Text "class Allowed {}"
if ($SupportsBundledWorkerSdk) {
    [void]$results.Add((Assert-Passes "A1 bundled Worker SDK source" {
        Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "bundled-worker-sdk-source.zip")
    }))
}
else {
    [void]$results.Add((Assert-Fails "A1 removed Worker SDK source" {
        Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "bundled-worker-sdk-source.zip")
    }))
}

New-TestZip `
    -Path (Join-Path $OutputRoot "removed-hotswap-content.zip") `
    -EntryName "Editor/HotSwap/HotSwap_Avtr/Placeholder.asset" `
    -Text "placeholder"
if ($RequiresHotSwapRemoval) {
    [void]$results.Add((Assert-Fails "A1b removed HotSwap content" {
        Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "removed-hotswap-content.zip")
    }))
}
else {
    [void]$results.Add((Assert-Passes "A1b legacy HotSwap content" {
        Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "removed-hotswap-content.zip")
    }))
}

New-TestZip `
    -Path (Join-Path $OutputRoot "worker-template-source-injection.zip") `
    -EntryName "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Assets/Injected.cs" `
    -Text "class Injected {}"
[void]$results.Add((Assert-Fails "A2 non-SDK Worker template source injection" {
    Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "worker-template-source-injection.zip")
}))

New-TestZip `
    -Path (Join-Path $OutputRoot "bundled-worker-sdk-pdb-injection.zip") `
    -EntryName "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Packages/com.vrchat.base/Runtime/Injected.pdb" `
    -Text "debug symbols"
[void]$results.Add((Assert-Fails "A3 bundled Worker SDK debug symbol" {
    Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "bundled-worker-sdk-pdb-injection.zip")
}))

New-TestZip `
    -Path (Join-Path $OutputRoot "arbitrary-worker-package-source.zip") `
    -EntryName "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Packages/com.attacker/Injected.cs" `
    -Text "class Injected {}"
[void]$results.Add((Assert-Fails "A4 arbitrary Worker package source" {
    Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "arbitrary-worker-package-source.zip")
}))

New-TestZip `
    -Path (Join-Path $OutputRoot "lookalike-worker-package-source.zip") `
    -EntryName "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Packages/com.nickel-jp.avatar-recovery-hotswap-worker/Leaked.cs" `
    -Text "class Leaked {}"
[void]$results.Add((Assert-Fails "A5 lookalike Worker package source" {
    Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "lookalike-worker-package-source.zip")
}))

New-TestZip `
    -Path (Join-Path $OutputRoot "worker-sdk-traversal-source.zip") `
    -EntryName "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Packages/com.vrchat.base/../Assets/Injected.cs" `
    -Text "class Injected {}"
[void]$results.Add((Assert-Fails "A6 Worker SDK traversal source" {
    Test-PackageZipGuard -ZipPath (Join-Path $OutputRoot "worker-sdk-traversal-source.zip")
}))

New-TestZip `
    -Path (Join-Path $OutputRoot "avatar-worker-orphan-meta.zip") `
    -EntryName "Editor/HotSwap/HotSwap_Avtr/WorkerTemplate~/Assets/Editor.meta" `
    -Text "fileFormatVersion: 2"
[void]$results.Add((Assert-Fails "A7 Avatar Worker template orphan Unity metadata" {
    Test-NoOrphanUnityMetaEntriesInZip `
        -ZipPath (Join-Path $OutputRoot "avatar-worker-orphan-meta.zip")
}))

New-TestZip `
    -Path (Join-Path $OutputRoot "world-worker-orphan-meta.zip") `
    -EntryName "Editor/HotSwap/HotSwap_wrld/WorkerTemplate~/Assets/Editor.meta" `
    -Text "fileFormatVersion: 2"
[void]$results.Add((Assert-Fails "A8 World Worker template orphan Unity metadata" {
    Test-NoOrphanUnityMetaEntriesInZip `
        -ZipPath (Join-Path $OutputRoot "world-worker-orphan-meta.zip")
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
        url = "https://example.invalid/avatar-recovery/packages/$PackageId-$nextVersion.zip"
        repo = "https://example.invalid/avatar-recovery/index.json"
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

[void]$results.Add((Assert-Passes "T VPM build rejects orphan Unity metadata" {
    $fixtureRoot = Join-Path $OutputRoot "vpm-orphan-meta"
    $fixtureProjectRoot = Join-Path $fixtureRoot "project"
    $fixturePackageRoot = Join-Path $fixtureProjectRoot "Packages\$PackageId"
    $fixtureAssetsRoot = Join-Path $fixturePackageRoot "Assets"
    Ensure-Directory $fixtureAssetsRoot

    $fixtureVersion = "1.2.8"
    $fixtureManifest = [ordered]@{
        name = $PackageId
        displayName = "Avatar Recovery"
        version = $fixtureVersion
        unity = "2022.3"
        url = "https://example.invalid/avatar-recovery/packages/$PackageId-$fixtureVersion.zip"
        repo = "https://example.invalid/avatar-recovery/index.json"
        vpmDependencies = [ordered]@{
            "com.vrchat.base" = ">=3.7.0 <3.11.0"
        }
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $fixturePackageRoot "package.json"),
        ($fixtureManifest | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText(
        (Join-Path $fixtureAssetsRoot "Editor.meta"),
        "fileFormatVersion: 2`n",
        [System.Text.UTF8Encoding]::new($false))

    $buildOutput = @(
        & powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $RepoRoot "BuildVpmRepository.ps1") `
            -ProjectRoot $fixtureProjectRoot `
            -OutputRoot $fixtureRoot `
            -BaseUrl "https://example.invalid/avatar-recovery" `
            -MinimumPublishedVersion "1.0.0" `
            -MaximumPublishedVersion $fixtureVersion `
            -MaximumPublishedVersionCount 3 2>&1
    )
    if ($LASTEXITCODE -eq 0) {
        throw "VPM build accepted orphan Unity metadata."
    }
    if (($buildOutput -join [Environment]::NewLine) -notmatch
        'Unity \.meta entries whose assets or directories would be absent') {
        throw (
            "VPM build failed for an unexpected reason." +
            [Environment]::NewLine +
            ($buildOutput -join [Environment]::NewLine))
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
