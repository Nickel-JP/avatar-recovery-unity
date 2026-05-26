# Avatar Recovery Unity

VPM repository for `com.nickel-jp.avatar-recovery`.

## Overview

Avatar Recovery Unity is a Unity Editor extension for restoring VRChat `.vrca` / `.vrcw` AssetBundles into a Unity project.
It is intended for technical recovery, inspection, diagnostics, and migration work on avatars/worlds that you created, legitimately purchased, or are explicitly authorized to handle.

The tool calls AssetRipper.exe as an external process, then applies Avatar Recovery Unity's own C# post-processing pipeline to help recover script references, shader references, prefab selection, diagnostics, and safer pose-reset handling for avatars that may break when imported directly.

## Technical Specifications

| Item | Details |
|---|---|
| Unity | Unity 2022.3.22f1 is required. VCC is recommended. |
| VRChat SDK | Base and Avatars `>=3.10.0 <3.11.0`, installed through VCC. |
| Package ID | `com.nickel-jp.avatar-recovery` |
| Distribution | VPM repository for VRChat Creator Companion |
| Target environment | Unity Editor on Windows 10 / 11 |
| Main pipeline | AssetRipper extraction plus Avatar Recovery post-processing |
| External extractor | AssetRipper.exe from `Release.zip`, downloaded separately from [Dean2k/SARS](https://github.com/Dean2k/SARS) |
| Recommended shaders | Poiyomi Toon Shader or lilToon for closer material restoration |
| License | MIT |

## Environment Notes

Unity 2022.3.22f1 is the required Unity version for this package and for VRChat avatar upload workflows targeted by this tool. Do not upgrade the project to a newer Unity version unless VRChat officially changes its supported Unity version.

As of 2026, the minimum VRChat Avatar SDK version for uploading avatars is 3.9.0 or later. New avatar uploads may be restricted on SDK versions older than 3.9.0. This VPM package declares `com.vrchat.base` and `com.vrchat.avatars` dependencies in the `>=3.10.0 <3.11.0` range, so VCC-managed installs should satisfy the upload requirement.

Validated test environment:

| Item | Tested version / environment |
|---|---|
| OS | Windows 11 |
| Unity | Unity 2022.3.22f1 |
| VRChat SDK - Base | 3.10.3 |
| VRChat SDK - Avatars | 3.10.3 |
| Avatar Recovery | 1.0.1 |
| PowerShell for batchmode test | 7.6.0 |
| Test coverage | Manual Unity Editor operation and Unity batchmode restore test |

Mac, Linux, Unity 2019, Unity 6, and other Unity versions have not been validated.

## AssetRipper / AssetsDataBaseRipper Usage

This tool uses AssetRipper.exe as an external executable for AssetBundle extraction.
Some users may refer to similar workflows as AssetsDataBaseRipper, but in this package the supported external extraction workflow is AssetRipper.exe.

AssetRipper itself is not bundled in this VPM package. Users should download `Release.zip` separately from [Dean2k/SARS](https://github.com/Dean2k/SARS), extract it, then configure the included `AssetRipper.exe` path in the tool settings or place it in one of the supported auto-detection folders.

AssetRipper is used only as an external process. It is not bundled, linked, embedded, or redistributed inside Avatar Recovery Unity.
Because AssetRipper is a separate project with its own license, this repository only distributes Avatar Recovery Unity code, VPM metadata, and the package zip files.

## Implementation and Rights Notes

Avatar Recovery Unity's post-processing pipeline is written as original C# code.
It references established Unity and VRChat asset-recovery techniques and workflows, including SARS-inspired recovery concepts, but it is an independent implementation and does not copy proprietary third-party source code.

SARS uses a custom license that restricts code redistribution. Avatar Recovery Unity does not bundle SARS source code or binaries.
The package is structured this way to keep the distributed code and metadata clear: Avatar Recovery Unity itself is distributed under the MIT license, while AssetRipper, VRChat SDK, external shaders, and recovered assets remain subject to their own licenses, terms, and rights.

## Ethical Use

Use this tool only for files you have the right to inspect or recover, such as avatars/worlds you created, legitimately purchased, your own local test bundles, your own backups, or assets you have explicit permission to maintain.

Do not use this tool to steal, clone, extract, modify, redistribute, resell, re-upload, or impersonate another creator's work. Recovered data may still contain copyrighted assets, paid models, licensed shaders, or private modifications.

Respect the original creator's terms, VRChat rules, third-party licenses, and applicable laws. This tool is provided for recovery, maintenance, and verification workflows, not for bypassing creator intent or ownership rights.

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
