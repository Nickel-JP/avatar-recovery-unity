using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

using AssetsTools.NET;

namespace AvatarRecovery.Tools.ExpressionMenuNormalizer
{
    internal static class FingerprintUtility
    {
        private const int BufferSize = 1024 * 1024;

        public static string ComputeFileSha256(string path)
        {
            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                BufferSize,
                FileOptions.SequentialScan))
            {
                return ComputeStreamSha256(stream, 0, stream.Length);
            }
        }

        public static string ComputeStreamSha256(Stream stream, long offset, long length)
        {
            if (stream == null)
            {
                throw new ArgumentNullException("stream");
            }

            if (!stream.CanRead || !stream.CanSeek)
            {
                throw new InvalidOperationException("ハッシュ対象ストリームは読み取りとシークに対応している必要があります。");
            }

            if (offset < 0 || length < 0 || offset > stream.Length - length)
            {
                throw new InvalidDataException(
                    string.Format(
                        CultureInfo.InvariantCulture,
                        "ハッシュ対象範囲が不正です。offset={0}, length={1}, streamLength={2}",
                        offset,
                        length,
                        stream.Length));
            }

            long originalPosition = stream.Position;
            try
            {
                stream.Position = offset;
                using (SHA256 sha256 = SHA256.Create())
                {
                    byte[] buffer = new byte[BufferSize];
                    long remaining = length;
                    while (remaining > 0)
                    {
                        int requested = (int)Math.Min(buffer.Length, remaining);
                        int read = stream.Read(buffer, 0, requested);
                        if (read <= 0)
                        {
                            throw new EndOfStreamException("ハッシュ対象の読み取り中に予期せず終端へ到達しました。");
                        }

                        sha256.TransformBlock(buffer, 0, read, null, 0);
                        remaining -= read;
                    }

                    sha256.TransformFinalBlock(new byte[0], 0, 0);
                    return ToHex(sha256.Hash);
                }
            }
            finally
            {
                stream.Position = originalPosition;
            }
        }

        public static string ComputeFieldFingerprint(
            AssetTypeValueField field,
            bool skipRootName)
        {
            if (field == null || field.IsDummy)
            {
                throw new InvalidDataException("フィールド指紋の対象が存在しません。");
            }

            using (MemoryStream stream = new MemoryStream())
            {
                using (BinaryWriter writer = new BinaryWriter(stream, new UTF8Encoding(false), true))
                {
                    WriteField(writer, field, skipRootName, true);
                }

                stream.Position = 0;
                return ComputeStreamSha256(stream, 0, stream.Length);
            }
        }

        public static string ComputePPtrFingerprint(AssetTypeValueField field)
        {
            if (field == null || field.IsDummy)
            {
                throw new InvalidDataException("PPtr指紋の対象が存在しません。");
            }

            using (MemoryStream stream = new MemoryStream())
            {
                using (BinaryWriter writer = new BinaryWriter(stream, new UTF8Encoding(false), true))
                {
                    WritePPtrs(writer, field, string.Empty);
                }

                stream.Position = 0;
                return ComputeStreamSha256(stream, 0, stream.Length);
            }
        }

        private static void WriteField(
            BinaryWriter writer,
            AssetTypeValueField field,
            bool skipRootName,
            bool isRoot)
        {
            WriteString(writer, field.FieldName);
            WriteString(writer, field.TypeName);
            writer.Write(field.IsDummy);

            if (field.Value == null)
            {
                writer.Write(false);
            }
            else
            {
                writer.Write(true);
                WriteString(writer, field.Value.ValueType.ToString());
                WriteValue(writer, field.Value.AsObject);
            }

            List<AssetTypeValueField> includedChildren = new List<AssetTypeValueField>();
            if (field.Children != null)
            {
                foreach (AssetTypeValueField child in field.Children)
                {
                    if (skipRootName
                        && isRoot
                        && string.Equals(child.FieldName, "m_Name", StringComparison.Ordinal))
                    {
                        continue;
                    }

                    includedChildren.Add(child);
                }
            }

            writer.Write(includedChildren.Count);
            foreach (AssetTypeValueField child in includedChildren)
            {
                WriteField(writer, child, false, false);
            }
        }

        private static void WriteValue(BinaryWriter writer, object value)
        {
            if (value == null)
            {
                writer.Write((byte)0);
                return;
            }

            byte[] byteArray = value as byte[];
            if (byteArray != null)
            {
                writer.Write((byte)1);
                writer.Write(byteArray.Length);
                writer.Write(byteArray);
                return;
            }

            string stringValue = value as string;
            if (stringValue != null)
            {
                writer.Write((byte)2);
                WriteString(writer, stringValue);
                return;
            }

            TypeCode typeCode = Type.GetTypeCode(value.GetType());
            writer.Write((byte)3);
            writer.Write((int)typeCode);

            switch (typeCode)
            {
                case TypeCode.Boolean:
                    writer.Write((bool)value);
                    break;
                case TypeCode.SByte:
                    writer.Write((sbyte)value);
                    break;
                case TypeCode.Byte:
                    writer.Write((byte)value);
                    break;
                case TypeCode.Int16:
                    writer.Write((short)value);
                    break;
                case TypeCode.UInt16:
                    writer.Write((ushort)value);
                    break;
                case TypeCode.Int32:
                    writer.Write((int)value);
                    break;
                case TypeCode.UInt32:
                    writer.Write((uint)value);
                    break;
                case TypeCode.Int64:
                    writer.Write((long)value);
                    break;
                case TypeCode.UInt64:
                    writer.Write((ulong)value);
                    break;
                case TypeCode.Single:
                    writer.Write(BitConverter.GetBytes((float)value));
                    break;
                case TypeCode.Double:
                    writer.Write(BitConverter.GetBytes((double)value));
                    break;
                case TypeCode.Decimal:
                    int[] bits = decimal.GetBits((decimal)value);
                    foreach (int bit in bits)
                    {
                        writer.Write(bit);
                    }

                    break;
                case TypeCode.Char:
                    writer.Write((char)value);
                    break;
                case TypeCode.DateTime:
                    writer.Write(((DateTime)value).ToBinary());
                    break;
                default:
                    WriteString(writer, value.GetType().FullName);
                    WriteString(writer, Convert.ToString(value, CultureInfo.InvariantCulture));
                    break;
            }
        }

        private static void WritePPtrs(
            BinaryWriter writer,
            AssetTypeValueField field,
            string path)
        {
            string currentPath = path.Length == 0
                ? field.FieldName
                : path + "/" + field.FieldName;

            AssetTypeValueField fileId;
            AssetTypeValueField pathId;
            if (IsPPtr(field, out fileId, out pathId))
            {
                WriteString(writer, currentPath);
                writer.Write(fileId.AsInt);
                writer.Write(pathId.AsLong);
            }

            if (field.Children == null)
            {
                return;
            }

            for (int index = 0; index < field.Children.Count; index++)
            {
                WritePPtrs(
                    writer,
                    field.Children[index],
                    currentPath + "[" + index.ToString(CultureInfo.InvariantCulture) + "]");
            }
        }

        private static bool IsPPtr(
            AssetTypeValueField field,
            out AssetTypeValueField fileId,
            out AssetTypeValueField pathId)
        {
            fileId = null;
            pathId = null;
            if (field == null
                || field.IsDummy
                || field.Children == null
                || !field.TypeName.StartsWith("PPtr<", StringComparison.Ordinal))
            {
                return false;
            }

            foreach (AssetTypeValueField child in field.Children)
            {
                if (string.Equals(child.FieldName, "m_FileID", StringComparison.Ordinal))
                {
                    fileId = child;
                }
                else if (string.Equals(child.FieldName, "m_PathID", StringComparison.Ordinal))
                {
                    pathId = child;
                }
            }

            return fileId != null
                && !fileId.IsDummy
                && pathId != null
                && !pathId.IsDummy;
        }

        private static void WriteString(BinaryWriter writer, string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value ?? string.Empty);
            writer.Write(bytes.Length);
            writer.Write(bytes);
        }

        private static string ToHex(byte[] bytes)
        {
            StringBuilder builder = new StringBuilder(bytes.Length * 2);
            foreach (byte value in bytes)
            {
                builder.Append(value.ToString("X2", CultureInfo.InvariantCulture));
            }

            return builder.ToString();
        }
    }
}
