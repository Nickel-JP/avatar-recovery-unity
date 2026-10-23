param(
    [Parameter(Mandatory = $true)][string]$BaselinePath,
    [Parameter(Mandatory = $true)][string]$CandidatePath,
    [Parameter(Mandatory = $true)][string]$CecilPath,
    [string]$PolicyPath = (Join-Path $PSScriptRoot 'StringLiteralPolicy.json'),
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'StringLiteralContract.psm1') -Force
$report = Test-AvatarRecoveryLiteralContract @PSBoundParameters
if (-not $report.Passed) {
    throw '設定キー・SDK照合名の集合差分、または候補DLL内の秘密候補を検出しました。非公開の比較報告を確認してください。'
}
$report
