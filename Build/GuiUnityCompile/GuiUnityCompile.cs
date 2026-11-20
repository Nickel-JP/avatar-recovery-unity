#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

using UnityEditor;
using UnityEditor.Compilation;
using UnityEngine;

namespace AvatarRecovery.Build
{
    // 初回importの結果は使用せず、GUIメニューで開始したコンパイルだけを記録します。
    [InitializeOnLoad]
    internal static class GuiUnityCompile
    {
        private const string SessionKey = "AvatarRecovery.Build.GuiCompile.Session";
        private const string ObservationKey = "AvatarRecovery.Build.GuiCompile.Observation";
        private const string ArmMenu = "Tools/AvatarRecovery Build/1. Arm and Compile";
        private const string ExportMenu = "Tools/AvatarRecovery Build/2. Export Compile Receipt";
        private const string RequiredUnityVersion = "2022.3.22f1";
        private static string ProjectRoot => Normalize(Directory.GetParent(Application.dataPath).FullName);
        private static string RequestPath => Path.Combine(ProjectRoot, ".avatar-recovery-gui-compile/request.json");

        [Serializable]
        private sealed class FileRecord
        {
            public string Path;
            public long Length;
            public string Sha256;
        }

        [Serializable]
        private sealed class Request
        {
            public int SchemaVersion;
            public string RequestNonce;
            public string CreatedUtc;
            public string ProjectRoot;
            public string SourcePackageRoot;
            public string PackageId;
            public string Version;
            public string UnityVersion;
            public string AssemblyName;
            public string AssemblyPath;
            public string PackageRelativeRoot;
            public string ReceiptPath;
            public FileRecord[] SourceFiles;
            public FileRecord[] OriginFiles;
            public FileRecord[] PayloadFiles;
        }

        [Serializable]
        private sealed class Observation
        {
            public string State;
            public string RequestNonce;
            public string RequestSha256;
            public string EditorSessionNonce;
            public string CompilationId;
            public string StartedUtc;
            public string FinishedUtc;
            public int CompileErrorCount;
            public bool TargetAssemblyCompiled;
            public bool TargetAssemblyUnchanged;
            public bool CleanBuildCacheRequested;
            public string BeforeAssemblySha256;
            public string AssemblySha256;
            public string ExpectedAssemblyPath;
            public string TargetAssemblyEventPath;
        }

        [Serializable]
        private sealed class Diagnostic
        {
            public string Utc;
            public string Event;
            public string State;
            public string RequestNonce;
            public string CompilationId;
            public string EditorSessionNonce;
            public string AssemblyPath;
            public string NormalizedAssemblyPath;
            public string ExpectedAssemblyPath;
            public bool MatchesTarget;
            public int EventErrorCount;
            public int CompileErrorCount;
            public bool TargetAssemblyCompiled;
            public bool TargetAssemblyUnchanged;
            public string BeforeAssemblySha256;
            public string ObservedAssemblySha256;
            public string CurrentAssemblySha256;
            public string Error;
        }

        [Serializable]
        private sealed class Receipt
        {
            public int SchemaVersion;
            public string RequestNonce;
            public string RequestSha256;
            public string ProjectRoot;
            public string UnityVersion;
            public string AssemblyName;
            public string AssemblyPath;
            public string AssemblySha256;
            public string AssemblyMvid;
            public bool IsBatchMode;
            public bool ExportedFromMenu;
            public bool TargetAssemblyCompiled;
            public bool TargetAssemblyUnchanged;
            public bool CleanBuildCacheRequested;
            public string BeforeAssemblySha256;
            public string TargetAssemblyEventPath;
            public int CompileErrorCount;
            public string EditorSessionNonce;
            public string CompilationId;
            public string StartedUtc;
            public string FinishedUtc;
            public string ExportedUtc;
        }

        [Serializable]
        private sealed class PackageIdentity
        {
            public string name;
            public string version;
        }

        static GuiUnityCompile()
        {
            if (string.IsNullOrEmpty(SessionState.GetString(SessionKey, string.Empty)))
                SessionState.SetString(SessionKey, Guid.NewGuid().ToString("N"));
            CompilationPipeline.compilationStarted += OnCompilationStarted;
            CompilationPipeline.assemblyCompilationFinished += OnAssemblyCompilationFinished;
            CompilationPipeline.assemblyCompilationNotRequired += OnAssemblyCompilationNotRequired;
            CompilationPipeline.compilationFinished += OnCompilationFinished;
        }

        [MenuItem(ArmMenu)]
        private static void ArmAndCompile()
        {
            try
            {
                RequireIdleGui();
                var request = ReadRequest();
                ValidateInputs(request);
                if (File.Exists(request.ReceiptPath))
                    throw new InvalidOperationException("このビルドのreceiptは既に保存されています。");
                var assemblyPath = NormalizeProjectPath(request.AssemblyPath);
                var observation = new Observation
                {
                    State = "Armed",
                    RequestNonce = request.RequestNonce,
                    RequestSha256 = Hash(RequestPath),
                    EditorSessionNonce = SessionState.GetString(SessionKey, string.Empty),
                    CleanBuildCacheRequested = true,
                    BeforeAssemblySha256 = Hash(assemblyPath),
                    ExpectedAssemblyPath = assemblyPath
                };
                Save(observation);
                WriteDiagnostic(observation, "arm", currentHash: observation.BeforeAssemblySha256);
                CompilationPipeline.RequestScriptCompilation(RequestScriptCompilationOptions.CleanBuildCache);
                Debug.Log("GUIコンパイルの記録を開始しました。コンパイルと再読込の完了後にExport Compile Receiptを選択してください。");
            }
            catch (Exception exception) { Fail(exception); }
        }

        [MenuItem(ArmMenu, true)]
        private static bool CanArm() => !Application.isBatchMode && !EditorApplication.isCompiling &&
            !EditorApplication.isUpdating && File.Exists(RequestPath);

        private static void OnCompilationStarted(object context)
        {
            var observation = Load();
            if (observation == null || observation.State == "Exported" || observation.State == "Failed") return;
            try
            {
                RequireGui();
                var request = ReadRequest();
                RequireMatchingRequest(request, observation);
                if (observation.State != "Armed" || !observation.CleanBuildCacheRequested)
                    throw new InvalidOperationException("明示的に要求したコンパイル以外が開始されました。Armからやり直してください。");
                ValidateInputs(request);
                observation.State = "Compiling";
                observation.CompilationId = Guid.NewGuid().ToString("N");
                observation.StartedUtc = DateTime.UtcNow.ToString("O");
                observation.FinishedUtc = null;
                observation.CompileErrorCount = 0;
                observation.TargetAssemblyCompiled = false;
                observation.TargetAssemblyUnchanged = false;
                observation.AssemblySha256 = null;
                observation.TargetAssemblyEventPath = null;
                Save(observation);
                WriteDiagnostic(observation, "compilation-started");
            }
            catch (Exception exception) { Fail(exception); }
        }

        private static void OnAssemblyCompilationFinished(string assemblyPath, CompilerMessage[] messages)
        {
            var observation = Load();
            if (observation == null || observation.State != "Compiling") return;
            try
            {
                int errors = messages.Count(message => message.type == CompilerMessageType.Error);
                observation.CompileErrorCount += errors;
                var request = ReadRequest();
                RequireMatchingRequest(request, observation);
                if (SamePath(assemblyPath, Path.Combine(ProjectRoot, request.AssemblyPath)))
                {
                    if (observation.TargetAssemblyCompiled || observation.TargetAssemblyUnchanged)
                        throw new InvalidOperationException("対象assemblyのコンパイル完了が重複しました。");
                    observation.TargetAssemblyCompiled = true;
                    observation.TargetAssemblyEventPath = assemblyPath;
                    if (errors == 0)
                        observation.AssemblySha256 = Hash(assemblyPath);
                }
                Save(observation);
                WriteDiagnostic(observation, "assembly-finished", assemblyPath, errors,
                    currentHash: SamePath(assemblyPath, observation.ExpectedAssemblyPath) ? observation.AssemblySha256 : null);
            }
            catch (Exception exception) { Fail(exception); }
        }

        private static void OnAssemblyCompilationNotRequired(string assemblyPath)
        {
            var observation = Load();
            if (observation == null || observation.State != "Compiling") return;
            try
            {
                var request = ReadRequest();
                RequireMatchingRequest(request, observation);
                string currentHash = null;
                if (SamePath(assemblyPath, observation.ExpectedAssemblyPath))
                {
                    if (observation.TargetAssemblyCompiled || observation.TargetAssemblyUnchanged)
                        throw new InvalidOperationException("対象assemblyの完了通知が重複しました。");
                    currentHash = Hash(assemblyPath);
                    if (currentHash != observation.BeforeAssemblySha256)
                        throw new InvalidOperationException("NotRequired通知のDLLがArm時の内容から変わりました。");
                    // Unity 2022.3は、再コンパイル後も同一内容ならこの通知を使用します。
                    observation.TargetAssemblyUnchanged = true;
                    observation.TargetAssemblyEventPath = assemblyPath;
                    observation.AssemblySha256 = currentHash;
                }
                Save(observation);
                WriteDiagnostic(observation, "assembly-not-required", assemblyPath, currentHash: currentHash);
            }
            catch (Exception exception) { Fail(exception); }
        }

        private static void OnCompilationFinished(object context)
        {
            var observation = Load();
            if (observation == null || observation.State != "Compiling") return;
            try
            {
                var request = ReadRequest();
                RequireMatchingRequest(request, observation);
                ValidateInputs(request);
                string currentHash = Hash(observation.ExpectedAssemblyPath);
                WriteDiagnostic(observation, "compilation-finished", currentHash: currentHash);
                if (observation.CompileErrorCount != 0 || !observation.CleanBuildCacheRequested ||
                    !(observation.TargetAssemblyCompiled ^ observation.TargetAssemblyUnchanged) ||
                    string.IsNullOrEmpty(observation.AssemblySha256) ||
                    currentHash != observation.AssemblySha256 ||
                    (observation.TargetAssemblyUnchanged && currentHash != observation.BeforeAssemblySha256))
                    throw new InvalidOperationException("対象assemblyの完了確認に失敗しました。errors=" + observation.CompileErrorCount +
                        "; finished=" + observation.TargetAssemblyCompiled + "; unchanged=" + observation.TargetAssemblyUnchanged +
                        "; beforeHash=" + observation.BeforeAssemblySha256 + "; observedHash=" + observation.AssemblySha256 +
                        "; currentHash=" + currentHash + "; callbackPath=" + observation.TargetAssemblyEventPath +
                        "; expectedPath=" + observation.ExpectedAssemblyPath);
                observation.FinishedUtc = DateTime.UtcNow.ToString("O");
                observation.State = "Succeeded";
                Save(observation);
                WriteDiagnostic(observation, "compilation-accepted", currentHash: currentHash);
            }
            catch (Exception exception) { Fail(exception); }
        }

        [MenuItem(ExportMenu)]
        private static void ExportReceipt()
        {
            try
            {
                RequireIdleGui();
                var request = ReadRequest();
                var observation = Load();
                if (observation == null || observation.State != "Succeeded")
                    throw new InvalidOperationException("Arm and Compileから新しいコンパイルを完了してください。");
                RequireMatchingRequest(request, observation);
                ValidateInputs(request);
                var dllPath = Path.Combine(ProjectRoot, request.AssemblyPath);
                var currentHash = Hash(dllPath);
                if (currentHash != observation.AssemblySha256)
                    throw new InvalidOperationException("コンパイル後に対象DLLが変わりました。");
                if (!observation.CleanBuildCacheRequested ||
                    !(observation.TargetAssemblyCompiled ^ observation.TargetAssemblyUnchanged) ||
                    (observation.TargetAssemblyUnchanged && currentHash != observation.BeforeAssemblySha256))
                    throw new InvalidOperationException("対象assemblyの完了種別またはArm時のDLLと一致しません。");
                var compiledAssembly = CompilationPipeline.GetAssemblies(AssembliesType.Editor)
                    .Single(assembly => assembly.name == request.AssemblyName);
                if (!SamePath(compiledAssembly.outputPath, dllPath) || compiledAssembly.sourceFiles.Length == 0)
                    throw new InvalidOperationException("対象assemblyの出力先またはソースが一致しません。");
                var sourcePaths = new HashSet<string>(request.SourceFiles.Select(record => record.Path), StringComparer.Ordinal);
                var packagePrefix = request.PackageRelativeRoot + "/";
                foreach (var source in compiledAssembly.sourceFiles)
                {
                    var relative = Relative(ProjectRoot, source);
                    if (!relative.StartsWith(packagePrefix, StringComparison.Ordinal) || !sourcePaths.Contains(relative))
                        throw new InvalidOperationException("対象assemblyが固定したpackage以外のソースを使用しています。");
                }
                // domain reload後にUnityが実際に読み込んだassemblyのMVIDを記録します。
                var loaded = AppDomain.CurrentDomain.GetAssemblies().Single(assembly => assembly.GetName().Name == request.AssemblyName);
                if (!SamePath(loaded.Location, dllPath))
                    throw new InvalidOperationException("Unityが読み込んだassemblyの場所が一致しません。");
                var receipt = new Receipt
                {
                    SchemaVersion = 1,
                    RequestNonce = request.RequestNonce,
                    RequestSha256 = observation.RequestSha256,
                    ProjectRoot = request.ProjectRoot,
                    UnityVersion = Application.unityVersion,
                    AssemblyName = request.AssemblyName,
                    AssemblyPath = request.AssemblyPath,
                    AssemblySha256 = currentHash,
                    AssemblyMvid = loaded.ManifestModule.ModuleVersionId.ToString("D"),
                    IsBatchMode = Application.isBatchMode,
                    ExportedFromMenu = true,
                    TargetAssemblyCompiled = observation.TargetAssemblyCompiled,
                    TargetAssemblyUnchanged = observation.TargetAssemblyUnchanged,
                    CleanBuildCacheRequested = observation.CleanBuildCacheRequested,
                    BeforeAssemblySha256 = observation.BeforeAssemblySha256,
                    TargetAssemblyEventPath = observation.TargetAssemblyEventPath,
                    CompileErrorCount = observation.CompileErrorCount,
                    EditorSessionNonce = observation.EditorSessionNonce,
                    CompilationId = observation.CompilationId,
                    StartedUtc = observation.StartedUtc,
                    FinishedUtc = observation.FinishedUtc,
                    ExportedUtc = DateTime.UtcNow.ToString("O")
                };
                var temporaryPath = request.ReceiptPath + ".tmp";
                using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
                    writer.Write(JsonUtility.ToJson(receipt, true));
                WriteDiagnostic(observation, "export-ready", currentHash: currentHash);
                File.Move(temporaryPath, request.ReceiptPath);
                observation.State = "Exported";
                Save(observation);
                Debug.Log("GUIコンパイルのreceiptを保存しました。待機中のビルドが後続工程へ進みます。");
            }
            catch (Exception exception) { Fail(exception); }
        }

        [MenuItem(ExportMenu, true)]
        private static bool CanExport() => CanArm() && Load()?.State == "Succeeded";

        private static Request ReadRequest()
        {
            RequireGui();
            AssertRegularPath(RequestPath);
            var request = JsonUtility.FromJson<Request>(File.ReadAllText(RequestPath, Encoding.UTF8));
            if (request == null || request.SchemaVersion != 1 ||
                !Regex.IsMatch(request.RequestNonce ?? string.Empty, "^[0-9a-f]{32}$") ||
                request.UnityVersion != RequiredUnityVersion || Application.unityVersion != RequiredUnityVersion ||
                !SamePath(request.ProjectRoot, ProjectRoot) ||
                request.PackageRelativeRoot != "Packages/" + request.PackageId ||
                request.AssemblyPath != "Library/ScriptAssemblies/" + request.AssemblyName + ".dll" ||
                !SamePath(request.ReceiptPath, Path.Combine(ProjectRoot, ".avatar-recovery-gui-compile/" + request.RequestNonce + ".receipt.json")))
                throw new InvalidOperationException("GUIコンパイル要求のproject・Unity版・identityが一致しません。");
            var package = JsonUtility.FromJson<PackageIdentity>(File.ReadAllText(
                Resolve(ProjectRoot, request.PackageRelativeRoot + "/package.json"), Encoding.UTF8));
            if (package == null || package.name != request.PackageId || package.version != request.Version)
                throw new InvalidOperationException("固定したpackage identityと一致しません。");
            return request;
        }

        private static void ValidateInputs(Request request)
        {
            ValidateManifest(ProjectRoot, request.SourceFiles, true);
            ValidateManifest(request.SourcePackageRoot, request.OriginFiles, false);
            foreach (var record in request.PayloadFiles ?? throw new InvalidOperationException("payload一覧がありません。"))
            {
                VerifyFile(ProjectRoot, record);
                var prefix = request.PackageRelativeRoot + "/";
                if (!record.Path.StartsWith(prefix, StringComparison.Ordinal))
                    throw new InvalidOperationException("payloadの相対パスが不正です。");
                VerifyFile(request.SourcePackageRoot, new FileRecord
                {
                    Path = record.Path.Substring(prefix.Length), Length = record.Length, Sha256 = record.Sha256
                });
            }
        }

        private static void ValidateManifest(string root, FileRecord[] expected, bool project)
        {
            if (expected == null || expected.Length == 0) throw new InvalidOperationException("ソース一覧がありません。");
            var paths = new HashSet<string>(StringComparer.Ordinal);
            var searchRoots = project ? new[] { "Assets", "Packages", "ProjectSettings" } : new[] { string.Empty };
            foreach (var searchRoot in searchRoots)
            {
                var directories = new Stack<string>();
                directories.Push(Path.Combine(root, searchRoot));
                while (directories.Count > 0)
                {
                    var directory = directories.Pop();
                    AssertRegularPath(directory);
                    foreach (var path in Directory.GetFileSystemEntries(directory))
                    {
                        var name = Path.GetFileName(path);
                        if (name.StartsWith(".", StringComparison.Ordinal) || name.EndsWith("~", StringComparison.Ordinal)) continue;
                        AssertRegularPath(path);
                        if (Directory.Exists(path)) { directories.Push(path); continue; }
                        var relative = Relative(root, path);
                        if (IsInputPath(relative)) paths.Add(relative);
                    }
                }
            }
            if (paths.Count != expected.Length || !paths.SetEquals(expected.Select(record => record.Path)))
                throw new InvalidOperationException("コンパイル対象のソース一覧が変わりました。");
            foreach (var record in expected) VerifyFile(root, record);
        }

        private static bool IsInputPath(string relative)
        {
            var segments = relative.Split('/');
            if (segments.Any(segment => segment.StartsWith(".", StringComparison.Ordinal) || segment.EndsWith("~", StringComparison.Ordinal)))
                return false;
            if (relative.StartsWith("ProjectSettings/", StringComparison.Ordinal))
                return !relative.EndsWith(".meta", StringComparison.OrdinalIgnoreCase);
            return Regex.IsMatch(relative, "\\.(cs|asmdef|asmref|rsp|dll)$", RegexOptions.IgnoreCase) ||
                Regex.IsMatch(relative, "\\.(asmdef|asmref|dll)\\.meta$", RegexOptions.IgnoreCase) ||
                segments[segments.Length - 1] == "package.json" || relative == "Packages/manifest.json" ||
                relative == "Packages/packages-lock.json";
        }

        private static void VerifyFile(string root, FileRecord record)
        {
            var path = Resolve(root, record.Path);
            if (record.Length < 0 || !Regex.IsMatch(record.Sha256 ?? string.Empty, "^[0-9a-f]{64}$") ||
                new FileInfo(path).Length != record.Length || Hash(path) != record.Sha256)
                throw new InvalidOperationException("固定したソースまたはpayloadの内容が変わりました。");
        }

        private static string Resolve(string root, string relative)
        {
            var prefix = Normalize(root) + "/";
            var path = Normalize(Path.Combine(root, relative));
            if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("固定したルート外のパスです。");
            AssertRegularPath(path);
            return path;
        }

        private static string Relative(string root, string path)
        {
            var prefix = Normalize(root) + "/";
            var fullPath = Normalize(Path.IsPathRooted(path) ? path : Path.Combine(ProjectRoot, path));
            if (!fullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("コンパイル対象にルート外のソースがあります。");
            return fullPath.Substring(prefix.Length);
        }

        private static string Normalize(string path) => Path.GetFullPath(path).TrimEnd('\\', '/').Replace('\\', '/');
        private static string NormalizeProjectPath(string path) => Normalize(Path.IsPathRooted(path) ? path : Path.Combine(ProjectRoot, path));
        private static bool SamePath(string left, string right) => string.Equals(
            NormalizeProjectPath(left), NormalizeProjectPath(right), StringComparison.OrdinalIgnoreCase);

        private static void AssertRegularPath(string path)
        {
            var current = Path.GetFullPath(path);
            while (!string.IsNullOrEmpty(current))
            {
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("reparse pointを経由するパスは使用できません。");
                current = Path.GetDirectoryName(current);
            }
        }

        private static string Hash(string path)
        {
            AssertRegularPath(path);
            using (var algorithm = SHA256.Create())
            using (var stream = File.OpenRead(path))
                return BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", string.Empty).ToLowerInvariant();
        }

        private static void RequireGui()
        {
            if (Application.isBatchMode) throw new InvalidOperationException("通常のGUI Editorで操作してください。");
        }

        private static void RequireIdleGui()
        {
            RequireGui();
            if (EditorApplication.isCompiling || EditorApplication.isUpdating)
                throw new InvalidOperationException("コンパイルとimportの完了を待ってください。");
        }

        private static void RequireMatchingRequest(Request request, Observation observation)
        {
            if (observation.RequestNonce != request.RequestNonce || observation.RequestSha256 != Hash(RequestPath) ||
                observation.EditorSessionNonce != SessionState.GetString(SessionKey, string.Empty))
                throw new InvalidOperationException("要求またはEditor sessionが変わりました。");
        }

        private static Observation Load()
        {
            var json = SessionState.GetString(ObservationKey, string.Empty);
            return string.IsNullOrEmpty(json) ? null : JsonUtility.FromJson<Observation>(json);
        }

        private static void Save(Observation observation) => SessionState.SetString(ObservationKey, JsonUtility.ToJson(observation));

        private static void WriteDiagnostic(Observation observation, string eventName, string assemblyPath = null,
            int eventErrors = 0, string currentHash = null, string error = null)
        {
            var path = Resolve(ProjectRoot, ".avatar-recovery-gui-compile/" + observation.RequestNonce + ".events.private.jsonl");
            var record = new Diagnostic
            {
                Utc = DateTime.UtcNow.ToString("O"), Event = eventName, State = observation.State,
                RequestNonce = observation.RequestNonce, CompilationId = observation.CompilationId,
                EditorSessionNonce = observation.EditorSessionNonce,
                AssemblyPath = assemblyPath,
                NormalizedAssemblyPath = assemblyPath == null ? null : NormalizeProjectPath(assemblyPath),
                ExpectedAssemblyPath = observation.ExpectedAssemblyPath,
                MatchesTarget = assemblyPath != null && SamePath(assemblyPath, observation.ExpectedAssemblyPath),
                EventErrorCount = eventErrors, CompileErrorCount = observation.CompileErrorCount,
                TargetAssemblyCompiled = observation.TargetAssemblyCompiled, TargetAssemblyUnchanged = observation.TargetAssemblyUnchanged,
                BeforeAssemblySha256 = observation.BeforeAssemblySha256, ObservedAssemblySha256 = observation.AssemblySha256,
                CurrentAssemblySha256 = currentHash, Error = error
            };
            File.AppendAllText(path, JsonUtility.ToJson(record) + "\n", new UTF8Encoding(false));
        }

        private static void Fail(Exception exception)
        {
            var observation = Load();
            if (observation != null)
            {
                observation.State = "Failed";
                Save(observation);
                try { WriteDiagnostic(observation, "failed", error: exception.Message); }
                catch (Exception diagnosticException) { Debug.LogError("GUIコンパイル診断を書き込めません: " + diagnosticException.Message); }
            }
            Debug.LogError("GUIコンパイルのreceiptを保存できません: " + exception.Message);
        }
    }
}
#endif
