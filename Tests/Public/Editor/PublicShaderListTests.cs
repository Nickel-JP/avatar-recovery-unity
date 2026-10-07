using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

using NUnit.Framework;
using UnityEditor;
using UnityEngine;

namespace AvatarRecovery.PublicTests
{
    [TestFixture]
    public sealed class PublicShaderListTests
    {
        private const string PackageId = "com.nickel-jp.avatar-recovery";
        private const string ExpectedVersion = "1.2.21";
        private const string ExpectedDllSha256 = "4f650465f851f00172d373a06dba6fb9985b9d49b00b5abd7ec15ffd34bdffac";
        private const string FolderPrefix = "Assets/__AvatarRecoveryPublicTests_";
        private const string Header = "MaterialName,MaterialPath,OriginalShaderName,RenderQueue,ShaderDefaultQueue,ShaderVersion\n";
        private const int OriginalQueue = 2100;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        private static readonly Vector2 TextureScale = new Vector2(2.5f, 0.75f);
        private static readonly Vector2 TextureOffset = new Vector2(0.125f, -0.25f);
        private static readonly Vector4 VectorValue = new Vector4(1, 2, 3, 4);
        private static readonly Color ColorValue = new Color(0.25f, 0.5f, 0.75f, 1);
        private static readonly Color32[] TexturePixels =
        {
            new Color32(255, 0, 0, 255), new Color32(0, 255, 0, 128),
            new Color32(0, 0, 255, 64), new Color32(23, 47, 89, 255)
        };

        private string _folder;
        private string _reportPath;
        private byte[] _reportBytes;
        private PublicShaderListApi _viewer;
        private Shader _sourceShader;
        private Shader _targetShader;
        private Texture2D _texture;
        private byte[] _textureBytes;
        private readonly Dictionary<string, Color> _savedColors = new Dictionary<string, Color>();

        [OneTimeSetUp]
        public void RequirePinnedDistribution()
        {
            Assert.IsTrue(Application.isBatchMode, "専用プロジェクトのCLIで実行してください。");
            Assert.AreEqual("2022.3.22f1", Application.unityVersion, "検証対象のUnityバージョンが違います。");
            var package = UnityEditor.PackageManager.PackageInfo.GetAllRegisteredPackages()
                .Single(item => item.name == PackageId);
            Assert.AreEqual(ExpectedVersion, package.version, "検証対象の配布バージョンが違います。");
            var dllPath = Path.Combine(package.resolvedPath, "Editor/EditorTools.AvatarRecovery.Editor.dll");
            using (var stream = File.OpenRead(dllPath))
            using (var sha256 = SHA256.Create())
            {
                var digest = BitConverter.ToString(sha256.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                Assert.AreEqual(ExpectedDllSha256, digest, "公開1.2.21のDLLと一致しません。");
            }
        }

        [SetUp]
        public void SetUp()
        {
            _folder = FolderPrefix + Guid.NewGuid().ToString("N");
            Assert.IsNotEmpty(AssetDatabase.CreateFolder("Assets", Path.GetFileName(_folder)),
                "検証用フォルダを作成できませんでした。");
            Assert.IsNotEmpty(AssetDatabase.CreateFolder(_folder, "_ShaderReport"),
                "検証用レポートフォルダを作成できませんでした。");
            _reportPath = _folder + "/_ShaderReport/MaterialShaderMap.csv";
            _reportBytes = null;
            _savedColors.Clear();
            _viewer = new PublicShaderListApi();
        }

        [TearDown]
        public void TearDown()
        {
            try
            {
                _viewer?.Dispose();
                _viewer = null;
            }
            finally
            {
                _sourceShader = null;
                _targetShader = null;
                _texture = null;
                _textureBytes = null;
                _savedColors.Clear();
                if (_folder != null)
                {
                    Assert.IsTrue(_folder.StartsWith(FolderPrefix, StringComparison.Ordinal));
                    Assert.IsFalse(_folder.Substring(FolderPrefix.Length).Contains("/"));
                    if (AssetDatabase.IsValidFolder(_folder))
                        Assert.IsTrue(AssetDatabase.DeleteAsset(_folder), "検証用アセットを片付けられませんでした。");
                    _folder = null;
                }
            }
        }

        [TestCase("-1", "3077", "3077")]
        [TestCase("0", "2000", "0")]
        [TestCase("2450", "2000", "2450")]
        [TestCase("5000", "2000", "5000")]
        [TestCase("-1", "", "unknown")]
        [TestCase("-1", "-1", "unknown")]
        [TestCase("", "2000", "unknown")]
        [TestCase("-2", "2000", "unknown")]
        [TestCase("5001", "2000", "unknown")]
        [TestCase("invalid", "2000", "unknown")]
        public void QueueLabelsUseReportValuesWithoutInstalledShader(string queue, string defaultQueue, string expected)
        {
            const string missingShader = "AvatarRecoveryPublicTests/NotInstalled";
            Assert.IsNull(Shader.Find(missingShader));
            LoadReport(Header + CsvRow("Example", "Example.mat", missingShader, queue, defaultQueue, ""));
            Assert.AreEqual(1, _viewer.Rows.Count);
            var actual = _viewer.QueueLabel(0);
            if (expected == "unknown") Assert.That(actual, Is.EqualTo("Unknown").Or.EqualTo("不明"));
            else Assert.AreEqual(expected, actual);
            AssertReportUnchanged();
        }

        [TestCase(-1)]
        [TestCase(0)]
        [TestCase(2000)]
        [TestCase(2450)]
        [TestCase(2500)]
        [TestCase(3100)]
        [TestCase(4000)]
        [TestCase(5000)]
        public void SelectedAssignmentPreservesMaterialDataAfterSaveAndRepeat(int queue)
        {
            var path = CreateMaterial("Example.mat", queue);
            LoadReport(Header + MaterialRow("Example", "Example.mat", queue.ToString(CultureInfo.InvariantCulture)));
            _viewer.SelectAll(true);
            _viewer.Reassign();
            AssertMaterialState(path, _targetShader, queue);
            var firstSave = File.ReadAllBytes(path);

            _viewer.SelectAll(true);
            _viewer.Reassign();
            AssertMaterialState(path, _targetShader, queue);
            CollectionAssert.AreEqual(firstSave, File.ReadAllBytes(path), "再実行で保存内容が変化しました。");
            AssertReportUnchanged();
        }

        [TestCase("", false)]
        [TestCase("", true)]
        [TestCase("5001", false)]
        [TestCase("5001", true)]
        [TestCase("invalid", false)]
        [TestCase("invalid", true)]
        public void UnknownQueueFollowsSelectedPolicy(string queue, bool useDefault)
        {
            var path = CreateMaterial("Unknown.mat", OriginalQueue);
            var originalBytes = File.ReadAllBytes(path);
            LoadReport(Header + MaterialRow("Unknown", "Unknown.mat", queue));
            _viewer.SelectAll(true);
            _viewer.UseShaderDefaultForUnknownQueue(useDefault);
            _viewer.Reassign();
            AssertMaterialState(path, useDefault ? _targetShader : _sourceShader, useDefault ? -1 : OriginalQueue);
            if (!useDefault)
                CollectionAssert.AreEqual(originalBytes, File.ReadAllBytes(path), "スキップしたMaterialが変更されました。");
            AssertReportUnchanged();
        }

        [TestCase(false)]
        [TestCase(true)]
        public void UnselectedMaterialIsNotModified(bool selectThenClear)
        {
            var path = CreateMaterial("Unselected.mat", OriginalQueue);
            var originalBytes = File.ReadAllBytes(path);
            LoadReport(Header + MaterialRow("Unselected", "Unselected.mat", "3100"));
            if (selectThenClear)
            {
                _viewer.SelectAll(true);
                _viewer.SelectAll(false);
            }
            _viewer.Reassign();
            AssertMaterialState(path, _sourceShader, OriginalQueue);
            CollectionAssert.AreEqual(originalBytes, File.ReadAllBytes(path));
            AssertReportUnchanged();
        }

        [Test]
        public void SelectingOneRowLeavesOtherMaterialUnchanged()
        {
            var selectedPath = CreateMaterial("Selected.mat", OriginalQueue);
            var otherPath = CreateMaterial("Other.mat", OriginalQueue);
            var otherBytes = File.ReadAllBytes(otherPath);
            LoadReport(Header + MaterialRow("Selected", "Selected.mat", "3100") +
                MaterialRow("Other", "Other.mat", "4000"));
            Assert.AreEqual(2, _viewer.Rows.Count);
            _viewer.SelectRow(0);
            _viewer.Reassign();
            AssertMaterialState(selectedPath, _targetShader, 3100);
            AssertMaterialState(otherPath, _sourceShader, OriginalQueue);
            CollectionAssert.AreEqual(otherBytes, File.ReadAllBytes(otherPath));
            AssertReportUnchanged();
        }

        [Test]
        public void MissingOriginalShaderLeavesSelectedMaterialUnchanged()
        {
            var path = CreateMaterial("MissingShader.mat", OriginalQueue);
            var originalBytes = File.ReadAllBytes(path);
            LoadReport(Header + CsvRow("MissingShader", "MissingShader.mat",
                "AvatarRecoveryPublicTests/NotInstalled", "3100", "", ""));
            _viewer.SelectAll(true);
            _viewer.Reassign();
            AssertMaterialState(path, _sourceShader, OriginalQueue);
            CollectionAssert.AreEqual(originalBytes, File.ReadAllBytes(path));
            AssertReportUnchanged();
        }

        [TestCase("Shader 1.2.3")]
        [TestCase("Shader \"Edition, A\" 1.2.3")]
        [TestCase("Shader 1.2.3\n追加情報")]
        [TestCase("シェーダー 1.2.3")]
        public void CsvVersionLabelSurvivesReportLoading(string label)
        {
            LoadReport(Header + CsvRow("Example", "Example.mat", "Unavailable/Example", "2450", "2000", label));
            Assert.AreEqual(1, _viewer.Rows.Count);
            Assert.AreEqual(1, _viewer.ReadRowStrings(0).Count(value => value == label),
                "CSVの版ラベルが一覧の行に保持されていません。");
            Assert.AreEqual("2450", _viewer.QueueLabel(0));
            AssertReportUnchanged();
        }

        [Test]
        public void LegacyCsvWithoutQueueOrVersionLoadsAsUnknown()
        {
            const string legacy = "MaterialName,MaterialPath,OriginalShaderName,ShaderFileID,ShaderGuid,Status\n" +
                "Legacy,Legacy.mat,Unavailable/Legacy,4800000,public-test-guid,Missing\n";
            LoadReport(legacy);
            Assert.AreEqual(1, _viewer.Rows.Count);
            Assert.That(_viewer.QueueLabel(0), Is.EqualTo("Unknown").Or.EqualTo("不明"));
            CollectionAssert.Contains(_viewer.ReadRowStrings(0), "Unavailable/Legacy");
            AssertReportUnchanged();
        }

        [TestCase("")]
        [TestCase(Header)]
        public void EmptyReportLoadsWithoutRows(string csv)
        {
            LoadReport(csv);
            Assert.AreEqual(0, _viewer.Rows.Count);
            _viewer.SelectAll(true);
            _viewer.Reassign();
            AssertReportUnchanged();
        }

        private void LoadReport(string csv)
        {
            File.WriteAllText(_reportPath, csv, Utf8);
            _reportBytes = File.ReadAllBytes(_reportPath);
            AssetDatabase.ImportAsset(_reportPath, ImportAssetOptions.ForceSynchronousImport);
            _viewer.LoadReport(_folder);
        }

        private void AssertReportUnchanged()
        {
            CollectionAssert.AreEqual(_reportBytes, File.ReadAllBytes(_reportPath), "入力のCSVが書き換えられました。");
        }

        private string MaterialRow(string name, string relativePath, string queue)
        {
            return CsvRow(name, relativePath, _targetShader.name, queue, "3000", "Fixture 1.0.0");
        }

        private static string CsvRow(params string[] values)
        {
            return string.Join(",", values.Select(value => "\"" + value.Replace("\"", "\"\"") + "\"")) + "\n";
        }

        private string CreateMaterial(string name, int queue)
        {
            EnsureMaterialInputs();
            var material = new Material(_sourceShader)
            {
                renderQueue = queue,
                enableInstancing = true,
                doubleSidedGI = true,
                globalIlluminationFlags = MaterialGlobalIlluminationFlags.RealtimeEmissive
            };
            try
            {
                material.SetOverrideTag("PublicTestTag", "OriginalValue");
                material.SetTexture("_MainTex", _texture);
                material.SetTextureScale("_MainTex", TextureScale);
                material.SetTextureOffset("_MainTex", TextureOffset);
                material.SetColor("_Color", ColorValue);
                material.SetFloat("_FloatValue", 0.375f);
                material.SetVector("_VectorValue", VectorValue);
                var path = _folder + "/" + name;
                AssetDatabase.CreateAsset(material, path);
                AssetDatabase.SaveAssetIfDirty(material);
                // 製品操作前に保存・再読込し、Unityの初回保存で確定した値を基準にします。
                AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceSynchronousImport | ImportAssetOptions.ForceUpdate);
                var savedMaterial = AssetDatabase.LoadAssetAtPath<Material>(path);
                Assert.IsNotNull(savedMaterial, "操作前のMaterialを再読込できませんでした。");
                _savedColors.Add(path, savedMaterial.GetColor("_Color"));
                return path;
            }
            catch
            {
                if (!AssetDatabase.Contains(material)) UnityEngine.Object.DestroyImmediate(material);
                throw;
            }
        }

        private void EnsureMaterialInputs()
        {
            if (_sourceShader != null) return;
            var suffix = _folder.Substring(FolderPrefix.Length);
            _sourceShader = CreateShader("Source", "Geometry", suffix);
            _targetShader = CreateShader("Target", "Transparent", suffix);
            Assert.AreEqual(2000, _sourceShader.renderQueue);
            Assert.AreEqual(3000, _targetShader.renderQueue);
            _texture = new Texture2D(2, 2, TextureFormat.RGBA32, false);
            try
            {
                _texture.SetPixels32(TexturePixels);
                _texture.Apply();
                AssetDatabase.CreateAsset(_texture, _folder + "/Texture.asset");
                AssetDatabase.SaveAssetIfDirty(_texture);
                _textureBytes = File.ReadAllBytes(_folder + "/Texture.asset");
            }
            catch
            {
                if (!AssetDatabase.Contains(_texture)) UnityEngine.Object.DestroyImmediate(_texture);
                _texture = null;
                throw;
            }
        }

        private Shader CreateShader(string role, string queue, string suffix)
        {
            var path = _folder + "/" + role + ".shader";
            var name = "AvatarRecoveryPublicTests/" + suffix + "/" + role;
            var text = "Shader \"" + name + "\" { Properties {\n" +
                "_MainTex (\"Texture\", 2D) = \"white\" {}\n" +
                "_Color (\"Color\", Color) = (1,1,1,1)\n" +
                "_FloatValue (\"Float\", Float) = 0\n" +
                "_VectorValue (\"Vector\", Vector) = (0,0,0,0)\n" +
                "} SubShader { Tags { \"Queue\"=\"" + queue + "\" } Pass {} } }\n";
            File.WriteAllText(path, text, Utf8);
            AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceSynchronousImport);
            var shader = AssetDatabase.LoadAssetAtPath<Shader>(path);
            Assert.IsNotNull(shader, "合成Shaderを読み込めませんでした。");
            Assert.IsFalse(ShaderUtil.ShaderHasError(shader), "合成Shaderにコンパイルエラーがあります。");
            return shader;
        }

        private void AssertMaterialState(string path, Shader expectedShader, int expectedRawQueue)
        {
            AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceSynchronousImport | ImportAssetOptions.ForceUpdate);
            var material = AssetDatabase.LoadAssetAtPath<Material>(path);
            Assert.IsNotNull(material);
            Assert.AreEqual(expectedShader, material.shader);
            using (var serialized = new SerializedObject(material))
                Assert.AreEqual(expectedRawQueue, serialized.FindProperty("m_CustomRenderQueue").intValue);
            Assert.AreEqual(expectedRawQueue == -1 ? expectedShader.renderQueue : expectedRawQueue, material.renderQueue);
            Assert.AreEqual("OriginalValue", material.GetTag("PublicTestTag", false));
            Assert.IsTrue(material.enableInstancing);
            Assert.IsTrue(material.doubleSidedGI);
            Assert.AreEqual(MaterialGlobalIlluminationFlags.RealtimeEmissive, material.globalIlluminationFlags);
            Assert.AreEqual(_texture, material.GetTexture("_MainTex"));
            Assert.AreEqual(TextureScale, material.GetTextureScale("_MainTex"));
            Assert.AreEqual(TextureOffset, material.GetTextureOffset("_MainTex"));
            Assert.IsTrue(_savedColors.TryGetValue(path, out var savedColor), "操作前の色の基準値がありません。");
            var actualColor = material.GetColor("_Color");
            AssertColorComponent("R", savedColor.r, actualColor.r);
            AssertColorComponent("G", savedColor.g, actualColor.g);
            AssertColorComponent("B", savedColor.b, actualColor.b);
            AssertColorComponent("A", savedColor.a, actualColor.a);
            Assert.AreEqual(0.375f, material.GetFloat("_FloatValue"));
            Assert.AreEqual(VectorValue, material.GetVector("_VectorValue"));
            CollectionAssert.AreEqual(TexturePixels, _texture.GetPixels32());
            CollectionAssert.AreEqual(_textureBytes, File.ReadAllBytes(_folder + "/Texture.asset"),
                "参照先Textureの保存内容が変化しました。");
        }

        private static void AssertColorComponent(string component, float expected, float actual)
        {
            // 許容誤差を設けず、保存済み基準値とのビット単位の一致を確認します。
            var expectedBits = BitConverter.ToInt32(BitConverter.GetBytes(expected), 0);
            var actualBits = BitConverter.ToInt32(BitConverter.GetBytes(actual), 0);
            Assert.AreEqual(expectedBits, actualBits,
                "保存後の色成分 " + component + " が変化しました。基準=" +
                expected.ToString("R", CultureInfo.InvariantCulture) + ", 実測=" +
                actual.ToString("R", CultureInfo.InvariantCulture));
        }
    }
}
