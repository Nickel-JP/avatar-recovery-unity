param([Parameter(Mandatory = $true)][string]$CecilPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -Path ([IO.Path]::GetFullPath($CecilPath))
Import-Module (Join-Path $PSScriptRoot '../StringLiteralContract.psm1') -Force
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runRoot = Join-Path $repoRoot ('.work/StringLiteralTests/' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$policyPath = Join-Path $PSScriptRoot '../StringLiteralPolicy.json'
$script:passed = 0

function Assert-Check {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
    Write-Output "PASS: $Name"
}

function New-TestAssembly {
    param([string]$Name, [AllowEmptyCollection()][string[]]$Literals = @(), [AllowEmptyCollection()][string[]]$Constants = @())
    $path = Join-Path $runRoot ($Name + '.dll')
    $definition = [Mono.Cecil.AssemblyNameDefinition]::new($Name, [Version]'1.0.0.0')
    $assembly = [Mono.Cecil.AssemblyDefinition]::CreateAssembly($definition, $Name, [Mono.Cecil.ModuleKind]::Dll)
    try {
        $module = $assembly.MainModule
        $type = [Mono.Cecil.TypeDefinition]::new('Fixture', 'Strings', [Mono.Cecil.TypeAttributes]::Public, $module.TypeSystem.Object)
        $module.Types.Add($type)
        $method = [Mono.Cecil.MethodDefinition]::new('Read',
            ([Mono.Cecil.MethodAttributes]([int][Mono.Cecil.MethodAttributes]::Public -bor [int][Mono.Cecil.MethodAttributes]::Static)), $module.TypeSystem.Void)
        $type.Methods.Add($method)
        foreach ($literal in $Literals) {
            $method.Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldstr, [string]$literal))
            $method.Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Pop))
        }
        $method.Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ret))
        $index = 0
        foreach ($constant in $Constants) {
            $field = [Mono.Cecil.FieldDefinition]::new(('Value' + $index++),
                ([Mono.Cecil.FieldAttributes]([int][Mono.Cecil.FieldAttributes]::Public -bor [int][Mono.Cecil.FieldAttributes]::Static -bor [int][Mono.Cecil.FieldAttributes]::Literal)),
                $module.TypeSystem.String)
            $field.Constant = $constant
            $type.Fields.Add($field)
        }
        $assembly.Write($path)
    }
    finally { $assembly.Dispose() }
    return $path
}

function Compare-Fixture {
    param([string]$Before, [string]$After, [string]$Policy = $policyPath, [string]$Output = '')
    return Test-AvatarRecoveryLiteralContract -BaselinePath $Before -CandidatePath $After -PolicyPath $Policy -OutputPath $Output
}

try {
    $key = 'AvatarRecovery_CachePath'
    $sdk = 'VRC.Core.PipelineManager'
    $base = New-TestAssembly 'baseline' @($key, $sdk, 'blueprintId', 'license text', 'AvatarRecovery_Run_')
    $same = New-TestAssembly 'same' @('license changed', $sdk, $key, $key, 'blueprintId', '')
    $result = Compare-Fixture $base $same
    Assert-Check $result.Passed '順序・重複・表示文の変更は集合差分にしない'
    Assert-Check ($result.Comparisons.SettingsKeys.BaselineCount -eq 1) 'ログ用の一時名を設定キーに分類しない'

    $changedKey = New-TestAssembly 'changed-key' @('AvatarRecovery_Cachepath', $sdk, 'blueprintId')
    $result = Compare-Fixture $base $changedKey
    Assert-Check (-not $result.Passed -and $result.Comparisons.SettingsKeys.Added[0] -ceq 'AvatarRecovery_Cachepath' -and
        $result.Comparisons.SettingsKeys.Removed[0] -ceq $key) '設定キーの大文字小文字差を検出する'

    $addedKey = New-TestAssembly 'added-key' @($key, 'AvatarRecovery_NewSetting', $sdk, 'blueprintId')
    Assert-Check (-not (Compare-Fixture $base $addedKey).Passed) '新しい設定キーの追加を検出する'
    $removedSdk = New-TestAssembly 'removed-sdk' @($key, 'blueprintId')
    Assert-Check (-not (Compare-Fixture $base $removedSdk).Passed) 'SDK完全名の欠落を検出する'
    $changedSdk = New-TestAssembly 'changed-sdk' @($key, 'VRC.Core.OtherManager', 'blueprintId')
    Assert-Check (-not (Compare-Fixture $base $changedSdk).Passed) 'SDK完全名の置換を検出する'
    $removedMember = New-TestAssembly 'removed-member' @($key, $sdk)
    Assert-Check (-not (Compare-Fixture $base $removedMember).Passed) 'SDKの短いメンバー名の欠落を検出する'

    $constant = New-TestAssembly 'constant' @() @($key, $sdk, 'blueprintId')
    Assert-Check (Compare-Fixture $base $constant).Passed 'ldstrと定数フィールドの格納場所の差は許容する'
    $empty = New-TestAssembly 'empty'
    Assert-Check (Compare-Fixture $empty $empty).Passed '空集合を比較できる'
    $trailingNewline = New-TestAssembly 'trailing-newline' @("$key`n", "$sdk`n")
    Assert-Check (Compare-Fixture $empty $trailingNewline).Passed '末尾改行を含む文を公開識別子に分類しない'

    $secretValue = 'Token=fixture-only-not-a-real-credential'
    $secret = New-TestAssembly 'secret' @($key, $sdk, 'blueprintId', $secretValue)
    $modifiedPolicy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
    $modifiedPolicy.PublicCategories.SdkNames.ExactValues += $secretValue
    $overridePath = Join-Path $runRoot 'policy.json'
    $modifiedPolicy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $overridePath -Encoding UTF8
    $reportPath = Join-Path $runRoot 'redacted-report.json'
    $result = Compare-Fixture $base $secret -Policy $overridePath -Output $reportPath
    Assert-Check (-not $result.Passed -and $result.Candidate.SecretCandidateCount -eq 1) '公開値の除外指定でも秘密候補の検査を省略しない'
    Assert-Check (-not ([IO.File]::ReadAllText($reportPath)).Contains($secretValue)) '秘密候補の値を報告へ出さない'
    Assert-Check (Compare-Fixture $secret $base).Passed '旧版の秘密候補を除去した候補を拒否しない'
    $privateKey = New-TestAssembly 'private-key' @('-----BEGIN PRIVATE KEY-----')
    Assert-Check (-not (Compare-Fixture $empty $privateKey).Passed) '秘密鍵本文のマーカーを検出する'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $runRoot 'candidate.zip'
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $same, 'Editor/EditorTools.AvatarRecovery.Editor.dll') }
    finally { $archive.Dispose() }
    Assert-Check (Compare-Fixture $base $zip).Passed 'ZIP内の実DLLを比較する'
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
    try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $same, 'editor/editortools.avatarrecovery.editor.dll') }
    finally { $archive.Dispose() }
    $rejected = $false
    try { $null = Compare-Fixture $base $zip } catch { $rejected = $_.Exception.Message -like '*一意に特定*' }
    Assert-Check $rejected 'DLLが重複したZIPを拒否する'

    $beforeHash = (Get-FileHash -LiteralPath $base).Hash
    $rejected = $false
    try { $null = Compare-Fixture $base $same -Output $base } catch { $rejected = $_.Exception.Message -like '*上書き*' }
    Assert-Check ($rejected -and (Get-FileHash -LiteralPath $base).Hash -eq $beforeHash) '報告による入力DLLの上書きを拒否する'
    $alias = Join-Path $runRoot 'input-alias.json'
    New-Item -ItemType HardLink -Path $alias -Value $base | Out-Null
    $null = Compare-Fixture $base $same -Output $alias
    Assert-Check ((Get-FileHash -LiteralPath $base).Hash -eq $beforeHash) 'hardlinkへの報告出力で入力本体を変更しない'
    $null = Compare-Fixture $base $same -Output $alias
    Assert-Check ((Get-Content -Raw -LiteralPath $alias | ConvertFrom-Json).Passed) '既存の比較報告を再出力できる'
    Write-Output "String literal contract: $script:passed passed, 0 failed."
}
finally {
    # このテストが作成した一時ディレクトリだけを削除します。
    $allowed = [IO.Path]::GetFullPath((Join-Path $repoRoot '.work/StringLiteralTests')).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($runRoot)
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'テスト出力の削除範囲が不正です。' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
