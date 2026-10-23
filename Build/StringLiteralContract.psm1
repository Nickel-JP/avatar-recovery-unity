Set-StrictMode -Version Latest

function ConvertTo-OrdinalLiteralSet {
    param([AllowEmptyCollection()][string[]]$Values = @())
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $Values) { [void]$set.Add($value) }
    return ,$set
}

function Get-OrdinalLiteralValues {
    param([Collections.Generic.HashSet[string]]$Set)
    $values = [string[]]@($Set)
    [Array]::Sort($values, [StringComparer]::Ordinal)
    return ,$values
}

function Read-LiteralContractPolicy {
    param([string]$Path)
    $policy = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($policy.format -cne 'AvatarRecovery literal contract policy v1') {
        throw '文字列分類ポリシーの形式が一致しません。'
    }
    $categories = [ordered]@{}
    foreach ($name in @('SettingsKeys', 'SdkNames')) {
        $category = $policy.PublicCategories.$name
        $patterns = @($category.Patterns | ForEach-Object {
            [regex]::new($_, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1))
        })
        $categories[$name] = @{
            Patterns = $patterns
            Exact = ConvertTo-OrdinalLiteralSet -Values @($category.ExactValues)
            Excluded = ConvertTo-OrdinalLiteralSet -Values @($category.ExcludedValues)
        }
    }
    $secretRules = @($policy.SecretValueRules | ForEach-Object {
        @{ Name = [string]$_.Name; Regex = [regex]::new($_.Pattern,
            [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1)) }
    })
    if ($secretRules.Count -eq 0) { throw '秘密候補の検査規則がありません。' }
    return @{ Categories = $categories; SecretRules = $secretRules }
}

function Get-LiteralContractInventory {
    param([string]$Path, $Policy)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $buffer = [IO.MemoryStream]::new()
    $archive = $null
    $stream = $null
    $assembly = $null
    try {
        if ([IO.Path]::GetExtension($fullPath) -ieq '.zip') {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($fullPath)
            $entries = @($archive.Entries | Where-Object {
                $_.FullName -ieq 'Editor/EditorTools.AvatarRecovery.Editor.dll'
            })
            if ($entries.Count -ne 1) { throw '比較対象ZIPのEditor DLLを一意に特定できません。' }
            $length = $entries[0].Length
            $stream = $entries[0].Open()
        }
        else {
            $stream = [IO.File]::OpenRead($fullPath)
            $length = $stream.Length
        }
        if ($length -le 0 -or $length -gt 64MB) { throw '比較対象DLLのサイズが検査範囲外です。' }
        $stream.CopyTo($buffer)
        $buffer.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $dllHash = ([BitConverter]::ToString($sha.ComputeHash($buffer))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $buffer.Position = 0
        # 対象DLLはロードせず、ILと定数フィールドを読み取ります。
        $reader = [Mono.Cecil.ReaderParameters]::new()
        $reader.ReadSymbols = $false
        $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($buffer, $reader)
        $literals = ConvertTo-OrdinalLiteralSet
        foreach ($type in $assembly.MainModule.GetTypes()) {
            foreach ($field in $type.Fields) {
                if ($field.HasConstant -and $field.Constant -is [string] -and $field.Constant.Length -gt 0) {
                    [void]$literals.Add([string]$field.Constant)
                }
            }
            foreach ($method in $type.Methods) {
                if (-not $method.HasBody) { continue }
                foreach ($instruction in $method.Body.Instructions) {
                    if ($instruction.OpCode.Code -eq [Mono.Cecil.Cil.Code]::Ldstr -and
                        $instruction.Operand -is [string] -and $instruction.Operand.Length -gt 0) {
                        [void]$literals.Add([string]$instruction.Operand)
                    }
                }
            }
        }
        $sets = [ordered]@{}
        foreach ($name in $Policy.Categories.Keys) { $sets[$name] = ConvertTo-OrdinalLiteralSet }
        $secretFindings = [Collections.Generic.List[object]]::new()
        $secretCount = 0
        $otherCount = 0
        foreach ($literal in $literals) {
            $secret = $false
            # 公開値の分類より秘密候補の検査を優先し、値そのものは報告に残しません。
            foreach ($rule in $Policy.SecretRules) {
                if ($rule.Regex.IsMatch($literal)) {
                    $secret = $true
                    $secretFindings.Add([pscustomobject]@{ Rule = $rule.Name })
                }
            }
            if ($secret) { $secretCount++; continue }
            $matched = $false
            foreach ($name in $Policy.Categories.Keys) {
                $category = $Policy.Categories[$name]
                if ($category.Excluded.Contains($literal)) { continue }
                $isPublic = $category.Exact.Contains($literal)
                foreach ($pattern in $category.Patterns) {
                    if ($pattern.IsMatch($literal)) { $isPublic = $true; break }
                }
                if ($isPublic) { [void]$sets[$name].Add($literal); $matched = $true }
            }
            if (-not $matched) { $otherCount++ }
        }
        $publicValues = [ordered]@{}
        foreach ($name in $sets.Keys) { $publicValues[$name] = Get-OrdinalLiteralValues -Set $sets[$name] }
        return [pscustomobject]@{
            ArtifactSHA256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            DllSHA256 = $dllHash
            DistinctNonEmptyLiteralCount = $literals.Count
            PublicCompatibilityValues = [pscustomobject]$publicValues
            SecretCandidateCount = $secretCount
            SecretFindings = @($secretFindings.ToArray())
            OtherLiteralCount = $otherCount
        }
    }
    finally {
        if ($null -ne $assembly) { $assembly.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $archive) { $archive.Dispose() }
        $buffer.Dispose()
    }
}

function Test-AvatarRecoveryLiteralContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaselinePath,
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [string]$PolicyPath = (Join-Path $PSScriptRoot 'StringLiteralPolicy.json'),
        [string]$CecilPath = '',
        [string]$OutputPath = ''
    )
    if ($null -eq ('Mono.Cecil.AssemblyDefinition' -as [type])) {
        if ([string]::IsNullOrWhiteSpace($CecilPath)) { throw '静的比較にはMono.Cecil.dllの指定が必要です。' }
        Add-Type -Path ([IO.Path]::GetFullPath($CecilPath))
    }
    $policy = Read-LiteralContractPolicy -Path $PolicyPath
    $baseline = Get-LiteralContractInventory -Path $BaselinePath -Policy $policy
    $candidate = Get-LiteralContractInventory -Path $CandidatePath -Policy $policy
    $equal = $true
    $comparisons = [ordered]@{}
    foreach ($name in $policy.Categories.Keys) {
        $before = ConvertTo-OrdinalLiteralSet -Values $baseline.PublicCompatibilityValues.$name
        $after = ConvertTo-OrdinalLiteralSet -Values $candidate.PublicCompatibilityValues.$name
        $added = ConvertTo-OrdinalLiteralSet -Values (Get-OrdinalLiteralValues -Set $after)
        $added.ExceptWith($before)
        $removed = ConvertTo-OrdinalLiteralSet -Values (Get-OrdinalLiteralValues -Set $before)
        $removed.ExceptWith($after)
        $categoryEqual = $before.SetEquals($after)
        if (-not $categoryEqual) { $equal = $false }
        $comparisons[$name] = [pscustomobject]@{
            BaselineCount = $before.Count; CandidateCount = $after.Count; Equal = $categoryEqual
            Added = Get-OrdinalLiteralValues -Set $added
            Removed = Get-OrdinalLiteralValues -Set $removed
        }
    }
    $report = [pscustomobject]@{
        Format = 'AvatarRecovery literal contract report v1'
        PolicySHA256 = (Get-FileHash -LiteralPath $PolicyPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Scope = 'Ordinal sets of non-empty ldstr values and string field constants; type metadata and runtime-composed suffixes are separate.'
        Baseline = $baseline; Candidate = $candidate
        Comparisons = [pscustomobject]$comparisons
        PublicCompatibilitySetsEqual = $equal
        Passed = ($equal -and $candidate.SecretCandidateCount -eq 0)
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $fullOutput = [IO.Path]::GetFullPath($OutputPath)
        foreach ($inputPath in @($BaselinePath, $CandidatePath, $PolicyPath, $CecilPath)) {
            if ($inputPath -and [IO.Path]::GetFullPath($inputPath).Equals($fullOutput, [StringComparison]::OrdinalIgnoreCase)) {
                throw '比較対象ファイルを報告で上書きできません。'
            }
        }
        # junction等で入力の別名へ書き込まないよう、出力経路を確認します。
        $ancestor = $fullOutput
        while ($ancestor) {
            if ((Test-Path -LiteralPath $ancestor) -and
                ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw '報告の出力先にはjunctionやシンボリックリンクを使用できません。'
            }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullOutput))
        $temporary = $fullOutput + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        $backup = $temporary + '.bak'
        try {
            [IO.File]::WriteAllText($temporary, ($report | ConvertTo-Json -Depth 12) + "`n", [Text.UTF8Encoding]::new($false))
            # 既存ファイルへの直接書込みを避け、別のhardlinkが指す入力本体を維持します。
            if ([IO.File]::Exists($fullOutput)) { [IO.File]::Replace($temporary, $fullOutput, $backup) }
            else { [IO.File]::Move($temporary, $fullOutput) }
        }
        finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
            if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
        }
    }
    return $report
}

Export-ModuleMember -Function Test-AvatarRecoveryLiteralContract
