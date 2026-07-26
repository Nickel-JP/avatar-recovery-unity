using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace AvatarRecovery.Tools.ExpressionMenuNormalizer
{
    internal enum ExitCode
    {
        Success = 0,
        InvalidArguments = 2,
        InvalidInput = 3,
        ParseFailure = 4,
        WriteFailure = 5,
        VerificationFailure = 6,
        UnexpectedFailure = 10
    }

    internal sealed class NormalizerException : Exception
    {
        public NormalizerException(ExitCode exitCode, string message)
            : base(message)
        {
            ExitCode = exitCode;
        }

        public NormalizerException(ExitCode exitCode, string message, Exception innerException)
            : base(message, innerException)
        {
            ExitCode = exitCode;
        }

        public ExitCode ExitCode { get; private set; }
    }

    internal sealed class CommandLineOptions
    {
        private CommandLineOptions(string inputPath, string outputPath, string classPackagePath)
        {
            InputPath = inputPath;
            OutputPath = outputPath;
            ClassPackagePath = classPackagePath;
        }

        public string InputPath { get; private set; }

        public string OutputPath { get; private set; }

        public string ClassPackagePath { get; private set; }

        public static CommandLineOptions Parse(string[] args)
        {
            if (args == null)
            {
                throw Usage("引数がありません。");
            }

            Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
            for (int index = 0; index < args.Length; index++)
            {
                string key = args[index];
                if (key != "--input" && key != "--output" && key != "--class-package")
                {
                    throw Usage("未対応の引数です: " + key);
                }

                if (values.ContainsKey(key))
                {
                    throw Usage("引数が重複しています: " + key);
                }

                if (index + 1 >= args.Length || args[index + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    throw Usage("引数の値がありません: " + key);
                }

                values.Add(key, args[++index]);
            }

            string input;
            string output;
            string classPackage;
            if (!values.TryGetValue("--input", out input)
                || !values.TryGetValue("--output", out output)
                || !values.TryGetValue("--class-package", out classPackage))
            {
                throw Usage("必須引数が不足しています。");
            }

            string fullInput = GetFullPath(input, "--input");
            string fullOutput = GetFullPath(output, "--output");
            string fullClassPackage = GetFullPath(classPackage, "--class-package");

            if (!File.Exists(fullInput))
            {
                throw new NormalizerException(ExitCode.InvalidInput, "入力VRCAが見つかりません: " + fullInput);
            }

            if (new FileInfo(fullInput).Length == 0)
            {
                throw new NormalizerException(ExitCode.InvalidInput, "入力VRCAが空です: " + fullInput);
            }

            if (!File.Exists(fullClassPackage))
            {
                throw new NormalizerException(
                    ExitCode.InvalidInput,
                    "class.tpkが見つかりません: " + fullClassPackage);
            }

            if (new FileInfo(fullClassPackage).Length == 0)
            {
                throw new NormalizerException(
                    ExitCode.InvalidInput,
                    "class.tpkが空です: " + fullClassPackage);
            }

            if (string.Equals(fullInput, fullOutput, StringComparison.OrdinalIgnoreCase))
            {
                throw new NormalizerException(
                    ExitCode.InvalidInput,
                    "元VRCAと出力先に同じパスは指定できません。");
            }

            if (Directory.Exists(fullOutput))
            {
                throw new NormalizerException(
                    ExitCode.InvalidInput,
                    "出力先はディレクトリではなくファイルパスを指定してください: " + fullOutput);
            }

            if (File.Exists(fullOutput))
            {
                throw new NormalizerException(
                    ExitCode.InvalidInput,
                    "既存ファイルの上書きは禁止されています: " + fullOutput);
            }

            return new CommandLineOptions(fullInput, fullOutput, fullClassPackage);
        }

        private static string GetFullPath(string path, string optionName)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                throw Usage(optionName + " が空です。");
            }

            try
            {
                return Path.GetFullPath(path);
            }
            catch (Exception exception)
            {
                throw new NormalizerException(
                    ExitCode.InvalidArguments,
                    optionName + " のパスが不正です: " + path,
                    exception);
            }
        }

        private static NormalizerException Usage(string message)
        {
            return new NormalizerException(
                ExitCode.InvalidArguments,
                message
                + Environment.NewLine
                + "Usage: ExpressionMenuNormalizer.exe --input <original.vrca> "
                + "--output <temporary.vrca> --class-package <class.tpk>");
        }
    }

    internal sealed class NormalizationResult
    {
        public int SchemaVersion { get; set; }

        public string Status { get; set; }

        public string SourceSha256 { get; set; }

        public string OutputSha256 { get; set; }

        public int CandidateCount { get; set; }

        public int RenamedCount { get; set; }

        public int MenuCountBefore { get; set; }

        public int MenuCountAfter { get; set; }

        public int MeshCount { get; set; }

        public int ControlCount { get; set; }

        public int SubMenuControlCount { get; set; }

        public int IconReferenceCount { get; set; }

        public int ParameterReferenceCount { get; set; }

        public int SubParameterCount { get; set; }

        public int LabelCount { get; set; }

        public int LabelIconReferenceCount { get; set; }

        public string MenuGraphSha256 { get; set; }

        public string Message { get; set; }
    }

    internal static class ResultJsonSerializer
    {
        public static string Serialize(NormalizationResult result)
        {
            StringBuilder builder = new StringBuilder(512);
            builder.Append('{');
            AppendNumber(builder, "schemaVersion", result.SchemaVersion, true);
            AppendString(builder, "status", result.Status, false);
            AppendString(builder, "sourceSha256", result.SourceSha256, false);
            AppendNullableString(builder, "outputSha256", result.OutputSha256, false);
            AppendNumber(builder, "candidateCount", result.CandidateCount, false);
            AppendNumber(builder, "renamedCount", result.RenamedCount, false);
            AppendNumber(builder, "menuCountBefore", result.MenuCountBefore, false);
            AppendNumber(builder, "menuCountAfter", result.MenuCountAfter, false);
            AppendNumber(builder, "meshCount", result.MeshCount, false);
            AppendNumber(builder, "controlCount", result.ControlCount, false);
            AppendNumber(
                builder,
                "subMenuControlCount",
                result.SubMenuControlCount,
                false);
            AppendNumber(
                builder,
                "iconReferenceCount",
                result.IconReferenceCount,
                false);
            AppendNumber(
                builder,
                "parameterReferenceCount",
                result.ParameterReferenceCount,
                false);
            AppendNumber(
                builder,
                "subParameterCount",
                result.SubParameterCount,
                false);
            AppendNumber(builder, "labelCount", result.LabelCount, false);
            AppendNumber(
                builder,
                "labelIconReferenceCount",
                result.LabelIconReferenceCount,
                false);
            AppendString(
                builder,
                "menuGraphSha256",
                result.MenuGraphSha256,
                false);
            AppendString(builder, "message", result.Message, false);
            builder.Append('}');
            return builder.ToString();
        }

        private static void AppendNumber(
            StringBuilder builder,
            string propertyName,
            int value,
            bool first)
        {
            AppendSeparator(builder, first);
            AppendQuoted(builder, propertyName);
            builder.Append(':');
            builder.Append(value.ToString(CultureInfo.InvariantCulture));
        }

        private static void AppendString(
            StringBuilder builder,
            string propertyName,
            string value,
            bool first)
        {
            AppendSeparator(builder, first);
            AppendQuoted(builder, propertyName);
            builder.Append(':');
            AppendQuoted(builder, value ?? string.Empty);
        }

        private static void AppendNullableString(
            StringBuilder builder,
            string propertyName,
            string value,
            bool first)
        {
            AppendSeparator(builder, first);
            AppendQuoted(builder, propertyName);
            builder.Append(':');
            if (value == null)
            {
                builder.Append("null");
            }
            else
            {
                AppendQuoted(builder, value);
            }
        }

        private static void AppendSeparator(StringBuilder builder, bool first)
        {
            if (!first)
            {
                builder.Append(',');
            }
        }

        private static void AppendQuoted(StringBuilder builder, string value)
        {
            builder.Append('"');
            foreach (char character in value)
            {
                switch (character)
                {
                    case '"':
                        builder.Append("\\\"");
                        break;
                    case '\\':
                        builder.Append("\\\\");
                        break;
                    case '\b':
                        builder.Append("\\b");
                        break;
                    case '\f':
                        builder.Append("\\f");
                        break;
                    case '\n':
                        builder.Append("\\n");
                        break;
                    case '\r':
                        builder.Append("\\r");
                        break;
                    case '\t':
                        builder.Append("\\t");
                        break;
                    default:
                        if (character < 0x20)
                        {
                            builder.Append("\\u");
                            builder.Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            builder.Append(character);
                        }

                        break;
                }
            }

            builder.Append('"');
        }
    }

    internal static class Log
    {
        public static void Info(string message)
        {
            Console.Error.WriteLine("[ExpressionMenuNormalizer] " + message);
        }

        public static void Error(string message)
        {
            Console.Error.WriteLine("[ExpressionMenuNormalizer][ERROR] " + message);
        }
    }
}
