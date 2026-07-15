# AvatarRecovery Unity

VPM repository for `com.nickel-jp.avatar-recovery`.

AvatarRecovery is a Unity Editor extension for inspecting VRChat `.vrca`, `.vrcw`, and `.vrcp` AssetBundles and recovering their contents into a Unity project when you have permission to do so.

AvatarRecovery launches `AssetRipper.exe` as an external process, then applies its own C# post-processing to help safely restore script and shader GUIDs, handle missing scripts, select the appropriate prefab, and reset poses. AssetRipper itself and the SARS source code are not included.

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
VCC and ALCOM can choose versions listed in this repository. The public index is currently limited to the active supported release.

## Public Verification

The current protected package is `com.nickel-jp.avatar-recovery-1.2.5.zip`.
After downloading the ZIP, verify the published hash before importing it:

```powershell
# 1. Calculate the ZIP SHA-256 hash.
(Get-FileHash .\com.nickel-jp.avatar-recovery-1.2.5.zip -Algorithm SHA256).Hash

# Confirm that it matches the packages/com.nickel-jp.avatar-recovery-1.2.5.zip entry in
# checksums/com.nickel-jp.avatar-recovery-1.2.5.sha256.txt.
```

To verify the signed DLL, extract the package and compare the signer thumbprint with the published certificate:

```powershell
Expand-Archive .\com.nickel-jp.avatar-recovery-1.2.5.zip -DestinationPath .\avatar-recovery-verify -Force
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
| Unity | Unity 2022.3.x |
| VRChat SDK | `com.vrchat.base >=3.7.0 <3.11.0` |
| Package ID | `com.nickel-jp.avatar-recovery` |
| Target OS | Windows 10 / 11 |
| External extractor | AssetRipper.exe, obtained separately by the user |
| License | AvatarRecovery Custom License |

Avatar projects should install `VRChat SDK - Avatars`; world projects should install `VRChat SDK - Worlds`. Keep VRChat SDK packages on the same version line.

## Update History

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

AssetRipper and SARS are separate projects governed by their own licenses. AvatarRecovery does not bundle AssetRipper binaries or SARS source code.

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
