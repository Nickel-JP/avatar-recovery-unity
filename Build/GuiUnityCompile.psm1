Set-StrictMode -Version Latest

function Assert-GuiCompileRegularPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        if ((Test-Path -LiteralPath $current) -and
            (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'GUI compile paths must not traverse reparse points.'
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Assert-GuiUnityCompileProjectLocation {
    param([string]$ProjectRoot, [string]$SeedRoot)
    $allowed = [IO.Path]::GetFullPath('G:\UnityTest').TrimEnd('\', '/') + '\'
    $project = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    $seed = [IO.Path]::GetFullPath($SeedRoot).TrimEnd('\', '/')
    foreach ($path in @($project, $seed)) {
        Assert-GuiCompileRegularPath -Path $path
        if (-not $path.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'GUI compile projects and seeds must be below G:\UnityTest.'
        }
    }
    if ($project.Equals($seed, [StringComparison]::OrdinalIgnoreCase) -or
        $project.StartsWith($seed + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $seed.StartsWith($project + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'GUI compile project and seed must be separate, non-nested directories.'
    }
    if (Test-Path -LiteralPath (Join-Path $project 'Temp\UnityLockfile')) {
        throw 'Close the existing compile project before staging a new GUI compile request.'
    }
    $manifestPath = Join-Path $seed 'Packages\manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.dependencies.'com.coplaydev.unity-mcp' -cne
        'https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#v10.1.2') {
        throw 'GUI compile seed must retain the pinned CoplayDev Unity MCP v10.1.2 dependency.'
    }
    if (@($manifest.dependencies.PSObject.Properties.Name | Where-Object { $_ -match '(?i)synaptic' }).Count -ne 0) {
        throw 'GUI compile seed must not contain a Synaptic dependency.'
    }
    $versionText = Get-Content -LiteralPath (Join-Path $seed 'ProjectSettings\ProjectVersion.txt') -Raw
    if ($versionText -notmatch '(?m)^m_EditorVersion: 2022\.3\.22f1\s*$') {
        throw 'GUI compile seed must use Unity 2022.3.22f1.'
    }
}

function Get-GuiCompileHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-GuiCompileRegularPath -Path $Path
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-GuiCompileInputPath {
    param([string]$RelativePath)
    $segments = $RelativePath.Replace('\', '/').Split('/')
    foreach ($segment in $segments) {
        if ($segment.StartsWith('.') -or $segment.EndsWith('~')) { return $false }
    }
    if ($RelativePath.StartsWith('ProjectSettings/', [StringComparison]::Ordinal)) {
        return -not $RelativePath.EndsWith('.meta', [StringComparison]::OrdinalIgnoreCase)
    }
    $name = $segments[$segments.Length - 1]
    return ($RelativePath -match '(?i)\.(cs|asmdef|asmref|rsp|dll)$' -or
        $RelativePath -match '(?i)\.(asmdef|asmref|dll)\.meta$' -or
        $name -ceq 'package.json' -or $RelativePath -ceq 'Packages/manifest.json' -or
        $RelativePath -ceq 'Packages/packages-lock.json')
}

function Get-GuiCompileManifest {
    param([string]$Root, [switch]$Project)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + '\'
    Assert-GuiCompileRegularPath -Path $fullRoot
    $searchRoots = if ($Project) { @('Assets', 'Packages', 'ProjectSettings') } else { @('') }
    $records = [Collections.Generic.List[object]]::new()
    foreach ($subRoot in $searchRoots) {
        $searchPath = if ([string]::IsNullOrEmpty($subRoot)) { $fullRoot } else { Join-Path $fullRoot $subRoot }
        $directories = [Collections.Generic.Stack[string]]::new()
        $directories.Push($searchPath)
        while ($directories.Count -gt 0) {
            $directory = $directories.Pop()
            Assert-GuiCompileRegularPath -Path $directory
            foreach ($file in Get-ChildItem -LiteralPath $directory -Force) {
                if ($file.Name.StartsWith('.') -or $file.Name.EndsWith('~')) { continue }
                if ($file.PSIsContainer) { $directories.Push($file.FullName); continue }
                $relative = $file.FullName.Substring($fullRoot.Length).Replace('\', '/')
                if (-not (Test-GuiCompileInputPath -RelativePath $relative)) { continue }
                [void]$records.Add([PSCustomObject]@{
                    Path = $relative
                    Length = [long]$file.Length
                    Sha256 = Get-GuiCompileHash -Path $file.FullName
                })
            }
        }
    }
    @($records.ToArray() | Sort-Object -Property Path -CaseSensitive)
}

function Assert-GuiCompileManifest {
    param([object[]]$Expected, [object[]]$Actual)
    if ($Expected.Count -ne $Actual.Count) { throw 'GUI compile source file set changed.' }
    $actualMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($record in $Actual) { $actualMap.Add([string]$record.Path, $record) }
    foreach ($record in $Expected) {
        if (-not $actualMap.ContainsKey([string]$record.Path)) { throw 'GUI compile source file set changed.' }
        $current = $actualMap[[string]$record.Path]
        if ([long]$current.Length -ne [long]$record.Length -or $current.Sha256 -cne $record.Sha256) {
            throw ('GUI compile source changed: ' + $record.Path)
        }
    }
}

function New-GuiUnityCompileRequest {
    param([string]$ProjectRoot, [string]$SourcePackageRoot, [string]$PackageId, [string]$Version,
        [string]$AssemblyName, [string]$ExporterRoot, $NormalizerReport, $TextureReport)
    foreach ($inputReport in @(
        @{ Name = 'ExpressionMenuNormalizer'; Value = $NormalizerReport },
        @{ Name = 'TextureArrayLayoutTool'; Value = $TextureReport })) {
        if ($null -eq $inputReport.Value -or $inputReport.Value -is [array] -or
            $null -eq $inputReport.Value.PSObject.Properties['Files']) {
            throw ('GUI compile requires one structured payload report without command output: ' + $inputReport.Name)
        }
    }
    $project = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/').Replace('\', '/')
    $origin = [IO.Path]::GetFullPath($SourcePackageRoot).TrimEnd('\', '/').Replace('\', '/')
    $exporterTarget = Join-Path $project 'Assets\Editor\AvatarRecoveryGuiCompile'
    if (Test-Path -LiteralPath $exporterTarget) {
        throw 'GUI compile exporter staging directory already exists in the seed.'
    }
    [void][IO.Directory]::CreateDirectory($exporterTarget)
    foreach ($name in @('GuiUnityCompile.cs', 'AvatarRecovery.GuiCompile.Editor.asmdef',
        'GuiUnityCompile.cs.meta', 'AvatarRecovery.GuiCompile.Editor.asmdef.meta')) {
        Copy-Item -LiteralPath (Join-Path $ExporterRoot $name) -Destination $exporterTarget
    }
    $originFiles = @(Get-GuiCompileManifest -Root $origin)
    $packageRelativeRoot = 'Packages/' + $PackageId
    $stagedFiles = @(Get-GuiCompileManifest -Root (Join-Path $project $packageRelativeRoot))
    Assert-GuiCompileManifest -Expected $originFiles -Actual $stagedFiles
    $payloadFiles = [Collections.Generic.List[object]]::new()
    foreach ($payload in @(
        @{ Root = 'Tools~/ExpressionMenuNormalizer'; Report = $NormalizerReport },
        @{ Root = 'Tools~/TextureArrayLayoutTool'; Report = $TextureReport })) {
        foreach ($file in @($payload.Report.Files)) {
            if ([IO.Path]::GetFileName([string]$file.Name) -cne [string]$file.Name -or
                [string]$file.SHA256 -cnotmatch '^[0-9a-f]{64}$') {
                throw 'GUI compile payload report contains an invalid identity.'
            }
            $relative = $packageRelativeRoot + '/' + $payload.Root + '/' + $file.Name
            foreach ($path in @((Join-Path $project $relative), (Join-Path $origin ($payload.Root + '/' + $file.Name)))) {
                if ((Get-GuiCompileHash -Path $path) -cne [string]$file.SHA256 -or
                    (Get-Item -LiteralPath $path).Length -ne [long]$file.Length) {
                    throw 'GUI compile payload differs from the signed build report.'
                }
            }
            [void]$payloadFiles.Add([PSCustomObject]@{ Path = $relative; Length = [long]$file.Length; Sha256 = [string]$file.SHA256 })
        }
    }
    $nonce = [Guid]::NewGuid().ToString('N')
    $requestRoot = Join-Path $project '.avatar-recovery-gui-compile'
    [void][IO.Directory]::CreateDirectory($requestRoot)
    $requestPath = Join-Path $requestRoot 'request.json'
    $receiptPath = Join-Path $requestRoot ($nonce + '.receipt.json')
    $requestData = [PSCustomObject]@{
        SchemaVersion = 1; RequestNonce = $nonce; CreatedUtc = [DateTime]::UtcNow.ToString('O')
        ProjectRoot = $project; SourcePackageRoot = $origin; PackageId = $PackageId; Version = $Version
        UnityVersion = '2022.3.22f1'; AssemblyName = $AssemblyName
        AssemblyPath = 'Library/ScriptAssemblies/' + $AssemblyName + '.dll'
        PackageRelativeRoot = $packageRelativeRoot
        ReceiptPath = $receiptPath.Replace('\', '/')
        SourceFiles = @(Get-GuiCompileManifest -Root $project -Project)
        OriginFiles = $originFiles; PayloadFiles = @($payloadFiles.ToArray())
    }
    [IO.File]::WriteAllText($requestPath, ($requestData | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    [PSCustomObject]@{ Data = $requestData; RequestPath = $requestPath; ReceiptPath = $receiptPath
        RequestSha256 = Get-GuiCompileHash -Path $requestPath }
}

function Read-GuiCompileJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-GuiCompileRegularPath -Path $Path
    $arguments = @{ InputObject = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8); ErrorAction = 'Stop' }
    $command = Get-Command -Name 'Microsoft.PowerShell.Utility\ConvertFrom-Json' -CommandType Cmdlet -ErrorAction Stop
    if ($command.Parameters.ContainsKey('DateKind')) {
        # 対応版では、ISO日時をJSONに記録された文字列のまま保持します。
        $arguments.DateKind = 'String'
    }
    Microsoft.PowerShell.Utility\ConvertFrom-Json @arguments
}

function ConvertTo-GuiCompileUtcTimestamp {
    param([AllowNull()]$Value, [Parameter(Mandatory = $true)][string]$FieldName)
    $typeName = if ($null -eq $Value) { '<null>' } else { $Value.GetType().FullName }
    try {
        if ($Value -is [DateTimeOffset]) {
            $timestamp = $Value
        }
        elseif ($Value -is [DateTime]) {
            # Unspecifiedは元のタイムゾーンを確定できないため、UTCとみなしません。
            if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw 'Timestamp timezone is unspecified.' }
            $timestamp = [DateTimeOffset]::new($Value)
        }
        elseif ($Value -is [string]) {
            if ($Value -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?(?:Z|[+-][0-9]{2}:[0-9]{2})$') {
                throw 'Timestamp must contain an explicit timezone.'
            }
            $timestamp = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
        }
        else { throw 'Timestamp type is unsupported.' }
        $timestamp.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw ("GUI compile field '{0}' has type '{1}'; expected a valid timezone-qualified timestamp." -f $FieldName, $typeName)
    }
}

function Wait-GuiUnityCompileReceipt {
    param($Request, [int]$TimeoutSeconds)
    if (Test-Path -LiteralPath $Request.ReceiptPath -PathType Leaf) {
        Write-Host ('Reading the existing GUI receipt: ' + $Request.ReceiptPath)
    }
    else {
        Write-Host ('GUI compile request staged: ' + $Request.RequestPath)
        Write-Host ('Open the project with Unity 2022.3.22f1 GUI: ' + $Request.Data.ProjectRoot)
        Write-Host 'Use Tools/AvatarRecovery Build/1. Arm and Compile, then 2. Export Compile Receipt after reload.'
        Write-Host 'This build does not start Unity. Keep this build process running until the receipt is exported.'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $Request.ReceiptPath -PathType Leaf)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the GUI compile receipt.' }
        Start-Sleep -Seconds 1
    }
    Assert-GuiCompileRegularPath -Path $Request.ReceiptPath
    $receipt = Read-GuiCompileJson -Path $Request.ReceiptPath
    $data = $Request.Data
    foreach ($name in @('StartedUtc', 'FinishedUtc', 'ExportedUtc')) {
        $property = $receipt.PSObject.Properties[$name]
        if ($null -eq $property) { throw ("GUI compile receipt field '{0}' has type '<missing>'; expected a timezone-qualified timestamp." -f $name) }
        $receipt.$name = ConvertTo-GuiCompileUtcTimestamp -Value $property.Value -FieldName ('receipt.' + $name)
    }
    $createdProperty = $data.PSObject.Properties['CreatedUtc']
    if ($null -eq $createdProperty) { throw "GUI compile request field 'CreatedUtc' has type '<missing>'; expected a timezone-qualified timestamp." }
    $createdTimestamp = ConvertTo-GuiCompileUtcTimestamp -Value $createdProperty.Value -FieldName 'request.CreatedUtc'
    foreach ($name in @('RequestNonce', 'RequestSha256', 'ProjectRoot', 'UnityVersion', 'AssemblyName',
        'AssemblyPath', 'AssemblySha256', 'AssemblyMvid', 'BeforeAssemblySha256', 'TargetAssemblyEventPath',
        'EditorSessionNonce', 'CompilationId',
        'StartedUtc', 'FinishedUtc', 'ExportedUtc')) {
        $property = $receipt.PSObject.Properties[$name]
        $value = if ($null -eq $property) { $null } else { $property.Value }
        if ($value -isnot [string]) {
            $typeName = if ($null -eq $property) { '<missing>' } elseif ($null -eq $value) { '<null>' } else { $value.GetType().FullName }
            throw ("GUI compile receipt field '{0}' has type '{1}'; expected System.String." -f $name, $typeName)
        }
    }
    foreach ($name in @('IsBatchMode', 'ExportedFromMenu', 'TargetAssemblyCompiled', 'TargetAssemblyUnchanged', 'CleanBuildCacheRequested')) {
        $property = $receipt.PSObject.Properties[$name]
        $value = if ($null -eq $property) { $null } else { $property.Value }
        if ($value -isnot [bool]) {
            $typeName = if ($null -eq $property) { '<missing>' } elseif ($null -eq $value) { '<null>' } else { $value.GetType().FullName }
            throw ("GUI compile receipt field '{0}' has type '{1}'; expected System.Boolean." -f $name, $typeName)
        }
    }
    foreach ($name in @('SchemaVersion', 'CompileErrorCount')) {
        $property = $receipt.PSObject.Properties[$name]
        $value = if ($null -eq $property) { $null } else { $property.Value }
        if ($value -isnot [int] -and $value -isnot [long]) {
            $typeName = if ($null -eq $property) { '<missing>' } elseif ($null -eq $value) { '<null>' } else { $value.GetType().FullName }
            throw ("GUI compile receipt field '{0}' has type '{1}'; expected System.Int32 or System.Int64." -f $name, $typeName)
        }
    }
    if ((Get-GuiCompileHash -Path $Request.RequestPath) -cne $Request.RequestSha256 -or
        $receipt.SchemaVersion -ne 1 -or $receipt.RequestNonce -cne $data.RequestNonce -or
        $receipt.RequestSha256 -cne $Request.RequestSha256 -or
        $receipt.ProjectRoot -cne $data.ProjectRoot -or $receipt.UnityVersion -cne $data.UnityVersion -or
        $receipt.AssemblyName -cne $data.AssemblyName -or $receipt.AssemblyPath -cne $data.AssemblyPath -or
        $receipt.IsBatchMode -or -not $receipt.ExportedFromMenu -or
        -not $receipt.CleanBuildCacheRequested -or
        ($receipt.TargetAssemblyCompiled -eq $receipt.TargetAssemblyUnchanged) -or
        $receipt.BeforeAssemblySha256 -cnotmatch '^[0-9a-f]{64}$' -or
        ($receipt.TargetAssemblyUnchanged -and $receipt.BeforeAssemblySha256 -cne $receipt.AssemblySha256) -or
        $receipt.CompileErrorCount -ne 0 -or
        [string]$receipt.EditorSessionNonce -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$receipt.CompilationId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'GUI compile receipt identity or successful GUI compilation evidence is invalid.'
    }
    $eventPath = if ([IO.Path]::IsPathRooted($receipt.TargetAssemblyEventPath)) {
        [IO.Path]::GetFullPath($receipt.TargetAssemblyEventPath)
    } else { [IO.Path]::GetFullPath((Join-Path $data.ProjectRoot $receipt.TargetAssemblyEventPath)) }
    if (-not $eventPath.Equals([IO.Path]::GetFullPath((Join-Path $data.ProjectRoot $data.AssemblyPath)), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'GUI compile target callback path does not match the fixed assembly path.'
    }
    $created = [DateTimeOffset]::Parse($createdTimestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    $started = [DateTimeOffset]::Parse($receipt.StartedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    $finished = [DateTimeOffset]::Parse($receipt.FinishedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    $exported = [DateTimeOffset]::Parse($receipt.ExportedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    if ($started -lt $created -or $finished -lt $started -or $exported -lt $finished -or
        $exported -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) { throw 'GUI compile receipt timestamps are invalid.' }
    Assert-GuiCompileManifest -Expected @($data.SourceFiles) -Actual @(Get-GuiCompileManifest -Root $data.ProjectRoot -Project)
    Assert-GuiCompileManifest -Expected @($data.OriginFiles) -Actual @(Get-GuiCompileManifest -Root $data.SourcePackageRoot)
    foreach ($file in $data.PayloadFiles) {
        $originRelative = $file.Path.Substring($data.PackageRelativeRoot.Length + 1)
        foreach ($path in @((Join-Path $data.ProjectRoot $file.Path), (Join-Path $data.SourcePackageRoot $originRelative))) {
            if ((Get-GuiCompileHash -Path $path) -cne $file.Sha256 -or
                (Get-Item -LiteralPath $path).Length -ne [long]$file.Length) { throw 'GUI compile payload changed.' }
        }
    }
    $dllPath = Join-Path $data.ProjectRoot $data.AssemblyPath
    if ((Get-GuiCompileHash -Path $dllPath) -cne $receipt.AssemblySha256) { throw 'GUI compile DLL SHA-256 mismatch.' }
    # 呼び出し元が既存のMono.Cecilを読み込み、同じDLLのMVIDを確認します。
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($dllPath)
    try {
        if ($assembly.Name.Name -cne $data.AssemblyName -or
            $assembly.MainModule.Mvid.ToString('D') -cne $receipt.AssemblyMvid) {
            throw 'GUI compile DLL assembly identity or MVID mismatch.'
        }
    }
    finally { $assembly.Dispose() }
    $assemblyResult = if ($receipt.TargetAssemblyCompiled) { 'Finished' } else { 'Unchanged (existing artifact retained)' }
    Write-Host ('GUI assembly result: ' + $assemblyResult)
    [PSCustomObject]@{ ReceiptPath = $Request.ReceiptPath; AssemblySha256 = [string]$receipt.AssemblySha256
        AssemblyResult = $assemblyResult }
}

function Open-GuiUnityCompileRequest {
    param([string]$ProjectRoot, [string]$SourcePackageRoot, [string]$PackageId, [string]$Version,
        [string]$AssemblyName, [string]$ReceiptPath)
    $project = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/').Replace('\', '/')
    $origin = [IO.Path]::GetFullPath($SourcePackageRoot).TrimEnd('\', '/').Replace('\', '/')
    $requestPath = Join-Path $project '.avatar-recovery-gui-compile/request.json'
    $data = Read-GuiCompileJson -Path $requestPath
    foreach ($name in @('RequestNonce', 'ProjectRoot', 'SourcePackageRoot', 'PackageId', 'Version',
        'UnityVersion', 'AssemblyName', 'AssemblyPath', 'PackageRelativeRoot', 'ReceiptPath')) {
        $property = $data.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [string]) {
            $typeName = if ($null -eq $property) { '<missing>' } elseif ($null -eq $property.Value) { '<null>' } else { $property.Value.GetType().FullName }
            throw ("GUI resume request field '{0}' has type '{1}'; expected System.String." -f $name, $typeName)
        }
    }
    if ($data.SchemaVersion -isnot [int] -and $data.SchemaVersion -isnot [long]) {
        throw 'GUI resume request SchemaVersion must be System.Int32 or System.Int64.'
    }
    if ($data.SchemaVersion -ne 1 -or $data.RequestNonce -cnotmatch '^[0-9a-f]{32}$' -or
        -not $data.ProjectRoot.Equals($project, [StringComparison]::OrdinalIgnoreCase) -or
        -not $data.SourcePackageRoot.Equals($origin, [StringComparison]::OrdinalIgnoreCase) -or
        $data.PackageId -cne $PackageId -or $data.Version -cne $Version -or
        $data.UnityVersion -cne '2022.3.22f1' -or $data.AssemblyName -cne $AssemblyName -or
        $data.AssemblyPath -cne ('Library/ScriptAssemblies/' + $AssemblyName + '.dll') -or
        $data.PackageRelativeRoot -cne ('Packages/' + $PackageId)) {
        throw 'GUI resume request does not match the selected project, source, package, version, or assembly.'
    }
    $expectedReceipt = [IO.Path]::GetFullPath((Join-Path $project ('.avatar-recovery-gui-compile/' + $data.RequestNonce + '.receipt.json')))
    foreach ($path in @($ReceiptPath, $data.ReceiptPath)) {
        if (-not [IO.Path]::GetFullPath($path).Equals($expectedReceipt, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'GUI resume requires the original receipt path for the original request nonce.'
        }
        Assert-GuiCompileRegularPath -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'GUI resume requires an existing completed GUI receipt.' }
    }
    [PSCustomObject]@{ Data = $data; RequestPath = $requestPath; ReceiptPath = $expectedReceipt
        RequestSha256 = Get-GuiCompileHash -Path $requestPath }
}

function Get-GuiUnityCompileResumePayloadReports {
    param($Request, [string]$TextureReportPath)
    $groups = @{}
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($root in @('Tools~/ExpressionMenuNormalizer', 'Tools~/TextureArrayLayoutTool')) {
        $prefix = $Request.Data.PackageRelativeRoot + '/' + $root + '/'
        $records = [Collections.Generic.List[object]]::new()
        foreach ($file in @($Request.Data.PayloadFiles | Where-Object { $_.Path.StartsWith($prefix, [StringComparison]::Ordinal) })) {
            $name = $file.Path.Substring($prefix.Length)
            if ($name.Length -eq 0 -or [IO.Path]::GetFileName($name) -cne $name -or -not $seen.Add($file.Path)) {
                throw 'GUI resume payload manifest contains an invalid or duplicate file path.'
            }
            [void]$records.Add([PSCustomObject]@{ Name = $name; Length = [long]$file.Length; SHA256 = [string]$file.Sha256 })
        }
        $groups[$root] = @($records.ToArray())
    }
    if ($seen.Count -ne @($Request.Data.PayloadFiles).Count -or $groups['Tools~/ExpressionMenuNormalizer'].Count -eq 0) {
        throw 'GUI resume payload manifest does not match the supported payload groups.'
    }
    $textureFiles = @($groups['Tools~/TextureArrayLayoutTool'])
    if ($textureFiles.Count -eq 0) {
        $textureReport = [PSCustomObject]@{ Enabled = $false; Files = @(); SignedFileNames = @(); ResumeReconstructed = $true }
    }
    else {
        $textureReport = Read-GuiCompileJson -Path $TextureReportPath
        if ($textureReport.Enabled -isnot [bool] -or -not $textureReport.Enabled -or
            @($textureReport.Files).Count -ne $textureFiles.Count) {
            throw 'GUI resume texture report is missing or has a different file contract.'
        }
        $actual = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($file in @($textureReport.Files)) { $actual.Add([string]$file.Name, $file) }
        foreach ($file in $textureFiles) {
            if (-not $actual.ContainsKey($file.Name) -or
                [long]$actual[$file.Name].Length -ne $file.Length -or $actual[$file.Name].SHA256 -cne $file.SHA256) {
                throw 'GUI resume texture report does not match the original GUI request payload identities.'
            }
        }
    }
    [PSCustomObject]@{ NormalizerFiles = @($groups['Tools~/ExpressionMenuNormalizer']); TextureReport = $textureReport }
}

Export-ModuleMember -Function Assert-GuiUnityCompileProjectLocation, New-GuiUnityCompileRequest, Wait-GuiUnityCompileReceipt, Open-GuiUnityCompileRequest, Get-GuiUnityCompileResumePayloadReports
