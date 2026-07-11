# AvatarRecovery Update History

Recent release notes are shown in [README.md](README.md). This page keeps the older entries so the GitHub project overview stays shorter.

## Recent Older Releases

### Version 1.2.2 — Long Asset Path Fix

- Fixed AssetRipper transaction commits that appended a suffix to an already long asset filename and exceeded NTFS's 255-character component limit.
- Switched transaction and GUID-repair temporary files to short sibling names while preserving same-directory replacement semantics.
- Extended long-path-safe handling to Script, AnimationClip, Material, and GUID-conflict `.meta` processing.
- Verified the protected package against the original failing VRCA, including a 250-character `.anim` filename and its 255-character `.meta` file.

### Version 1.2.1 — Security Boundary Correction

- Clarified the security guarantees and limitations of the distributed package.
- Removed protection behavior that did not provide the intended security value.
- Strengthened release verification and regression coverage.
- Updated user-facing guidance so supported assurances and user responsibilities are easier to understand.

### Version 1.1.18 — Recovery History Serialization Fix

- Fixed a Unity Console warning where opening recovery history after a successful restore could report duplicate serialized field names.
- Recovery history now loads safely after restore operations in protected package builds.
- Updated the VPM index so the active public package line points to 1.1.18.

### Version 1.1.17 — Unity Startup Domain Reload Fix

- Restored AvatarRecovery's Unity Console log handler before assembly reload and Editor quit so old-domain handlers are not left behind.
- Avoided caching a transient startup failure when Unity reports the packaged DLL path late during domain reload.
- Updated the VPM index so the active public package line points to 1.1.17.

### Version 1.1.16 — Restore History Foldout

- Added a `復元履歴` / `Recovery History` foldout below the Avatar / World / Prop file groups in the File Select tab.
- Successful restores are recorded with the restored name, original file extension, output location, file size, and restore time.
- Added sorting by restore order, file size, and extension order `.vrca` / `.vrcw` / `.vrcp`.
- Recovery history rows display labels such as `RestoredName [.vrca]` and jump to the restored asset or output folder when clicked.
- Updated the VPM index so the active public package line points to 1.1.16.

### Version 1.1.15 — Unity Startup Verification Fix

- Fixed a Unity startup failure where the packaged Editor DLL could throw `System.Security.VerificationException` with `Invalid instruction target ffffffb7`.
- Added a final IL branch validation step to the protected package build so invalid branch targets fail the build instead of reaching Unity.
- Updated the VPM index so the active public package line points to 1.1.15.

### Version 1.1.14 — Script Report Output and Release Verification

- Added `_ScriptReport/Scripts.md` output for restored assets.
- The script report lists source file information, blueprint / Unity version summaries, detected script names, stub GUIDs, original `.cs.meta` relative paths, resolved MonoScript GUIDs, referring asset paths, fixed reference counts, and unresolved script entries.
- Clarified that the script report identifies script references and metadata; it does not restore C# source code.
- Added public verification steps for ZIP SHA-256 hashes and DLL Authenticode signer thumbprints.
- Added lightweight GitHub Actions checks for PowerShell syntax, package self-tests, and published GitHub Pages artifacts.
- Updated the VPM index so the active public package line points to 1.1.14.

### Version 1.1.13 — AvatarRecovery Help Window

- Added `AvatarRecovery > AvatarRecovery説明書` to the Unity menu.
- Added a scrollable Unity EditorWindow titled `AvatarRecovery の使い方`.
- Rendered the maintainer help document in a Unity Editor-friendly layout with styled headings and readable body text.

### Version 1.1.12 — Face_Emo AnimationClip Name Sanitization

- Added `AnimationClipNameSanitizer` so Face_Emo can safely create assets from recovered clips.
- Replaces `/`, `\`, Windows-invalid filename characters, and control characters in `AnimationClip.name`.
- Shortens overly long clip names with a stable hash suffix.
- Runs after animation binding restoration and before `Face_Anima` sorting.
- Verified the sanitizer against existing output with `ClipCount=746`, `Renamed=705`, and `UnsafeAfter=0`.

### Version 1.1.11 — Expression Animation Binding Restore

- Added `AnimationClipBindingRestorer`.
- Restores hashed Transform paths such as `path_0x...` to real prefab-relative paths where they can be resolved.
- Restores `blendShape.<uint>` property names to real SkinnedMeshRenderer blendShape names where they can be resolved.
- Runs before `Face_Anima` sorting so expression tools see the repaired bindings.

### Version 1.1.10 — Face_Anima Automatic Sorting

- Added automatic sorting for expression-like AnimationClips into `Face_Anima`.
- Uses expression signals such as `blink`, `eye`, `mouth`, `viseme`, `vrc.v_`, and common Japanese expression terms.
- Requires at least two expression signals before moving a clip, reducing false positives.
- Keeps ambiguous clips in `Animations`.
- Moves assets through Unity's `AssetDatabase` instead of manually moving files or `.meta` files.

### Version 1.1.9 — AAO / Avatar Optimizer Safety

- Added automatic detection for avatars that appear to use AAO / Avatar Optimizer.
- Skips PoseResetter automatically when AAO / Avatar Optimizer usage is detected.
- Added a manual file-menu checkbox to force PoseResetter skip when automatic detection is not enough.
- Preserved the existing `.vrca` recovery flow when AAO / Avatar Optimizer is not detected.

### Version 1.1.8 — File Preview Button Label

- Changed the per-file preview button label from Japanese `情報表示` / English `View Info` to `File Preview`.
- Updated the VPM index so the active public package line points to 1.1.8.

### Version 1.1.7 — Scene AssetBundle Info View Stability

- Fixed `View Assets Info` so scene-only `.vrcw` AssetBundles do not call Unity's GameObject asset loading path.
- Scene-only bundles now show scene paths and asset names without logging `This method cannot be used on a streamed scene AssetBundle`.
- Updated the VPM index so the active public package line points to 1.1.7.

### Version 1.1.6 — EditorWindow Serialization Stability

- Fixed Unity EditorWindow serialized field-name collisions after release processing.
- Added a build-time check that fails if EditorWindow fields collapse to duplicate names during release processing.
- Updated the VPM index so the active public package line points to 1.1.6.

## Older Releases

### Version 1.1.5 — Signed Release Artifacts

- Added self-signed Authenticode signing for the distributed Editor DLL.
- Added SHA-256 checksum output for the package ZIP and DLL.
- Added detached signatures for the package ZIP, checksum file, and VPM index.

### Version 1.1.4 — Tool License Display

- Added the full AvatarRecovery license text to the tool-side License view.
- Kept third-party license notices visible in the Unity Editor UI.

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
