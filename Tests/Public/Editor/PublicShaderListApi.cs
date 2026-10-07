using System;
using System.Collections;
using System.Linq;
using System.Reflection;
using System.Runtime.ExceptionServices;

using UnityEngine;

namespace AvatarRecovery.PublicTests
{
    // 配布DLLに残る画面の入口を呼びます。製品の処理や行データはテスト側で再実装しません。
    internal sealed class PublicShaderListApi : IDisposable
    {
        private const string AssemblyName = "EditorTools.AvatarRecovery.Editor";
        private const string WindowTypeName = "EditorTools.AvatarRecovery.ShaderListViewerWindow";
        private const BindingFlags Flags = BindingFlags.Public | BindingFlags.NonPublic |
            BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly;
        private readonly Type _windowType;
        private ScriptableObject _window;

        internal PublicShaderListApi()
        {
            var assembly = AppDomain.CurrentDomain.GetAssemblies()
                .Single(candidate => candidate.GetName().Name == AssemblyName);
            _windowType = assembly.GetType(WindowTypeName, true);
            _window = ScriptableObject.CreateInstance(_windowType);
        }

        internal IList Rows => (IList)RequireField("_materialRows").GetValue(_window);

        internal void LoadReport(string rootAssetPath)
        {
            Invoke("LoadFromRoot", rootAssetPath);
        }

        internal void SelectAll(bool selected)
        {
            Invoke("SetMaterialRowsSelected", Rows, selected);
        }

        internal void SelectRow(int index)
        {
            // 製品がCSVから読み込んだ行をそのまま選択操作へ渡します。
            var selection = (IList)Activator.CreateInstance(Rows.GetType());
            selection.Add(Rows[index]);
            Invoke("SetMaterialRowsSelected", selection, true);
        }

        internal void UseShaderDefaultForUnknownQueue(bool enabled)
        {
            RequireField("_useShaderDefaultForUnknownQueue").SetValue(_window, enabled);
        }

        internal void Reassign()
        {
            Invoke("ReassignSelectedMaterialShaders", false);
        }

        internal string QueueLabel(int index)
        {
            return (string)Invoke("GetRenderQueueLabel", Rows[index]);
        }

        internal string[] ReadRowStrings(int index)
        {
            // 出力の文字列だけを検査し、行の型名やフィールド名には依存しません。
            var row = Rows[index];
            return row.GetType().GetFields(Flags)
                .Where(field => field.FieldType == typeof(string))
                .Select(field => (string)field.GetValue(row)).ToArray();
        }

        public void Dispose()
        {
            if (_window == null) return;
            UnityEngine.Object.DestroyImmediate(_window);
            _window = null;
        }

        private FieldInfo RequireField(string name)
        {
            var field = _windowType.GetField(name, Flags);
            if (field == null)
                throw new InvalidOperationException("配布版に必要な画面設定がありません: " + name);
            return field;
        }

        private object Invoke(string name, params object[] arguments)
        {
            var candidates = _windowType.GetMethods(Flags).Where(method =>
                method.Name == name && ParametersMatch(method.GetParameters(), arguments)).ToArray();
            if (candidates.Length != 1)
                throw new InvalidOperationException("配布版の呼び出し先を一意に確認できません: " + name);
            try
            {
                return candidates[0].Invoke(candidates[0].IsStatic ? null : _window, arguments);
            }
            catch (TargetInvocationException exception) when (exception.InnerException != null)
            {
                ExceptionDispatchInfo.Capture(exception.InnerException).Throw();
                throw;
            }
        }

        private static bool ParametersMatch(ParameterInfo[] parameters, object[] arguments)
        {
            if (parameters.Length != arguments.Length) return false;
            for (var index = 0; index < parameters.Length; index++)
            {
                if (arguments[index] == null || !parameters[index].ParameterType.IsInstanceOfType(arguments[index]))
                    return false;
            }
            return true;
        }
    }
}
