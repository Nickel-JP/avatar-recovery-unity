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
VCC can choose versions listed in this repository. The public index is currently limited to the active supported release.

## Public Verification

The current protected package is `com.nickel-jp.avatar-recovery-1.1.17.zip`.
After downloading the ZIP, verify the published hash before importing it:

```powershell
# 1. ZIP のハッシュ検証
(Get-FileHash .\com.nickel-jp.avatar-recovery-1.1.17.zip -Algorithm SHA256).Hash

# checksums/com.nickel-jp.avatar-recovery-1.1.17.sha256.txt の
# packages/com.nickel-jp.avatar-recovery-1.1.17.zip 行と一致すること
```

To verify the signed DLL, extract the package and compare the signer thumbprint with the published certificate:

```powershell
Expand-Archive .\com.nickel-jp.avatar-recovery-1.1.17.zip -DestinationPath .\avatar-recovery-verify -Force
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
