# AvatarRecovery Unity

VPM repository for `com.nickel-jp.avatar-recovery`.

AvatarRecovery は、VRChat の `.vrca` / `.vrcw` / `.vrcp` AssetBundle を Unity Editor 内で確認し、許可された範囲で Unity プロジェクトへ復元するための Editor 拡張です。

AssetRipper.exe を外部プロセスとして呼び出し、その後に AvatarRecovery 独自の C# 後処理で Script GUID、Shader GUID、Missing Script、Prefab 選択、Pose Reset の安全確認を補助します。AssetRipper 本体と SARS ソースコードは同梱していません。

## VPM Repository

```text
https://nickel-jp.github.io/avatar-recovery-unity/index.json
```

## Install

Click the button below to add this repository to VRChat Creator Companion:

[![Add to VCC](https://img.shields.io/badge/VCC-Add%20Repository-2563eb?style=for-the-badge&logo=unity&logoColor=white)](https://nickel-jp.github.io/avatar-recovery-unity/add/)

Manual repository URL:

```text
https://nickel-jp.github.io/avatar-recovery-unity/index.json
```

After adding the repository, install `Avatar Recovery` from the VCC package list.
VCC can choose any version listed in this repository, including older published versions.

## Technical Specifications

| Item | Details |
|---|---|
| Unity | Unity 2022.3.x |
| VRChat SDK | `com.vrchat.base >=3.7.0 <3.11.0` |
| Package ID | `com.nickel-jp.avatar-recovery` |
| Target OS | Windows 10 / 11 |
| External extractor | AssetRipper.exe, obtained separately by the user |
| License | AvatarRecovery Custom License |

Avatar projects should install `VRChat SDK - Avatars`; world projects should install `VRChat SDK - Worlds`. Keep VRChat SDK packages on the same version line.

## Update History

### Version 1.1.2 — Package Maintenance

- Updated the VPM package and repository metadata for the 1.1.2 release.
- Preserved Unity message methods, VRC SDK callback types, package metadata, and VPM index fields for compatibility.

### Version 1.1.1 — MissingScriptSearch Add Row and Foldout Defaults

- MissingScriptSearch target input now uses an Add-style ObjectField row instead of a large drag-and-drop box.
- GameObject / Prefab scan targets can still be added by dragging onto the Add row or selecting an object.
- File Select keeps the Avatar / World / Prop foldout headers visible, but the groups start collapsed instead of always expanded.

### Version 1.1.0 — DLL Package and v1.1.0 UI Cleanup

- UI names were organized around `AvatarRecovery`, `View Assets Info`, and `Run`.
- File Select now opens Avatar / World / Prop groups by default.
- `View Assets Info` can show scene-only `.vrcw` bundle information even when no GameObject preview is available.
- Preview camera distance is clamped to avoid unusably close views.
- `Shader Error Fix` wording replaces the old pink-material wording.
- The Shader Lists viewer no longer shows a dedicated `MaterialShaderMap.txt` tab.
- The old diagnostics tab and automatic diagnostics path were removed.
- A `Logs` tab exports the latest batch result as TXT, Markdown, or CSV.
- First-use consent was added. Choosing not to agree disables the tool UI but does not delete files.
- MissingScriptSearch drag-and-drop now adds targets instead of replacing the previous target.
- The package license changed to AvatarRecovery Custom License for v1.1.0 and later.

Older release notes are available in [UPDATE_HISTORY.md](UPDATE_HISTORY.md).

## License

AvatarRecovery v1.1.0 and later are distributed under the AvatarRecovery Custom License. See `LICENSE`.

Earlier AvatarRecovery versions that were already published with the MIT License remain governed by the license terms attached to those earlier published versions.

AssetRipper and SARS are separate projects governed by their own licenses. AvatarRecovery does not bundle AssetRipper binaries or SARS source code.

## Ethical Use

Use this tool only for files you have the right to inspect or recover, such as assets you created, legitimately purchased, own as backups, or are explicitly authorized to maintain.

Do not use this tool to steal, clone, extract, modify, redistribute, resell, re-upload, or impersonate another creator's work.

## Rebuild

Maintainer-only example:

```powershell
powershell -ExecutionPolicy Bypass -File .\BuildVpmRepository.ps1 `
  -ProjectRoot "<path-to-UnityProject>" `
  -BaseUrl "https://nickel-jp.github.io/avatar-recovery-unity"
```

Rebuilding updates `index.json` and package metadata locally. Commit, push, and GitHub Pages publication are separate maintainer actions.
