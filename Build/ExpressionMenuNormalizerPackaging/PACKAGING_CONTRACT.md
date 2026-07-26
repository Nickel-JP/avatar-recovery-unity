# ExpressionMenuNormalizer packaging contract

`BuildProtectedAvatarRecoveryPackage.ps1` は、次の固定パスにあるプロジェクトを
`Release/net48` としてビルドします。

`Build/ExpressionMenuNormalizer/ExpressionMenuNormalizer.csproj`

## 必須のビルド出力

- `ExpressionMenuNormalizer.exe`
- `ExpressionMenuNormalizer.exe.config`
- `AssetRipper.TextureDecoder.dll`
- `AssetsTools.NET.dll`
- `AssetsTools.NET.Texture.dll`
- `crunchunity.dll`
- `System.Buffers.dll`
- `System.Half.dll`
- `System.Memory.dll`
- `System.Numerics.Vectors.dll`
- `System.Runtime.CompilerServices.Unsafe.dll`
- `class.tpk`
- `AssetRipper.TextureDecoder.LICENSE.txt`
- `AssetsTools.NET.LICENSE.txt`
- `Crunch.LICENSE.txt`
- `RuntimeDependencies.LICENSE.txt`
- `THIRD_PARTY_NOTICES.md`

必須ファイルが欠落、空、または契約外の実行時 EXE/DLL/CONFIG/JSON/TPK が追加された場合、
配布ビルドは失敗します。新しい実行時依存関係を追加する場合は、先にこの契約と
ビルドスクリプトの許可リストを更新してください。

## 配布先

検証済みファイルだけを、ソースパッケージ直下の次のフォルダーへコピーします。

`Tools~/ExpressionMenuNormalizer/`

`Editor` アセンブリのコンパイル対象には含めません。配布フォルダーには
`SHA256SUMS.txt` を生成し、ステージング先・最終パッケージ・ZIP 内のバイト列が
同一であることを検証します。

実行可能な EXE/DLL は、配布パッケージ本体と同じコード署名設定を使用します。
署名必須ビルドでは署名者を検証し、明示的な未署名ビルドでは既存ポリシーに従います。

検証済みPayloadの署名後SHA-256を同一ビルドのAvatarRecovery DLLへ埋め込むため、
`-SkipUnityCompile` は使用できません。
