[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$dependencyDirectory = Join-Path $projectRoot 'Dependencies'
$classPackagePath = Join-Path $dependencyDirectory 'class.tpk'
$projectPath = Join-Path $projectRoot 'ExpressionMenuNormalizer.csproj'

$expectedAssetsToolsHash = 'D77EFBC23E963995A58D8C9F2C4345E86BEBC26CFDF8A958AEE57583FA77F60D'
$expectedClassPackageHash = 'E63C5ED98380AA87F8CC4AE408589ADD2F859F887C232068D9106406CC901E3B'
$expectedRuntimeHashes = @{
    'AssetRipper.TextureDecoder.dll' = 'F4122BF4F3749ABFB6B8C98A8AB9440C67544511443FFC06ECA0CC423D4228EB'
    'AssetsTools.NET.Texture.dll' = '189D7E51FEEFB3829E5338790FE60D09CF6E716A7980F7A355A5D78CA003CDCA'
    'crunchunity.dll' = 'A23F2E66D83551795C941CA36086260A9B3B61D205779FAF5F4F949A00393B41'
    'System.Buffers.dll' = 'ACCCCFBE45D9F08FFEED9916E37B33E98C65BE012CFFF6E7FA7B67210CE1FEFB'
    'System.Half.dll' = 'B1FB190A77169E4A561ACFC7883ADCA479BA43D36F95D85EC36DB1B0FA11D0C0'
    'System.Memory.dll' = 'BF3FB84664F4097F1A8A9BC71A51DCF8CF1A905D4080A4D290DA1730866E856F'
    'System.Numerics.Vectors.dll' = '1D3EF8698281E7CF7371D1554AFEF5872B39F96C26DA772210A33DA041BA1183'
    'System.Runtime.CompilerServices.Unsafe.dll' = '66409F670315AFE8610F17A4D3A1EE52D72B6A46C544CEC97544E8385F90AD74'
}

foreach ($requiredFile in @($classPackagePath, $projectPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "必須ファイルが見つかりません: $requiredFile"
    }
}

$actualClassPackageHash = (Get-FileHash -LiteralPath $classPackagePath -Algorithm SHA256).Hash
if ($actualClassPackageHash -ne $expectedClassPackageHash) {
    throw "class.tpk のSHA-256が固定値と一致しません: $actualClassPackageHash"
}

& dotnet build $projectPath --configuration $Configuration --nologo
if ($LASTEXITCODE -ne 0) {
    throw "ExpressionMenuNormalizerのビルドに失敗しました。exit=$LASTEXITCODE"
}

$outputDirectory = Join-Path $projectRoot "bin\$Configuration\net48"
$requiredOutputs = @(
    'ExpressionMenuNormalizer.exe',
    'ExpressionMenuNormalizer.exe.config',
    'AssetRipper.TextureDecoder.dll',
    'AssetsTools.NET.dll',
    'AssetsTools.NET.Texture.dll',
    'crunchunity.dll',
    'System.Buffers.dll',
    'System.Half.dll',
    'System.Memory.dll',
    'System.Numerics.Vectors.dll',
    'System.Runtime.CompilerServices.Unsafe.dll',
    'class.tpk',
    'AssetRipper.TextureDecoder.LICENSE.txt',
    'AssetsTools.NET.LICENSE.txt',
    'Crunch.LICENSE.txt',
    'RuntimeDependencies.LICENSE.txt',
    'THIRD_PARTY_NOTICES.md'
)

foreach ($fileName in $requiredOutputs) {
    $outputPath = Join-Path $outputDirectory $fileName
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw "ビルド必須出力が見つかりません: $outputPath"
    }
}

$builtClassPackageHash = (Get-FileHash -LiteralPath (Join-Path $outputDirectory 'class.tpk') -Algorithm SHA256).Hash
if ($builtClassPackageHash -ne $expectedClassPackageHash) {
    throw 'Release出力内のclass.tpk SHA-256が固定値と一致しません。'
}

$assetsToolsOutput = Join-Path $outputDirectory 'AssetsTools.NET.dll'
$assetsToolsVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($assetsToolsOutput).FileVersion
if ($assetsToolsVersion -ne '3.0.0.0') {
    throw "NuGetから復元したAssetsTools.NET.dllのバージョンが3.0.0.0ではありません: $assetsToolsVersion"
}

$assetsToolsHash = (Get-FileHash -LiteralPath $assetsToolsOutput -Algorithm SHA256).Hash
if ($assetsToolsHash -ne $expectedAssetsToolsHash) {
    throw "NuGetから復元したAssetsTools.NET.dllのSHA-256が固定値と一致しません: $assetsToolsHash"
}

foreach ($runtimeFileName in $expectedRuntimeHashes.Keys) {
    $runtimePath = Join-Path $outputDirectory $runtimeFileName
    $runtimeHash = (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash
    if ($runtimeHash -ne $expectedRuntimeHashes[$runtimeFileName]) {
        throw "$runtimeFileName のSHA-256が固定値と一致しません: $runtimeHash"
    }
}

Write-Host "ExpressionMenuNormalizer build OK: $outputDirectory"
