# Public package regression tests

This suite exercises the distributed AvatarRecovery 1.2.21 Editor package. It creates synthetic inputs at runtime and does not require product source, private test helpers, or avatar files.

## Requirements

- Windows, PowerShell 7.2 or newer, Git, and a licensed Unity 2022.3.22f1 installation.
- Network access to the official VRChat SDK releases, Unity Package Manager, and the pinned CoplayDev Unity MCP package. A live MCP connection is not required.
- A writable `G:\UnityTest` directory. The runner creates a dedicated project and refuses existing projects without its own marker. It never closes an already running user Editor.

The package ZIP and DLL hashes are fixed in the runner and tests. VRChat Base/Avatars 3.10.5 downloads are hash-checked before extraction. Unity Test Framework 1.1.33 and CoplayDev Unity MCP v10.1.2 are declared explicitly. A different package version needs its own reviewed test baseline; changing only a displayed version is insufficient.

## Run locally

From the repository root, use PowerShell 7:

```powershell
.\Build\Invoke-PublicUnityTests.ps1 `
  -ProjectPath 'G:\UnityTest\AvatarRecovery-1.2.21-PublicValidation' `
  -UnityPath 'C:\Program Files\Unity\Hub\Editor\2022.3.22f1\Editor\Unity.exe'
```

Use `-PrepareOnly` to create the project without starting Unity. The normal command runs the `AvatarRecovery.PublicTests` EditMode assembly with `-batchmode -nographics -runTests`. It fails if Unity returns an error, XML is absent, no tests run, a test fails, or a test is skipped.

Each run writes a new directory below `.work/PublicUnityTests/`. `results.xml`, `summary.json`, and `unity.log` are the shareable evidence files. The summary identifies the package ZIP, DLL, Unity version, dependency versions, counts, and XML hash. Files named `*.raw.*` are local diagnostics and should not be uploaded. Log sanitization removes known local paths and licensing identifiers; review additional diagnostics before sharing them.

## Coverage

The 35 test cases cover render-queue labels and boundary values, shader reassignment, selection behavior, persistence of material properties and texture references after reimport, repeated assignment, unknown queues, missing shaders, CSV version-label preservation, older CSV columns, and empty input. The checks call the packaged Editor behavior and inspect the resulting assets.

This is not the historical 517-test suite. It does not cover real-avatar recovery, original shader-file version extraction, GUI appearance, SDK lower-bound decisions, or recovery from an operating-system file-write denial. Historical local tests using private input remain separate evidence.

## GitHub Actions

The standard `verify-build.yml` workflow runs repository consistency, package self-tests, and signed update-metadata verification on a GitHub-hosted Windows runner. It is independent of the Unity suite.

`unity-public-tests.yml` runs the same public Unity script and publishes XML, a hash-linked summary, and the sanitized Unity log. It is intentionally an owner-triggered `workflow_dispatch` on `main`, using the selected commit. Public pull-request code is not automatically executed on a local computer.

Before dispatching it, supply a Windows x64 runner labeled `avatar-recovery-unity-2022` with PowerShell 7, licensed Unity 2022.3.22f1 at the default path, and `G:\UnityTest`. A runner must actually be online; adding this workflow does not itself provision or validate one. A one-job ephemeral runner can be used instead of installing a persistent service. Treat the workflow run as successful only when the Unity job ran and its artifact summary reports every test passed.

## Distribution checks

```powershell
.\Build\Test-PublicRepository.ps1
.\Build\Tests\Test-PublicRepository.Tests.ps1
.\Build\Test-UpdateManifest.ps1
```

These checks reject disagreement between the first version entry in the README, CI, package manifests, index, and update metadata. They also reject reintroduced 1.3.x ZIP/signature files, missing or mismatched indexed packages, and a package directory above 800,000,000 bytes. Signature verification includes modified-signature rejection cases. None of these checks substitutes for Unity functional testing.
