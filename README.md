# AvatarRecovery Unity

VPM repository for `com.nickel-jp.avatar-recovery`.

AvatarRecovery is a Unity Editor extension for inspecting VRChat `.vrca`, `.vrcw`, and `.vrcp` AssetBundles and recovering their contents into a Unity project when you have permission to do so.

AvatarRecovery launches the bundled AssetRipper 1.3.14 files as an external process, then applies its own C# post-processing to help safely restore script and shader GUIDs, handle missing scripts, select the appropriate prefab, and reset poses. A separate AssetRipper download or path setting is not required. AssetRipper and SARS source code are not included.

## VPM Repository

```text
https://nickel-jp.github.io/avatar-recovery-unity/index.json
```

## Install

Click one of the buttons below to add this repository to your VPM client.
The VCC button uses the `vcc://vpm/addRepo` repository link because most users install packages through VRChat Creator Companion.
For ALCOM, open the instructions page and add the repository URL manually.

[![Add to VCC](https://img.shields.io/badge/VCC-Add%20Repository-2563eb?style=for-the-badge&logo=unity&logoColor=white)](https://nickel-jp.github.io/avatar-recovery-unity/add/)

[![When adding a package in ALCOM](assets/badges/when-adding-package-in-alcom.svg)](https://nickel-jp.github.io/avatar-recovery-unity/add/alcom/)

The ALCOM page explains why this site prioritizes the VCC redirect and how to add the repository from ALCOM.
[ALCOM](https://booth.pm/ja/items/6448396) is a cross-platform open-source alternative to VRChat Creator Companion, built on [vrc-get/vrc-get](https://github.com/vrc-get/vrc-get).

Manual repository URL:

```text
https://nickel-jp.github.io/avatar-recovery-unity/index.json
```

For vrc-get CLI:

```powershell
vrc-get repo add https://nickel-jp.github.io/avatar-recovery-unity/index.json
```

After adding the repository, install `Avatar Recovery` from the VCC or ALCOM package list.
In VCC or ALCOM, you can choose from the three newest supported AvatarRecovery versions in this repository. Refresh the repository in your client if a newly published version does not appear immediately.

Version 1.2.12 is the current public stable version. Newer 1.3.x releases remain withdrawn from the active VPM listing because of reliability issues. Existing VCC and ALCOM users do not need to add a new repository: refresh the existing `Avatar Recovery Unity` repository, then manually select version 1.2.12. Existing 1.3.x installations are not downgraded automatically.

## AvatarRecovery Community Server

Join the official AvatarRecovery Discord server for update announcements, bug reports, troubleshooting, and discussion with other users.

[Join the AvatarRecovery Community Server](https://discord.gg/M9nFq8HXv)

日本語: [AvatarRecovery Community Serverに参加する方はこちらから](https://discord.gg/M9nFq8HXv)

## Public Verification

The current package is `com.nickel-jp.avatar-recovery-1.2.12.zip`.
After downloading the ZIP, verify the published hash before importing it:

```powershell
# 1. Calculate the ZIP SHA-256 hash.
(Get-FileHash .\com.nickel-jp.avatar-recovery-1.2.12.zip -Algorithm SHA256).Hash

# Confirm that it is F326D6F226BFCDB78BFD0902F0E6EEAA03670271858CCBD64B0B4684A42248D4
# and matches the packages/com.nickel-jp.avatar-recovery-1.2.12.zip entry in
# checksums/com.nickel-jp.avatar-recovery-1.2.12.sha256.txt.
```

To verify the signed DLL, extract the package and compare the signer thumbprint with the published certificate:

```powershell
Expand-Archive .\com.nickel-jp.avatar-recovery-1.2.12.zip -DestinationPath .\avatar-recovery-verify -Force
$dll = ".\avatar-recovery-verify\Editor\EditorTools.AvatarRecovery.Editor.dll"
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(".\certificates\avatar-recovery-self-signed-code-signing.cer")

# 2. Verify the DLL's Authenticode signature.
$signature = Get-AuthenticodeSignature $dll
$signature

# Confirm that SignerCertificate.Thumbprint matches the certificate in certificates/.
($signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
($cert.Thumbprint -replace '\s', '').ToUpperInvariant()
```

## Security Model and Limits

Published verification information supports distribution-integrity checks. Obtain expected values through an independently trusted channel; information downloaded only from the same compromised origin cannot establish trust by itself.

Code distributed to a client cannot guarantee confidentiality or immutability. Keep truly sensitive processing on a controlled server.

## Technical Specifications

| Item | Details |
|---|---|
| Unity | Unity 2022.3.22f1 |
| VRChat SDK | `com.vrchat.base >=3.7.0 <3.11.0` |
| Package ID | `com.nickel-jp.avatar-recovery` |
| Target OS | Windows 10 / 11 |
| External extractor | Bundled AssetRipper 1.3.14 |
| License | AvatarRecovery Custom License |

Avatar projects should install `VRChat SDK - Avatars`; world projects should install `VRChat SDK - Worlds`. Keep VRChat SDK packages on the same version line.

## Update History

### Current Public Version — 1.2.12 Bundled AssetRipper

- Bundled AssetRipper 1.3.14 and the related files required for it to run.
- Removed separate AssetRipper downloads, arbitrary version selection, path settings, and external executable discovery. AvatarRecovery now uses only the bundled version.
- Extracts the bundled files under the Unity project's `Library/AvatarRecovery` folder on first use, outside Unity's imported Assets and script assemblies.
- Preserved the version 1.2.11 recovery workflow, AAO compatibility, Expression Menu recovery, shader recovery, and Missing Script handling. No HotSwap or animation-performance changes are included.
- Verified in Unity 2022.3.22f1 with a successful package build, EditorWindow smoke test, AssetRipper startup, and all 7 available EditMode tests passing.
- Refresh the `Avatar Recovery Unity` repository in VCC or ALCOM, then update AvatarRecovery to version 1.2.12.

### Version 1.2.11 — AAO Recovery Reliability

- Fixed recurring recovery failures for valid AAO-generated avatar layouts that do not require conventional skinning data.
- If an AAO repair candidate cannot be accepted, recovery now keeps the original Raw prefab only when that prefab can be reloaded successfully.
- Kept the version 1.2.10 workflow and compatibility. HotSwap and animation-processing changes from the withdrawn 1.3.x line are not included.
- Verified in Unity 2022.3.22f1 with all 15 focused AAO recovery regression tests passing, including validation against a recovered AAO avatar fixture.
- Refresh the `Avatar Recovery Unity` repository in VCC or ALCOM, then update AvatarRecovery to version 1.2.11.

### Rollback to 1.2.10

- Restored version 1.2.10 as the current supported public release because of reliability issues reported in later versions.
- Refresh the `Avatar Recovery Unity` repository in VCC or ALCOM, then manually select AvatarRecovery 1.2.10.
- Existing 1.3.x installations are not downgraded automatically.

### Version 1.3.6 — Expression Menu Icon Compatibility

- Fixed a recovery failure where valid PNG icons in restored Expression Menus could be rejected because Unity represents the loaded image using a different compatible texture format.
- Expression Menu icon verification now compares the resulting RGBA pixels instead of rejecting a normal Unity texture solely because of its storage format.
- Kept output-path, existing-file, and image-size boundaries while allowing Unity-readable icon formats to complete normal recovery.
- Preserved the HotSwap-separated package layout and the Unity 2022.3.22f1 / VRChat SDK 3.10.4 environment from version 1.3.5.
- Ran all 517 tests in the final integrated source package: 512 passed, the remaining five matched the same environment-sensitive failures as version 1.3.5, and no new regression was found.

### Version 1.3.5 — HotSwap Separation and SDK 3.10.4

- Removed Avatar and World HotSwap from the Unity package so AvatarRecovery remains focused on normal Avatar, World, and Prop recovery.
- HotSwap will be provided separately as a desktop application instead of remaining coupled to the AvatarRecovery Unity package.
- Preserved normal recovery, Expression Menu recovery, AAO compatibility, shader recovery, preview, and VRCA auto-backup workflows.
- Removed the dedicated HotSwap Unity environments from the package, reducing package size and import work.
- Fixed recovery failures when valid AssetRipper output omits folder `.meta` files; AvatarRecovery now safely completes only the missing folder metadata while keeping file metadata and final-output integrity checks strict.
- Updated the supported environment to VRChat SDK 3.10.4 and Unity 2022.3.22f1.
- Ran all 513 tests in the final integrated package: 508 passed, the remaining five matched existing environment-sensitive failures, and no new regression was found.

### Version 1.3.4 — AAO and Shader Recovery Safety

- Fixed cases where recoverable AAO-optimized avatars and some older avatar layouts were rejected by integrity checks.
- Improved shader restoration safety: ambiguous, duplicate, and unresolved candidates are no longer guessed, and multi-material updates are applied only when the whole set can be verified.
- Preserved the existing `Shaders.txt` and `MaterialShaderMap` recovery and review workflow.
- Strengthened temporary-output and final-output handling so unverified results are not adopted when file state cannot be confirmed safely.
- Restored Unity rendering state even when texture reading stops with an error, preventing the failed operation from affecting later Editor work.
- Kept the published Avatar and World HotSwap implementation, setup, and compatibility unchanged.
- Verified in Unity 2022.3.22f1 with 388 core regression tests, 16 AAO budget tests, 9 older-layout compatibility tests, one replacement-conflict safety test, and a successful real 0Polygon recovery from an ALCOM-installed 1.3.4 package.

### Version 1.3.3 — Low-Spec HotSwap Reliability

- Fixed cases where Avatar HotSwap could stop during startup even though the dedicated Unity environment was still preparing, especially on slower PCs and first runs.
- HotSwap now keeps waiting while dedicated Unity is making valid progress and retries temporary file, access, and connection failures instead of failing immediately.
- Improved recovery from incomplete previous attempts while preventing overlapping runs from interfering with active work.
- Added stricter thumbnail and input-file checks before startup, with clear guidance in the HotSwap window instead of repeated Console exceptions.
- Kept the existing VCC, ALCOM, and VRChat SDK login workflow. Start HotSwap from a Unity Editor where VRChat SDK login is already confirmed; the official VRChat consent confirmation may still appear when required by the SDK.
- No folder deletion, SDK replacement, or additional login setup is required for this update.
- Verified with Unity 2022.3.22f1 using a clean first-time preparation that exceeded two minutes, 43 automated HotSwap tests, and the signed release-artifact self-test.

### Version 1.3.2 — HotSwap Reliability and Performance

- Fixed an issue that could prevent the dedicated Avatar HotSwap Unity environment from being prepared.
- Fixed a compatibility issue that could reject recoverable older or unusually structured Avatar bundles during Avatar HotSwap validation.
- Existing incomplete or outdated dedicated environments are safely prepared again without requiring users to delete folders or replace SDK files manually.
- Preserved login handoff, Worker startup and resume behavior, and the existing alternate recovery flow.
- Reduced World HotSwap processing time while preserving the existing workflow, validation, and recovery behavior.
- Added drag-and-drop input for Avatar and World thumbnails and VRCA/VRCW files while keeping the existing Browse buttons.
- Renamed the dedicated Unity displays and template assets so Avatar and World HotSwap environments are easier to identify.
- Kept normal recovery, Expression Menu recovery, and the version 1.3.1 AAO improvements unchanged.
- Use the existing `Prepare dedicated Unity for HotSwap` or Avatar HotSwap action normally; no additional recovery steps are required.

### Version 1.3.1 — AAO Recovery Reliability and Faster Animation Processing

- Expanded compatibility with valid AAO-generated mesh layouts that could previously be rejected as damaged.
- When an AAO repair candidate cannot be adopted safely, recovery now continues with the verified reloadable Raw prefab instead of rolling back the whole result. Recovery still stops if the original prefab itself cannot be reloaded safely.
- Reduced repeated AnimationClip discovery and import work. In the validation VRCA, total recovery time improved by about 13.8% and post-extraction processing by about 46%; actual results vary by avatar and system.
- Preserved the existing per-clip Face animation separation, animation references, naming behavior, and recovered avatar appearance in regression validation.
- Kept the existing public VPM repository URL. Refresh `Avatar Recovery Unity` in VCC or ALCOM, then update `Avatar Recovery` to version 1.3.1.

### Version 1.3.0 — Avatar and World HotSwap

- Added Avatar and World HotSwap workflows that use a dedicated, validated Unity 2022.3.22f1 and VRChat SDK 3.10.2 environment for build and upload operations.
- Reduced repeated processing and file-copy overhead. Under the same validation conditions, Avatar HotSwap completed about 12% faster and World HotSwap about 3.5–7% faster than the previous baseline; actual results vary by project and system.
- Added a cleanup preview and explicit approval step. Cleanup stops without deleting data if the selected targets change after preview.
- Improved interrupted-job recovery, completion records, worker shutdown, snapshot cleanup, and VRChat session safety.
- Included the validated SDK content required by the dedicated HotSwap environment, avoiding an additional SDK download during HotSwap setup.
- Verified Avatar and World HotSwap with the release package in Unity 2022.3.22f1, together with package-integrity and published-artifact checks.
- Kept the existing public VPM repository URL. Refresh `Avatar Recovery Unity` in VCC or ALCOM, then update `Avatar Recovery` to version 1.3.0.

### Version 1.2.10 — AAO Recovery Compatibility Hotfix

- Fixed the AvatarRecovery 1.2.9 regression that incorrectly rejected valid AAO-generated meshes without active Bone Weights.
- Preserved strict root-bone, used-bone, and prefab-reference validation for meshes that use Bone Weights.
- Verified successful recovery, including AAO integrity validation, with both VRCA files reported by affected users in Unity 2022.3.22f1.
- Published the fix as version 1.2.10 so VCC and ALCOM retrieve the corrected package instead of reusing a cached 1.2.9 package.
- Refresh the repository in VCC or ALCOM, then update AvatarRecovery to version 1.2.10.

### Version 1.2.9 — Expression Menu and AAO Recovery Compatibility

- Preserved the existing recovery path for VRCA files whose Expression Menus are already restored by AssetRipper.
- Added recovery for Expression Menus that previously appeared as Missing after extraction.
- Verified restored Root Menus, SubMenus, controls, parameters, and icons in both the final and Raw prefabs before accepting the result.
- Kept incomplete or unsupported Menu results from replacing the normal AssetRipper output.
- Preserved AAO-optimized avatar detection, mesh repair, and Pose Reset protection.
- Verified the normal, Menu-recovery, and AAO-optimized workflows in Unity 2022.3.22f1.
- Known limitations:
  - Expression Menu recovery can only use Menu, SubMenu, icon, and reference data that remains in the VRCA. If required data is missing, corrupt, ambiguous, or unsupported, the normal AssetRipper result is preserved and the Menu may remain Missing.
  - If AAO evidence has been removed or a safe pose cannot be determined uniquely, Pose Reset is skipped. AvatarRecovery cannot reconstruct an already damaged baked pose or the creator's original AAO authoring setup from information that is no longer present.
  - Bone Weights that are structurally valid but semantically incorrect cannot always be identified or reconstructed automatically.
  - Extreme BlendShape values or combinations outside the avatar's normal authored range can still cause clipping or disappearing geometry.
  - Very large AAO-optimized avatars can require substantially longer validation time and may temporarily appear unresponsive while checks are running.
  - The Raw prefab is the AssetRipper-extracted state before AvatarRecovery's repair steps; it is not the creator's original Unity prefab.
  - Source data that was never stored in the VRCA, such as original FBX/PSD files, Modular Avatar or NDMF authoring setup, and source scripts, cannot be recovered.
  - When recovery cannot be verified safely, AvatarRecovery does not guess or overwrite the normal result; manual repair may still be required.

### Version 1.2.8 — Editor Responsiveness

- Reduced Unity Editor stalls while selecting recovery files or folders by moving native selection and folder enumeration away from the Editor's main thread.
- Added selected files to the queue incrementally so large selections no longer block the AvatarRecovery window for one long operation.
- Reduced repeated work in recovery history rendering, AssetRipper path discovery, and background-image loading.
- Improved native dialog cleanup when selection is cancelled, scripts reload, or Unity closes.
- Preserved the existing extraction and recovery pipeline, including Face animation selection and Blueprint ID cleanup.
- Refresh the repository in VCC or ALCOM, then update AvatarRecovery to version 1.2.8.

### Version 1.2.7 — Multi-Select and Console Compatibility

- Added Windows-native multi-selection for recovery files and source folders; hold Ctrl while selecting individual items to add them to the existing batch queue.
- Improved AvatarRecovery's Console logging so it no longer changes the logging configuration used by other Unity Editor tools.
- Kept the existing color-coded Console presentation while consolidating each batch result into one `[Batch Extraction Complete]` entry with a pink title and green details.
- Preserved existing recovery behavior, including Face animation selection and Blueprint ID cleanup.
- Verified the protected package in Unity 2022.3.22f1 with the Selena_sample.vrca recovery workflow, with one successful restore and no errors in the successful run.
- Refresh the repository in VCC or ALCOM, then update AvatarRecovery to version 1.2.7.

### Version 1.2.6 — GitHub/Discord and Recovery Stability

- Renamed the `GitHub` tab to `GitHub/Discord` and added the official AvatarRecovery Community Server for update announcements, bug reports, and community support.
- Added the latest three update entries from the official repository, manual reload, original/Japanese display, and offline cache support.
- Added installed/latest AvatarRecovery and Unity version information to the File Select tab and moved batch results to the Unity Console.
- Fixed incorrect GUID-conflict detection that could block a repeated restore when no live conflicting asset remained.
- Improved prefab post-processing so affected prefabs are skipped safely while Blueprint ID cleanup and existing Face animation selection behavior remain intact.
- If version 1.2.6 was installed previously, refresh the repository in VCC or ALCOM and reinstall 1.2.6 to receive the finalized package.

### Version 1.2.5 — Long-Running Extraction Stability

- Fixed long-running AssetRipper extraction being reported as failed while it was still making progress.
- After 60 minutes, processing now continues and asks the user to choose `Wait` or `Cancel` instead of stopping automatically.
- Choosing `Wait` keeps the extraction running and shows the continuation prompt again after another 60 minutes.
- Improved cancellation reliability, failure diagnostics, and temporary-output safety.

### Version 1.2.4 — Language, GitHub, and Manual

- Added `AvatarRecovery → Language → Japanese / English` to the Unity menu.
- Kept the `Language` menu label unchanged regardless of the selected language.
- Synchronized menu selection with the language control inside the tool and persisted the selected language.
- Added a `GitHub` information tab with English and Japanese guidance and a direct link to the official repository.
- Renamed the Unity menu entry to `AvatarRecovery → Manual` and added a complete English manual while retaining Japanese.
- Synchronized the manual window title and content with the language selected from either the Unity menu or the tool window.
- Updated the manual to match the current folder import, avatar backup, preview, and Shader Lists interfaces.
- If version 1.2.4 was already installed, refresh the repository in VCC or ALCOM and reinstall 1.2.4 to receive the finalized package.

### Version 1.2.3 — Menu Visibility Cleanup

- Streamlined the AvatarRecovery menu by hiding two maintenance entries.
- Retained the underlying PhysBone・Contact reference check and Scene cleanup behavior for internal and automatic use.
- Verified that the remaining menu entries stay available and the underlying functions remain in the package.

### Version 1.2.2 — Long Asset Path Fix

- Fixed AssetRipper transaction commits that appended a suffix to an already long asset filename and exceeded NTFS's 255-character component limit.
- Switched transaction and GUID-repair temporary files to short sibling names while preserving same-directory replacement semantics.
- Extended long-path-safe handling to Script, AnimationClip, Material, and GUID-conflict `.meta` processing.
- Regression-tested the protected package with the original VRCA, including a 250-character `.anim` filename and its 255-character `.meta` file.

### Version 1.2.1 — Security Boundary Correction

- Clarified the security guarantees and limitations of the distributed package.
- Removed protection behavior that did not provide the intended security value.
- Strengthened release verification and regression coverage.

### Version 1.2.0 — Recovery Stability and Failure Guidance

- Improved the reliability of the main recovery workflow while preserving its existing behavior.
- Added failure dialogs that show the failure reason and a recommended resolution when extraction, recovery, or automatic backup processing cannot continue.
- Fixed a Unity startup issue that could incorrectly prevent AvatarRecovery from running.
- Updated the VPM index so the active public package line points to 1.2.0.

### Version 1.1.20 — Shader Lists Selection and Match Sorting

- Added visible-row select all / clear controls to the `Material -> Shader` view in Shader Lists.
- Added Match / Mismatch display filters. When neither filter is selected, both matching and mismatching rows are shown.
- Added sorting options to keep original order, show matching shaders first, or show mismatching shaders first.
- Updated the VPM index so the active public package line points to 1.1.20.

### Version 1.1.19 — Project-Scoped Recovery History

- Recovery history is now saved per Unity project instead of as a shared editor-wide list.
- Reopening the same Unity project keeps its recovery history available.
- Recovery history is capped to the latest 20 successful restores.
- Updated the VPM index so the active public package line points to 1.1.19.

Older release notes are available in [UPDATE_HISTORY.md](UPDATE_HISTORY.md).

## License

AvatarRecovery v1.1.0 and later are distributed under the AvatarRecovery Custom License. See `LICENSE`.

Earlier AvatarRecovery releases published under the MIT License remain governed by their original license terms.

AssetRipper and SARS are separate projects governed by their own licenses. For AssetRipper, AvatarRecovery bundles only AssetRipper.exe and the related files required for it to run. AssetRipper and SARS source code are not included.

## Ethical Use

Use this tool only for files you have the right to inspect or recover, such as assets you created or legitimately purchased, assets you own as backups, or assets you are explicitly authorized to maintain.

Do not use this tool to steal, clone, extract, modify, redistribute, resell, re-upload, or impersonate another creator's work.

## Rebuild

Maintainer-only example:

```powershell
powershell -ExecutionPolicy Bypass -File .\BuildVpmRepository.ps1 `
  -ProjectRoot "<path-to-UnityProject>" `
  -BaseUrl "https://nickel-jp.github.io/avatar-recovery-unity"
```

Rebuilding updates `index.json` and package metadata locally. Commit, push, and GitHub Pages publication are separate maintainer actions.

## Maintainer Security

Protected releases are built locally. GitHub Actions intentionally stays lightweight: `.github/workflows/verify-build.yml` performs PowerShell syntax checks, runs the protection self tests against the checked-in public package, and audits the GitHub Pages artifacts through `Invoke-PublishedReleaseAudit.ps1`. Full protected-build reproduction is not run in CI because it would require Unity licensing, VRChat SDK setup, private source workspace state, and signing material.

The release process validates distribution artifacts and rejects unintended sensitive data before publication. Implementation details are maintained in private audit records.

Maintainers should use GitHub Vigilant Mode and signed commits for protection-pipeline changes. Configure either GPG or SSH commit signing with a key registered in GitHub's `SSH and GPG keys` settings, then enable signing:

```powershell
git config --global commit.gpgsign true
# For SSH signing:
git config --global gpg.format ssh
git config --global user.signingkey "<path-to-your-public-ssh-key>"
```

Commits that modify `BuildProtectedAvatarRecoveryPackage.ps1`, `Build/`, `.github/workflows/`, or published package artifacts should show GitHub's `Verified` badge.
