# Third-party notices

## AssetsTools.NET

- 公式ソース: https://github.com/nesrak1/AssetsTools.NET
- 公式パッケージ: https://www.nuget.org/packages/AssetsTools.NET/3.0.0
- 使用バージョン: Assembly/File version `3.0.0.0`
- ライセンス: MIT
- ライセンス本文: `AssetsTools.NET.LICENSE.txt`

`AssetsTools.NET.dll`はプロジェクトへ直接保存せず、公式NuGetの`3.0.0`を復元してRelease出力へ含めます。.NET Framework 4.8ビルドでは`lib/net40`が選択されます。

- 公式NuGet内`lib/net40/AssetsTools.NET.dll` SHA-256（署名前）: `D77EFBC23E963995A58D8C9F2C4345E86BEBC26CFDF8A958AEE57583FA77F60D`

配布工程ではAuthenticode署名によりDLLのSHA-256が変わります。配布物のハッシュは、署名後に生成する`SHA256SUMS.txt`を正とします。

`class.tpk`はAssetsTools.NETのClassPackage入力としてプロジェクトへ同梱する固定データです。

- `class.tpk` SHA-256: `E63C5ED98380AA87F8CC4AE408589ADD2F859F887C232068D9106406CC901E3B`

ビルド時は上記ハッシュへ一致しない`class.tpk`を受理しません。

## AssetsTools.NET.Texture

- 公式ソース: https://github.com/nesrak1/AssetsTools.NET
- 公式パッケージ: https://www.nuget.org/packages/AssetsTools.NET.Texture/3.0.2
- 使用バージョン: `3.0.2`
- ライセンス: MIT（`AssetsTools.NET.LICENSE.txt`）

Texture2Dの画素内容を復元前後で照合するために使用します。

## AssetRipper.TextureDecoder

- 公式ソース: https://github.com/AssetRipper/AssetRipper.TextureDecoder
- 公式パッケージ: https://www.nuget.org/packages/AssetRipper.TextureDecoder/1.3.0
- 使用バージョン: `1.3.0`
- ライセンス: MIT
- ライセンス本文: `AssetRipper.TextureDecoder.LICENSE.txt`

依存するランタイムライブラリの通知は、NuGetパッケージのライセンス情報と
配布物に同梱する通知ファイルへ集約します。

## Unity Crunch decoder

- 公式配布元: https://github.com/AssetRipper/AssetRipper
- 使用元リリース: `1.3.3`
- バイナリ: `crunchunity.dll`（Windows x64）
- ライセンス: zlib / MIT
- ライセンス本文: `Crunch.LICENSE.txt`

Unity Crunch形式のTexture2Dを画素内容へ展開するために使用します。

## .NET runtime dependencies

- `Half` 1.0.0
- `System.Buffers` 4.5.1
- `System.Memory` 4.5.5
- `System.Numerics.Vectors` 4.5.0
- `System.Runtime.CompilerServices.Unsafe` 4.5.3
- ライセンス: MIT
- ライセンス本文: `RuntimeDependencies.LICENSE.txt`

これらはTexture2Dデコーダーの.NET Framework 4.8互換依存として同梱します。
