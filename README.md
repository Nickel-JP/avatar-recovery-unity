# Avatar Recovery Unity

VPM repository for `com.nickel-jp.avatar-recovery`.

## Overview

Avatar Recovery Unity is a Unity Editor extension for restoring VRChat `.vrca` / `.vrcw` / `.vrcp` AssetBundles into a Unity project.
It is intended for technical recovery, inspection, diagnostics, and migration work on avatars/worlds/props that you created, legitimately purchased, or are explicitly authorized to handle.

The tool calls AssetRipper.exe as an external process, then applies Avatar Recovery Unity's own C# post-processing pipeline to help recover script references, shader references, prefab selection, diagnostics, and safer pose-reset handling for avatars that may break when imported directly.

## Technical Specifications

| Item | Details |
|---|---|
| Unity | Unity 2022.3.22f1 is required. VCC is recommended. |
| VRChat SDK | Base `>=3.7.0 <3.11.0` is required for install compatibility. Avatars SDK is used for avatar projects, and Worlds SDK is supported for world projects. |
| Package ID | `com.nickel-jp.avatar-recovery` |
| Distribution | VPM repository for VRChat Creator Companion |
| Target environment | Unity Editor on Windows 10 / 11 |
| Main pipeline | AssetRipper extraction plus Avatar Recovery post-processing |
| External extractor | AssetRipper.exe from `Release.zip`, downloaded separately from [Dean2k/SARS](https://github.com/Dean2k/SARS) |
| Recommended shaders | Poiyomi Toon Shader or lilToon for closer material restoration |
| License | MIT |

## Environment Notes

Unity 2022.3.22f1 is the required Unity version for this package and for VRChat avatar upload workflows targeted by this tool. Do not upgrade the project to a newer Unity version unless VRChat officially changes its supported Unity version.

As of 2026, the minimum VRChat Avatar SDK version for uploading avatars is 3.9.0 or later. New avatar uploads may be restricted on SDK versions older than 3.9.0. This VPM package declares only the shared `com.vrchat.base` dependency in the `>=3.7.0 <3.11.0` range so it can be installed into both avatar and world projects without forcing only Base to a newer SDK line. Install `VRChat SDK - Avatars` for avatar recovery/upload workflows, or `VRChat SDK - Worlds` for world recovery workflows.

Keep the installed VRChat SDK packages on the same version line. For example, avoid `VRChat SDK - Worlds 3.7.6` with `VRChat SDK - Base 3.10.3`; VCC should resolve them to matching versions such as Worlds/Base 3.10.3 or Worlds/Base 3.7.6.

Validated test environment:

| Item | Tested version / environment |
|---|---|
| OS | Windows 11 |
| Unity | Unity 2022.3.22f1 |
| VRChat SDK - Base | 3.10.3 |
| VRChat SDK - Avatars | 3.10.3 |
| VRChat SDK - Worlds | 3.10.3 |
| Avatar Recovery | 1.0.11 |
| PowerShell for batchmode test | 7.6.0 |
| Test coverage | Manual Unity Editor operation and Unity batchmode restore test |

Mac, Linux, Unity 2019, Unity 6, and other Unity versions have not been validated.

## Update History

### Version 1.0.11 — Removed the File Select Add Row

This update keeps the 1.0.10 file grouping UI and removes the low-visibility `Add` object field row.

- Removed the `Add` row from the File Select tab.
- Kept file addition through `Browse File...` and `Add from Folder...`.
- Preserved the `Avatar (.vrca)`, `World (.vrcw)`, and `Prop (.vrcp)` foldout groups.
- Preserved the existing batch extraction, preview, removal, and restore routing behavior.

### Version 1.0.10 — File Select Add Field and Type Foldouts

This update reorganizes the File Select tab without changing the recovery pipeline.

- Replaced the large file drop box with a Shader Lists-style `Add` object field row.
- Kept drag-and-drop support for `.vrca`, `.vrcw`, `.vrcp`, and folders containing those files on the `Add` row.
- Split the selected file list into `Avatar (.vrca)`, `World (.vrcw)`, and `Prop (.vrcp)` foldout groups.
- Keeps all three foldouts closed by default.
- Preserved the existing batch extraction, preview, removal, and restore routing behavior.

### Version 1.0.9 — Safer Scene Missing Prefab Cleanup

This update improves cleanup for stale Scene objects that Unity reports as missing prefab instances after restoration.

- Recognizes Unity's `Missing Prefab with guid: ...` suffix when matching old restored Scene placements.
- Matches strong VRChat blueprint fragments such as `avtr_`, `wrld_`, and `prop_` in legacy Scene object names.
- Automatically saves cleaned Scenes only when they had no unsaved changes before cleanup.
- Warns users to save manually when a cleaned Scene was already dirty or has no saved path.
- Added `AvatarRecovery → 現在のSceneのMissing Prefab配置を削除` for confirmed cleanup of stale objects already left in open Scenes.

### Version 1.0.8 — Color-Coded Original Shader Match Status

This update adds a color-coded match indicator to the `Material → Shader` viewer.

- Added a `Match` column beside the original shader name.
- Shows a green check mark when `Shader.Find(originalShaderName)` returns a shader whose `name` exactly matches the original shader name.
- Shows a red check mark when the shader is missing or the found shader name is not an exact match.
- Added tooltips to explain each match or mismatch result.

### Version 1.0.7 — Material Shader Reassignment from Shader Lists

This update publishes the Material-row shader reassignment workflow as a new VPM version so VCC and Unity Package Manager can detect it without relying on same-version cache invalidation.

- Added Material-row checkboxes in the `Material → Shader` viewer.
- Added the `選択したマテリアルにシェーダーを再割り当て` action directly below the search field.
- Reassigns only when `Shader.Find(originalShaderName)` returns a shader whose `name` exactly matches the original shader name.
- Skips missing shaders, mismatched shader names, and missing materials without throwing.

### Version 1.0.6 — Prop Recovery as a Third File Type

This update adds `.vrcp` as a formal third recovery type while preserving the existing `.vrca` avatar and `.vrcw` world paths.

- Added `.vrcp` file selection, folder-add, drag-and-drop, preview, and batch extraction support.
- Added a separate default output folder: `Assets/AvatarRecovery/Restored Prop data`.
- Recognized `prop_` blueprint IDs and shortened prop restore names, for example `Campfire by VRChat [prop_49fec698]`.
- Skipped avatar-only PoseResetter and Gesture Layer Mask fixing for Prop restores.
- Disabled only the AvatarDescriptor-required diagnostic check for Prop auto-diagnostics while keeping material and Missing Script diagnostics active.
- Kept Script GUID fixing, Shader GUID fixing, Missing Script policy, prefab selection/renaming, and shader reports active for Prop restores.
- Verified package metadata and VPM repository rebuild target for `1.0.6`.

### Version 1.0.5 — Short Restored Names and Long-Path-Safe Shader Reports

This update fixes a Windows path-length failure where `Shaders.txt` could be generated but `MaterialShaderMap.txt` / `.csv` failed with `DirectoryNotFoundException` in long VCC project paths.

- Changed restored folder and prefab names to a shorter, identifiable format such as `Drakepq [avtr_0cb6582b]`.
- Meaningful source names keep the avatar name and author when available; weak placeholder names such as `___`, `__data`, or `Unknown` are omitted.
- Added warnings when a restored name exceeds 80 characters or when a generated report path exceeds 240 characters. The restore continues after warning.
- Changed newly generated shader report folders to fixed `_ShaderReport` folders to avoid duplicated long names like `RestoredName of Shaders`.
- Kept existing `RestoredName of Shaders` and `List of Shaders` report folders readable for backward compatibility.
- Changed `Shaders.txt`, `MaterialShaderMap.txt`, and `MaterialShaderMap.csv` writes to the same long-path-safe writer path.
- Updated shader list viewer and diagnostics text to point users to `_ShaderReport`.
- Fixed VRCA Preview material errors when shader auto-reassignment is disabled by forcing preview-only material copies to use a fallback shader in `lilToon > Poiyomi > Standard` order.

Debug and verification performed:

- Reproduced the reported path-length pattern where `Shaders.txt` stayed below the classic Windows path limit while `MaterialShaderMap.txt` exceeded it.
- Confirmed the attached style filename `___ by Drakepq avtr_0cb6582b-a677-42c7-adec-2ffac02a1961.vrca` resolves to `Drakepq [avtr_0cb6582b]`.
- Verified the preview shader fallback path is separate from extraction, so extraction still respects the user's shader replacement settings.
- Verified the package metadata and VPM repository index were rebuilt for `1.0.5`.

### Version 1.0.4 — Material Shader Map and Missing Expression Menu Warning

This update adds a material-to-original-shader report for restored materials, plus explicit warnings for restored avatar prefabs whose `Expressions > Menu` reference could not be resolved.

- Added the `AvatarRecovery → Shader一覧を開く` viewer for opening generated `List of Shaders` reports inside Unity.
- The shader list viewer now uses a Unity-standard foldout/ObjectField style list for drag-and-drop source management.
- Multiple `List of Shaders` folders can be added to the viewer, and the visible report can be switched with per-list checkboxes.
- Material names in the viewer can ping the corresponding restored `.mat` asset in the Unity Project window.
- Changed newly generated shader report folders from the shared `List of Shaders` name to `RestoredName of Shaders`, for example `mameron of Shaders`.
- Existing `List of Shaders` folders remain readable by the shader list viewer for backward compatibility.
- Added `RestoredName of Shaders/MaterialShaderMap.txt` and `RestoredName of Shaders/MaterialShaderMap.csv`.
- The material shader map records each material name, material path, original shader full name, shader fileID, shader GUID, and resolution status.
- The map is collected before any optional shader auto-reassignment, so it records the original restored `.mat` shader reference even when auto-reassignment is enabled.
- Shader names are resolved by matching `.mat` `m_Shader` GUIDs against AssetRipper-exported `.shader.meta` stub GUIDs.
- Unity built-in shader references such as `guid: 0000000000000000f000000000000000` are resolved from fileID where possible, for example `Legacy Shaders/Particles/Additive`.
- `Auto-Reassign Shaders (SARS)` remains default OFF.
- Added a diagnostics check for unresolved `VRCExpressionsMenu` references in restored prefabs.
- Added an automatic Unity Console warning after AssetRipper/SARS extraction when the final prefab still points to a missing Expression Menu GUID such as a `deadbeef` placeholder.
- The warning explains that this usually means AssetRipper/SARS could not restore the `VRCExpressionsMenu` asset body from the extracted data, and that Avatar Recovery cannot perfectly reconstruct the original menu hierarchy, labels, icons, or ordering without the original menu asset.
- Recommended recovery path: reassign the menu from the original UnityPackage/project/backup, or create an empty `VRCExpressionsMenu` only to clear the Missing field.
- Fixed a VRCA Preview issue where invalid `Renderer.bounds` values from broken or unusual bundles could send `{ NaN, NaN, NaN }` to Unity's internal `Preview Scene Camera`.
- The preview camera now skips non-finite renderer bounds and sanitizes camera angle, target, and distance before rendering.

Debug and verification performed:

- Reproduced the issue on a restored prefab where `expressionParameters` resolved correctly but `expressionsMenu` pointed to `0000000deadbeef15deadf00d0000000`.
- Verified the same unresolved GUID existed in the raw pose backup before Avatar Recovery pose-reset or rename post-processing.
- Added detection by reading the prefab YAML reference directly, so the warning works even when Unity displays the field as `Missing`.
- Verified the material shader map against an AssetRipper export containing 69 materials and 38 shader stubs; all 69 material shader references resolved, including Unity built-in particle shaders.

### Version 1.0.3 — SDK Compatibility Stabilization

This update prevents Avatar Recovery Unity from causing a Base-only VRChat SDK upgrade in existing projects.

- Changed the VPM dependency for `com.vrchat.base` from `>=3.10.0 <3.11.0` to `>=3.7.0 <3.11.0`.
- This avoids the broken mix of `VRChat SDK - Worlds 3.7.6` with `VRChat SDK - Base 3.10.3` that can trigger `VRCWorldBuilder` initialization errors.
- Added a Unity Console warning when `VRChat SDK - Base` and `VRChat SDK - Avatars` / `VRChat SDK - Worlds` are installed on different version lines.
- Kept all previously published VCC versions available in `index.json`.

Debug and verification performed:

- Reproduced the risky dependency state as a VCC/VPM resolution issue, not an Avatar Recovery C# compile error.
- Verified that installing `Avatar Recovery 1.0.3` into a new World project using `VRChat SDK - Worlds 3.7.6` keeps `VRChat SDK - Base 3.7.6`.
- Verified Unity 2022.3.22f1 batchmode compilation with the World 3.7.6 / Base 3.7.6 project.
- Verified public GitHub Pages `index.json`, package URL, and zip SHA256.

### Version 1.0.2 — World Project Install Support

This update made the package installable in VRChat World projects while preserving Avatar project behavior.

- Removed the mandatory `com.vrchat.avatars` VPM dependency.
- Updated the editor assembly definition so it no longer directly references `VRC.SDK3A` / `VRC.SDK3A.Editor`.
- Reworked `VRCAvatarDescriptor` usage through reflection / serialized access where needed.
- Allowed World projects to skip Avatar-only environment checks instead of logging a hard Avatar SDK error.
- Updated package metadata and documentation to describe both `.vrca` and `.vrcw` recovery use cases.

Debug and verification performed:

- Verified VCC installation into new Avatar and World projects.
- Verified SDK 3.10.3 Avatar and World project compilation in Unity 2022.3.22f1 batchmode.
- Verified `index.json` includes version `1.0.2` while preserving `1.0.1` and `1.0.0`.
- Verified public package URL and zip SHA256 after GitHub Pages deployment.

### Before VPM Version 1.0.0 — Important Pre-Release Stabilization

These fixes were completed before the public VPM `1.0.0` package line. They are included in every published VCC version from `1.0.0` onward.

- Added the AssetRipper-based recovery pipeline and Avatar Recovery Unity's original C# post-processing flow.
- Added script GUID recovery for SDK components such as avatar descriptors and pipeline-related scripts.
- Added shader GUID recovery, shader detection, and `List of Shaders/Shaders.txt` output for manual material repair.
- Added the `Auto-Reassign Shaders` option so users can choose between preserving original shader references for manual reassignment or automatically rewriting material shader references.
- Added Missing Script cleanup and a dedicated Missing Script search/removal workflow.
- Added safer prefab selection so the tool does not blindly use the first prefab exported by AssetRipper.
- Added prefab renaming so restored prefabs are named after the original `.vrca` / `.vrcw` file when possible.
- Added pose-reset safety handling to prevent risky `PoseResetter` results from being applied unconditionally to the final production prefab.
- Added raw pose backup / pose reset candidate storage so pose-reset decisions can be inspected without losing the original imported pose data.
- Added cleanup for stale prefab artifacts before copying newly extracted assets, reducing leftover raw prefab confusion between repeated restores.
- Added long path, UTF-8, atomic file replacement, temporary directory retry cleanup, and resource leak fixes from production-debug review.
- Added batch extraction, cache scanning, cancelable progress, preview tooling, diagnostics, and more detailed Console summaries.

Debug and verification performed before VPM publication:

- Investigated broken-looking restored avatars caused by unsafe pose resetting and moved the workflow toward candidate/backup-based safety checks.
- Verified that shader list output is generated during the AssetRipper recovery path even when automatic shader reassignment is disabled.
- Reviewed and fixed high-risk Unity Editor issues such as path handling, file replacement, RenderTexture cleanup, missing null checks, and scan-state cleanup.
- Verified the package in Unity 2022.3.22f1 with manual Editor operation and batchmode-oriented checks before publishing the VPM repository.

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

Use this tool only for files you have the right to inspect or recover, such as avatars/worlds/props you created, legitimately purchased, your own local test bundles, your own backups, or assets you have explicit permission to maintain.

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
