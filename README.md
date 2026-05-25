# Avatar Recovery Unity

VPM repository for `com.nickel-jp.avatar-recovery`.

## Install

Add this repository URL to VRChat Creator Companion:

```text
https://nickel-jp.github.io/avatar-recovery-unity/index.json
```

One-click VCC URL:

```text
vcc://vpm/addRepo?url=https%3A%2F%2Fnickel-jp.github.io%2Favatar-recovery-unity%2Findex.json
```

After adding the repository, install `Avatar Recovery` from the VCC package list.

## Rebuild

```powershell
powershell -ExecutionPolicy Bypass -File .\BuildVpmRepository.ps1 -ProjectRoot "C:\VRChatProjects\tttt" -BaseUrl "https://nickel-jp.github.io/avatar-recovery-unity"
```

If the GitHub Pages URL changes, rebuild with the new `-BaseUrl` before publishing.
