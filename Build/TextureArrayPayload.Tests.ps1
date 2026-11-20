param([string]$OutputRoot = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repo ('.work/Minimal1230/Validation/BuildPayload/contract-' + [Guid]::NewGuid().ToString('N'))
}
$testRoot = [IO.Path]::GetFullPath($OutputRoot)
$allowed = [IO.Path]::GetFullPath((Join-Path $repo '.work/Minimal1230/Validation/BuildPayload')).TrimEnd('\') + '\'
if (-not $testRoot.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $testRoot)) {
    throw 'Tests require a fresh directory under isolated Minimal1230/Validation/BuildPayload.'
}
[void][IO.Directory]::CreateDirectory($testRoot)
Import-Module (Join-Path $PSScriptRoot 'TextureArrayPayload.psm1') -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$contract = Get-TextureArrayPayloadContract
$results = [Collections.Generic.List[object]]::new()
$completed = $false
$context = [PSCustomObject]@{ Required = $true; Mode = 'TestSignerSimulation' }
$sign = {
    param($Path, $Context)
    # 実際の署名鍵を使わず、署名前後でバイトが変わる契約を検査します。
    [IO.File]::AppendAllText($Path, '|test-signed|', [Text.UTF8Encoding]::new($false))
}
$verify = {
    param($Path, $Context)
    if (-not [IO.File]::ReadAllText($Path).EndsWith('|test-signed|', [StringComparison]::Ordinal)) {
        throw 'Test signature simulation is absent.'
    }
}

function Check {
    param([string]$Name, [scriptblock]$Action)
    try { & $Action; [void]$results.Add([PSCustomObject]@{ Name = $Name; Passed = $true }) }
    catch { [void]$results.Add([PSCustomObject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message }); throw }
}

function Must-Fail {
    param([scriptblock]$Action)
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected rejection did not occur.' }
}

function New-Case {
    param([string]$Name)
    $root = Join-Path $testRoot $Name
    $input = Join-Path $root 'input'
    $registry = Join-Path $root 'registry/source'
    [void][IO.Directory]::CreateDirectory($input)
    [void][IO.Directory]::CreateDirectory($registry)
    foreach ($name in $contract.InputNames) { [IO.File]::WriteAllText((Join-Path $input $name), 'fixture:' + $name) }
    $dependencies = @(
        [PSCustomObject]@{ Name = 'alpha'; Version = '1.2.3'; License = 'MIT'; Repository = 'https://example.invalid/alpha' },
        [PSCustomObject]@{ Name = 'alpha'; Version = '2.0.0'; License = 'MIT OR Apache-2.0'; Repository = 'https://example.invalid/alpha' }
    )
    [IO.File]::WriteAllText((Join-Path $input 'RustWorker.ThirdPartyDependencies.json'), ($dependencies | ConvertTo-Json))
    $lockPath = Join-Path $root 'Cargo.lock'
    $blocks = @('version = 3')
    foreach ($dependency in $dependencies) {
        $blocks += '[[package]]', ('name = "' + $dependency.Name + '"'), ('version = "' + $dependency.Version + '"'),
            'source = "registry+https://github.com/rust-lang/crates.io-index"'
        $directory = Join-Path $registry ('alpha-' + $dependency.Version)
        [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllText((Join-Path $directory 'LICENSE-MIT'), "MIT License`nCopyright (c) Test authors " + $dependency.Version)
        [IO.File]::WriteAllText((Join-Path $directory 'NOTICE.txt'), 'Fixture attribution ' + $dependency.Version)
    }
    [IO.File]::WriteAllText($lockPath, ($blocks -join "`n") + "`n")
    $toolchain = Join-Path $root 'toolchain/1.99.1-x86_64-pc-windows-msvc'
    [void][IO.Directory]::CreateDirectory((Join-Path $toolchain 'share/doc/rust'))
    [void][IO.Directory]::CreateDirectory((Join-Path $toolchain 'lib/rustlib'))
    [IO.File]::WriteAllText((Join-Path $toolchain 'lib/rustlib/multirust-channel-manifest.toml'), "[pkg.rust]`nversion = `"1.99.1 (fixture)`"`n")
    [IO.File]::WriteAllText((Join-Path $toolchain 'share/doc/rust/COPYRIGHT-library.html'), '<html><title>Copyright notices for The Rust Standard Library</title><body>Full fixture license and attribution text.</body></html>')
    [PSCustomObject]@{ Root = $root; Input = $input; Registry = (Split-Path -Parent $registry); Lock = $lockPath; Stage = (Join-Path $root 'stage'); Toolchain = $toolchain }
}

function Stage-Case {
    param($Case, [scriptblock]$Signer = $sign, $SigningContext = $context, [string[]]$Forbidden = @())
    New-TextureArrayPayloadStage -InputRoot $Case.Input -StageRoot $Case.Stage -CargoLockPath $Case.Lock `
        -RegistryRoot $Case.Registry -RustToolchainRoot $Case.Toolchain -SignFile $Signer -VerifySignature $verify -Context $SigningContext -ForbiddenPathTokens $Forbidden
}

function New-CaseZip {
    param($Case, [string]$Name)
    $package = Join-Path $Case.Root ('package-' + $Name)
    $tools = Join-Path $package 'Tools~/TextureArrayLayoutTool'
    [void][IO.Directory]::CreateDirectory($tools)
    foreach ($file in Get-ChildItem -LiteralPath $Case.Stage -File) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $tools $file.Name) }
    $zip = Join-Path $Case.Root ($Name + '.zip')
    # 実際のVPM packagerと同じく、.NET Frameworkでも区切りを明示してentryを作ります。
    $fileStream = [IO.FileStream]::new($zip, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($fileStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($file in Get-ChildItem -LiteralPath $package -File -Recurse) {
                $relative = $file.FullName.Substring($package.Length + 1).Replace('\', '/')
                $entry = $archive.CreateEntry($relative)
                $source = [IO.File]::OpenRead($file.FullName)
                $destination = $entry.Open()
                try { $source.CopyTo($destination) } finally { $destination.Dispose(); $source.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $fileStream.Dispose() }
    return $zip
}

function Add-ZipEntry {
    param([string]$Zip, [string]$Name)
    $archive = [IO.Compression.ZipFile]::Open($Zip, [IO.Compression.ZipArchiveMode]::Update)
    try { $entry = $archive.CreateEntry($Name); $stream = $entry.Open(); try { $stream.WriteByte(65) } finally { $stream.Dispose() } }
    finally { $archive.Dispose() }
}

try {
    $valid = New-Case 'valid'
    $before = (Get-FileHash -LiteralPath (Join-Path $valid.Input 'TextureArrayLayoutTool.exe') -Algorithm SHA256).Hash
    $report = Stage-Case $valid
    Check 'FixedNamesAndPostSigningHashes' {
        if ($report.Files.Count -ne 21 -or $report.SignedFileNames.Count -ne 11) { throw 'Contract count mismatch.' }
        $entry = @($report.Files | Where-Object Name -CEQ 'TextureArrayLayoutTool.exe')[0]
        if ($entry.SHA256 -eq $before.ToLowerInvariant()) { throw 'Manifest used an unsigned hash.' }
        if ((Get-FileHash -LiteralPath (Join-Path $valid.Input 'TextureArrayLayoutTool.exe') -Algorithm SHA256).Hash -ne $before) { throw 'Input was modified.' }
    }
    Check 'CargoVersionsAndFullNotices' {
        $text = [IO.File]::ReadAllText((Join-Path $valid.Stage $contract.NoticesName))
        foreach ($token in @('alpha@1.2.3', 'alpha@2.0.0', 'Copyright (c) Test authors', 'Fixture attribution')) {
            if (-not $text.Contains($token)) { throw 'License or attribution text is missing.' }
        }
        if ($report.RustNotices.PackageCount -ne 2 -or $report.RustNotices.LicenseFiles.Count -ne 4) { throw 'Notices inventory mismatch.' }
        $source = Join-Path $valid.Toolchain 'share/doc/rust/COPYRIGHT-library.html'
        $staged = Join-Path $valid.Stage $contract.StandardLibraryName
        if ((Get-FileHash -LiteralPath $source).Hash -cne (Get-FileHash -LiteralPath $staged).Hash -or
            $report.RustNotices.StandardLibrary.ToolchainVersion -cne '1.99.1') { throw 'Standard-library notices were changed or unpinned.' }
        $manifest = [IO.File]::ReadAllText((Join-Path $valid.Stage $contract.ManifestName))
        if (-not $manifest.Contains('# Rust standard-library toolchain: 1.99.1') -or
            -not $manifest.Contains($report.RustNotices.StandardLibrary.SourceSHA256)) { throw 'Standard-library provenance metadata is missing.' }
    }
    Check 'InputMissingDependencyRejected' { $case = New-Case 'missing'; Remove-Item -LiteralPath (Join-Path $case.Input 'AssetsTools.NET.Texture.dll'); Must-Fail { Stage-Case $case } }
    Check 'UnexpectedPayloadRejected' { $case = New-Case 'extra'; [IO.File]::WriteAllText((Join-Path $case.Input 'debug.pdb'), 'private'); Must-Fail { Stage-Case $case } }
    Check 'NestedPayloadRejected' { $case = New-Case 'nested'; [void][IO.Directory]::CreateDirectory((Join-Path $case.Input 'nested')); Must-Fail { Stage-Case $case } }
    Check 'UnsignedContextRejected' { $case = New-Case 'unsigned'; Must-Fail { Stage-Case $case -SigningContext ([PSCustomObject]@{ Required = $false }) } }
    Check 'CargoInventoryMismatchRejected' { $case = New-Case 'lock-mismatch'; [IO.File]::AppendAllText($case.Lock, "`n[[package]]`nname = `"beta`"`nversion = `"1.0.0`"`nsource = `"registry+https://github.com/rust-lang/crates.io-index`"`n"); Must-Fail { Stage-Case $case } }
    Check 'UnknownCargoSourceRejected' { $case = New-Case 'unknown-source'; [IO.File]::AppendAllText($case.Lock, "`n[[package]]`nname = `"beta`"`nversion = `"1.0.0`"`nsource = `"git+https://example.invalid/unknown`"`n"); Must-Fail { Stage-Case $case } }
    Check 'MissingLicenseRejected' { $case = New-Case 'no-license'; foreach ($file in Get-ChildItem -LiteralPath (Join-Path $case.Registry 'source/alpha-1.2.3') -File) { Remove-Item -LiteralPath $file.FullName }; Must-Fail { Stage-Case $case } }
    Check 'ExistingNoticesAreNeverOverwritten' { $case = New-Case 'notice-nooverwrite'; $output = Join-Path $case.Root 'existing-notices.txt'; [IO.File]::WriteAllText($output, 'keep-existing'); Must-Fail { New-TextureArrayRustNotices -CargoLockPath $case.Lock -DependencyManifestPath (Join-Path $case.Input 'RustWorker.ThirdPartyDependencies.json') -RegistryRoot $case.Registry -OutputPath $output }; if ([IO.File]::ReadAllText($output) -cne 'keep-existing') { throw 'Existing notice was overwritten.' } }
    Check 'WrongStandardLibraryVersionRejected' { $case = New-Case 'stdlib-version'; [IO.File]::WriteAllText((Join-Path $case.Toolchain 'lib/rustlib/multirust-channel-manifest.toml'), "[pkg.rust]`nversion = `"1.99.0`"`n"); Must-Fail { Stage-Case $case } }
    Check 'MissingStandardLibraryNoticesRejected' { $case = New-Case 'stdlib-missing'; Remove-Item -LiteralPath (Join-Path $case.Toolchain 'share/doc/rust/COPYRIGHT-library.html'); Must-Fail { Stage-Case $case } }
    Check 'PrivatePathInStandardLibraryRejected' { $case = New-Case 'stdlib-marker'; [IO.File]::AppendAllText((Join-Path $case.Toolchain 'share/doc/rust/COPYRIGHT-library.html'), 'Z:\internal\build'); Must-Fail { Stage-Case $case -Forbidden @('Z:\internal\build') } }
    Check 'SignerFailurePreservesInput' { $case = New-Case 'signer-failure'; $hash = (Get-FileHash -LiteralPath (Join-Path $case.Input 'png-repack-worker.exe')).Hash; Must-Fail { Stage-Case $case -Signer { param($Path, $Context) throw 'Simulated signer failure.' } }; if ((Get-FileHash -LiteralPath (Join-Path $case.Input 'png-repack-worker.exe')).Hash -ne $hash) { throw 'Input changed after signer failure.' } }
    Check 'SourceRaceRejected' { $case = New-Case 'source-race'; $raceInput = Join-Path $case.Input 'png-repack-worker.exe'; $signer = { param($Path, $Context) [IO.File]::AppendAllText($Path, '|test-signed|'); [IO.File]::AppendAllText($raceInput, 'changed') }.GetNewClosure(); Must-Fail { Stage-Case $case -Signer $signer } }
    Check 'SigningCannotChangeUnsignedLicenseData' { $case = New-Case 'unsigned-data-race'; $notice = Join-Path $case.Stage $contract.StandardLibraryName; $signer = { param($Path, $Context) [IO.File]::AppendAllText($Path, '|test-signed|'); [IO.File]::AppendAllText($notice, 'changed') }.GetNewClosure(); Must-Fail { Stage-Case $case -Signer $signer } }
    Check 'PrivatePathAsciiRejectedWithoutDisclosure' { $case = New-Case 'path-ascii'; [IO.File]::AppendAllText((Join-Path $case.Input 'png-repack-worker.exe'), 'Z:\internal\build'); Must-Fail { Stage-Case $case -Forbidden @('Z:\internal\build') } }
    Check 'PrivatePathUnicodeRejected' { $case = New-Case 'path-unicode'; [IO.File]::WriteAllBytes((Join-Path $case.Input 'png-repack-worker.exe'), [Text.Encoding]::Unicode.GetBytes('Z:\internal\build')); Must-Fail { Stage-Case $case -Forbidden @('Z:\internal\build') } }
    Check 'PrivacyAllowsAllFixedPublicFiles' {
        $root = Join-Path $testRoot 'privacy-fixed'
        [void][IO.Directory]::CreateDirectory($root)
        foreach ($name in @($contract.PayloadNames + $contract.ManifestName)) {
            $text = if ([IO.Path]::GetExtension($name) -ieq '.json') { '{"public":[{"value":"allowed"}]}' } else { 'public-data' }
            [IO.File]::WriteAllText((Join-Path $root $name), $text)
        }
        & (Get-Module TextureArrayPayload) { param($Root, $Names) Test-TextureArrayLocalPathLeak -Root $Root -Names $Names -ForbiddenPathTokens @('Z:\internal\build') } $root @($contract.PayloadNames + $contract.ManifestName)
    }
    Check 'PrivacyChecksEveryFixedPayloadName' {
        $root = Join-Path $testRoot 'privacy-each'
        [void][IO.Directory]::CreateDirectory($root)
        foreach ($name in @($contract.PayloadNames + $contract.ManifestName)) {
            $text = if ([IO.Path]::GetExtension($name) -ieq '.json') { '{"leak":"Z:\\internal\\build"}' } else { 'Z:\internal\build' }
            [IO.File]::WriteAllText((Join-Path $root $name), $text)
            Must-Fail { & (Get-Module TextureArrayPayload) { param($Root, $Name) Test-TextureArrayLocalPathLeak -Root $Root -Names @($Name) -ForbiddenPathTokens @('Z:\internal\build') } $root $name }
        }
    }
    Check 'DecodedNestedJsonKeysAndDuplicateValuesRejected' {
        $root = Join-Path $testRoot 'privacy-json'
        [void][IO.Directory]::CreateDirectory($root)
        $variants = @(
            '{"outer":[{"nested":"Z:\\internal\\build"}]}',
            '{"outer":"Z:\u005cinternal\u005cbuild"}',
            '{"\u005a:\u005cinternal\u005cbuild":"public"}',
            '{"name":"\u005a\u003a\u005cinternal\u005cbuild","name":"public"}',
            '{"path":"Z:\/internal\/build"}',
            '{"path":"\u005a\u003a\u005c\u0069\u006e\u0074\u0065\u0072\u006e\u0061\u006c\u005c\u0062\u0075\u0069\u006c\u0064"}'
        )
        foreach ($text in $variants) {
            [IO.File]::WriteAllText((Join-Path $root 'inventory.json'), $text)
            Must-Fail { & (Get-Module TextureArrayPayload) { param($Root) Test-TextureArrayLocalPathLeak -Root $Root -Names @('inventory.json') -ForbiddenPathTokens @('Z:\internal\build') } $root }
        }
    }
    Check 'NonstandardJsonCannotBypassPrivacy' {
        $root = Join-Path $testRoot 'nonstandard-json'
        [void][IO.Directory]::CreateDirectory($root)
        [IO.File]::WriteAllText((Join-Path $root 'inventory.json'), '[{Name:''alpha'',ExtraDetails:''\u005a:\\internal\\build''}]')
        Must-Fail { & (Get-Module TextureArrayPayload) { param($Root) Test-TextureArrayLocalPathLeak -Root $Root -Names @('inventory.json') -ForbiddenPathTokens @('Z:\internal\build') } $root }
    }
    Check 'UnquotedJsonKeysAreRejected' {
        $root = Join-Path $testRoot 'unquoted-json'
        [void][IO.Directory]::CreateDirectory($root)
        [IO.File]::WriteAllText((Join-Path $root 'inventory.json'), '{Name:"alpha"}')
        Must-Fail { & (Get-Module TextureArrayPayload) { param($Root) Test-TextureArrayLocalPathLeak -Root $Root -Names @('inventory.json') -ForbiddenPathTokens @('Z:\internal\build') } $root }
    }
    Check 'GeneratedCargoNoticePrivacyIsMandatory' {
        $case = New-Case 'cargo-notice-private'
        [IO.File]::AppendAllText((Join-Path $case.Registry 'source/alpha-1.2.3/NOTICE.txt'), 'Z:\internal\build')
        Must-Fail { Stage-Case $case -Forbidden @('Z:\internal\build') }
    }
    Check 'EscapedExtraDependencyMetadataIsRejected' {
        $case = New-Case 'metadata-private'
        $path = Join-Path $case.Input 'RustWorker.ThirdPartyDependencies.json'
        $document = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        $document[0] | Add-Member -MemberType NoteProperty -Name ExtraDetails -Value ([PSCustomObject]@{ Values = @([PSCustomObject]@{ Path = 'Z:\internal\build' }) })
        [IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 8))
        Must-Fail { Stage-Case $case -Forbidden @('Z:\internal\build') }
    }
    Check 'StageHashTamperRejected' { $case = New-Case 'tamper'; $item = Stage-Case $case; [IO.File]::AppendAllText((Join-Path $case.Stage 'class.tpk'), 'changed'); Must-Fail { Test-TextureArrayPayloadDirectory -Root $case.Stage -ExpectedReport $item -VerifySignature $verify -Context $context } }
    Check 'DuplicateReportIdentityRejected' { $bad = $report | ConvertTo-Json -Depth 12 | ConvertFrom-Json; $bad.Files[1] = $bad.Files[0]; Must-Fail { Test-TextureArrayPayloadDirectory -Root $valid.Stage -ExpectedReport $bad -VerifySignature $verify -Context $context } }
    $zip = New-CaseZip $valid 'valid'
    Check 'FinalZipMatchesSignedStage' { Test-TextureArrayPayloadZip -ZipPath $zip -ExpectedReport $report }
    foreach ($entry in @('Tools~/TextureArrayLayoutTool/TextureArrayLayoutTool.exe', 'Tools~/TextureArrayLayoutTool/../outside.dll', 'Tools~/TextureArrayLayoutTool/nested/file.dll',
            'Tools~/./TextureArrayLayoutTool/png-repack-worker.exe', 'Tools~//TextureArrayLayoutTool/png-repack-worker.exe',
            'Tools~/TextureArrayLayoutTool./png-repack-worker.exe', 'Tools~ /TextureArrayLayoutTool/png-repack-worker.exe')) {
        Check ('BadZipEntryRejected-' + $results.Count) { $copy = Join-Path $valid.Root ('bad-' + $results.Count + '.zip'); Copy-Item -LiteralPath $zip -Destination $copy; Add-ZipEntry -Zip $copy -Name $entry; Must-Fail { Test-TextureArrayPayloadZip -ZipPath $copy -ExpectedReport $report } }
    }
    Check 'CaseAliasZipRejected' { $copy = Join-Path $valid.Root 'case-alias.zip'; Copy-Item -LiteralPath $zip -Destination $copy; Add-ZipEntry -Zip $copy -Name 'tools~/TextureArrayLayoutTool/AssetsTools.NET.Texture.dll'; Must-Fail { Test-TextureArrayPayloadZip -ZipPath $copy -ExpectedReport $report } }
    Check 'MainScriptSyntaxAndStageOrder' {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'BuildProtectedAvatarRecoveryPackage.ps1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count -ne 0) { throw 'Main build script has syntax errors.' }
        $source = [IO.File]::ReadAllText((Join-Path $repo 'BuildProtectedAvatarRecoveryPackage.ps1'))
        $stage = $source.LastIndexOf('$textureArrayPayloadReport = Invoke-TextureArrayPayloadBuildAndStage', [StringComparison]::Ordinal)
        $compile = $source.LastIndexOf('Initialize-CompileProject', [StringComparison]::Ordinal)
        $zipCheck = $source.LastIndexOf('Test-TextureArrayPayloadZip -ZipPath $zipPath', [StringComparison]::Ordinal)
        if ($stage -lt 0 -or $stage -ge $compile -or $zipCheck -le $compile) { throw 'Stage/compile/ZIP verification order is invalid.' }
    }
    Check 'MainWrapperReusesSignerAndProducesSourceStage' {
        $case = New-Case 'main-wrapper'
        $script:SourcePackageRoot = Join-Path $case.Root 'package'
        $target = Join-Path $script:SourcePackageRoot 'Tools~/TextureArrayLayoutTool'
        [void][IO.Directory]::CreateDirectory($target)
        foreach ($file in Get-ChildItem -LiteralPath $case.Input -File) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $target $file.Name) }
        $script:ReleaseRoot = $case.Root
        $script:ProtectionRoot = Join-Path $case.Root 'protection'
        $script:PrivateBackupRoot = Join-Path $case.Root 'private'
        $script:LocalPrivateBackupRoot = Join-Path $case.Root 'local-private'
        [void][IO.Directory]::CreateDirectory($script:PrivateBackupRoot)
        [void][IO.Directory]::CreateDirectory($script:LocalPrivateBackupRoot)
        $script:TextureArrayRustCargoLock = $case.Lock
        $script:TextureArrayRustRegistryRoot = $case.Registry
        $script:TextureArrayRustToolchainRoot = $case.Toolchain
        $script:RequireTextureArrayPayload = $true
        $script:TextureArrayPayloadModulePath = Join-Path $PSScriptRoot 'TextureArrayPayload.psm1'
        $script:RepoRoot = $repo
        $script:Version = '1.2.29'
        $script:SignatureCalls = [Collections.Generic.List[string]]::new()
        $script:SignatureReports = [Collections.Generic.List[string]]::new()
        function script:ConvertTo-FullPath { param([string]$Path) [IO.Path]::GetFullPath($Path) }
        function script:Invoke-CodeSign { param($Path, $Context) if ($Context.Mode -cne 'TestSignerSimulation') { throw 'Signer context changed.' }; [void]$script:SignatureCalls.Add($Path); & $sign $Path $Context }
        function script:Test-CodeSignature { param($Path, $Context) if ($Context.Mode -cne 'TestSignerSimulation') { throw 'Verifier context changed.' }; & $verify $Path $Context }
        function script:Save-CodeSignatureReport { param($Path, $ReportName, $Context) [void]$script:SignatureReports.Add($ReportName) }
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'BuildProtectedAvatarRecoveryPackage.ps1'), [ref]$tokens, [ref]$errors)
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-TextureArrayPayloadBuildAndStage' }, $true)
        Invoke-Expression ($function.Extent.Text.Replace('function Invoke-TextureArrayPayloadBuildAndStage', 'function script:Invoke-TextureArrayPayloadBuildAndStage'))
        $staged = Invoke-TextureArrayPayloadBuildAndStage -Context $context
        if (-not $staged.Enabled -or $script:SignatureCalls.Count -ne 11 -or $script:SignatureReports.Count -ne 11) { throw 'Main wrapper did not reuse the existing signing context.' }
        Test-TextureArrayPayloadDirectory -Root $target -ExpectedReport $staged -VerifySignature $verify -Context $context
        if (-not (Test-Path -LiteralPath (Join-Path $script:PrivateBackupRoot 'texture-array-payload-1.2.29.json'))) { throw 'Private stage report is absent.' }
    }
    Check 'LegacyPayloadDoesNotInvokeNewStage' {
        $script:SourcePackageRoot = Join-Path $testRoot 'legacy-package'
        $script:RequireTextureArrayPayload = $false
        $legacy = Invoke-TextureArrayPayloadBuildAndStage -Context $context
        if ($legacy.Enabled -or $legacy.Files.Count -ne 0) { throw 'Legacy payload behavior changed.' }
    }
    Check 'DeclaredRustCandidateCannotSkipBothMissingWorkers' {
        $case = New-Case 'declared-missing'
        $script:SourcePackageRoot = Join-Path $case.Root 'package'
        $target = Join-Path $script:SourcePackageRoot 'Tools~/TextureArrayLayoutTool'
        [void][IO.Directory]::CreateDirectory($target)
        foreach ($file in Get-ChildItem -LiteralPath $case.Input -File | Where-Object { $_.Name -cne 'png-repack-worker.exe' }) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $target $file.Name)
        }
        $script:RequireTextureArrayPayload = $true
        try { Must-Fail { Invoke-TextureArrayPayloadBuildAndStage -Context $context } }
        finally { $script:RequireTextureArrayPayload = $false }
    }
    Check 'CurrentEditorSourcePassesNarrowAllowlist' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'BuildProtectedAvatarRecoveryPackage.ps1'), [ref]$tokens, [ref]$errors)
        foreach ($variableName in @('UnityMagicMethods', 'ReflectionPatterns', 'AttributeContractPatterns')) {
            $assignment = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq $variableName }, $true)
            if ($null -eq $assignment) { throw 'Source-scan contract variable was not found.' }
            Invoke-Expression $assignment.Extent.Text
        }
        foreach ($functionName in @('ConvertTo-FullPath', 'Get-RelativePathForReport', 'New-SourceScanHit', 'Get-AllowlistSet', 'Assert-SourceScanAllowlist', 'Get-SourceScan')) {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName }, $true)
            if ($null -eq $definition) { throw 'Source-scan function was not found.' }
            Invoke-Expression $definition.Extent.Text
        }
        $scan = Get-SourceScan -SourceRoot (Join-Path $repo '.work/Minimal1230/Candidate/SourcePackage/com.nickel-jp.avatar-recovery/Editor')
        Assert-SourceScanAllowlist -Scan $scan -AllowlistPath (Join-Path $PSScriptRoot 'ReflectionSerializationAllowlist.txt')
    }
    Check 'RealCargoNoticesInventory' {
        $rust = Join-Path $repo '.work/Rust1228/RustWorker'
        $real = New-TextureArrayRustNotices -CargoLockPath (Join-Path $rust 'Cargo.lock') `
            -DependencyManifestPath (Join-Path $rust 'ThirdPartyDependencies.json') `
            -RegistryRoot (Join-Path $repo '.work/Rust1228/Toolchain/cargo/registry/src') -OutputPath (Join-Path $testRoot 'real-rust-notices.txt')
        if ($real.PackageCount -le 0 -or $real.LicenseFiles.Count -lt $real.PackageCount) { throw 'Real Cargo notices are incomplete.' }
    }
    Check 'RealStandardLibraryCopiedWithoutReduction' {
        $toolchain = Join-Path $repo '.work/Rust1228/Toolchain/rustup/toolchains/1.99.1-x86_64-pc-windows-msvc'
        $output = Join-Path $testRoot 'real-standard-library.html'
        $metadata = & (Get-Module TextureArrayPayload) {
            param($Root, $Output, $Forbidden)
            $record = Copy-TextureArrayRustStandardLibraryNotice -ToolchainRoot $Root -OutputPath $Output
            Test-TextureArrayLocalPathLeak -Root ([IO.Path]::GetDirectoryName($Output)) -Names @([IO.Path]::GetFileName($Output)) -ForbiddenPathTokens $Forbidden
            return $record
        } $toolchain $output @([Environment]::GetFolderPath('UserProfile'), $repo)
        $hash = (Get-FileHash -LiteralPath (Join-Path $toolchain 'share/doc/rust/COPYRIGHT-library.html') -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($metadata.SourceSHA256 -cne $hash -or (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash -or
            $metadata.ToolchainVersion -cne '1.99.1') { throw 'Real standard-library notice copy is incomplete.' }
    }
    $completed = $true
}
finally {
    $failed = @($results | Where-Object { -not $_.Passed }).Count
    $summary = [PSCustomObject]@{ Passed = $completed -and $failed -eq 0 -and $results.Count -ge 41; Completed = $completed; Checks = $results.Count; Failed = $failed;
        Signing = 'SimulationOnly'; RealAuthenticodeBuildExecuted = $false; Results = @($results.ToArray()) }
    [IO.File]::WriteAllText((Join-Path $testRoot 'results.json'), ($summary | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $summary | Select-Object Passed, Checks, Failed, Signing, RealAuthenticodeBuildExecuted | ConvertTo-Json -Compress
}
