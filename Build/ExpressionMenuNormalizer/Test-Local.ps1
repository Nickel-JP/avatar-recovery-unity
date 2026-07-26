[CmdletBinding()]
param(
    [Parameter()]
    [string]$ExecutablePath = '',

    [Parameter()]
    [string]$ClassPackagePath = '',

    [Parameter()]
    [string]$AiriVrcaPath = $env:AVATAR_RECOVERY_TEST_AIRI_VRCA,

    [Parameter()]
    [string]$MoyoVrcaPath = $env:AVATAR_RECOVERY_TEST_MOYO_VRCA,

    [Parameter()]
    [switch]$KeepOutputs
)

$ErrorActionPreference = 'Stop'
$scriptRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath =
        Join-Path $scriptRoot 'bin\Release\net48\ExpressionMenuNormalizer.exe'
}
if ([string]::IsNullOrWhiteSpace($ClassPackagePath)) {
    $ClassPackagePath =
        Join-Path $scriptRoot 'bin\Release\net48\class.tpk'
}
if ([string]::IsNullOrWhiteSpace($AiriVrcaPath) -or
    [string]::IsNullOrWhiteSpace($MoyoVrcaPath)) {
    throw '検証用VRCAを-AiriVrcaPath/-MoyoVrcaPath、またはAVATAR_RECOVERY_TEST_AIRI_VRCA/AVATAR_RECOVERY_TEST_MOYO_VRCAで指定してください。'
}

foreach ($requiredFile in @($ExecutablePath, $ClassPackagePath, $AiriVrcaPath, $MoyoVrcaPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "検証用ファイルが見つかりません: $requiredFile"
    }
}

$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$runDirectory = Join-Path $temporaryBase ('AvatarRecovery-ExpressionMenuNormalizer-' + [Guid]::NewGuid().ToString('N'))
$runDirectory = [System.IO.Path]::GetFullPath($runDirectory)
if (-not $runDirectory.StartsWith($temporaryBase, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "検証一時ディレクトリがOSのTemp配下ではありません: $runDirectory"
}

New-Item -ItemType Directory -Path $runDirectory | Out-Null

function Invoke-Normalizer {
    param(
        [Parameter(Mandatory)]
        [string]$InputPath,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$LogPath
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1はnative stderrをErrorRecordへ変換するため、
        # 終了コードを取得するまではContinueで明示的に捕捉します。
        $ErrorActionPreference = 'Continue'
        $stdout = & $ExecutablePath `
            --input $InputPath `
            --output $OutputPath `
            --class-package $ClassPackagePath 2> $LogPath
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        $errorLog = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
        throw "Normalizerが失敗しました。exit=$exitCode`n$errorLog"
    }

    $lines = @($stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($lines.Count -ne 1) {
        throw "stdoutは単一JSONである必要があります。lines=$($lines.Count)"
    }

    return $lines[0] | ConvertFrom-Json
}

try {
    $airiSourceHash = (Get-FileHash -LiteralPath $AiriVrcaPath -Algorithm SHA256).Hash
    $airiOutput = Join-Path $runDirectory 'airi-normalized.vrca'
    $airiLog = Join-Path $runDirectory 'airi.log'
    $airiResult = Invoke-Normalizer -InputPath $AiriVrcaPath -OutputPath $airiOutput -LogPath $airiLog

    if ($airiResult.schemaVersion -ne 1 `
        -or $airiResult.status -ne 'normalized' `
        -or $airiResult.candidateCount -le 0 `
        -or $airiResult.candidateCount -ne $airiResult.renamedCount `
        -or $airiResult.menuCountBefore -ne $airiResult.menuCountAfter `
        -or $airiResult.controlCount -ne 226 `
        -or $airiResult.subMenuControlCount -ne 45 `
        -or $airiResult.iconReferenceCount -ne 206 `
        -or $airiResult.parameterReferenceCount -ne 181 `
        -or $airiResult.subParameterCount -ne 20 `
        -or $airiResult.labelCount -ne 0 `
        -or $airiResult.labelIconReferenceCount -ne 0 `
        -or $airiResult.menuGraphSha256 -notmatch '^[0-9A-Fa-f]{64}$' `
        -or -not (Test-Path -LiteralPath $airiOutput -PathType Leaf)) {
        throw "airiの正規化結果が契約を満たしていません: $($airiResult | ConvertTo-Json -Compress)"
    }

    $airiSourceHashAfter = (Get-FileHash -LiteralPath $AiriVrcaPath -Algorithm SHA256).Hash
    if ($airiSourceHashAfter -ne $airiSourceHash) {
        throw 'airiの元VRCAが変更されました。'
    }

    $airiSecondOutput = Join-Path $runDirectory 'airi-second-pass.vrca'
    $airiSecondLog = Join-Path $runDirectory 'airi-second-pass.log'
    $airiSecondResult = Invoke-Normalizer `
        -InputPath $airiOutput `
        -OutputPath $airiSecondOutput `
        -LogPath $airiSecondLog
    if ($airiSecondResult.status -ne 'unchanged' `
        -or $airiSecondResult.candidateCount -ne 0 `
        -or $airiSecondResult.controlCount -ne $airiResult.controlCount `
        -or $airiSecondResult.subMenuControlCount -ne $airiResult.subMenuControlCount `
        -or $airiSecondResult.iconReferenceCount -ne $airiResult.iconReferenceCount `
        -or $airiSecondResult.parameterReferenceCount -ne $airiResult.parameterReferenceCount `
        -or $airiSecondResult.subParameterCount -ne $airiResult.subParameterCount `
        -or $airiSecondResult.labelCount -ne $airiResult.labelCount `
        -or $airiSecondResult.labelIconReferenceCount -ne $airiResult.labelIconReferenceCount `
        -or -not [string]::IsNullOrEmpty($airiSecondResult.menuGraphSha256) `
        -or (Test-Path -LiteralPath $airiSecondOutput)) {
        throw "airiの二重実行が冪等ではありません: $($airiSecondResult | ConvertTo-Json -Compress)"
    }

    $moyoSourceHash = (Get-FileHash -LiteralPath $MoyoVrcaPath -Algorithm SHA256).Hash
    $moyoOutput = Join-Path $runDirectory 'moyo-normalized.vrca'
    $moyoLog = Join-Path $runDirectory 'moyo.log'
    $moyoResult = Invoke-Normalizer -InputPath $MoyoVrcaPath -OutputPath $moyoOutput -LogPath $moyoLog
    if ($moyoResult.schemaVersion -ne 1 `
        -or $moyoResult.status -ne 'unchanged' `
        -or $moyoResult.candidateCount -ne 0 `
        -or $moyoResult.renamedCount -ne 0 `
        -or $moyoResult.menuCountBefore -ne $moyoResult.menuCountAfter `
        -or $moyoResult.controlCount -lt 0 `
        -or $moyoResult.subMenuControlCount -lt 0 `
        -or $moyoResult.iconReferenceCount -lt 0 `
        -or $moyoResult.parameterReferenceCount -lt 0 `
        -or $moyoResult.subParameterCount -lt 0 `
        -or $moyoResult.labelCount -lt 0 `
        -or $moyoResult.labelIconReferenceCount -lt 0 `
        -or -not [string]::IsNullOrEmpty($moyoResult.menuGraphSha256) `
        -or (Test-Path -LiteralPath $moyoOutput)) {
        throw "Moyoの非変更結果が契約を満たしていません: $($moyoResult | ConvertTo-Json -Compress)"
    }

    $moyoSourceHashAfter = (Get-FileHash -LiteralPath $MoyoVrcaPath -Algorithm SHA256).Hash
    if ($moyoSourceHashAfter -ne $moyoSourceHash) {
        throw 'Moyoの元VRCAが変更されました。'
    }

    Write-Host 'ExpressionMenuNormalizer local validation OK'
    Write-Host "airi: $($airiResult | ConvertTo-Json -Compress)"
    Write-Host "airi second pass: $($airiSecondResult | ConvertTo-Json -Compress)"
    Write-Host "Moyo: $($moyoResult | ConvertTo-Json -Compress)"
    if ($KeepOutputs) {
        Write-Host "検証出力: $runDirectory"
    }
}
finally {
    if (-not $KeepOutputs -and (Test-Path -LiteralPath $runDirectory -PathType Container)) {
        $resolvedRunDirectory = [System.IO.Path]::GetFullPath($runDirectory)
        if (-not $resolvedRunDirectory.StartsWith($temporaryBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "安全確認に失敗したため一時ディレクトリを削除しません: $resolvedRunDirectory"
        }

        Remove-Item -LiteralPath $resolvedRunDirectory -Recurse -Force
    }
}
