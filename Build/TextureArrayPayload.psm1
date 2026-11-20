Set-StrictMode -Version Latest

function Get-TextureArrayPayloadContract {
    # 成果物の名前は固定し、作業ファイルや追加DLLを暗黙に配布しません。
    $names = @(
        'AssetRipper.TextureDecoder.dll', 'AssetRipper.TextureDecoder.LICENSE.txt',
        'AssetsTools.NET.dll', 'AssetsTools.NET.LICENSE.txt', 'AssetsTools.NET.Texture.dll',
        'class.tpk', 'Crunch.LICENSE.txt', 'crunchunity.dll',
        'png-repack-worker.exe', 'RuntimeDependencies.LICENSE.txt',
        'RustWorker.ThirdPartyDependencies.json', 'RustWorker.THIRD_PARTY_NOTICES.txt',
        'RustWorker.StandardLibrary.COPYRIGHT.html',
        'System.Buffers.dll', 'System.Half.dll', 'System.Memory.dll',
        'System.Numerics.Vectors.dll', 'System.Runtime.CompilerServices.Unsafe.dll',
        'TextureArrayLayoutTool.exe', 'TextureArrayLayoutTool.exe.config'
    )
    [PSCustomObject]@{
        PayloadNames = $names
        InputNames = @($names | Where-Object { $_ -cne 'RustWorker.THIRD_PARTY_NOTICES.txt' -and $_ -cne 'RustWorker.StandardLibrary.COPYRIGHT.html' })
        SignedNames = @($names | Where-Object { [IO.Path]::GetExtension($_) -in @('.exe', '.dll') })
        ManifestName = 'SHA256SUMS.txt'
        NoticesName = 'RustWorker.THIRD_PARTY_NOTICES.txt'
        StandardLibraryName = 'RustWorker.StandardLibrary.COPYRIGHT.html'
    }
}

function Assert-TextureArrayRegularPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Texture payload paths must not traverse reparse points.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Get-TextureArrayHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextureArrayFileRecords {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string[]]$Names)
    foreach ($name in $Names) {
        $path = Join-Path $Root $name
        Assert-TextureArrayRegularPath -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Texture payload file is missing: $name" }
        $item = Get-Item -LiteralPath $path
        if ($item.Length -le 0) { throw "Texture payload file is empty: $name" }
        [PSCustomObject]@{ Name = $name; Length = [long]$item.Length; SHA256 = Get-TextureArrayHash -Path $path }
    }
}

function Test-TextureArrayLocalPathLeak {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string[]]$Names,
        [string[]]$ForbiddenPathTokens = @())
    $tokens = @($ForbiddenPathTokens | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($tokens.Count -eq 0) { return }
    foreach ($name in $Names) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $Root $name))
        $views = @([Text.Encoding]::ASCII.GetString($bytes), [Text.Encoding]::UTF8.GetString($bytes), [Text.Encoding]::Unicode.GetString($bytes))
        if ($bytes.Length -gt 1) { $views += [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1) }
        if ([IO.Path]::GetExtension($name) -ieq '.json') {
            try {
                $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
                if ($json.Length -gt 0 -and $json[0] -eq [char]0xFEFF) { $json = $json.Substring(1) }
                # 単引用符・未引用キーを先に拒否し、下の全文字列検査を回避する解釈差をなくします。
                Add-Type -AssemblyName System.Runtime.Serialization -ErrorAction Stop
                $quotas = [Xml.XmlDictionaryReaderQuotas]::new()
                $quotas.MaxDepth = 64
                $quotas.MaxStringContentLength = 1048576
                $quotas.MaxArrayLength = 100000
                $strictReader = [Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader([Text.Encoding]::UTF8.GetBytes($json), $quotas)
                try { while ($strictReader.Read()) { } }
                finally { $strictReader.Dispose() }
                $null = ConvertFrom-Json -InputObject $json -ErrorAction Stop
                # 入れ子の値とキーをすべて復号します。重複キーで後の値に隠れた文字列も除外しません。
                foreach ($match in [regex]::Matches($json, '"(?:[^"\\]|\\.)*"')) {
                    $views += [string](ConvertFrom-Json -InputObject $match.Value -ErrorAction Stop)
                }
            }
            catch {
                # JSON本文や復号した個人情報を例外文へ転載しません。
                throw "Texture payload JSON cannot be privacy-validated: $name"
            }
        }
        foreach ($token in $tokens) {
            foreach ($variant in @($token, $token.Replace('\', '/'), $token.Replace('/', '\'))) {
                foreach ($view in $views) {
                    if ($view.IndexOf($variant, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        # 検出した個人パス自体をログへ書きません。
                        throw "Texture payload contains a local build path marker: $name"
                    }
                }
            }
        }
    }
}

function Assert-TextureArrayNames {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string[]]$Required,
        [string[]]$Optional = @())
    Assert-TextureArrayRegularPath -Path $Root
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'Texture payload directory is missing.' }
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @($Required) + @($Optional)) { [void]$allowed.Add($name) }
    $actual = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if ($item.PSIsContainer -or -not $allowed.Contains($item.Name)) {
            throw "Unexpected texture payload entry: $($item.Name)"
        }
        Assert-TextureArrayRegularPath -Path $item.FullName
        [void]$actual.Add($item.Name)
    }
    foreach ($name in $Required) {
        if (-not $actual.Contains($name)) { throw "Texture payload file is missing: $name" }
    }
}

function New-TextureArrayRustNotices {
    param(
        [Parameter(Mandatory = $true)][string]$CargoLockPath,
        [Parameter(Mandatory = $true)][string]$DependencyManifestPath,
        [Parameter(Mandatory = $true)][string]$RegistryRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    foreach ($path in @($CargoLockPath, $DependencyManifestPath, $RegistryRoot, $OutputPath)) {
        Assert-TextureArrayRegularPath -Path $path
    }
    if (Test-Path -LiteralPath $OutputPath) { throw 'Existing Rust notices must not be overwritten.' }
    $lockText = [IO.File]::ReadAllText([IO.Path]::GetFullPath($CargoLockPath))
    $locked = @{}
    foreach ($block in [regex]::Split($lockText, '(?m)^\[\[package\]\]\s*$')) {
        if ($block -notmatch '(?m)^source = ') { continue }
        if ($block -notmatch '(?m)^source = "registry\+https://github.com/rust-lang/crates.io-index"\s*$') {
            throw 'Rust notices require an explicitly supported Cargo registry source.'
        }
        $nameMatch = [regex]::Match($block, '(?m)^name = "(?<value>[A-Za-z0-9_-]+)"\s*$')
        $versionMatch = [regex]::Match($block, '(?m)^version = "(?<value>[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+-]*)"\s*$')
        if (-not $nameMatch.Success -or -not $versionMatch.Success) { throw 'Cargo.lock contains an invalid package identity.' }
        $key = $nameMatch.Groups['value'].Value + '@' + $versionMatch.Groups['value'].Value
        if ($locked.ContainsKey($key)) { throw 'Cargo.lock contains a duplicate package identity.' }
        $locked[$key] = $true
    }
    # Windows PowerShell 5.1のConvertFrom-Jsonは配列を一つの出力として返すため、代入後に正規化します。
    $dependencyText = [IO.File]::ReadAllText([IO.Path]::GetFullPath($DependencyManifestPath))
    if (-not $dependencyText.TrimStart().StartsWith('[')) { throw 'Rust dependency inventory must be a JSON array.' }
    $dependencyDocument = $dependencyText | ConvertFrom-Json
    $dependencies = @($dependencyDocument)
    if ($locked.Count -eq 0 -or $locked.Count -ne $dependencies.Count) { throw 'Rust dependency inventory does not match Cargo.lock.' }
    $seen = @{}
    $parts = [Collections.Generic.List[string]]::new()
    $records = [Collections.Generic.List[object]]::new()
    [void]$parts.Add('AvatarRecovery PNG worker: third-party license and copyright notices')
    foreach ($dependency in @($dependencies | Sort-Object Name, Version)) {
        $name = [string]$dependency.Name
        $version = [string]$dependency.Version
        $key = $name + '@' + $version
        if ($name -notmatch '^[A-Za-z0-9_-]+$' -or $version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+-]*$' -or
            -not $locked.ContainsKey($key) -or $seen.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$dependency.License)) {
            throw 'Rust dependency inventory has an unpinned or duplicate package.'
        }
        $seen[$key] = $true
        $directories = @(Get-ChildItem -LiteralPath $RegistryRoot -Directory -Force | ForEach-Object {
            $candidate = Join-Path $_.FullName ($name + '-' + $version)
            if (Test-Path -LiteralPath $candidate -PathType Container) { Get-Item -LiteralPath $candidate -Force }
        })
        if ($directories.Count -ne 1) { throw "Expected exactly one local crate source: $key" }
        Assert-TextureArrayRegularPath -Path $directories[0].FullName
        $licenses = @(Get-ChildItem -LiteralPath $directories[0].FullName -File -Force | Where-Object {
            $_.Name -match '^(?i:LICEN[CS]E|NOTICE|COPYING|COPYRIGHT)(?:$|[._-])'
        } | Sort-Object Name)
        if ($licenses.Count -eq 0) { throw "Crate license text is missing: $key" }
        [void]$parts.Add("`n===== $key =====`nSPDX: $($dependency.License)`nRepository: $($dependency.Repository)")
        foreach ($license in $licenses) {
            Assert-TextureArrayRegularPath -Path $license.FullName
            $text = [IO.File]::ReadAllText($license.FullName, [Text.UTF8Encoding]::new($false, $true))
            if ([string]::IsNullOrWhiteSpace($text) -or $text.Contains([char]0)) { throw "Crate license text is invalid: $key" }
            [void]$parts.Add("`n--- $($license.Name) ---`n" + $text.TrimEnd())
            [void]$records.Add([PSCustomObject]@{ Package = $key; Name = $license.Name; SHA256 = Get-TextureArrayHash -Path $license.FullName })
        }
    }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath))
    [void][IO.Directory]::CreateDirectory($parent)
    $noticeStream = [IO.FileStream]::new([IO.Path]::GetFullPath($OutputPath), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $writer = [IO.StreamWriter]::new($noticeStream, [Text.UTF8Encoding]::new($false))
        try { $writer.Write(($parts -join "`n") + "`n") } finally { $writer.Dispose() }
    }
    finally { $noticeStream.Dispose() }
    [PSCustomObject]@{ PackageCount = $dependencies.Count; CargoLockSHA256 = Get-TextureArrayHash -Path $CargoLockPath; LicenseFiles = @($records.ToArray()) }
}

function Test-TextureArrayPayloadManifest {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][object[]]$Files)
    $contract = Get-TextureArrayPayloadContract
    $entries = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($line in Get-Content -LiteralPath (Join-Path $Root $contract.ManifestName) -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        $match = [regex]::Match($line, '^(?<hash>[0-9a-f]{64})  (?<name>[^\\/]+)$')
        if (-not $match.Success -or $entries.ContainsKey($match.Groups['name'].Value)) { throw 'Texture payload manifest is invalid or duplicated.' }
        $entries[$match.Groups['name'].Value] = $match.Groups['hash'].Value
    }
    $payload = @($Files | Where-Object { $_.Name -cne $contract.ManifestName })
    if ($entries.Count -ne $payload.Count) { throw 'Texture payload manifest count does not match.' }
    foreach ($file in $payload) {
        if (-not $entries.ContainsKey($file.Name) -or $entries[$file.Name] -cne $file.SHA256) { throw "Texture payload manifest mismatch: $($file.Name)" }
    }
}

function Copy-TextureArrayRustStandardLibraryNotice {
    param([Parameter(Mandatory = $true)][string]$ToolchainRoot, [Parameter(Mandatory = $true)][string]$OutputPath)
    $manifest = Join-Path $ToolchainRoot 'lib/rustlib/multirust-channel-manifest.toml'
    $source = Join-Path $ToolchainRoot 'share/doc/rust/COPYRIGHT-library.html'
    foreach ($path in @($ToolchainRoot, $manifest, $source, $OutputPath)) { Assert-TextureArrayRegularPath -Path $path }
    $text = [IO.File]::ReadAllText([IO.Path]::GetFullPath($manifest))
    $section = [regex]::Match($text, '(?ms)^\[pkg\.rust\]\r?\n(?<body>.*?)(?=^\[|\z)')
    if (-not $section.Success -or $section.Groups['body'].Value -notmatch '(?m)^version = "1\.99\.1(?: \([^"\r\n]*\))?"\s*$') {
        throw 'Standard-library notices require the pinned Rust 1.99.1 toolchain.'
    }
    $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($source))
    $html = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if (-not $html.Contains('Copyright notices for The Rust Standard Library')) { throw 'Rust standard-library notices are not the full expected document.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $sourceHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $stream = [IO.FileStream]::new([IO.Path]::GetFullPath($OutputPath), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    if ((Get-TextureArrayHash -Path $OutputPath) -cne $sourceHash -or (Get-TextureArrayHash -Path $source) -cne $sourceHash) {
        throw 'Rust standard-library notice copy changed its bytes.'
    }
    [PSCustomObject]@{ ToolchainVersion = '1.99.1'; SourceFile = 'share/doc/rust/COPYRIGHT-library.html';
        SourceSHA256 = $sourceHash; SourceLength = [long]$bytes.Length; ToolchainManifestSHA256 = Get-TextureArrayHash -Path $manifest }
}

function Assert-TextureArrayPayloadReport {
    param([Parameter(Mandatory = $true)]$Report)
    $contract = Get-TextureArrayPayloadContract
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @($contract.PayloadNames + $contract.ManifestName)) { [void]$expected.Add($name) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in @($Report.Files)) {
        if (-not $expected.Contains([string]$file.Name) -or -not $seen.Add([string]$file.Name) -or
            [long]$file.Length -le 0 -or [string]$file.SHA256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Texture payload report has an invalid identity, length or hash.'
        }
    }
    if ($seen.Count -ne $expected.Count) { throw 'Texture payload report does not cover the fixed file contract.' }
}

function Test-TextureArrayPayloadDirectory {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$ExpectedReport,
        [Parameter(Mandatory = $true)][scriptblock]$VerifySignature, [Parameter(Mandatory = $true)]$Context)
    $contract = Get-TextureArrayPayloadContract
    Assert-TextureArrayPayloadReport -Report $ExpectedReport
    Assert-TextureArrayNames -Root $Root -Required @($contract.PayloadNames + $contract.ManifestName)
    $expected = @($ExpectedReport.Files)
    if ($expected.Count -ne $contract.PayloadNames.Count + 1) { throw 'Texture payload report count does not match the fixed contract.' }
    foreach ($file in $expected) {
        $path = Join-Path $Root $file.Name
        if ([long](Get-Item -LiteralPath $path).Length -ne [long]$file.Length -or (Get-TextureArrayHash -Path $path) -cne $file.SHA256) {
            throw "Texture payload length or hash mismatch: $($file.Name)"
        }
        if ($contract.SignedNames -ccontains $file.Name) { & $VerifySignature $path $Context | Out-Null }
    }
    Test-TextureArrayPayloadManifest -Root $Root -Files $expected
}

function New-TextureArrayPayloadStage {
    param([Parameter(Mandatory = $true)][string]$InputRoot, [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$CargoLockPath, [Parameter(Mandatory = $true)][string]$RegistryRoot,
        [Parameter(Mandatory = $true)][string]$RustToolchainRoot,
        [Parameter(Mandatory = $true)][scriptblock]$SignFile, [Parameter(Mandatory = $true)][scriptblock]$VerifySignature,
        [Parameter(Mandatory = $true)]$Context, [string[]]$ForbiddenPathTokens = @())
    if (-not $Context.Required) { throw 'Rust texture payload requires signed artifacts.' }
    $contract = Get-TextureArrayPayloadContract
    Assert-TextureArrayNames -Root $InputRoot -Required $contract.InputNames -Optional @($contract.NoticesName, $contract.StandardLibraryName, $contract.ManifestName)
    Assert-TextureArrayRegularPath -Path $StageRoot
    if (Test-Path -LiteralPath $StageRoot) { throw 'Existing texture stage directory must not be overwritten.' }
    $before = @(Get-TextureArrayFileRecords -Root $InputRoot -Names $contract.InputNames)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($StageRoot))
    foreach ($file in $before) { [IO.File]::Copy((Join-Path $InputRoot $file.Name), (Join-Path $StageRoot $file.Name), $false) }
    $notices = New-TextureArrayRustNotices -CargoLockPath $CargoLockPath `
        -DependencyManifestPath (Join-Path $StageRoot 'RustWorker.ThirdPartyDependencies.json') `
        -RegistryRoot $RegistryRoot -OutputPath (Join-Path $StageRoot $contract.NoticesName)
    $standardLibrary = Copy-TextureArrayRustStandardLibraryNotice -ToolchainRoot $RustToolchainRoot `
        -OutputPath (Join-Path $StageRoot $contract.StandardLibraryName)
    $notices | Add-Member -MemberType NoteProperty -Name StandardLibrary -Value $standardLibrary
    foreach ($file in $before) {
        if ((Get-TextureArrayHash -Path (Join-Path $StageRoot $file.Name)) -cne $file.SHA256) { throw 'Texture input changed while copying.' }
    }
    Test-TextureArrayLocalPathLeak -Root $StageRoot -Names $contract.PayloadNames -ForbiddenPathTokens $ForbiddenPathTokens
    $unsignedPayload = @(Get-TextureArrayFileRecords -Root $StageRoot -Names $contract.PayloadNames)
    foreach ($name in $contract.SignedNames) {
        $path = Join-Path $StageRoot $name
        & $SignFile $path $Context | Out-Null
        & $VerifySignature $path $Context | Out-Null
    }
    Test-TextureArrayLocalPathLeak -Root $StageRoot -Names $contract.PayloadNames -ForbiddenPathTokens $ForbiddenPathTokens
    foreach ($file in $unsignedPayload) {
        if ($contract.SignedNames -cnotcontains $file.Name -and
            (Get-TextureArrayHash -Path (Join-Path $StageRoot $file.Name)) -cne $file.SHA256) {
            throw "Unsigned texture data changed during signing: $($file.Name)"
        }
    }
    # 署名中に入力ビルドが差し替わった場合も、その候補を採用しません。
    foreach ($file in $before) {
        if ((Get-TextureArrayHash -Path (Join-Path $InputRoot $file.Name)) -cne $file.SHA256) { throw 'Texture input changed during signing.' }
    }
    $payload = @(Get-TextureArrayFileRecords -Root $StageRoot -Names $contract.PayloadNames)
    $lines = @('# AvatarRecovery TextureArrayLayoutTool and Rust worker payload SHA-256')
    $lines += '# Rust standard-library toolchain: ' + $standardLibrary.ToolchainVersion
    $lines += '# Rust standard-library source: ' + $standardLibrary.SourceFile
    $lines += '# Rust standard-library source SHA-256: ' + $standardLibrary.SourceSHA256
    $lines += '# Rust toolchain manifest SHA-256: ' + $standardLibrary.ToolchainManifestSHA256
    $lines += @($payload | Sort-Object Name | ForEach-Object { $_.SHA256 + '  ' + $_.Name })
    $manifestStream = [IO.FileStream]::new((Join-Path $StageRoot $contract.ManifestName), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $writer = [IO.StreamWriter]::new($manifestStream, [Text.UTF8Encoding]::new($false))
        try { $writer.Write(($lines -join "`n") + "`n") } finally { $writer.Dispose() }
    }
    finally { $manifestStream.Dispose() }
    Test-TextureArrayLocalPathLeak -Root $StageRoot -Names @($contract.PayloadNames + $contract.ManifestName) -ForbiddenPathTokens $ForbiddenPathTokens
    $report = [PSCustomObject]@{ Enabled = $true; Schema = 1; StageRoot = [IO.Path]::GetFullPath($StageRoot);
        InputFiles = $before; UnsignedPayloadFiles = $unsignedPayload; Files = @(Get-TextureArrayFileRecords -Root $StageRoot -Names @($contract.PayloadNames + $contract.ManifestName));
        SignedFileNames = @($contract.SignedNames); RustNotices = $notices }
    Test-TextureArrayPayloadDirectory -Root $StageRoot -ExpectedReport $report -VerifySignature $VerifySignature -Context $Context
    return $report
}

function Test-TextureArrayPayloadZip {
    param([Parameter(Mandatory = $true)][string]$ZipPath, [Parameter(Mandatory = $true)]$ExpectedReport)
    if (-not $ExpectedReport.Enabled) { return }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ZipPath))
    try {
        $prefix = 'Tools~/TextureArrayLayoutTool/'
        Assert-TextureArrayPayloadReport -Report $ExpectedReport
        $entries = [Collections.Generic.Dictionary[string, IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
        foreach ($entry in $archive.Entries) {
            # namespace判定より先に、展開時に別名へ正規化される経路を拒否します。
            $raw = $entry.FullName
            if ([string]::IsNullOrEmpty($raw) -or $raw.Contains('\') -or $raw.Contains(':')) {
                throw 'ZIP entry has a noncanonical separator or rooted path.'
            }
            $segments = $raw.Split([char]'/')
            for ($index = 0; $index -lt $segments.Length; $index++) {
                $segment = $segments[$index]
                $isDirectoryTerminator = $index -eq ($segments.Length - 1) -and $segment.Length -eq 0 -and $entry.Length -eq 0
                if ($isDirectoryTerminator) { continue }
                if ($segment.Length -eq 0 -or $segment -in @('.', '..') -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
                    throw 'ZIP entry contains a noncanonical path segment.'
                }
            }
            $name = $entry.FullName.Replace('\', '/')
            if (-not $name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($name -ceq $prefix -and [string]::IsNullOrEmpty($entry.Name)) { continue }
            if (-not $entry.FullName.StartsWith($prefix, [StringComparison]::Ordinal) -or $entry.FullName.Contains('\')) {
                throw 'Texture ZIP entry has a noncanonical name.'
            }
            $leaf = $name.Substring($prefix.Length)
            if ([string]::IsNullOrEmpty($leaf) -or $leaf.Contains('/') -or $entries.ContainsKey($leaf)) { throw 'Texture ZIP entry is nested or duplicated.' }
            $entries[$leaf] = $entry
        }
        if ($entries.Count -ne @($ExpectedReport.Files).Count) { throw 'Texture ZIP payload count does not match.' }
        foreach ($file in $ExpectedReport.Files) {
            if (-not $entries.ContainsKey($file.Name)) { throw "Texture ZIP payload is missing: $($file.Name)" }
            $entry = $entries[$file.Name]
            if ([long]$entry.Length -ne [long]$file.Length) { throw "Texture ZIP payload length mismatch: $($file.Name)" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose(); $stream.Dispose() }
            if ($hash -cne $file.SHA256) { throw "Texture ZIP payload hash mismatch: $($file.Name)" }
        }
    }
    finally { $archive.Dispose() }
}

Export-ModuleMember -Function Get-TextureArrayPayloadContract, New-TextureArrayRustNotices, New-TextureArrayPayloadStage, Test-TextureArrayPayloadDirectory, Test-TextureArrayPayloadZip
