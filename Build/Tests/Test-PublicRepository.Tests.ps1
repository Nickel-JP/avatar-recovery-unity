param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$checkScript = Join-Path $repoRoot 'Build/Test-PublicRepository.ps1'
$workParent = Join-Path $repoRoot '.work/PublicRepositoryTests'
$runRoot = Join-Path $workParent ([Guid]::NewGuid().ToString('N'))
$packageId = 'com.nickel-jp.avatar-recovery'
$baseUrl = 'https://nickel-jp.github.io/avatar-recovery-unity'
$passed = 0
$failed = 0

function Write-Text {
    param([string]$Path, [string]$Value)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Read-Json {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Write-Json {
    param([string]$Path, $Value)
    Write-Text $Path ($Value | ConvertTo-Json -Depth 30)
}

function Write-ManifestZip {
    param([string]$Path, $Manifest, [string]$AdditionalEntry = '')
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $names = @('package.json')
        if ($AdditionalEntry) { $names += $AdditionalEntry }
        foreach ($name in $names) {
            $writer = [IO.StreamWriter]::new($archive.CreateEntry($name).Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write(($Manifest | ConvertTo-Json -Depth 30)) }
            finally { $writer.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function Update-FixturePayload {
    param([string]$Root, [scriptblock]$Mutation = {})
    $index = Read-Json (Join-Path $Root 'index.json')
    $payload = [PSCustomObject]@{
        format = 'AvatarRecovery update notification payload v1'
        packageId = $packageId
        latestStableVersion = '1.2.21'
        sourceIndexSha256 = (Get-FileHash -LiteralPath (Join-Path $Root 'index.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        packageSha256 = $index.packages.$packageId.versions.'1.2.21'.zipSHA256
    }
    & $Mutation $payload
    # fixtureでは署名を生成しない。暗号検証はCIの別手順で行う。
    $envelope = @{
        format = 'AvatarRecovery update manifest envelope v1'
        payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)))
    }
    Write-Json (Join-Path $Root 'update-manifest.json') $envelope
}

function New-Fixture {
    param([string]$Root)
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'packages'))
    Write-Text (Join-Path $Root 'README.md') "# Fixture`n### Version 1.2.21 — Fixture`n### Version 1.2.20 — History`n"
    Write-Text (Join-Path $Root '.github/workflows/verify-build.yml') "env:`n  VERSION: 1.2.21`n"
    $versions = [ordered]@{}
    foreach ($version in @('1.2.21', '1.2.20', '1.2.19')) {
        $manifest = [ordered]@{
            name = $packageId
            version = $version
            unity = '2022.3'
            vpmDependencies = @{ 'com.vrchat.base' = '>=3.7.0 <3.11.0' }
            url = "$baseUrl/packages/$packageId-$version.zip"
            repo = "$baseUrl/index.json"
        }
        $zipPath = Join-Path $Root "packages/$packageId-$version.zip"
        Write-ManifestZip $zipPath $manifest
        $manifest.zipSHA256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $versions[$version] = $manifest
    }
    Write-Json (Join-Path $Root 'index.json') @{ packages = @{ $packageId = @{ versions = $versions } } }
    Update-FixturePayload $Root
}

function Change-Package {
    param([string]$Root, [scriptblock]$Mutation = {}, [string]$AdditionalEntry = '', [string]$Version = '1.2.21')
    $indexPath = Join-Path $Root 'index.json'
    $index = Read-Json $indexPath
    $manifest = $index.packages.$packageId.versions.$Version | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $manifest.PSObject.Properties.Remove('zipSHA256')
    & $Mutation $manifest
    $zipPath = Join-Path $Root "packages/$packageId-$Version.zip"
    Remove-Item -LiteralPath $zipPath
    Write-ManifestZip $zipPath $manifest $AdditionalEntry
    $index.packages.$packageId.versions.$Version.zipSHA256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Json $indexPath $index
    Update-FixturePayload $Root
}

function Invoke-Case {
    param([string]$Name, [string]$ExpectedCode, [scriptblock]$Mutation = {})
    $fixtureRoot = Join-Path $runRoot ($script:passed + $script:failed).ToString('00')
    New-Fixture $fixtureRoot
    & $Mutation $fixtureRoot
    $message = ''
    try {
        $result = & $checkScript -RepoRoot $fixtureRoot
        if ($result.Result -cne 'Passed' -or $result.IndexedVersions.Count -ne 3) {
            throw 'TEST_RESULT: 成功時の結果が不正です。'
        }
    }
    catch { $message = $_.Exception.Message }
    if (($ExpectedCode -eq '' -and $message -eq '') -or
        ($ExpectedCode -ne '' -and $message.StartsWith($ExpectedCode + ':', [StringComparison]::Ordinal))) {
        $script:passed++
        Write-Host "PASS $Name"
    }
    else {
        $script:failed++
        Write-Host "FAIL $Name (expected=$ExpectedCode, actual=$message)"
    }
}

try {
    Invoke-Case '整合した公開データ' ''
    Invoke-Case '古いREADME' 'README_VERSION' {
        param($root)
        Write-Text (Join-Path $root 'README.md') '### Version 1.2.20'
    }
    Invoke-Case '旧形式の最新見出し' 'README_HEADING' {
        param($root)
        Write-Text (Join-Path $root 'README.md') "### Current Public Version — 1.2.21`n### Version 1.2.21"
    }
    Invoke-Case '先頭の不正なVersion見出し' 'README_VERSION' {
        param($root)
        Write-Text (Join-Path $root 'README.md') "### Version upcoming`n### Version 1.2.21"
    }
    Invoke-Case '先頭が先行公開版の見出し' 'README_VERSION' {
        param($root)
        Write-Text (Join-Path $root 'README.md') "### Version 1.2.21-preview`n### Version 1.2.21"
    }
    Invoke-Case '古いCI版番号' 'CI_VERSION' {
        param($root)
        Write-Text (Join-Path $root '.github/workflows/verify-build.yml') "env:`n  VERSION: 1.2.20`n"
    }
    Invoke-Case '古い更新通知' 'UPDATE_VERSION' {
        param($root)
        Update-FixturePayload $root { param($payload) $payload.latestStableVersion = '1.2.12' }
    }
    Invoke-Case 'indexのハッシュ不一致' 'UPDATE_INDEX_HASH' {
        param($root)
        Update-FixturePayload $root { param($payload) $payload.sourceIndexSha256 = '0' * 64 }
    }
    Invoke-Case '更新通知のZIPハッシュ不一致' 'UPDATE_PACKAGE_HASH' {
        param($root)
        Update-FixturePayload $root { param($payload) $payload.packageSha256 = '0' * 64 }
    }
    Invoke-Case '撤回版ZIP再混入' 'WITHDRAWN_PACKAGE' {
        param($root)
        Write-Text (Join-Path $root "packages/$packageId-1.3.0.zip") 'withdrawn'
    }
    Invoke-Case '撤回版署名再混入' 'WITHDRAWN_PACKAGE' {
        param($root)
        Write-Text (Join-Path $root "packages/$packageId-1.3.6.zip.sig") 'withdrawn'
    }
    Invoke-Case '公開ZIP欠落' 'MISSING_FILE' {
        param($root)
        Remove-Item -LiteralPath (Join-Path $root "packages/$packageId-1.2.20.zip")
    }
    Invoke-Case '公開ZIP改変' 'ZIP_HASH' {
        param($root)
        Write-Text (Join-Path $root "packages/$packageId-1.2.21.zip") 'changed'
    }
    Invoke-Case 'ZIP内版番号不一致' 'ZIP_IDENTITY' {
        param($root)
        Change-Package $root { param($manifest) $manifest.version = '1.2.12' }
    }
    Invoke-Case 'ZIP内manifest二重定義' 'ZIP_DUPLICATE' {
        param($root)
        Change-Package $root -AdditionalEntry 'package.json'
    }
    Invoke-Case 'ZIP内manifest大文字衝突' 'ZIP_DUPLICATE' {
        param($root)
        Change-Package $root -AdditionalEntry 'PACKAGE.JSON'
    }
    Invoke-Case 'ZIP内パス逸脱' 'ZIP_PATH' {
        param($root)
        Change-Package $root -AdditionalEntry '../package.json'
    }
    Invoke-Case 'ZIP内バックスラッシュ' 'ZIP_PATH' {
        param($root)
        Change-Package $root -AdditionalEntry 'folder\package.json'
    }
    Invoke-Case 'ZIP内互換性宣言不一致' 'ZIP_MANIFEST' {
        param($root)
        Change-Package $root { param($manifest) $manifest.unity = '6000.0' }
    }
    Invoke-Case 'index版番号によるパス逸脱' 'INVALID_VERSION' {
        param($root)
        $path = Join-Path $root 'index.json'
        $index = Read-Json $path
        $index.packages.$packageId.versions | Add-Member -NotePropertyName '../1.2.21' -NotePropertyValue $index.packages.$packageId.versions.'1.2.21'
        $index.packages.$packageId.versions.PSObject.Properties.Remove('1.2.21')
        Write-Json $path $index
    }
    Invoke-Case '外部ZIPへのURL変更' 'INDEX_URL' {
        param($root)
        $path = Join-Path $root 'index.json'
        $index = Read-Json $path
        $index.packages.$packageId.versions.'1.2.21'.url = 'https://example.invalid/package.zip'
        Write-Json $path $index
    }
    Invoke-Case '旧版ZIPの公開時URL保持' '' {
        param($root)
        Change-Package $root -Version '1.2.20' -Mutation {
            param($manifest)
            $manifest.url = "https://raw.githubusercontent.com/Nickel-JP/avatar-recovery-unity/main/packages/$packageId-1.2.20.zip"
            $manifest.repo = 'https://raw.githubusercontent.com/Nickel-JP/avatar-recovery-unity/main/index.json'
        }
    }
    Invoke-Case '配布総量上限超過' 'DISTRIBUTION_SIZE' {
        param($root)
        $stream = [IO.File]::OpenWrite((Join-Path $root 'packages/size-fixture.zip'))
        try { $stream.SetLength(800000001L) }
        finally { $stream.Dispose() }
    }
    Write-Host "Public repository checks: $passed passed, $failed failed."
    if ($failed -gt 0) { throw "公開リポジトリの回帰テストが $failed 件失敗しました。" }
}
finally {
    # この実行で作成したfixtureだけを削除する。
    $fullRunRoot = [IO.Path]::GetFullPath($runRoot)
    $fullParent = [IO.Path]::GetFullPath($workParent).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullRunRoot.StartsWith($fullParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'テスト出力が作業ディレクトリ外のため削除を中止しました。'
    }
    if (Test-Path -LiteralPath $fullRunRoot) { Remove-Item -LiteralPath $fullRunRoot -Recurse -Force }
}
