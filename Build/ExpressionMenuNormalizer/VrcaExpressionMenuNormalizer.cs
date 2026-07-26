using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

using AssetsTools.NET;
using AssetsTools.NET.Extra;
using AssetsTools.NET.Texture;

namespace AvatarRecovery.Tools.ExpressionMenuNormalizer
{
    internal static class VrcaExpressionMenuNormalizer
    {
        private const int MonoBehaviourClassId = 114;
        private const int MonoScriptClassId = 115;
        private const int MeshClassId = 43;
        private const int Texture2DClassId = 28;
        private const int SubMenuControlType = 103;
        private const string MenuScriptName = "VRCExpressionsMenu";
        private const string MenuClassName = "VRCExpressionsMenu";
        private const string MenuNamespace = "VRC.SDK3.Avatars.ScriptableObjects";
        private const string AvatarDescriptorScriptName =
            "VRCAvatarDescriptor";
        private const string AvatarDescriptorClassName =
            "VRCAvatarDescriptor";
        private const string AvatarDescriptorNamespace =
            "VRC.SDK3.Avatars.Components";
        private const string MenuAssemblyName = "VRCSDK3A.dll";
        private const string InjectedNamePrefix = "AR_ExpressionMenu_";
        private const int MaximumTextureDimension = 16_384;
        private const long MaximumDecodedTextureBytes =
            256L * 1024L * 1024L;
        private const long MaximumEncodedTextureBytes =
            256L * 1024L * 1024L;

        public static NormalizationResult Normalize(CommandLineOptions options)
        {
            string sourceSha256 = FingerprintUtility.ComputeFileSha256(options.InputPath);
            SourceSnapshot snapshot = null;
            string partialOutputPath = null;

            try
            {
                snapshot = InspectAndPrepareSource(options);
                if (snapshot.Candidates.Count == 0)
                {
                    VerifySourceUnchanged(options.InputPath, sourceSha256);
                    return new NormalizationResult
                    {
                        SchemaVersion = 1,
                        Status = "unchanged",
                        SourceSha256 = sourceSha256,
                        OutputSha256 = null,
                        CandidateCount = 0,
                        RenamedCount = 0,
                        MenuCountBefore = snapshot.MenuCount,
                        MenuCountAfter = snapshot.MenuCount,
                        MeshCount = snapshot.MeshCount,
                        ControlCount = snapshot.ControlCount,
                        SubMenuControlCount =
                            snapshot.SubMenuControlCount,
                        IconReferenceCount =
                            snapshot.IconReferenceCount,
                        ParameterReferenceCount =
                            snapshot.ParameterReferenceCount,
                        SubParameterCount =
                            snapshot.SubParameterCount,
                        LabelCount = snapshot.LabelCount,
                        LabelIconReferenceCount =
                            snapshot.LabelIconReferenceCount,
                        MenuGraphSha256 =
                            snapshot.MenuGraphSha256,
                        Message = "AssetRipperで処理可能なMenuのみのため、正規化は不要です。"
                    };
                }

                string outputDirectory = Path.GetDirectoryName(options.OutputPath);
                if (string.IsNullOrEmpty(outputDirectory))
                {
                    throw new NormalizerException(
                        ExitCode.InvalidInput,
                        "出力先ディレクトリを解決できません: " + options.OutputPath);
                }

                Directory.CreateDirectory(outputDirectory);
                partialOutputPath = Path.Combine(
                    outputDirectory,
                    Path.GetFileName(options.OutputPath)
                    + ".partial."
                    + Guid.NewGuid().ToString("N"));

                WriteNormalizedBundle(options, snapshot, partialOutputPath);
                VerifySourceUnchanged(options.InputPath, sourceSha256);

                int menuCountAfter = VerifyNormalizedBundle(
                    options.ClassPackagePath,
                    partialOutputPath,
                    snapshot);

                string outputSha256 = FingerprintUtility.ComputeFileSha256(partialOutputPath);
                if (File.Exists(options.OutputPath))
                {
                    throw new NormalizerException(
                        ExitCode.WriteFailure,
                        "検証中に出力先ファイルが作成されたため、上書きを中止しました: "
                        + options.OutputPath);
                }

                File.Move(partialOutputPath, options.OutputPath);
                partialOutputPath = null;

                return new NormalizationResult
                {
                    SchemaVersion = 1,
                    Status = "normalized",
                    SourceSha256 = sourceSha256,
                    OutputSha256 = outputSha256,
                    CandidateCount = snapshot.Candidates.Count,
                    RenamedCount = snapshot.Candidates.Count,
                    MenuCountBefore = snapshot.MenuCount,
                    MenuCountAfter = menuCountAfter,
                    MeshCount = snapshot.MeshCount,
                    ControlCount = snapshot.ControlCount,
                    SubMenuControlCount =
                        snapshot.SubMenuControlCount,
                    IconReferenceCount =
                        snapshot.IconReferenceCount,
                    ParameterReferenceCount =
                        snapshot.ParameterReferenceCount,
                    SubParameterCount =
                        snapshot.SubParameterCount,
                    LabelCount = snapshot.LabelCount,
                    LabelIconReferenceCount =
                        snapshot.LabelIconReferenceCount,
                    MenuGraphSha256 =
                        snapshot.MenuGraphSha256,
                    Message = string.Format(
                        CultureInfo.InvariantCulture,
                        "無名のVRCExpressionsMenuを{0}件正規化し、非対象Assetと参照の不変性を検証しました。",
                        snapshot.Candidates.Count)
                };
            }
            finally
            {
                if (snapshot != null && snapshot.PreparedManager != null)
                {
                    try
                    {
                        snapshot.PreparedManager.UnloadAll(true);
                    }
                    catch (Exception exception)
                    {
                        Log.Error(
                            "AssetsTools.NETリソースの解放に失敗しました: "
                            + exception.Message);
                    }

                    snapshot.PreparedManager = null;
                    snapshot.PreparedBundle = null;
                }

                if (partialOutputPath != null && File.Exists(partialOutputPath))
                {
                    try
                    {
                        File.Delete(partialOutputPath);
                    }
                    catch (Exception exception)
                    {
                        Log.Error("一時出力の削除に失敗しました: " + exception.Message);
                    }
                }
            }
        }

        private static SourceSnapshot InspectAndPrepareSource(CommandLineOptions options)
        {
            AssetsManager manager = new AssetsManager();
            try
            {
                LoadClassPackage(manager, options.ClassPackagePath, ExitCode.ParseFailure);
                BundleFileInstance bundle;
                try
                {
                    bundle = manager.LoadBundleFile(options.InputPath, true);
                }
                catch (Exception exception)
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "入力VRCAをAssetBundleとして読み込めません。",
                        exception);
                }

                if (bundle == null || bundle.file == null)
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "入力VRCAのAssetBundle情報を取得できません。");
                }

                SourceSnapshot snapshot = new SourceSnapshot
                {
                    CompressionType = bundle.file.GetCompressionType()
                };

                IList<string> entryNames = bundle.file.GetAllFileNames();
                List<LoadedAssetsEntry> loadedAssetsEntries =
                    new List<LoadedAssetsEntry>();
                bool hasUnnamedMenuCandidate = false;
                for (int entryIndex = 0; entryIndex < entryNames.Count; entryIndex++)
                {
                    string entryName = entryNames[entryIndex];
                    bool isAssetsFile = bundle.file.IsAssetsFile(entryIndex);
                    snapshot.BundleEntries.Add(new BundleEntrySnapshot(
                        entryIndex,
                        entryName,
                        isAssetsFile));

                    if (!isAssetsFile)
                    {
                        long offset;
                        long length;
                        bundle.file.GetFileRange(entryIndex, out offset, out length);
                        snapshot.NonAssetsEntryHashes.Add(
                            entryIndex,
                            FingerprintUtility.ComputeStreamSha256(
                                bundle.DataStream,
                                offset,
                                length));
                        continue;
                    }

                    AssetsFileInstance assetsInstance;
                    try
                    {
                        assetsInstance = manager.LoadAssetsFileFromBundle(bundle, entryIndex, false);
                    }
                    catch (Exception exception)
                    {
                        throw new NormalizerException(
                            ExitCode.ParseFailure,
                            "SerializedFileを読み込めません: " + entryName,
                            exception);
                    }

                    if (assetsInstance == null || assetsInstance.file == null)
                    {
                        throw new NormalizerException(
                            ExitCode.ParseFailure,
                            "SerializedFile情報を取得できません: " + entryName);
                    }

                    LoadMatchingClassDatabase(
                        manager,
                        assetsInstance,
                        ExitCode.ParseFailure,
                        entryName);

                    Dictionary<long, MonoScriptIdentity> scripts =
                        ReadMonoScripts(
                            manager,
                            assetsInstance);
                    if (ContainsUnnamedExpressionMenuCandidate(
                        manager,
                        assetsInstance,
                        entryName,
                        scripts))
                    {
                        hasUnnamedMenuCandidate = true;
                    }

                    loadedAssetsEntries.Add(
                        new LoadedAssetsEntry(
                            entryIndex,
                            entryName,
                            assetsInstance,
                            scripts));
                }

                if (loadedAssetsEntries.Count == 0)
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "VRCA内にSerializedFileが見つかりません。");
                }

                foreach (LoadedAssetsEntry loadedEntry in
                         loadedAssetsEntries)
                {
                    LoadMatchingClassDatabase(
                        manager,
                        loadedEntry.AssetsInstance,
                        ExitCode.ParseFailure,
                        loadedEntry.EntryName);

                    AssetsFileSnapshot assetsSnapshot = InspectAssetsFile(
                        manager,
                        loadedEntry.AssetsInstance,
                        loadedEntry.EntryIndex,
                        loadedEntry.EntryName,
                        true,
                        hasUnnamedMenuCandidate,
                        loadedEntry.Scripts);
                    snapshot.AssetsFiles.Add(assetsSnapshot);
                    snapshot.MenuCount += assetsSnapshot.Menus.Count;
                    snapshot.MeshCount += assetsSnapshot.MeshCount;
                    snapshot.ControlCount +=
                        assetsSnapshot.ControlCount;
                    snapshot.SubMenuControlCount +=
                        assetsSnapshot.SubMenuControlCount;
                    snapshot.IconReferenceCount +=
                        assetsSnapshot.IconReferenceCount;
                    snapshot.ParameterReferenceCount +=
                        assetsSnapshot.ParameterReferenceCount;
                    snapshot.SubParameterCount +=
                        assetsSnapshot.SubParameterCount;
                    snapshot.LabelCount +=
                        assetsSnapshot.LabelCount;
                    snapshot.LabelIconReferenceCount +=
                        assetsSnapshot.LabelIconReferenceCount;
                    snapshot.Candidates.AddRange(assetsSnapshot.Candidates);
                }

                if (hasUnnamedMenuCandidate !=
                    (snapshot.Candidates.Count > 0))
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "無名VRCExpressionsMenuの事前判定と詳細解析の結果が一致しません。");
                }

                if (snapshot.Candidates.Count == 0)
                {
                    return snapshot;
                }

                PrepareCanonicalMenuGraph(snapshot);
                snapshot.MenuGraphSha256 =
                    ComputeMenuGraphSha256(
                        GetAllMenus(snapshot),
                        snapshot.RootMenuName,
                        true);

                foreach (AssetsFileSnapshot assetsSnapshot in snapshot.AssetsFiles)
                {
                    CaptureNonTargetAssetHashes(assetsSnapshot);

                    if (!assetsSnapshot.HasModifications)
                    {
                        continue;
                    }

                    bundle.file.BlockAndDirInfo.DirectoryInfos[assetsSnapshot.EntryIndex]
                        .SetNewData(assetsSnapshot.AssetsInstance.file);
                }

                snapshot.PreparedManager = manager;
                snapshot.PreparedBundle = bundle;
                manager = null;
                return snapshot;
            }
            finally
            {
                if (manager != null)
                {
                    manager.UnloadAll(true);
                }
            }
        }

        private static AssetsFileSnapshot InspectAssetsFile(
            AssetsManager manager,
            AssetsFileInstance assetsInstance,
            int entryIndex,
            string entryName,
            bool applyRenames,
            bool resolveTextureStableIds,
            Dictionary<long, MonoScriptIdentity> scripts)
        {
            AssetsFileSnapshot snapshot = new AssetsFileSnapshot(
                entryIndex,
                entryName,
                assetsInstance);
            snapshot.MetadataFingerprint =
                ComputeAssetsMetadataFingerprint(
                    assetsInstance.file);

            if (scripts == null)
            {
                throw new ArgumentNullException(nameof(scripts));
            }

            Dictionary<long, AssetFileInfo> assetsByPathId =
                BuildAssetInfoLookup(assetsInstance.file);
            Dictionary<long, string> textureStableIds =
                resolveTextureStableIds
                    ? new Dictionary<long, string>()
                    : null;

            foreach (AssetFileInfo info in assetsInstance.file.GetAssetsOfType(MonoBehaviourClassId))
            {
                AssetTypeValueField baseField;
                try
                {
                    baseField = manager.GetBaseField(
                        assetsInstance,
                        info,
                        AssetReadFlags.SkipMonoBehaviourFields);
                }
                catch (Exception exception)
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "MonoBehaviourを安全に解析できません。entry="
                        + entryName
                        + ", pathID="
                        + info.PathId.ToString(CultureInfo.InvariantCulture),
                        exception);
                }

                TryCaptureAvatarDescriptorRoot(
                    info,
                    baseField,
                    entryIndex,
                    entryName,
                    scripts,
                    snapshot);

                MenuRecord menu;
                if (!TryCreateMenuRecord(
                    manager,
                    assetsInstance,
                    assetsInstance.file,
                    info,
                    baseField,
                    entryIndex,
                    entryName,
                    scripts,
                    assetsByPathId,
                    textureStableIds,
                    resolveTextureStableIds,
                    out menu))
                {
                    continue;
                }

                snapshot.Menus.Add(menu);
                snapshot.ControlCount += menu.ControlCount;
                snapshot.SubMenuControlCount +=
                    menu.SubMenuControlCount;
                snapshot.IconReferenceCount +=
                    menu.IconReferenceCount;
                snapshot.ParameterReferenceCount +=
                    menu.ParameterReferenceCount;
                snapshot.SubParameterCount +=
                    menu.SubParameterCount;
                snapshot.LabelCount += menu.LabelCount;
                snapshot.LabelIconReferenceCount +=
                    menu.LabelIconReferenceCount;
                if (menu.OriginalName.Length != 0)
                {
                    continue;
                }

                if (!applyRenames)
                {
                    snapshot.Candidates.Add(menu);
                    continue;
                }

                string expectedName = CreateInjectedName(entryIndex, info.PathId);
                menu.ExpectedName = expectedName;
                menu.BaseField["m_Name"].AsString = expectedName;

                string nonNameAfterEdit = FingerprintUtility.ComputeFieldFingerprint(
                    menu.BaseField,
                    true);
                if (!string.Equals(
                    menu.NonNameFingerprint,
                    nonNameAfterEdit,
                    StringComparison.Ordinal))
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "m_Name以外のフィールドが編集時に変化しました: " + menu.Key);
                }

                info.SetNewData(menu.BaseField);
                snapshot.Candidates.Add(menu);
                snapshot.HasModifications = true;
            }

            foreach (AssetFileInfo info in assetsInstance.file.AssetInfos)
            {
                int typeId = info.GetTypeId(assetsInstance.file);
                AssetKey key = new AssetKey(entryIndex, entryName, info.PathId, typeId);
                if (!snapshot.AllAssets.Add(key))
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "SerializedFile内で重複するAsset識別子を検出しました: " + key);
                }

                if (typeId == MeshClassId)
                {
                    snapshot.MeshCount++;
                }
            }

            return snapshot;
        }

        private static void CaptureNonTargetAssetHashes(
            AssetsFileSnapshot snapshot)
        {
            HashSet<AssetKey> candidateKeys = new HashSet<AssetKey>();
            foreach (MenuRecord candidate in snapshot.Candidates)
            {
                candidateKeys.Add(candidate.Key);
            }

            foreach (AssetFileInfo info in snapshot.AssetsInstance.file.AssetInfos)
            {
                int typeId = info.GetTypeId(snapshot.AssetsInstance.file);
                AssetKey key = new AssetKey(
                    snapshot.EntryIndex,
                    snapshot.EntryName,
                    info.PathId,
                    typeId);
                if (candidateKeys.Contains(key))
                {
                    continue;
                }

                snapshot.NonTargetAssetHashes.Add(
                    key,
                    FingerprintUtility.ComputeStreamSha256(
                        snapshot.AssetsInstance.AssetsStream,
                        info.GetAbsoluteByteOffset(
                            snapshot.AssetsInstance.file),
                        info.ByteSize));
            }
        }

        private static Dictionary<long, MonoScriptIdentity> ReadMonoScripts(
            AssetsManager manager,
            AssetsFileInstance assetsInstance)
        {
            Dictionary<long, MonoScriptIdentity> scripts =
                new Dictionary<long, MonoScriptIdentity>();

            foreach (AssetFileInfo info in assetsInstance.file.GetAssetsOfType(MonoScriptClassId))
            {
                try
                {
                    AssetTypeValueField field = manager.GetBaseField(
                        assetsInstance,
                        info,
                        AssetReadFlags.None);
                    if (field == null || field.IsDummy)
                    {
                        throw new NormalizerException(
                            ExitCode.ParseFailure,
                            "MonoScriptの基底フィールドを取得できません。pathID="
                            + info.PathId.ToString(
                                CultureInfo.InvariantCulture));
                    }

                    MonoScriptIdentity identity = new MonoScriptIdentity(
                        GetRequiredString(field, "m_Name"),
                        GetRequiredString(field, "m_ClassName"),
                        GetRequiredString(field, "m_Namespace"),
                        GetRequiredString(field, "m_AssemblyName"));
                    scripts[info.PathId] = identity;
                }
                catch (Exception exception)
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "MonoScriptを安全に解析できません。pathID="
                        + info.PathId.ToString(CultureInfo.InvariantCulture),
                        exception);
                }
            }

            return scripts;
        }

        private static bool ContainsUnnamedExpressionMenuCandidate(
            AssetsManager manager,
            AssetsFileInstance assetsInstance,
            string entryName,
            IDictionary<long, MonoScriptIdentity> scripts)
        {
            foreach (AssetFileInfo info in
                     assetsInstance.file.GetAssetsOfType(
                         MonoBehaviourClassId))
            {
                AssetTypeValueField baseField;
                try
                {
                    baseField = manager.GetBaseField(
                        assetsInstance,
                        info,
                        AssetReadFlags.SkipMonoBehaviourFields);
                }
                catch (Exception exception)
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "MonoBehaviourの無名Menu事前判定に失敗しました。entry="
                        + entryName
                        + ", pathID="
                        + info.PathId.ToString(
                            CultureInfo.InvariantCulture),
                        exception);
                }

                if (baseField == null || baseField.IsDummy)
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "MonoBehaviourの基底フィールドを取得できません。entry="
                        + entryName
                        + ", pathID="
                        + info.PathId.ToString(
                            CultureInfo.InvariantCulture));
                }

                AssetTypeValueField gameObject =
                    baseField["m_GameObject"];
                AssetTypeValueField script =
                    baseField["m_Script"];
                AssetTypeValueField name =
                    baseField["m_Name"];
                if (gameObject == null ||
                    gameObject.IsDummy ||
                    script == null ||
                    script.IsDummy ||
                    name == null ||
                    name.IsDummy)
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "MonoBehaviourの共通フィールドが不足しています。entry="
                        + entryName
                        + ", pathID="
                        + info.PathId.ToString(
                            CultureInfo.InvariantCulture));
                }

                int gameObjectFileId;
                long gameObjectPathId;
                int scriptFileId;
                long scriptPathId;
                if (!TryReadPPtr(
                        gameObject,
                        out gameObjectFileId,
                        out gameObjectPathId) ||
                    !TryReadPPtr(
                        script,
                        out scriptFileId,
                        out scriptPathId))
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "MonoBehaviourの参照フィールドを解析できません。entry="
                        + entryName
                        + ", pathID="
                        + info.PathId.ToString(
                            CultureInfo.InvariantCulture));
                }

                if (gameObjectFileId != 0 ||
                    gameObjectPathId != 0)
                {
                    continue;
                }

                if (scriptFileId != 0 || scriptPathId == 0)
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "ScriptableObjectのMonoScript参照を同一SerializedFile内で解決できません。entry="
                        + entryName
                        + ", pathID="
                        + info.PathId.ToString(
                            CultureInfo.InvariantCulture));
                }

                MonoScriptIdentity identity;
                if (!scripts.TryGetValue(
                        scriptPathId,
                        out identity))
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "ScriptableObjectのMonoScript情報が見つかりません。entry="
                        + entryName
                        + ", pathID="
                        + info.PathId.ToString(
                            CultureInfo.InvariantCulture));
                }

                if (identity.IsExpressionsMenu &&
                    string.IsNullOrEmpty(name.AsString))
                {
                    return true;
                }
            }

            return false;
        }

        private static Dictionary<long, AssetFileInfo>
            BuildAssetInfoLookup(AssetsFile assetsFile)
        {
            Dictionary<long, AssetFileInfo> assetsByPathId =
                new Dictionary<long, AssetFileInfo>();
            foreach (AssetFileInfo info in assetsFile.AssetInfos)
            {
                if (assetsByPathId.ContainsKey(info.PathId))
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "SerializedFile内で重複するPathIDを検出しました: "
                        + info.PathId.ToString(
                            CultureInfo.InvariantCulture));
                }

                assetsByPathId.Add(info.PathId, info);
            }

            return assetsByPathId;
        }

        private static void TryCaptureAvatarDescriptorRoot(
            AssetFileInfo info,
            AssetTypeValueField baseField,
            int entryIndex,
            string entryName,
            IDictionary<long, MonoScriptIdentity> scripts,
            AssetsFileSnapshot snapshot)
        {
            if (baseField == null || baseField.IsDummy)
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "MonoBehaviourの基底フィールドを取得できません。entry="
                    + entryName
                    + ", pathID="
                    + info.PathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            AssetTypeValueField gameObject = baseField["m_GameObject"];
            AssetTypeValueField script = baseField["m_Script"];
            if (gameObject == null ||
                gameObject.IsDummy ||
                script == null ||
                script.IsDummy)
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "MonoBehaviourのDescriptor識別フィールドが不足しています。entry="
                    + entryName
                    + ", pathID="
                    + info.PathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            int gameObjectFileId;
            long gameObjectPathId;
            int scriptFileId;
            long scriptPathId;
            if (!TryReadPPtr(
                    gameObject,
                    out gameObjectFileId,
                    out gameObjectPathId) ||
                !TryReadPPtr(
                    script,
                    out scriptFileId,
                    out scriptPathId))
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "MonoBehaviourのDescriptor識別参照を解析できません。entry="
                    + entryName
                    + ", pathID="
                    + info.PathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            if (gameObjectFileId != 0 ||
                gameObjectPathId == 0 ||
                scriptFileId != 0 ||
                scriptPathId == 0)
            {
                return;
            }

            MonoScriptIdentity identity;
            if (!scripts.TryGetValue(scriptPathId, out identity) ||
                !identity.IsAvatarDescriptor)
            {
                return;
            }

            AssetTypeValueField customExpressions =
                baseField["customExpressions"];
            AssetTypeValueField expressionsMenu =
                baseField["expressionsMenu"];
            if (customExpressions == null ||
                customExpressions.IsDummy ||
                expressionsMenu == null ||
                expressionsMenu.IsDummy)
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "VRCAvatarDescriptorのExpression Menuフィールドが不足しています。entry="
                    + entryName
                    + ", pathID="
                    + info.PathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            if (!customExpressions.AsBool)
            {
                return;
            }

            int menuFileId;
            long menuPathId;
            ReadRequiredPPtr(
                expressionsMenu,
                "VRCAvatarDescriptor.expressionsMenu",
                entryName,
                info.PathId,
                out menuFileId,
                out menuPathId);
            if (menuFileId == 0 && menuPathId == 0)
            {
                return;
            }

            snapshot.DescriptorRootReferences.Add(
                new AssetReference(
                    entryIndex,
                    menuFileId,
                    menuPathId));
        }

        private static bool TryCreateMenuRecord(
            AssetsManager manager,
            AssetsFileInstance assetsInstance,
            AssetsFile assetsFile,
            AssetFileInfo info,
            AssetTypeValueField baseField,
            int entryIndex,
            string entryName,
            IDictionary<long, MonoScriptIdentity> scripts,
            IDictionary<long, AssetFileInfo> assetsByPathId,
            IDictionary<long, string> textureStableIds,
            bool resolveTextureStableIds,
            out MenuRecord menu)
        {
            menu = null;
            if (baseField == null || baseField.IsDummy)
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "MonoBehaviourの基底フィールドを取得できません。entry="
                    + entryName
                    + ", pathID="
                    + info.PathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            AssetTypeValueField gameObject = baseField["m_GameObject"];
            AssetTypeValueField script = baseField["m_Script"];
            AssetTypeValueField name = baseField["m_Name"];
            if (gameObject.IsDummy || script.IsDummy || name.IsDummy)
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "MonoBehaviourの共通フィールドが不足しています。entry="
                    + entryName
                    + ", pathID="
                    + info.PathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            int gameObjectFileId;
            long gameObjectPathId;
            int scriptFileId;
            long scriptPathId;
            if (!TryReadPPtr(gameObject, out gameObjectFileId, out gameObjectPathId)
                || !TryReadPPtr(script, out scriptFileId, out scriptPathId))
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "MonoBehaviourの参照フィールドを解析できません。entry="
                    + entryName
                    + ", pathID="
                    + info.PathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            if (gameObjectFileId != 0
                || gameObjectPathId != 0)
            {
                return false;
            }

            if (scriptFileId != 0 || scriptPathId == 0)
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "ScriptableObjectのMonoScript参照を同一SerializedFile内で解決できません。entry="
                    + entryName
                    + ", pathID="
                    + info.PathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            MonoScriptIdentity identity;
            if (!scripts.TryGetValue(scriptPathId, out identity))
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "ScriptableObjectのMonoScript情報が見つかりません。entry="
                    + entryName
                    + ", pathID="
                    + info.PathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            if (!identity.IsExpressionsMenu)
            {
                return false;
            }

            AssetTypeValueField controls = baseField["controls"];
            if (controls.IsDummy)
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "VRCExpressionsMenuにcontrolsフィールドがありません。entry="
                    + entryName
                    + ", pathID="
                    + info.PathId.ToString(CultureInfo.InvariantCulture));
            }

            MenuMetrics metrics = ReadMenuMetrics(
                manager,
                assetsInstance,
                assetsByPathId,
                textureStableIds,
                resolveTextureStableIds,
                entryIndex,
                controls,
                entryName,
                info.PathId);
            AssetKey key = new AssetKey(
                entryIndex,
                entryName,
                info.PathId,
                info.GetTypeId(assetsFile));
            menu = new MenuRecord
            {
                Key = key,
                BaseField = baseField,
                OriginalName = name.AsString ?? string.Empty,
                ExpectedName = name.AsString ?? string.Empty,
                ControlsFingerprint = FingerprintUtility.ComputeFieldFingerprint(controls, false),
                PPtrFingerprint = FingerprintUtility.ComputePPtrFingerprint(baseField),
                NonNameFingerprint = FingerprintUtility.ComputeFieldFingerprint(baseField, true),
                ControlCount = metrics.ControlCount,
                SubMenuControlCount =
                    metrics.SubMenuControlCount,
                IconReferenceCount =
                    metrics.IconReferenceCount,
                ParameterReferenceCount =
                    metrics.ParameterReferenceCount,
                SubParameterCount =
                    metrics.SubParameterCount,
                LabelCount = metrics.LabelCount,
                LabelIconReferenceCount =
                    metrics.LabelIconReferenceCount,
                Controls = metrics.Controls
            };
            return true;
        }

        private static MenuMetrics ReadMenuMetrics(
            AssetsManager manager,
            AssetsFileInstance assetsInstance,
            IDictionary<long, AssetFileInfo> assetsByPathId,
            IDictionary<long, string> textureStableIds,
            bool resolveTextureStableIds,
            int entryIndex,
            AssetTypeValueField controls,
            string entryName,
            long menuPathId)
        {
            MenuMetrics metrics = new MenuMetrics();
            IList<AssetTypeValueField> controlElements =
                GetRequiredArrayElements(
                    controls,
                    "controls",
                    entryName,
                    menuPathId);

            foreach (AssetTypeValueField control in controlElements)
            {
                AssetTypeValueField controlName =
                    GetRequiredField(control, "name", entryName, menuPathId);
                AssetTypeValueField icon =
                    GetRequiredField(control, "icon", entryName, menuPathId);
                AssetTypeValueField controlType =
                    GetRequiredField(control, "type", entryName, menuPathId);
                AssetTypeValueField subMenu =
                    GetRequiredField(control, "subMenu", entryName, menuPathId);
                AssetTypeValueField parameter =
                    GetRequiredField(control, "parameter", entryName, menuPathId);
                AssetTypeValueField parameterName =
                    GetRequiredField(parameter, "name", entryName, menuPathId);
                AssetTypeValueField value =
                    GetRequiredField(control, "value", entryName, menuPathId);
                AssetTypeValueField style = control["style"];
                AssetTypeValueField subParameters =
                    GetRequiredField(
                        control,
                        "subParameters",
                        entryName,
                        menuPathId);
                AssetTypeValueField labels =
                    GetRequiredField(control, "labels", entryName, menuPathId);

                int iconFileId;
                long iconPathId;
                ReadRequiredPPtr(
                    icon,
                    "icon",
                    entryName,
                    menuPathId,
                    out iconFileId,
                    out iconPathId);
                int subMenuFileId;
                long subMenuPathId;
                ReadRequiredPPtr(
                    subMenu,
                    "subMenu",
                    entryName,
                    menuPathId,
                    out subMenuFileId,
                    out subMenuPathId);

                ControlSemanticRecord semantic =
                    new ControlSemanticRecord
                    {
                        Name = controlName.AsString ?? string.Empty,
                        Type = controlType.AsInt,
                        ParameterName =
                            parameterName.AsString ?? string.Empty,
                        Value = value.AsFloat,
                        HasStyle =
                            style != null && !style.IsDummy,
                        Style =
                            style != null && !style.IsDummy
                                ? style.AsInt
                                : 0,
                        IconFileId = iconFileId,
                        IconPathId = iconPathId,
                        IconStableId =
                            resolveTextureStableIds
                                ? TryResolveTextureStableId(
                                    manager,
                                    assetsInstance,
                                    assetsByPathId,
                                    textureStableIds,
                                    iconFileId,
                                    iconPathId)
                                : string.Empty,
                        IconSourceKey =
                            CreateAssetReferenceKey(
                                entryIndex,
                                iconFileId,
                                iconPathId),
                        SubMenuFileId = subMenuFileId,
                        SubMenuPathId = subMenuPathId
                    };

                metrics.ControlCount++;
                if (semantic.HasIcon)
                {
                    metrics.IconReferenceCount++;
                }

                if (semantic.HasSubMenuReference)
                {
                    metrics.SubMenuControlCount++;
                }

                if (!string.IsNullOrEmpty(
                        parameterName.AsString))
                {
                    metrics.ParameterReferenceCount++;
                }

                IList<AssetTypeValueField> subParameterElements =
                    GetRequiredArrayElements(
                        subParameters,
                        "subParameters",
                        entryName,
                        menuPathId);
                metrics.SubParameterCount +=
                    subParameterElements.Count;
                foreach (AssetTypeValueField subParameter in
                         subParameterElements)
                {
                    AssetTypeValueField subParameterName =
                        GetRequiredField(
                        subParameter,
                        "name",
                        entryName,
                        menuPathId);
                    semantic.SubParameterNames.Add(
                        subParameterName.AsString ?? string.Empty);
                }

                IList<AssetTypeValueField> labelElements =
                    GetRequiredArrayElements(
                        labels,
                        "labels",
                        entryName,
                        menuPathId);
                metrics.LabelCount += labelElements.Count;
                foreach (AssetTypeValueField label in labelElements)
                {
                    AssetTypeValueField labelName =
                        GetRequiredField(
                        label,
                        "name",
                        entryName,
                        menuPathId);
                    AssetTypeValueField labelIcon =
                        GetRequiredField(
                            label,
                            "icon",
                            entryName,
                            menuPathId);
                    int labelIconFileId;
                    long labelIconPathId;
                    ReadRequiredPPtr(
                        labelIcon,
                        "label.icon",
                        entryName,
                        menuPathId,
                        out labelIconFileId,
                        out labelIconPathId);
                    bool hasLabelIcon =
                        labelIconFileId != 0 ||
                        labelIconPathId != 0;
                    semantic.Labels.Add(
                        new LabelSemanticRecord
                        {
                            Name =
                                labelName.AsString ??
                                string.Empty,
                            IconFileId = labelIconFileId,
                            IconPathId = labelIconPathId,
                            IconStableId =
                                resolveTextureStableIds
                                    ? TryResolveTextureStableId(
                                        manager,
                                        assetsInstance,
                                        assetsByPathId,
                                        textureStableIds,
                                        labelIconFileId,
                                        labelIconPathId)
                                    : string.Empty,
                            IconSourceKey =
                                CreateAssetReferenceKey(
                                    entryIndex,
                                    labelIconFileId,
                                    labelIconPathId)
                        });
                    if (hasLabelIcon)
                    {
                        metrics.LabelIconReferenceCount++;
                    }
                }

                metrics.Controls.Add(semantic);
            }

            return metrics;
        }

        private static AssetTypeValueField GetRequiredField(
            AssetTypeValueField parent,
            string fieldName,
            string entryName,
            long menuPathId)
        {
            AssetTypeValueField field = parent[fieldName];
            if (field == null || field.IsDummy)
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "VRCExpressionsMenuの必須フィールドがありません。field="
                    + fieldName
                    + ", entry="
                    + entryName
                    + ", pathID="
                    + menuPathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            return field;
        }

        private static IList<AssetTypeValueField>
            GetRequiredArrayElements(
                AssetTypeValueField parent,
                string fieldName,
                string entryName,
                long menuPathId)
        {
            AssetTypeValueField array =
                GetRequiredField(
                    parent,
                    "Array",
                    entryName,
                    menuPathId);
            if (array.Children == null)
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "VRCExpressionsMenuの配列を列挙できません。field="
                    + fieldName
                    + ", entry="
                    + entryName
                    + ", pathID="
                    + menuPathId.ToString(
                        CultureInfo.InvariantCulture));
            }

            return array.Children;
        }

        private static void ReadRequiredPPtr(
            AssetTypeValueField field,
            string fieldName,
            string entryName,
            long menuPathId,
            out int fileId,
            out long pathId)
        {
            if (!TryReadPPtr(field, out fileId, out pathId))
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "VRCExpressionsMenuのPPtrを解析できません。field="
                    + fieldName
                    + ", entry="
                    + entryName
                    + ", pathID="
                    + menuPathId.ToString(
                        CultureInfo.InvariantCulture));
            }
        }

        private static string TryResolveTextureStableId(
            AssetsManager manager,
            AssetsFileInstance assetsInstance,
            IDictionary<long, AssetFileInfo> assetsByPathId,
            IDictionary<long, string> textureStableIds,
            int fileId,
            long pathId)
        {
            if (fileId == 0 && pathId == 0)
            {
                return string.Empty;
            }

            if (fileId != 0 || pathId == 0)
            {
                Log.Error(
                    "Texture2D参照が外部または不正です: fileID="
                    + fileId.ToString(
                        CultureInfo.InvariantCulture)
                    + ", pathID="
                    + pathId.ToString(
                        CultureInfo.InvariantCulture));
                return null;
            }

            if (textureStableIds == null)
            {
                throw new ArgumentNullException(
                    nameof(textureStableIds));
            }

            string cachedStableId;
            if (textureStableIds.TryGetValue(
                    pathId,
                    out cachedStableId))
            {
                return cachedStableId;
            }

            AssetFileInfo targetInfo;
            if (!assetsByPathId.TryGetValue(pathId, out targetInfo) ||
                targetInfo.GetTypeId(assetsInstance.file) !=
                Texture2DClassId)
            {
                Log.Error(
                    "Icon参照先がTexture2Dではありません: pathID="
                    + pathId.ToString(
                        CultureInfo.InvariantCulture));
                return null;
            }

            try
            {
                AssetTypeValueField texture =
                    manager.GetBaseField(
                        assetsInstance,
                        targetInfo,
                        AssetReadFlags.None);
                if (texture == null || texture.IsDummy)
                {
                    Log.Error(
                        "Texture2Dの基底フィールドを取得できません: pathID="
                        + pathId.ToString(
                            CultureInfo.InvariantCulture));
                    return null;
                }

                AssetTypeValueField name = texture["m_Name"];
                if (name == null || name.IsDummy)
                {
                    Log.Error(
                        "Texture2Dのm_Nameを取得できません: pathID="
                        + pathId.ToString(
                            CultureInfo.InvariantCulture));
                    return null;
                }

                string displayName = string.IsNullOrEmpty(name.AsString)
                    ? "pathID="
                      + pathId.ToString(
                          CultureInfo.InvariantCulture)
                    : name.AsString;

                TextureFile textureFile =
                    TextureFile.ReadTextureFile(texture);
                if (textureFile == null ||
                    textureFile.m_Width <= 0 ||
                    textureFile.m_Height <= 0 ||
                    textureFile.m_Width >
                    MaximumTextureDimension ||
                    textureFile.m_Height >
                    MaximumTextureDimension)
                {
                    Log.Error(
                        "Texture2Dの寸法を取得できません: "
                        + displayName);
                    return null;
                }

                long expectedPixelLength =
                    checked(
                        (long)textureFile.m_Width *
                        textureFile.m_Height *
                        4L);
                if (expectedPixelLength >
                    MaximumDecodedTextureBytes)
                {
                    Log.Error(
                        "Texture2Dの展開後サイズが安全範囲外です: "
                        + displayName);
                    return null;
                }

                long encodedTextureLength =
                    textureFile.pictureData == null
                        ? 0L
                        : textureFile.pictureData.LongLength;
                if (textureFile.m_StreamData.size >
                    encodedTextureLength)
                {
                    encodedTextureLength =
                        textureFile.m_StreamData.size;
                }

                if (encodedTextureLength <= 0 ||
                    encodedTextureLength >
                    MaximumEncodedTextureBytes)
                {
                    Log.Error(
                        "Texture2Dの画像データ長が安全範囲外です: "
                        + displayName);
                    return null;
                }

                byte[] pictureData =
                    textureFile.FillPictureData(
                        assetsInstance);
                if (pictureData == null ||
                    pictureData.Length == 0 ||
                    pictureData.LongLength >
                    MaximumEncodedTextureBytes)
                {
                    Log.Error(
                        "Texture2Dの画像データを取得できません: "
                        + displayName
                        + ", format="
                        + textureFile.m_TextureFormat.ToString(
                            CultureInfo.InvariantCulture));
                    return null;
                }

                byte[] rgbaPixels =
                    TexturePixelDecoder.DecodeRgba32(
                        textureFile,
                        pictureData);
                if (rgbaPixels == null ||
                    rgbaPixels.LongLength !=
                    expectedPixelLength)
                {
                    Log.Error(
                        "Texture2DのRGBA32デコードに失敗しました: "
                        + displayName
                        + ", format="
                        + textureFile.m_TextureFormat.ToString(
                            CultureInfo.InvariantCulture)
                        + ", size="
                        + textureFile.m_Width.ToString(
                            CultureInfo.InvariantCulture)
                        + "x"
                        + textureFile.m_Height.ToString(
                            CultureInfo.InvariantCulture));
                    return null;
                }

                string pixelSha256;
                using (MemoryStream pixelStream =
                       new MemoryStream(
                           rgbaPixels,
                           false))
                {
                    pixelSha256 =
                        FingerprintUtility.ComputeStreamSha256(
                            pixelStream,
                            0,
                            pixelStream.Length);
                }

                string stableId =
                    textureFile.m_Width.ToString(
                        CultureInfo.InvariantCulture)
                    + "\u001F"
                    + textureFile.m_Height.ToString(
                        CultureInfo.InvariantCulture)
                    + "\u001F"
                    + pixelSha256;
                textureStableIds.Add(
                    pathId,
                    stableId);
                return stableId;
            }
            catch (Exception exception)
            {
                Log.Error(
                    "Texture2Dの安定識別子生成中に例外が発生しました: pathID="
                    + pathId.ToString(
                        CultureInfo.InvariantCulture)
                    + ", "
                    + exception);
                return null;
            }
        }

        private static string CreateAssetReferenceKey(
            int entryIndex,
            int fileId,
            long pathId)
        {
            if (fileId == 0 && pathId == 0)
            {
                return string.Empty;
            }

            return entryIndex.ToString(
                       CultureInfo.InvariantCulture)
                   + ":"
                   + fileId.ToString(
                       CultureInfo.InvariantCulture)
                   + ":"
                   + pathId.ToString(
                       CultureInfo.InvariantCulture);
        }

        private static void PrepareCanonicalMenuGraph(
            SourceSnapshot snapshot)
        {
            List<MenuRecord> menus = GetAllMenus(snapshot);
            Dictionary<string, MenuRecord> menusByReference =
                new Dictionary<string, MenuRecord>(
                    StringComparer.Ordinal);
            foreach (MenuRecord menu in menus)
            {
                string key = CreateMenuReferenceKey(
                    menu.Key.EntryIndex,
                    menu.Key.PathId);
                if (menusByReference.ContainsKey(key))
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "Expression Menu graphに重複するnode参照があります: "
                        + key);
                }

                menusByReference.Add(key, menu);
            }

            HashSet<string> descriptorRootKeys =
                new HashSet<string>(StringComparer.Ordinal);
            bool hasUnresolvedDescriptorRoot = false;
            foreach (AssetsFileSnapshot assetsFile in
                     snapshot.AssetsFiles)
            {
                foreach (AssetReference reference in
                         assetsFile.DescriptorRootReferences)
                {
                    if (reference.FileId != 0 ||
                        reference.PathId == 0)
                    {
                        hasUnresolvedDescriptorRoot = true;
                        continue;
                    }

                    descriptorRootKeys.Add(
                        CreateMenuReferenceKey(
                            reference.EntryIndex,
                            reference.PathId));
                }
            }

            string rootReferenceKey = null;
            MenuRecord rootMenu;
            if (!hasUnresolvedDescriptorRoot &&
                descriptorRootKeys.Count == 1)
            {
                foreach (string key in descriptorRootKeys)
                {
                    rootReferenceKey = key;
                }

                if (rootReferenceKey != null &&
                    menusByReference.TryGetValue(
                        rootReferenceKey,
                        out rootMenu))
                {
                    snapshot.RootMenuName =
                        rootMenu.ExpectedName;
                }
            }

            if (snapshot.Candidates.Count == 0)
            {
                return;
            }

            if (hasUnresolvedDescriptorRoot ||
                descriptorRootKeys.Count != 1 ||
                string.IsNullOrEmpty(rootReferenceKey) ||
                string.IsNullOrEmpty(snapshot.RootMenuName))
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "VRCAvatarDescriptorが参照する唯一のRoot Expression Menuを特定できません。");
            }

            HashSet<string> menuNames =
                new HashSet<string>(StringComparer.Ordinal);
            Dictionary<string, string> iconSourcesByStableId =
                new Dictionary<string, string>(
                    StringComparer.Ordinal);
            foreach (MenuRecord menu in menus)
            {
                if (string.IsNullOrEmpty(menu.ExpectedName) ||
                    !menuNames.Add(menu.ExpectedName))
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "Expression Menuの安定node名が空または重複しています: "
                        + menu.Key);
                }

                foreach (ControlSemanticRecord control in
                         menu.Controls)
                {
                    ValidateStableIconReference(
                        control.HasIcon,
                        control.IconStableId,
                        control.IconSourceKey,
                        iconSourcesByStableId,
                        menu.Key.ToString());
                    foreach (LabelSemanticRecord label in
                             control.Labels)
                    {
                        ValidateStableIconReference(
                            label.HasIcon,
                            label.IconStableId,
                            label.IconSourceKey,
                            iconSourcesByStableId,
                            menu.Key.ToString());
                    }
                }
            }

            Queue<string> pending =
                new Queue<string>();
            HashSet<string> visited =
                new HashSet<string>(StringComparer.Ordinal);
            pending.Enqueue(rootReferenceKey);
            while (pending.Count > 0)
            {
                string currentKey = pending.Dequeue();
                if (!visited.Add(currentKey))
                {
                    continue;
                }

                MenuRecord current;
                if (!menusByReference.TryGetValue(
                        currentKey,
                        out current))
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "Expression Menu graphのnode参照を解決できません: "
                        + currentKey);
                }

                foreach (ControlSemanticRecord control in
                         current.Controls)
                {
                    if (control.Type == SubMenuControlType &&
                        !control.HasSubMenuReference)
                    {
                        throw new NormalizerException(
                            ExitCode.ParseFailure,
                            "SubMenu controlの参照がMissingです: "
                            + current.Key);
                    }

                    if (!control.HasSubMenuReference)
                    {
                        continue;
                    }

                    if (control.SubMenuFileId != 0 ||
                        control.SubMenuPathId == 0)
                    {
                        throw new NormalizerException(
                            ExitCode.ParseFailure,
                            "Expression Menu graphに外部または不正なSubMenu参照があります: "
                            + current.Key);
                    }

                    string subMenuKey =
                        CreateMenuReferenceKey(
                            current.Key.EntryIndex,
                            control.SubMenuPathId);
                    if (!menusByReference.ContainsKey(
                            subMenuKey))
                    {
                        throw new NormalizerException(
                            ExitCode.ParseFailure,
                            "Expression Menu graphのSubMenu参照を解決できません: "
                            + current.Key);
                    }

                    pending.Enqueue(subMenuKey);
                }
            }

            if (visited.Count != menus.Count)
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "VRCAvatarDescriptorのRoot Menuから到達できないExpression Menuがあります。");
            }
        }

        private static void ValidateStableIconReference(
            bool hasIcon,
            string stableId,
            string sourceKey,
            IDictionary<string, string> sourcesByStableId,
            string menuKey)
        {
            if (!hasIcon)
            {
                if (!string.IsNullOrEmpty(stableId) ||
                    !string.IsNullOrEmpty(sourceKey))
                {
                    throw new NormalizerException(
                        ExitCode.ParseFailure,
                        "null Icon参照の識別情報が不正です: "
                        + menuKey);
                }

                return;
            }

            if (string.IsNullOrEmpty(stableId) ||
                string.IsNullOrEmpty(sourceKey))
            {
                throw new NormalizerException(
                    ExitCode.ParseFailure,
                    "Icon参照のTexture2D安定識別子を解決できません: "
                    + menuKey);
            }

            if (sourcesByStableId.ContainsKey(stableId))
            {
                // 同一寸法・同一画素のTexture2Dは意味的に同一として扱う。
                return;
            }

            sourcesByStableId.Add(stableId, sourceKey);
        }

        private static List<MenuRecord> GetAllMenus(
            SourceSnapshot snapshot)
        {
            List<MenuRecord> menus = new List<MenuRecord>();
            foreach (AssetsFileSnapshot assetsFile in
                     snapshot.AssetsFiles)
            {
                menus.AddRange(assetsFile.Menus);
            }

            return menus;
        }

        private static string ComputeMenuGraphSha256(
            IList<MenuRecord> menus,
            string rootMenuName,
            bool requireResolvedReferences,
            ExitCode failureCode = ExitCode.ParseFailure)
        {
            Dictionary<string, string> menuNamesByReference =
                new Dictionary<string, string>(
                    StringComparer.Ordinal);
            HashSet<string> menuNames =
                new HashSet<string>(StringComparer.Ordinal);
            foreach (MenuRecord menu in menus)
            {
                string referenceKey = CreateMenuReferenceKey(
                    menu.Key.EntryIndex,
                    menu.Key.PathId);
                if (string.IsNullOrEmpty(menu.ExpectedName) ||
                    menuNamesByReference.ContainsKey(referenceKey) ||
                    (requireResolvedReferences &&
                     !menuNames.Add(menu.ExpectedName)))
                {
                    throw new NormalizerException(
                        failureCode,
                        "Expression Menu graphのnode識別子が不正です: "
                        + menu.Key);
                }

                menuNamesByReference.Add(
                    referenceKey,
                    menu.ExpectedName);
            }

            List<string> nodeHashes =
                new List<string>(menus.Count);
            foreach (MenuRecord menu in menus)
            {
                using (MemoryStream nodeStream = new MemoryStream())
                {
                    using (BinaryWriter writer = new BinaryWriter(
                               nodeStream,
                               new UTF8Encoding(false),
                               true))
                    {
                        WriteCanonicalString(
                            writer,
                            menu.ExpectedName);
                        writer.Write(menu.Controls.Count);
                        foreach (ControlSemanticRecord control in
                                 menu.Controls)
                        {
                            WriteCanonicalString(
                                writer,
                                control.Name);
                            writer.Write(control.Type);
                            WriteCanonicalString(
                                writer,
                                control.ParameterName);
                            writer.Write(
                                BitConverter.GetBytes(
                                    control.Value));
                            writer.Write(control.HasStyle);
                            writer.Write(control.Style);
                            WriteCanonicalString(
                                writer,
                                GetCanonicalIconStableId(
                                    control.HasIcon,
                                    control.IconStableId,
                                    control.IconSourceKey,
                                    requireResolvedReferences,
                                    failureCode,
                                    menu.Key.ToString()));

                            string subMenuName = string.Empty;
                            if (control.HasSubMenuReference)
                            {
                                if (control.SubMenuFileId != 0 ||
                                    !menuNamesByReference.TryGetValue(
                                        CreateMenuReferenceKey(
                                            menu.Key.EntryIndex,
                                            control.SubMenuPathId),
                                        out subMenuName))
                                {
                                    if (requireResolvedReferences)
                                    {
                                        throw new NormalizerException(
                                            failureCode,
                                            "Expression Menu graphのSubMenu参照を解決できません: "
                                            + menu.Key);
                                    }

                                    subMenuName =
                                        CreateAssetReferenceKey(
                                            menu.Key.EntryIndex,
                                            control.SubMenuFileId,
                                            control.SubMenuPathId);
                                }
                            }

                            WriteCanonicalString(
                                writer,
                                subMenuName);
                            writer.Write(
                                control.SubParameterNames.Count);
                            foreach (string subParameterName in
                                     control.SubParameterNames)
                            {
                                WriteCanonicalString(
                                    writer,
                                    subParameterName);
                            }

                            writer.Write(control.Labels.Count);
                            foreach (LabelSemanticRecord label in
                                     control.Labels)
                            {
                                WriteCanonicalString(
                                    writer,
                                    label.Name);
                                WriteCanonicalString(
                                    writer,
                                    GetCanonicalIconStableId(
                                        label.HasIcon,
                                        label.IconStableId,
                                        label.IconSourceKey,
                                        requireResolvedReferences,
                                        failureCode,
                                        menu.Key.ToString()));
                            }
                        }
                    }

                    nodeStream.Position = 0;
                    nodeHashes.Add(
                        FingerprintUtility.ComputeStreamSha256(
                            nodeStream,
                            0,
                            nodeStream.Length));
                }
            }

            nodeHashes.Sort(StringComparer.Ordinal);
            using (MemoryStream graphStream = new MemoryStream())
            {
                using (BinaryWriter writer = new BinaryWriter(
                           graphStream,
                           new UTF8Encoding(false),
                           true))
                {
                    WriteCanonicalString(
                        writer,
                        rootMenuName ?? string.Empty);
                    writer.Write(nodeHashes.Count);
                    foreach (string nodeHash in nodeHashes)
                    {
                        WriteCanonicalString(writer, nodeHash);
                    }
                }

                graphStream.Position = 0;
                return FingerprintUtility.ComputeStreamSha256(
                    graphStream,
                    0,
                    graphStream.Length);
            }
        }

        private static string GetCanonicalIconStableId(
            bool hasIcon,
            string stableId,
            string sourceKey,
            bool requireResolvedReferences,
            ExitCode failureCode,
            string menuKey)
        {
            if (!hasIcon)
            {
                return string.Empty;
            }

            if (!string.IsNullOrEmpty(stableId))
            {
                return stableId;
            }

            if (requireResolvedReferences)
            {
                throw new NormalizerException(
                    failureCode,
                    "Expression Menu graphのIcon安定識別子を解決できません: "
                    + menuKey);
            }

            return sourceKey ?? string.Empty;
        }

        private static string CreateMenuReferenceKey(
            int entryIndex,
            long pathId)
        {
            return entryIndex.ToString(
                       CultureInfo.InvariantCulture)
                   + ":"
                   + pathId.ToString(
                       CultureInfo.InvariantCulture);
        }

        private static void WriteCanonicalString(
            BinaryWriter writer,
            string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(
                value ?? string.Empty);
            writer.Write(bytes.Length);
            writer.Write(bytes);
        }

        private static string ComputeAssetsMetadataFingerprint(
            AssetsFile assetsFile)
        {
            if (assetsFile == null ||
                assetsFile.Header == null ||
                assetsFile.Metadata == null)
            {
                throw new InvalidDataException(
                    "SerializedFile metadataを取得できません。");
            }

            AssetsFileMetadata metadata = assetsFile.Metadata;
            using (MemoryStream stream = new MemoryStream())
            {
                using (BinaryWriter writer = new BinaryWriter(
                           stream,
                           new UTF8Encoding(false),
                           true))
                {
                    writer.Write(assetsFile.Header.Version);
                    writer.Write(assetsFile.Header.Endianness);
                    WriteCanonicalString(
                        writer,
                        metadata.UnityVersion);
                    writer.Write(metadata.TargetPlatform);
                    writer.Write(metadata.TypeTreeEnabled);
                    WriteCanonicalString(
                        writer,
                        metadata.UserInformation);

                    WriteTypeTreeTypes(
                        writer,
                        metadata.TypeTreeTypes);

                    writer.Write(
                        metadata.ScriptTypes == null
                            ? 0
                            : metadata.ScriptTypes.Count);
                    if (metadata.ScriptTypes != null)
                    {
                        foreach (AssetPPtr scriptType in
                                 metadata.ScriptTypes)
                        {
                            WriteCanonicalString(
                                writer,
                                scriptType.FilePath);
                            writer.Write(scriptType.FileId);
                            writer.Write(scriptType.PathId);
                        }
                    }

                    writer.Write(
                        metadata.Externals == null
                            ? 0
                            : metadata.Externals.Count);
                    if (metadata.Externals != null)
                    {
                        foreach (AssetsFileExternal external in
                                 metadata.Externals)
                        {
                            WriteCanonicalString(
                                writer,
                                external.VirtualAssetPathName);
                            writer.Write(external.Guid.data0);
                            writer.Write(external.Guid.data1);
                            writer.Write(external.Guid.data2);
                            writer.Write(external.Guid.data3);
                            writer.Write((int)external.Type);
                            WriteCanonicalString(
                                writer,
                                external.PathName);
                            WriteCanonicalString(
                                writer,
                                external.OriginalPathName);
                        }
                    }

                    WriteTypeTreeTypes(
                        writer,
                        metadata.RefTypes);
                }

                stream.Position = 0;
                return FingerprintUtility.ComputeStreamSha256(
                    stream,
                    0,
                    stream.Length);
            }
        }

        private static void WriteTypeTreeTypes(
            BinaryWriter writer,
            IList<TypeTreeType> types)
        {
            writer.Write(types == null ? 0 : types.Count);
            if (types == null)
            {
                return;
            }

            foreach (TypeTreeType type in types)
            {
                writer.Write(type.TypeId);
                writer.Write(type.IsStrippedType);
                writer.Write(type.ScriptTypeIndex);
                WriteHash128(
                    writer,
                    type.ScriptIdHash);
                WriteHash128(
                    writer,
                    type.TypeHash);
                writer.Write(type.IsRefType);

                byte[] stringBuffer =
                    type.StringBufferBytes;
                writer.Write(
                    stringBuffer == null
                        ? 0
                        : stringBuffer.Length);
                if (stringBuffer != null)
                {
                    writer.Write(stringBuffer);
                }

                IList<TypeTreeNode> nodes = type.Nodes;
                writer.Write(nodes == null ? 0 : nodes.Count);
                if (nodes != null)
                {
                    foreach (TypeTreeNode node in nodes)
                    {
                        writer.Write(node.Version);
                        writer.Write(node.Level);
                        writer.Write((byte)node.TypeFlags);
                        writer.Write(node.TypeStrOffset);
                        writer.Write(node.NameStrOffset);
                        writer.Write(node.ByteSize);
                        writer.Write(node.Index);
                        writer.Write(node.MetaFlags);
                        writer.Write(node.RefTypeHash);
                    }
                }

                int[] dependencies =
                    type.TypeDependencies;
                writer.Write(
                    dependencies == null
                        ? 0
                        : dependencies.Length);
                if (dependencies != null)
                {
                    foreach (int dependency in dependencies)
                    {
                        writer.Write(dependency);
                    }
                }

                AssetTypeReference reference =
                    type.TypeReference;
                writer.Write(reference != null);
                if (reference != null)
                {
                    WriteCanonicalString(
                        writer,
                        reference.ClassName);
                    WriteCanonicalString(
                        writer,
                        reference.Namespace);
                    WriteCanonicalString(
                        writer,
                        reference.AsmName);
                }
            }
        }

        private static void WriteHash128(
            BinaryWriter writer,
            Hash128 hash)
        {
            byte[] data = hash.data;
            writer.Write(data == null ? 0 : data.Length);
            if (data != null)
            {
                writer.Write(data);
            }
        }

        private static void WriteNormalizedBundle(
            CommandLineOptions options,
            SourceSnapshot snapshot,
            string partialOutputPath)
        {
            string uncompressedStagePath = partialOutputPath + ".uncompressed";
            try
            {
                Log.Info(
                    string.Format(
                        CultureInfo.InvariantCulture,
                        "無名Menuを{0}件正規化した一時VRCAを書き出します。",
                        snapshot.Candidates.Count));

                // BundleのWriteでDirectoryInfoの置換を確定し、その後に元の圧縮方式へ再圧縮する。
                using (AssetsFileWriter writer = new AssetsFileWriter(uncompressedStagePath))
                {
                    snapshot.PreparedBundle.file.Write(writer, 0);
                }

                snapshot.PreparedManager.UnloadAll(true);
                snapshot.PreparedManager = null;
                snapshot.PreparedBundle = null;

                AssetsManager packManager = new AssetsManager();
                try
                {
                    BundleFileInstance stagedBundle = packManager.LoadBundleFile(
                        uncompressedStagePath,
                        true);
                    if (stagedBundle == null || stagedBundle.file == null)
                    {
                        throw new InvalidDataException(
                            "置換確定後の非圧縮AssetBundleを再読込できません。");
                    }

                    using (AssetsFileWriter writer = new AssetsFileWriter(partialOutputPath))
                    {
                        stagedBundle.file.Pack(
                            writer,
                            snapshot.CompressionType,
                            false,
                            null);
                    }
                }
                finally
                {
                    packManager.UnloadAll(true);
                }

                FileInfo outputInfo = new FileInfo(partialOutputPath);
                if (!outputInfo.Exists || outputInfo.Length == 0)
                {
                    throw new InvalidDataException("一時VRCAが生成されていないか空です。");
                }
            }
            catch (NormalizerException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new NormalizerException(
                    ExitCode.WriteFailure,
                    "正規化済み一時VRCAの書き出しに失敗しました。",
                    exception);
            }
            finally
            {
                if (snapshot.PreparedManager != null)
                {
                    snapshot.PreparedManager.UnloadAll(true);
                    snapshot.PreparedManager = null;
                    snapshot.PreparedBundle = null;
                }

                if (File.Exists(uncompressedStagePath))
                {
                    try
                    {
                        File.Delete(uncompressedStagePath);
                    }
                    catch (Exception exception)
                    {
                        Log.Error("非圧縮ステージファイルの削除に失敗しました: " + exception.Message);
                    }
                }
            }
        }

        private static int VerifyNormalizedBundle(
            string classPackagePath,
            string outputPath,
            SourceSnapshot source)
        {
            AssetsManager manager = new AssetsManager();
            try
            {
                LoadClassPackage(manager, classPackagePath, ExitCode.VerificationFailure);
                BundleFileInstance bundle;
                try
                {
                    bundle = manager.LoadBundleFile(outputPath, true);
                }
                catch (Exception exception)
                {
                    throw new NormalizerException(
                        ExitCode.VerificationFailure,
                        "正規化済みVRCAを再読込できません。",
                        exception);
                }

                if (bundle == null || bundle.file == null)
                {
                    throw new NormalizerException(
                        ExitCode.VerificationFailure,
                        "正規化済みVRCAのAssetBundle情報を取得できません。");
                }

                if (bundle.file.GetCompressionType() != source.CompressionType)
                {
                    throw new NormalizerException(
                        ExitCode.VerificationFailure,
                        "AssetBundleの圧縮方式が変化しました。");
                }

                IList<string> outputEntryNames = bundle.file.GetAllFileNames();
                if (outputEntryNames.Count != source.BundleEntries.Count)
                {
                    throw new NormalizerException(
                        ExitCode.VerificationFailure,
                        "AssetBundle内のエントリ数が変化しました。");
                }

                Dictionary<AssetKey, MenuRecord> outputMenus =
                    new Dictionary<AssetKey, MenuRecord>();
                HashSet<AssetKey> outputAssets = new HashSet<AssetKey>();
                HashSet<AssetKey> sourceAssets = source.AllAssets;
                Dictionary<AssetKey, string> sourceNonTargetAssetHashes =
                    source.NonTargetAssetHashes;
                Dictionary<int, AssetsFileSnapshot>
                    sourceAssetsFilesByEntryIndex =
                        new Dictionary<int, AssetsFileSnapshot>();
                foreach (AssetsFileSnapshot sourceAssetsFile in
                         source.AssetsFiles)
                {
                    sourceAssetsFilesByEntryIndex.Add(
                        sourceAssetsFile.EntryIndex,
                        sourceAssetsFile);
                }
                int outputMeshCount = 0;
                int unnamedMenuCount = 0;
                int outputControlCount = 0;
                int outputSubMenuControlCount = 0;
                int outputIconReferenceCount = 0;
                int outputParameterReferenceCount = 0;
                int outputSubParameterCount = 0;
                int outputLabelCount = 0;
                int outputLabelIconReferenceCount = 0;

                foreach (BundleEntrySnapshot expectedEntry in source.BundleEntries)
                {
                    int entryIndex = expectedEntry.EntryIndex;
                    string entryName = outputEntryNames[entryIndex];
                    bool isAssetsFile = bundle.file.IsAssetsFile(entryIndex);
                    if (!string.Equals(
                            entryName,
                            expectedEntry.EntryName,
                            StringComparison.Ordinal)
                        || isAssetsFile != expectedEntry.IsAssetsFile)
                    {
                        throw new NormalizerException(
                            ExitCode.VerificationFailure,
                            "AssetBundle内のエントリ構造が変化しました: index="
                            + entryIndex.ToString(CultureInfo.InvariantCulture));
                    }

                    if (!isAssetsFile)
                    {
                        long offset;
                        long length;
                        bundle.file.GetFileRange(entryIndex, out offset, out length);
                        string hash = FingerprintUtility.ComputeStreamSha256(
                            bundle.DataStream,
                            offset,
                            length);
                        string expectedHash = source.NonAssetsEntryHashes[entryIndex];
                        if (!string.Equals(hash, expectedHash, StringComparison.Ordinal))
                        {
                            throw new NormalizerException(
                                ExitCode.VerificationFailure,
                                "非SerializedFileエントリの内容が変化しました: " + entryName);
                        }

                        continue;
                    }

                    AssetsFileInstance assetsInstance = manager.LoadAssetsFileFromBundle(
                        bundle,
                        entryIndex,
                        false);
                    if (assetsInstance == null || assetsInstance.file == null)
                    {
                        throw new NormalizerException(
                            ExitCode.VerificationFailure,
                            "再読込したSerializedFile情報を取得できません: " + entryName);
                    }

                    AssetsFileSnapshot expectedAssetsFile;
                    if (!sourceAssetsFilesByEntryIndex.TryGetValue(
                            entryIndex,
                            out expectedAssetsFile))
                    {
                        throw new NormalizerException(
                            ExitCode.VerificationFailure,
                            "再読込したSerializedFileの元情報が見つかりません: " +
                            entryName);
                    }

                    string outputMetadataFingerprint =
                        ComputeAssetsMetadataFingerprint(
                            assetsInstance.file);
                    if (!string.Equals(
                            outputMetadataFingerprint,
                            expectedAssetsFile.MetadataFingerprint,
                            StringComparison.Ordinal))
                    {
                        throw new NormalizerException(
                            ExitCode.VerificationFailure,
                            "SerializedFileのmetadataまたはexternal参照表が変化しました: " +
                            entryName);
                    }

                    LoadMatchingClassDatabase(
                        manager,
                        assetsInstance,
                        ExitCode.VerificationFailure,
                        entryName);

                    Dictionary<long, MonoScriptIdentity> scripts = ReadMonoScripts(
                        manager,
                        assetsInstance);
                    Dictionary<long, AssetFileInfo> assetsByPathId =
                        BuildAssetInfoLookup(
                            assetsInstance.file);
                    Dictionary<long, string> textureStableIds =
                        new Dictionary<long, string>();

                    foreach (AssetFileInfo info in assetsInstance.file.AssetInfos)
                    {
                        int typeId = info.GetTypeId(assetsInstance.file);
                        AssetKey key = new AssetKey(
                            entryIndex,
                            entryName,
                            info.PathId,
                            typeId);
                        if (!outputAssets.Add(key))
                        {
                            throw new NormalizerException(
                                ExitCode.VerificationFailure,
                                "再読込後に重複するAsset識別子を検出しました: " + key);
                        }

                        if (typeId == MeshClassId)
                        {
                            outputMeshCount++;
                        }

                        string expectedRawHash;
                        if (sourceNonTargetAssetHashes.TryGetValue(key, out expectedRawHash))
                        {
                            string rawHash = FingerprintUtility.ComputeStreamSha256(
                                assetsInstance.AssetsStream,
                                info.GetAbsoluteByteOffset(assetsInstance.file),
                                info.ByteSize);
                            if (!string.Equals(rawHash, expectedRawHash, StringComparison.Ordinal))
                            {
                                throw new NormalizerException(
                                    ExitCode.VerificationFailure,
                                    "非対象Assetの生データが変化しました: " + key);
                            }
                        }
                    }

                    foreach (AssetFileInfo info in assetsInstance.file.GetAssetsOfType(
                        MonoBehaviourClassId))
                    {
                        AssetTypeValueField baseField;
                        try
                        {
                            baseField = manager.GetBaseField(
                                assetsInstance,
                                info,
                                AssetReadFlags.SkipMonoBehaviourFields);
                        }
                        catch (Exception exception)
                        {
                            throw new NormalizerException(
                                ExitCode.VerificationFailure,
                                "正規化後のMonoBehaviourを安全に再解析できません。entry="
                                + entryName
                                + ", pathID="
                                + info.PathId.ToString(
                                    CultureInfo.InvariantCulture),
                                exception);
                        }

                        MenuRecord menu;
                        if (!TryCreateMenuRecord(
                            manager,
                            assetsInstance,
                            assetsInstance.file,
                            info,
                            baseField,
                            entryIndex,
                            entryName,
                            scripts,
                            assetsByPathId,
                            textureStableIds,
                            true,
                            out menu))
                        {
                            continue;
                        }

                        if (menu.OriginalName.Length == 0)
                        {
                            unnamedMenuCount++;
                        }

                        outputMenus.Add(menu.Key, menu);
                        outputControlCount += menu.ControlCount;
                        outputSubMenuControlCount +=
                            menu.SubMenuControlCount;
                        outputIconReferenceCount +=
                            menu.IconReferenceCount;
                        outputParameterReferenceCount +=
                            menu.ParameterReferenceCount;
                        outputSubParameterCount +=
                            menu.SubParameterCount;
                        outputLabelCount += menu.LabelCount;
                        outputLabelIconReferenceCount +=
                            menu.LabelIconReferenceCount;
                    }
                }

                if (!sourceAssets.SetEquals(outputAssets))
                {
                    throw new NormalizerException(
                        ExitCode.VerificationFailure,
                        "PathIDまたはClassIDの集合が正規化前後で一致しません。");
                }

                if (outputMeshCount != source.MeshCount)
                {
                    throw new NormalizerException(
                        ExitCode.VerificationFailure,
                        "Mesh数が正規化前後で一致しません。");
                }

                if (outputMenus.Count != source.MenuCount)
                {
                    throw new NormalizerException(
                        ExitCode.VerificationFailure,
                        "VRCExpressionsMenu数が正規化前後で一致しません。");
                }

                if (outputControlCount != source.ControlCount ||
                    outputSubMenuControlCount !=
                    source.SubMenuControlCount ||
                    outputIconReferenceCount !=
                    source.IconReferenceCount ||
                    outputParameterReferenceCount !=
                    source.ParameterReferenceCount ||
                    outputSubParameterCount !=
                    source.SubParameterCount ||
                    outputLabelCount != source.LabelCount ||
                    outputLabelIconReferenceCount !=
                    source.LabelIconReferenceCount)
                {
                    throw new NormalizerException(
                        ExitCode.VerificationFailure,
                        "Expression Menu control構造の集計が正規化前後で一致しません。");
                }

                List<MenuRecord> outputMenuRecords =
                    new List<MenuRecord>(outputMenus.Values);
                string outputMenuGraphSha256 =
                    ComputeMenuGraphSha256(
                        outputMenuRecords,
                        source.RootMenuName,
                        true,
                        ExitCode.VerificationFailure);
                if (!string.Equals(
                        outputMenuGraphSha256,
                        source.MenuGraphSha256,
                        StringComparison.Ordinal))
                {
                    throw new NormalizerException(
                        ExitCode.VerificationFailure,
                        "Expression Menu graphのcanonical SHA-256が正規化前後で一致しません。");
                }

                if (unnamedMenuCount != 0)
                {
                    throw new NormalizerException(
                        ExitCode.VerificationFailure,
                        "正規化後も無名のVRCExpressionsMenuが"
                        + unnamedMenuCount.ToString(CultureInfo.InvariantCulture)
                        + "件残っています。");
                }

                foreach (MenuRecord expected in source.Candidates)
                {
                    MenuRecord actual;
                    if (!outputMenus.TryGetValue(expected.Key, out actual))
                    {
                        throw new NormalizerException(
                            ExitCode.VerificationFailure,
                            "正規化対象Menuが再読込後に見つかりません: " + expected.Key);
                    }

                    if (!string.Equals(
                        actual.OriginalName,
                        expected.ExpectedName,
                        StringComparison.Ordinal))
                    {
                        throw new NormalizerException(
                            ExitCode.VerificationFailure,
                            "正規化対象Menuの名前が一致しません: " + expected.Key);
                    }

                    if (!string.Equals(
                            actual.ControlsFingerprint,
                            expected.ControlsFingerprint,
                            StringComparison.Ordinal)
                        || !string.Equals(
                            actual.PPtrFingerprint,
                            expected.PPtrFingerprint,
                            StringComparison.Ordinal)
                        || !string.Equals(
                            actual.NonNameFingerprint,
                            expected.NonNameFingerprint,
                            StringComparison.Ordinal))
                    {
                        throw new NormalizerException(
                            ExitCode.VerificationFailure,
                            "controls、PPtr、またはm_Name以外の内容が変化しました: "
                            + expected.Key);
                    }
                }

                Log.Info(
                    string.Format(
                        CultureInfo.InvariantCulture,
                        "再読込検証に成功しました。menus={0}, meshes={1}, assets={2}",
                        outputMenus.Count,
                        outputMeshCount,
                        outputAssets.Count));
                return outputMenus.Count;
            }
            catch (NormalizerException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new NormalizerException(
                    ExitCode.VerificationFailure,
                    "正規化済みVRCAの再読込検証に失敗しました。",
                    exception);
            }
            finally
            {
                manager.UnloadAll(true);
            }
        }

        private static void LoadClassPackage(
            AssetsManager manager,
            string classPackagePath,
            ExitCode failureCode)
        {
            try
            {
                if (manager.LoadClassPackage(classPackagePath) == null)
                {
                    throw new InvalidDataException("AssetsTools.NETがclass.tpkを受理しませんでした。");
                }
            }
            catch (Exception exception)
            {
                throw new NormalizerException(
                    failureCode,
                    "class.tpkを読み込めません。",
                    exception);
            }
        }

        private static void LoadMatchingClassDatabase(
            AssetsManager manager,
            AssetsFileInstance assetsInstance,
            ExitCode failureCode,
            string entryName)
        {
            string unityVersion = assetsInstance.file.Metadata.UnityVersion;
            try
            {
                if (manager.LoadClassDatabaseFromPackage(unityVersion) == null)
                {
                    throw new InvalidDataException(
                        "対応するClassDatabaseがclass.tpkにありません: " + unityVersion);
                }
            }
            catch (Exception exception)
            {
                throw new NormalizerException(
                    failureCode,
                    "Unity "
                    + unityVersion
                    + " 用ClassDatabaseを読み込めません: "
                    + entryName,
                    exception);
            }
        }

        private static string GetRequiredString(
            AssetTypeValueField parent,
            string fieldName)
        {
            AssetTypeValueField field = parent[fieldName];
            if (field == null || field.IsDummy)
            {
                throw new InvalidDataException("必須フィールドがありません: " + fieldName);
            }

            return field.AsString ?? string.Empty;
        }

        private static bool TryReadPPtr(
            AssetTypeValueField field,
            out int fileId,
            out long pathId)
        {
            fileId = 0;
            pathId = 0;
            if (field == null || field.IsDummy)
            {
                return false;
            }

            AssetTypeValueField fileIdField = field["m_FileID"];
            AssetTypeValueField pathIdField = field["m_PathID"];
            if (fileIdField.IsDummy || pathIdField.IsDummy)
            {
                return false;
            }

            fileId = fileIdField.AsInt;
            pathId = pathIdField.AsLong;
            return true;
        }

        private static string CreateInjectedName(int entryIndex, long pathId)
        {
            return InjectedNamePrefix
                + entryIndex.ToString("D4", CultureInfo.InvariantCulture)
                + "_"
                + unchecked((ulong)pathId).ToString("X16", CultureInfo.InvariantCulture);
        }

        private static void VerifySourceUnchanged(string inputPath, string expectedSha256)
        {
            string actualSha256 = FingerprintUtility.ComputeFileSha256(inputPath);
            if (!string.Equals(actualSha256, expectedSha256, StringComparison.Ordinal))
            {
                throw new NormalizerException(
                    ExitCode.VerificationFailure,
                    "元VRCAのSHA-256が処理中に変化しました。");
            }
        }

        private sealed class SourceSnapshot
        {
            public SourceSnapshot()
            {
                BundleEntries = new List<BundleEntrySnapshot>();
                AssetsFiles = new List<AssetsFileSnapshot>();
                NonAssetsEntryHashes = new Dictionary<int, string>();
                Candidates = new List<MenuRecord>();
            }

            public AssetBundleCompressionType CompressionType { get; set; }

            public List<BundleEntrySnapshot> BundleEntries { get; private set; }

            public List<AssetsFileSnapshot> AssetsFiles { get; private set; }

            public Dictionary<int, string> NonAssetsEntryHashes { get; private set; }

            public List<MenuRecord> Candidates { get; private set; }

            public int MenuCount { get; set; }

            public int MeshCount { get; set; }

            public int ControlCount { get; set; }

            public int SubMenuControlCount { get; set; }

            public int IconReferenceCount { get; set; }

            public int ParameterReferenceCount { get; set; }

            public int SubParameterCount { get; set; }

            public int LabelCount { get; set; }

            public int LabelIconReferenceCount { get; set; }

            public string RootMenuName { get; set; }

            public string MenuGraphSha256 { get; set; }

            public AssetsManager PreparedManager { get; set; }

            public BundleFileInstance PreparedBundle { get; set; }

            public HashSet<AssetKey> AllAssets
            {
                get
                {
                    HashSet<AssetKey> assets = new HashSet<AssetKey>();
                    foreach (AssetsFileSnapshot file in AssetsFiles)
                    {
                        assets.UnionWith(file.AllAssets);
                    }

                    return assets;
                }
            }

            public Dictionary<AssetKey, string> NonTargetAssetHashes
            {
                get
                {
                    Dictionary<AssetKey, string> hashes =
                        new Dictionary<AssetKey, string>();
                    foreach (AssetsFileSnapshot file in AssetsFiles)
                    {
                        foreach (KeyValuePair<AssetKey, string> pair in file.NonTargetAssetHashes)
                        {
                            hashes.Add(pair.Key, pair.Value);
                        }
                    }

                    return hashes;
                }
            }
        }

        private sealed class AssetsFileSnapshot
        {
            public AssetsFileSnapshot(
                int entryIndex,
                string entryName,
                AssetsFileInstance assetsInstance)
            {
                EntryIndex = entryIndex;
                EntryName = entryName;
                AssetsInstance = assetsInstance;
                AllAssets = new HashSet<AssetKey>();
                NonTargetAssetHashes = new Dictionary<AssetKey, string>();
                Menus = new List<MenuRecord>();
                Candidates = new List<MenuRecord>();
                DescriptorRootReferences =
                    new List<AssetReference>();
            }

            public int EntryIndex { get; private set; }

            public string EntryName { get; private set; }

            public AssetsFileInstance AssetsInstance { get; private set; }

            public string MetadataFingerprint { get; set; }

            public HashSet<AssetKey> AllAssets { get; private set; }

            public Dictionary<AssetKey, string> NonTargetAssetHashes { get; private set; }

            public List<MenuRecord> Menus { get; private set; }

            public List<MenuRecord> Candidates { get; private set; }

            public List<AssetReference> DescriptorRootReferences
            {
                get;
                private set;
            }

            public int MeshCount { get; set; }

            public int ControlCount { get; set; }

            public int SubMenuControlCount { get; set; }

            public int IconReferenceCount { get; set; }

            public int ParameterReferenceCount { get; set; }

            public int SubParameterCount { get; set; }

            public int LabelCount { get; set; }

            public int LabelIconReferenceCount { get; set; }

            public bool HasModifications { get; set; }
        }

        private sealed class AssetReference
        {
            public AssetReference(
                int entryIndex,
                int fileId,
                long pathId)
            {
                EntryIndex = entryIndex;
                FileId = fileId;
                PathId = pathId;
            }

            public int EntryIndex { get; private set; }

            public int FileId { get; private set; }

            public long PathId { get; private set; }
        }

        private sealed class BundleEntrySnapshot
        {
            public BundleEntrySnapshot(int entryIndex, string entryName, bool isAssetsFile)
            {
                EntryIndex = entryIndex;
                EntryName = entryName;
                IsAssetsFile = isAssetsFile;
            }

            public int EntryIndex { get; private set; }

            public string EntryName { get; private set; }

            public bool IsAssetsFile { get; private set; }
        }

        private sealed class LoadedAssetsEntry
        {
            public LoadedAssetsEntry(
                int entryIndex,
                string entryName,
                AssetsFileInstance assetsInstance,
                Dictionary<long, MonoScriptIdentity> scripts)
            {
                EntryIndex = entryIndex;
                EntryName = entryName;
                AssetsInstance = assetsInstance;
                Scripts = scripts;
            }

            public int EntryIndex { get; private set; }

            public string EntryName { get; private set; }

            public AssetsFileInstance AssetsInstance { get; private set; }

            public Dictionary<long, MonoScriptIdentity> Scripts
            {
                get;
                private set;
            }
        }

        private sealed class MenuRecord
        {
            public AssetKey Key { get; set; }

            public AssetTypeValueField BaseField { get; set; }

            public string OriginalName { get; set; }

            public string ExpectedName { get; set; }

            public string ControlsFingerprint { get; set; }

            public string PPtrFingerprint { get; set; }

            public string NonNameFingerprint { get; set; }

            public int ControlCount { get; set; }

            public int SubMenuControlCount { get; set; }

            public int IconReferenceCount { get; set; }

            public int ParameterReferenceCount { get; set; }

            public int SubParameterCount { get; set; }

            public int LabelCount { get; set; }

            public int LabelIconReferenceCount { get; set; }

            public List<ControlSemanticRecord> Controls { get; set; }
        }

        private sealed class MenuMetrics
        {
            public MenuMetrics()
            {
                Controls = new List<ControlSemanticRecord>();
            }

            public int ControlCount { get; set; }

            public int SubMenuControlCount { get; set; }

            public int IconReferenceCount { get; set; }

            public int ParameterReferenceCount { get; set; }

            public int SubParameterCount { get; set; }

            public int LabelCount { get; set; }

            public int LabelIconReferenceCount { get; set; }

            public List<ControlSemanticRecord> Controls { get; private set; }
        }

        private sealed class ControlSemanticRecord
        {
            public ControlSemanticRecord()
            {
                SubParameterNames = new List<string>();
                Labels = new List<LabelSemanticRecord>();
            }

            public string Name { get; set; }

            public int Type { get; set; }

            public string ParameterName { get; set; }

            public float Value { get; set; }

            public bool HasStyle { get; set; }

            public int Style { get; set; }

            public int IconFileId { get; set; }

            public long IconPathId { get; set; }

            public string IconStableId { get; set; }

            public string IconSourceKey { get; set; }

            public bool HasIcon
            {
                get
                {
                    return IconFileId != 0 ||
                           IconPathId != 0;
                }
            }

            public int SubMenuFileId { get; set; }

            public long SubMenuPathId { get; set; }

            public bool HasSubMenuReference
            {
                get
                {
                    return SubMenuFileId != 0 ||
                           SubMenuPathId != 0;
                }
            }

            public List<string> SubParameterNames { get; private set; }

            public List<LabelSemanticRecord> Labels { get; private set; }
        }

        private sealed class LabelSemanticRecord
        {
            public string Name { get; set; }

            public int IconFileId { get; set; }

            public long IconPathId { get; set; }

            public string IconStableId { get; set; }

            public string IconSourceKey { get; set; }

            public bool HasIcon
            {
                get
                {
                    return IconFileId != 0 ||
                           IconPathId != 0;
                }
            }
        }

        private sealed class MonoScriptIdentity
        {
            public MonoScriptIdentity(
                string name,
                string className,
                string scriptNamespace,
                string assemblyName)
            {
                Name = name;
                ClassName = className;
                Namespace = scriptNamespace;
                AssemblyName = assemblyName;
            }

            public string Name { get; private set; }

            public string ClassName { get; private set; }

            public string Namespace { get; private set; }

            public string AssemblyName { get; private set; }

            public bool IsExpressionsMenu
            {
                get
                {
                    return string.Equals(Name, MenuScriptName, StringComparison.Ordinal)
                        && string.Equals(ClassName, MenuClassName, StringComparison.Ordinal)
                        && string.Equals(Namespace, MenuNamespace, StringComparison.Ordinal)
                        && string.Equals(
                            AssemblyName,
                            MenuAssemblyName,
                            StringComparison.Ordinal);
                }
            }

            public bool IsAvatarDescriptor
            {
                get
                {
                    return string.Equals(
                               Name,
                               AvatarDescriptorScriptName,
                               StringComparison.Ordinal)
                           && string.Equals(
                               ClassName,
                               AvatarDescriptorClassName,
                               StringComparison.Ordinal)
                           && string.Equals(
                               Namespace,
                               AvatarDescriptorNamespace,
                               StringComparison.Ordinal)
                           && string.Equals(
                               AssemblyName,
                               MenuAssemblyName,
                               StringComparison.Ordinal);
                }
            }
        }

        private sealed class AssetKey : IEquatable<AssetKey>
        {
            public AssetKey(int entryIndex, string entryName, long pathId, int typeId)
            {
                EntryIndex = entryIndex;
                EntryName = entryName;
                PathId = pathId;
                TypeId = typeId;
            }

            public int EntryIndex { get; private set; }

            public string EntryName { get; private set; }

            public long PathId { get; private set; }

            public int TypeId { get; private set; }

            public bool Equals(AssetKey other)
            {
                return other != null
                    && EntryIndex == other.EntryIndex
                    && PathId == other.PathId
                    && TypeId == other.TypeId
                    && string.Equals(EntryName, other.EntryName, StringComparison.Ordinal);
            }

            public override bool Equals(object obj)
            {
                return Equals(obj as AssetKey);
            }

            public override int GetHashCode()
            {
                unchecked
                {
                    int hash = EntryIndex;
                    hash = (hash * 397) ^ PathId.GetHashCode();
                    hash = (hash * 397) ^ TypeId;
                    hash = (hash * 397) ^ StringComparer.Ordinal.GetHashCode(EntryName);
                    return hash;
                }
            }

            public override string ToString()
            {
                return string.Format(
                    CultureInfo.InvariantCulture,
                    "{0}[{1}] pathID={2}, classID={3}",
                    EntryName,
                    EntryIndex,
                    PathId,
                    TypeId);
            }
        }
    }
}
