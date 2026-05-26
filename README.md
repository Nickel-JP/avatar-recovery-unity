# Avatar Recovery Unity

VPM repository for `com.nickel-jp.avatar-recovery`.

## ツール概要

Avatar Recovery Unity は、VRChat の `.vrca` ファイルからアバター関連データを Unity プロジェクトへ復元するための Unity Editor 拡張です。
自分が所有しているアバター、バックアップ、または明確な許可を得たデータの復旧・検証・移行作業を支援する目的で作成されています。

Missing Script 参照、シェーダー/マテリアル復旧、Prefab再構築、直接インポート時に崩壊しやすいアバターへの安全なPose Reset判定など、VRCA復元時に起きやすい問題の切り分けと補助を行います。

## 技術仕様

| 項目 | 内容 |
|---|---|
| Unity | 2022.3.x |
| VRChat SDK | Base and Avatars `>=3.10.0 <3.11.0` |
| Package ID | `com.nickel-jp.avatar-recovery` |
| 配布形式 | VRChat Creator Companion向けVPMリポジトリ |
| 対象環境 | Windows上のUnity Editor |
| 主な処理 | AssetRipper抽出 + Avatar Recovery独自の後処理 |
| ライセンス | MIT |

## AssetRipper / AssetsDataBaseRipperの利用について

このツールは、AssetBundle抽出のために外部実行ファイルとして AssetRipper.exe を利用します。
質問や環境によって AssetsDataBaseRipper と表記される場合がありますが、このVPMパッケージ内で扱う外部抽出ツールは AssetRipper.exe です。

AssetRipper本体はこのVPMパッケージには同梱していません。利用者が別途入手し、ツール設定でパスを指定するか、自動検出対象のフォルダーへ配置してください。

AssetRipperは別プロジェクトであり独自のライセンスを持つため、このリポジトリでは Avatar Recovery Unity 本体コード、VPMメタデータ、配布用zipのみを公開しています。

## 使用時の倫理観

このツールは、自分が権利を持つファイル、バックアップ、または管理・復旧の許可を得たデータに対してのみ使用してください。

他のクリエイターのアバターや素材を盗用、複製、再配布、販売、なりすましに利用することを目的としていません。復元されたデータには、著作権のある素材、有料モデル、ライセンス付きシェーダー、個人的な改変内容が含まれる可能性があります。

利用時は、元クリエイターの利用規約、VRChatのルール、各種ライセンス、適用される法律を尊重してください。このツールは復旧・保守・検証のためのものであり、クリエイターの意図や権利を回避するためのものではありません。

## Install

Click the button below to add this repository to VRChat Creator Companion:

[![Add to VCC](https://img.shields.io/badge/VCC-Add%20Repository-2563eb?style=for-the-badge&logo=unity&logoColor=white)](https://nickel-jp.github.io/avatar-recovery-unity/add/)

Manual repository URL:

```text
https://nickel-jp.github.io/avatar-recovery-unity/index.json
```

After adding the repository, install `Avatar Recovery` from the VCC package list.
VCC can choose any version listed in this repository, including older published versions.

Package license: MIT. See the `LICENSE` file included in the package zip.

## Rebuild

Maintainer-only command example. The package was rebuilt and verified in a developer environment using PowerShell 7.6.0.
The rebuild script keeps every package zip under `packages/` in `index.json`, so do not delete older zip files unless that version should disappear from VCC.

```powershell
powershell -ExecutionPolicy Bypass -File .\BuildVpmRepository.ps1 `
  -ProjectRoot "C:\path\to\UnityProject" `
  -BaseUrl "https://nickel-jp.github.io/avatar-recovery-unity"
```

If the GitHub Pages URL changes, rebuild with the new `-BaseUrl` before publishing.
