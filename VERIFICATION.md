# Verify an AvatarRecovery download

Download the ZIP and its matching SHA-256 checksum file from the [AvatarRecovery GitHub Releases](https://github.com/Nickel-JP/avatar-recovery-unity/releases). Obtain the expected checksum and signer certificate through a trusted source.

Save the ZIP and the [published code-signing certificate](certificates/avatar-recovery-self-signed-code-signing.cer) in the same folder. Open PowerShell in that folder and set the version to match the ZIP you downloaded.

## Check the ZIP checksum

```powershell
$version = '2.0.2'
$zip = "com.nickel-jp.avatar-recovery-$version.zip"
Get-FileHash -LiteralPath $zip -Algorithm SHA256
```

Compare the hash with the ZIP entry in the checksum file. Use the package only if the hashes match.

## Check the DLL signature

Run these commands in the same PowerShell session. Use a new folder name if the extraction folder already exists.

```powershell
$out = '.\avatar-recovery-verify'
Expand-Archive -LiteralPath $zip -DestinationPath $out
$dllName = 'Editor\EditorTools.AvatarRecovery.Editor.dll'
$dll = Join-Path $out $dllName
$certPath = Resolve-Path 'avatar-recovery-self-signed-code-signing.cer'
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath.Path)
$signature = Get-AuthenticodeSignature -FilePath $dll
$signature | Select-Object Status, StatusMessage
$signature.SignerCertificate.Thumbprint
$cert.Thumbprint
```

The two thumbprints must match. A self-signed certificate may show as untrusted on Windows. A missing signature, a hash mismatch, or a different signer means the check failed.

## Maintainer Commands

Run the rebuild command from the repository root. The settings below are for maintainers who sign release-related commits.

### Rebuild

```powershell
powershell -ExecutionPolicy Bypass -File .\BuildVpmRepository.ps1 `
  -ProjectRoot "<path-to-UnityProject>" `
  -BaseUrl "https://nickel-jp.github.io/avatar-recovery-unity"
```

### Enable signed commits

```powershell
git config --global commit.gpgsign true
# For SSH signing:
git config --global gpg.format ssh
git config --global user.signingkey "<path-to-your-public-ssh-key>"
```
