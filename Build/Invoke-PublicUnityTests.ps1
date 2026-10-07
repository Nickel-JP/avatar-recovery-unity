#requires -Version 7.2
param(
    [string]$ProjectPath = 'G:\UnityTest\AvatarRecovery-1.2.21-PublicValidation',
    [string]$UnityPath = 'C:\Program Files\Unity\Hub\Editor\2022.3.22f1\Editor\Unity.exe',
    [string]$ResultsPath = '',
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$unityVersion = '2022.3.22f1'
$packageVersion = '1.2.21'
$packageId = 'com.nickel-jp.avatar-recovery'
$packageSha256 = '574499ca36f5608e7dfff82735883741911669fc148cd60bb503c4b7b9aa8f1b'
$assemblySha256 = '4f650465f851f00172d373a06dbA6fb9985b9d49b00b5abd7ec15ffd34bdffac'.ToLowerInvariant()
$allowedRoot = [IO.Path]::GetFullPath('G:\UnityTest')
$projectRoot = [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\')
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$cacheRoot = Join-Path $repoRoot '.work\PublicUnityDependencyCache'
if ([string]::IsNullOrWhiteSpace($ResultsPath)) {
    $ResultsPath = Join-Path $repoRoot ".work\PublicUnityTests\$runId"
}
$resultRoot = [IO.Path]::GetFullPath($ResultsPath)
$markerPath = Join-Path $projectRoot '.avatar-recovery-public-tests.json'

function Write-JsonFile {
    param([string]$Path, $Value)
    Assert-NoReparsePoint -Path $Path
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12) + "`n", [Text.UTF8Encoding]::new($false))
}

function Assert-Hash {
    param([string]$Path, [string]$Expected)
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Expected) {
        throw "SHA-256 mismatch: $([IO.Path]::GetFileName($Path))"
    }
}

function Assert-NoReparsePoint {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and
            ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Junctions and symbolic links are not supported for generated test data.'
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Expand-VerifiedArchive {
    param([string]$ZipPath, [string]$Destination)
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $relative = $entry.FullName.Replace('/', '\')
            $target = [IO.Path]::GetFullPath((Join-Path $destinationRoot $relative))
            if ($relative.Contains(':') -or [IO.Path]::IsPathRooted($relative) -or
                -not $target.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase) -or
                -not $seen.Add($target) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'The dependency archive contains an unsafe or duplicate path.'
            }
            Assert-NoReparsePoint -Path $target
        }
        foreach ($entry in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $destinationRoot $entry.FullName.Replace('/', '\')))
            if ($entry.FullName.EndsWith('/')) {
                [void][IO.Directory]::CreateDirectory($target)
            } else {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        }
    } finally { $archive.Dispose() }
}

function Save-PublicText {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) { return }
    $stream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream)
    try { $value = $reader.ReadToEnd() } finally { $reader.Dispose() }
    foreach ($path in @($projectRoot, $repoRoot, [Environment]::GetFolderPath('UserProfile'))) {
        if ($path) {
            $value = $value.Replace($path, '[local-path]').Replace($path.Replace('\', '/'), '[local-path]')
        }
    }
    # 認証識別子を公開ログへ転記せず、エラー本文と実行結果は残します。
    $value = [regex]::Replace($value, '(?im)^.*(?:Machine Id:|Session Id:|Correlation Id:|External correlation Id:|Serial number assigned to:).*(\r?\n|$)', '')
    $value = $value.Replace("`r`n", "`n").Replace("`r", "`n")
    Assert-NoReparsePoint -Path $Destination
    [IO.File]::WriteAllText($Destination, $value, [Text.UTF8Encoding]::new($false))
}

function Assert-ProjectNotOpen {
    $busy = @(Get-CimInstance Win32_Process -Filter "Name = 'Unity.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine.Replace('/', '\').IndexOf($projectRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    if ($busy.Count -gt 0) { throw 'The test project is already open in Unity.' }
}

if (-not $IsWindows) { throw 'These package tests require Windows.' }
if (-not $projectRoot.StartsWith(($allowedRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The generated Unity project must be a child of G:\UnityTest.'
}
Assert-NoReparsePoint -Path $projectRoot
Assert-NoReparsePoint -Path $resultRoot
Assert-NoReparsePoint -Path $cacheRoot
if (-not (Test-Path -LiteralPath $UnityPath -PathType Leaf) -or
    -not (Get-Item -LiteralPath $UnityPath).VersionInfo.ProductVersion.StartsWith($unityVersion, [StringComparison]::Ordinal)) {
    throw "Unity $unityVersion is required."
}
$lockPath = $projectRoot + '.public-tests.lock'
Assert-NoReparsePoint -Path $lockPath
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($lockPath))
# 準備中も含め、同じプロジェクトを使う別実行を拒否します。
$projectLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
Assert-ProjectNotOpen
if (Test-Path -LiteralPath $projectRoot) {
    if (-not (Test-Path -LiteralPath $markerPath)) { throw 'Refusing to overwrite a project not created by this script.' }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ($marker.format -ne 'AvatarRecovery public test project v1' -or $marker.version -ne $packageVersion) {
        throw 'The existing test project has an incompatible marker.'
    }
} else { [void][IO.Directory]::CreateDirectory($projectRoot) }
foreach ($relative in @('Assets','Packages','ProjectSettings')) {
    $existingTree = Join-Path $projectRoot $relative
    Assert-NoReparsePoint -Path $existingTree
    if (Test-Path -LiteralPath $existingTree) {
        $links = @(Get-ChildItem -LiteralPath $existingTree -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($links.Count -gt 0) { throw 'The managed project contains a junction or symbolic link.' }
    }
}
foreach ($path in @($cacheRoot, $resultRoot, (Join-Path $projectRoot 'Assets'), (Join-Path $projectRoot 'Packages'), (Join-Path $projectRoot 'ProjectSettings'))) {
    [void][IO.Directory]::CreateDirectory($path)
}
Write-JsonFile -Path $markerPath -Value @{format='AvatarRecovery public test project v1';version=$packageVersion}

$dependencies = @(
    @{id='com.vrchat.base';version='3.10.5';url='https://github.com/vrchat/packages/releases/download/3.10.5/com.vrchat.base-3.10.5.zip';sha256='fbfb3e7a38778dcb55d7a860286819e6f0726d10d5039f61474bd1b9c629029e'},
    @{id='com.vrchat.avatars';version='3.10.5';url='https://github.com/vrchat/packages/releases/download/3.10.5/com.vrchat.avatars-3.10.5.zip';sha256='03bdea0c24257070f0e7a73c9033742a1ce0f67463b12a6c2ad29608b1f33a77'}
)
foreach ($dependency in $dependencies) {
    $zipPath = Join-Path $cacheRoot ($dependency.id + '-' + $dependency.version + '.zip')
    Assert-NoReparsePoint -Path $zipPath
    if (-not (Test-Path -LiteralPath $zipPath)) {
        $downloadPath = Join-Path $cacheRoot ([Guid]::NewGuid().ToString('N') + '.download')
        try {
            Invoke-WebRequest -Uri $dependency.url -OutFile $downloadPath
            Assert-Hash -Path $downloadPath -Expected $dependency.sha256
            if (Test-Path -LiteralPath $zipPath) {
                Assert-Hash -Path $zipPath -Expected $dependency.sha256
            } else { Move-Item -LiteralPath $downloadPath -Destination $zipPath }
        } finally {
            if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath }
        }
    }
    Assert-Hash -Path $zipPath -Expected $dependency.sha256
    Expand-VerifiedArchive -ZipPath $zipPath -Destination (Join-Path $projectRoot ('Packages\' + $dependency.id))
}
$packageZip = Join-Path $repoRoot "packages\$packageId-$packageVersion.zip"
Assert-Hash -Path $packageZip -Expected $packageSha256
Expand-VerifiedArchive -ZipPath $packageZip -Destination (Join-Path $projectRoot "Packages\$packageId")
Assert-Hash -Path (Join-Path $projectRoot "Packages\$packageId\Editor\EditorTools.AvatarRecovery.Editor.dll") -Expected $assemblySha256

$upmDependencies = [ordered]@{
    'com.coplaydev.unity-mcp'='https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#v10.1.2'
    'com.unity.test-framework'='1.1.33'
}
foreach ($module in @('ai','androidjni','animation','assetbundle','audio','cloth','director','imageconversion','imgui','jsonserialize','particlesystem','physics','physics2d','screencapture','terrain','terrainphysics','tilemap','ui','uielements','umbra','unityanalytics','unitywebrequest','unitywebrequestassetbundle','unitywebrequestaudio','unitywebrequesttexture','unitywebrequestwww','vehicles','video','vr','wind','xr')) {
    $upmDependencies['com.unity.modules.' + $module] = '1.0.0'
}
Write-JsonFile -Path (Join-Path $projectRoot 'Packages\manifest.json') -Value @{dependencies=$upmDependencies}
Assert-NoReparsePoint -Path (Join-Path $projectRoot 'ProjectSettings\ProjectVersion.txt')
[IO.File]::WriteAllText((Join-Path $projectRoot 'ProjectSettings\ProjectVersion.txt'), "m_EditorVersion: $unityVersion`nm_EditorVersionWithRevision: $unityVersion (887be4894c44)`n", [Text.UTF8Encoding]::new($false))
$testTarget = Join-Path $projectRoot 'Assets\AvatarRecoveryPublicTests'
Assert-NoReparsePoint -Path $testTarget
[void][IO.Directory]::CreateDirectory($testTarget)
Copy-Item -Path (Join-Path $repoRoot 'Tests\Public\*') -Destination $testTarget -Recurse -Force
Assert-NoReparsePoint -Path (Join-Path $projectRoot 'PublicRepositoryReadme.txt')
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination (Join-Path $projectRoot 'PublicRepositoryReadme.txt')
if ($PrepareOnly) { Write-Output 'Public test project prepared; Unity has not been started.'; return }

$privateLog = Join-Path $resultRoot 'unity.raw.log'
$privateXml = Join-Path $resultRoot 'results.raw.xml'
if ((Test-Path -LiteralPath $privateLog) -or (Test-Path -LiteralPath $privateXml)) { throw 'ResultsPath already contains a run. Select an empty result directory.' }
$started = [DateTime]::UtcNow
$arguments = @('-batchmode','-nographics','-projectPath',('"' + $projectRoot + '"'),'-runTests','-testPlatform','EditMode','-assemblyNames','AvatarRecovery.PublicTests','-testResults',('"' + $privateXml + '"'),'-logFile',('"' + $privateLog + '"'))
$process = $null
try {
    Assert-ProjectNotOpen
    # Unityがパッケージ解決後に再起動する場合も、子プロセスの終了まで待ちます。
    $process = Start-Process -FilePath $UnityPath -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden -Wait -PassThru
    $exitCode = $process.ExitCode
} finally {
    if ($null -ne $process) { $process.Dispose() }
    Save-PublicText -Source $privateLog -Destination (Join-Path $resultRoot 'unity.log')
    Save-PublicText -Source $privateXml -Destination (Join-Path $resultRoot 'results.xml')
}
if (-not (Test-Path -LiteralPath $privateXml)) { throw "Unity exited with $exitCode without test XML." }
[xml]$xml = Get-Content -LiteralPath $privateXml -Raw
$run = $xml.'test-run'
$summary = [ordered]@{
    format='AvatarRecovery public Unity test result v1'
    packageVersion=$packageVersion;packageSha256=$packageSha256;assemblySha256=$assemblySha256
    unityVersion=$unityVersion;sdkVersion='3.10.5';testAssembly='AvatarRecovery.PublicTests'
    executionEnvironment=$(if ($env:GITHUB_ACTIONS -eq 'true') { 'GitHub Actions' } else { 'local' })
    startedAtUtc=$started.ToString('o');completedAtUtc=[DateTime]::UtcNow.ToString('o')
    unityExitCode=$exitCode;result=[string]$run.result
    total=[int]$run.total;passed=[int]$run.passed;failed=[int]$run.failed;skipped=[int]$run.skipped
    testXmlSha256=(Get-FileHash -LiteralPath (Join-Path $resultRoot 'results.xml') -Algorithm SHA256).Hash.ToLowerInvariant()
    dependencies=$dependencies
}
Write-JsonFile -Path (Join-Path $resultRoot 'summary.json') -Value $summary
Write-Output ($summary | ConvertTo-Json -Depth 5)
if ($exitCode -ne 0 -or $summary.result -ne 'Passed' -or $summary.total -le 0 -or
    $summary.failed -ne 0 -or $summary.skipped -ne 0 -or $summary.passed -ne $summary.total) {
    throw 'Public Unity tests did not all pass. Inspect results.xml and unity.log.'
}
} finally { $projectLock.Dispose() }
