# AvatarRecovery 1.1.5 Protection Exclusions

This document records why specific names or strings are preserved for the first protected 1.1.5 release.

## Public API Kept

- `EditorTools.AvatarRecovery.AvatarRecoveryWindow`: Unity `EditorWindow` entry point and menu-opened window.
- `EditorTools.AvatarRecovery.ShaderListViewerWindow`: Unity `EditorWindow` entry point and menu-opened window.
- `EditorTools.AvatarRecovery.ViewAssetsInfoWindow`: Unity `EditorWindow` entry point opened from the tool UI.
- `EditorTools.AvatarRecovery.VrcaAutoBackupPreprocess`: VRC SDK `IVRCSDKPreprocessAvatarCallback` TypeCache/callback target.
- `EditorTools.AvatarRecovery.VrcaAutoBackupPostprocess`: VRC SDK `IVRCSDKPostprocessAvatarCallback` TypeCache/callback target.
- `EditorTools.AvatarRecovery.VrcaAutoBackupSdkCallback`: VRC SDK `IVRCSDKBuildRequestedCallback` TypeCache/callback target.

## Public Types Reduced

The following non-entry types were changed from public to internal because they are used only inside the single `EditorTools.AvatarRecovery.Editor` assembly:

- `AvatarRecoveryEnvChecker`
- `EditorPrefsHelper`
- `VrcaAutoBackup`
- `AppLanguage`
- `LS`
- `Loc`
- `VrcaLoader`
- `VrcaFileType`
- `VrcaPlatform`
- `VrcaUnityVersion`
- `VrcaFileInfo`
- `PoseResetter`
- `VrcaExtractor`
- `ShaderRemapper`
- `MissingScriptDeletePolicy`
- `MissingScriptCleaner`
- `ScriptGuidFixer`
- `ShaderGuidFixer`
- `AvatarRecoveryValidators`
- `AssetRipperBridge`
- `GestureLayerMaskFixer`
- `ShaderListWriter`

`ViewAssetsInfoWindow.Open(VrcaFileInfo)` was changed from public to internal because `VrcaFileInfo` is now internal.

## Obfuscar Name Exclusions

- Unity magic methods are skipped globally: `OnGUI`, `OnEnable`, `OnDisable`, `OnDestroy`, `OnFocus`, `OnLostFocus`, `OnHierarchyChange`, `OnProjectChange`, `OnSelectionChange`, `OnInspectorUpdate`, `CreateGUI`, `Update`, `Awake`, `OnValidate`, `Reset`.
- Methods with Unity attributes are skipped because Unity resolves them by attribute and often by method metadata.
- EditorWindow types are skipped as whole types, including methods, properties, fields, and events, for the first protected release to avoid empty or unresponsive windows and Unity serialized field-name collisions after Domain Reload.
- VRC SDK callback classes are skipped as whole types, including members, because VRC SDK discovers callback implementers through TypeCache.
- Enum fields are skipped so stored/displayed enum names remain stable when `ToString()` or inspector names are used.
- Protected DLL builds fail if an EditorWindow type contains duplicate field names after obfuscation. This guards `AvatarRecoveryWindow`, `ShaderListViewerWindow`, and `ViewAssetsInfoWindow` against Unity's `The same field name is serialized multiple times` warning.
- Runtime integrity guard calls are injected only into `Build/RuntimeIntegrityGuardTargets.txt` entries before Obfuscar. The generated guard source is internal and uses Unity `InitializeOnLoad` to cache trust state without making a public API.
- Cecil control-flow obfuscation is intentionally limited to `Build/ControlFlowObfuscationAllowlist.txt` entries and skips constructors, native/abstract methods, and methods with exception handlers. Problem methods should be removed from the allowlist rather than patched around ad hoc.

## Reflection And Serialization Contracts

`Build/ReflectionSerializationAllowlist.txt` records detected reflection, Unity serialization, EditorPrefs, and UI Toolkit name-reference contracts. New unlisted hits fail the protected build.

No UXML or USS files are currently present under the source package, so there are no UI Toolkit `binding-path`, `name`, or `type` contracts to preserve in 1.1.5.

## Leak And Secret Rules

The package ZIP must not include source, symbols, PFX/P12/private keys, mapping files, rename reports, Obfuscar reports, or PEM files. Public certificate files are published outside the ZIP as verification material only.

Legitimate runtime strings such as `Assets/`, `Packages/`, `.vrca`, `.vrcw`, and `.vrcp` are allowlisted in `Build/BinaryLeakAllowlist.txt`; local absolute paths, PFX paths, private key markers, and signing passwords are never allowlisted.
