# ExpressionMenuNormalizer

AssetRipperが書き出せない無名の`VRCExpressionsMenu`だけを、一時VRCA内で決定論的な名前へ正規化する隔離CLIです。元VRCAは読み取り専用で扱い、名前付きMenuは変更しません。

## ビルド

```powershell
.\Build.ps1 -Configuration Release
```

次の固定済み依存物を使います。

- `AssetsTools.NET` 3.0.0（公式NuGetから復元）
- `AssetsTools.NET.Texture` 3.0.2（公式NuGetから復元）
- `AssetRipper.TextureDecoder` 1.3.0（推移的依存）
- `Dependencies/crunchunity.dll`（Windows x64、SHA-256を検証）
- `Dependencies/class.tpk`（プロジェクトへ同梱し、SHA-256を検証）

Release出力はWindows x64向け`bin\Release\net48`です。実行に必要な本体・固定依存DLL・
`class.tpk`・ライセンス通知は、`Build.ps1`の必須出力契約で一括検証します。

## CLI

```text
ExpressionMenuNormalizer.exe --input <original.vrca> --output <temporary.vrca> --class-package <class.tpk>
```

- 成功時のexit codeは`0`です。
- stdoutは`schemaVersion=1`の単一JSONだけです。
- ログはstderrへ出力します。
- `status=normalized`の場合だけ出力VRCAを作成します。
- `status=unchanged`の場合は出力を作成しません。
- 既存ファイルへの上書きと、入力・出力の同一パス指定は禁止します。

## 対象判定

次の全条件へ一致し、`m_Name`が空のオブジェクトだけを変更します。

- ClassID `114`
- `m_GameObject`がnull
- MonoScriptの名前・クラス名が`VRCExpressionsMenu`
- namespaceが`VRC.SDK3.Avatars.ScriptableObjects`
- assemblyが`VRCSDK3A.dll`

注入名は`AR_ExpressionMenu_`で始まり、Bundleエントリ番号とPathIDから決定します。

## 非破壊検証

出力を再読込し、次の不変性を確認してから最終出力へ移動します。

- PathIDとClassIDの集合
- 非対象Assetのシリアライズ済み生データ
- 全Meshの生データと個数
- 対象Menuの`controls`
- 対象Menu内の全PPtr
- 対象Menuの`m_Name`以外の全フィールド
- 非SerializedFileエントリ
- SerializedFileのUnityVersion・type metadata・external参照表
- AssetBundleの圧縮方式
- 元VRCAのSHA-256

検証に失敗した場合、最終出力は作成しません。

## ローカル検証

```powershell
$env:AVATAR_RECOVERY_TEST_AIRI_VRCA = "C:\path\to\menu-recovery-fixture.vrca"
$env:AVATAR_RECOVERY_TEST_MOYO_VRCA = "C:\path\to\normal-menu-fixture.vrca"
.\Test-Local.ps1
```

追加復元が必要なfixtureを正規化し、二重実行が`unchanged`になることを確認します。通常のAssetRipper経路で復元可能なfixtureは最初から`unchanged`であることを確認します。どちらも元VRCAのSHA-256を検証します。

## 依存物

AssetsTools.NETはプロジェクトへDLLを直接保存せず、公式NuGetのバージョンをcsprojで固定しています。`class.tpk`だけは再現可能なビルドのためプロジェクト配下でソース管理します。公式リポジトリ、ライセンス、および固定情報は`THIRD_PARTY_NOTICES.md`を参照してください。
