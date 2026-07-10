# AvatarRecovery Unity

VPM repository for `com.nickel-jp.avatar-recovery`.

AvatarRecovery は、VRChat の `.vrca` / `.vrcw` / `.vrcp` AssetBundle を Unity Editor 内で確認し、許可された範囲で Unity プロジェクトへ復元するための Editor 拡張です。

AssetRipper.exe を外部プロセスとして呼び出し、その後に AvatarRecovery 独自の C# 後処理で Script GUID、Shader GUID、Missing Script、Prefab 選択、Pose Reset の安全確認を補助します。AssetRipper 本体と SARS ソースコードは同梱していません。

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

The current protected package is `com.nickel-jp.avatar-recovery-1.2.0.zip`.
After downloading the ZIP, verify the published hash before importing it:

```powershell
# 1. ZIP のハッシュ検証
(Get-FileHash .\com.nickel-jp.avatar-recovery-1.2.0.zip -Algorithm SHA256).Hash

# checksums/com.nickel-jp.avatar-recovery-1.2.0.sha256.txt の
# packages/com.nickel-jp.avatar-recovery-1.2.0.zip 行と一致すること
```

To verify the signed DLL, extract the package and compare the signer thumbprint with the published certificate:

```powershell
Expand-Archive .\com.nickel-jp.avatar-recovery-1.2.0.zip -DestinationPath .\avatar-recovery-verify -Force
$dll = ".\avatar-recovery-verify\Editor\EditorTools.AvatarRecovery.Editor.dll"
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(".\certificates\avatar-recovery-self-signed-code-signing.cer")

# 2. DLL の Authenticode 署名検証
$signature = Get-AuthenticodeSignature $dll
$signature

# SignerCertificate.Thumbprint が certificates/ の証明書と一致すること
($signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
($cert.Thumbprint -replace '\s', '').ToUpperInvariant()
```

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

### Version 1.2.0 — Protected Recovery Core and Failure Guidance

- Isolated the main AssetBundle parsing, GUID conflict detection, Prefab selection, and import path decisions into internal recovery-core classes while preserving the existing recovery workflow.
- Expanded string encryption, control-flow obfuscation, anti-decompile hardening, and runtime-integrity coverage for the main recovery path.
- Added failure dialogs that show the failure reason and a recommended resolution when extraction, recovery, or automatic backup processing cannot continue.
- Stabilized runtime-integrity sidecar discovery during Unity startup and hardened the protection build so unmatched or skipped protection targets fail the release build.
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

## Maintainer Security

Protected releases are built locally. GitHub Actions intentionally stays lightweight: `.github/workflows/verify-build.yml` performs PowerShell syntax checks, runs the protection self tests against the checked-in public package, and audits the GitHub Pages artifacts through `Invoke-PublishedReleaseAudit.ps1`. Full protected-build reproduction is not run in CI because it would require Unity licensing, VRChat SDK setup, private source workspace state, and signing material.

Maintainers should use GitHub Vigilant Mode and signed commits for protection-pipeline changes. Configure either GPG or SSH commit signing with a key registered in GitHub's `SSH and GPG keys` settings, then enable signing:

```powershell
git config --global commit.gpgsign true
# For SSH signing:
git config --global gpg.format ssh
git config --global user.signingkey "<path-to-your-public-ssh-key>"
```

Commits that modify `BuildProtectedAvatarRecoveryPackage.ps1`, `Build/`, `.github/workflows/`, or published package artifacts should show GitHub's `Verified` badge.
