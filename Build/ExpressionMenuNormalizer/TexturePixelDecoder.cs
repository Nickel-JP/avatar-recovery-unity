using System;
using System.Runtime.InteropServices;

using AssetsTools.NET.Texture;

namespace AvatarRecovery.Tools.ExpressionMenuNormalizer
{
    /// <summary>
    /// Texture2DをUnityと同じRGBA32並びへ復号する。
    /// Unity Crunchだけは管理実装の互換性問題を避け、公式AssetRipperと
    /// 同じネイティブデコーダー契約を使用する。
    /// </summary>
    internal static class TexturePixelDecoder
    {
        private const int Dxt1CrunchedFormat = 28;
        private const int Dxt5CrunchedFormat = 29;
        private const int EtcRgb4CrunchedFormat = 64;
        private const int Etc2Rgba8CrunchedFormat = 65;
        private const int BytesPerPixel = 4;

        public static byte[] DecodeRgba32(
            TextureFile textureFile,
            byte[] pictureData)
        {
            if (textureFile == null)
            {
                throw new ArgumentNullException(nameof(textureFile));
            }

            if (pictureData == null || pictureData.Length == 0)
            {
                throw new ArgumentException(
                    "Texture2Dの画像データが空です。",
                    nameof(pictureData));
            }

            int textureFormat = textureFile.m_TextureFormat;
            if (textureFormat != Dxt1CrunchedFormat &&
                textureFormat != Dxt5CrunchedFormat &&
                textureFormat != EtcRgb4CrunchedFormat &&
                textureFormat != Etc2Rgba8CrunchedFormat)
            {
                return textureFile.DecodeTextureRaw(
                    pictureData,
                    false);
            }

            byte[] blockData =
                UnityCrunchNativeDecoder.Decompress(
                    pictureData,
                    textureFile.m_Width,
                    textureFile.m_Height,
                    textureFile.m_MipCount,
                    textureFile.m_ImageCount,
                    textureFile.m_TextureDimension,
                    textureFormat);
            TextureFormat decodedFormat;
            switch (textureFormat)
            {
                case Dxt1CrunchedFormat:
                    decodedFormat = TextureFormat.DXT1;
                    break;
                case Dxt5CrunchedFormat:
                    decodedFormat = TextureFormat.DXT5;
                    break;
                case EtcRgb4CrunchedFormat:
                    decodedFormat = TextureFormat.ETC_RGB4;
                    break;
                case Etc2Rgba8CrunchedFormat:
                    decodedFormat = TextureFormat.ETC2_RGBA8;
                    break;
                default:
                    throw new InvalidOperationException(
                        "未対応のUnity Crunch形式です。");
            }

            byte[] rgbaPixels = TextureFile.DecodeManagedData(
                blockData,
                decodedFormat,
                textureFile.m_Width,
                textureFile.m_Height,
                false,
                textureFile.GetSwizzler());
            long expectedLength =
                checked(
                    (long)textureFile.m_Width *
                    textureFile.m_Height *
                    BytesPerPixel);
            if (rgbaPixels == null ||
                rgbaPixels.LongLength != expectedLength)
            {
                throw new InvalidOperationException(
                    "Unity Crunch展開後のRGBA32長が不正です。");
            }

            return rgbaPixels;
        }
    }

    internal static class UnityCrunchNativeDecoder
    {
        private const int Dxt1CrunchedFormat = 28;
        private const int Dxt5CrunchedFormat = 29;
        private const int EtcRgb4CrunchedFormat = 64;
        private const int Etc2Rgba8CrunchedFormat = 65;
        private const int Dxt1BlockBytes = 8;
        private const int Dxt5BlockBytes = 16;

        [DllImport(
            "crunchunity.dll",
            CallingConvention = CallingConvention.Cdecl,
            ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.I1)]
        private static extern bool DecompressUnityCRN(
            byte[] sourceData,
            int sourceSize,
            out IntPtr uncompressedData,
            out int uncompressedSize);

        [DllImport(
            "ucrtbase.dll",
            CallingConvention = CallingConvention.Cdecl,
            EntryPoint = "free",
            ExactSpelling = true)]
        private static extern void FreeCrtMemory(
            IntPtr memory);

        public static byte[] Decompress(
            byte[] sourceData,
            int width,
            int height,
            int mipCount,
            int imageCount,
            int textureDimension,
            int textureFormat)
        {
            if (sourceData == null || sourceData.Length == 0)
            {
                throw new ArgumentException(
                    "Unity Crunch入力が空です。",
                    nameof(sourceData));
            }

            if (width <= 0 || height <= 0)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(width),
                    "Texture2Dの寸法が不正です。");
            }

            if (mipCount <= 0 || mipCount > 32)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(mipCount),
                    "Texture2DのMip数が不正です。");
            }

            if (imageCount != 1 || textureDimension != 2)
            {
                throw new InvalidOperationException(
                    "Menu iconとして扱えないTexture2D次元です。");
            }

            int bytesPerBlock;
            if (textureFormat == Dxt1CrunchedFormat)
            {
                bytesPerBlock = Dxt1BlockBytes;
            }
            else if (textureFormat == Dxt5CrunchedFormat)
            {
                bytesPerBlock = Dxt5BlockBytes;
            }
            else if (textureFormat == EtcRgb4CrunchedFormat)
            {
                bytesPerBlock = Dxt1BlockBytes;
            }
            else if (textureFormat == Etc2Rgba8CrunchedFormat)
            {
                bytesPerBlock = Dxt5BlockBytes;
            }
            else
            {
                throw new ArgumentOutOfRangeException(
                    nameof(textureFormat),
                    "未対応のUnity Crunch形式です。");
            }

            long blockCountX = ((long)width + 3L) / 4L;
            long blockCountY = ((long)height + 3L) / 4L;
            long expectedBaseLevelLength =
                checked(blockCountX * blockCountY * bytesPerBlock);
            long expectedAllMipLength = 0;
            int mipWidth = width;
            int mipHeight = height;
            for (int mipIndex = 0;
                 mipIndex < mipCount;
                 mipIndex++)
            {
                long mipBlockCountX =
                    ((long)mipWidth + 3L) / 4L;
                long mipBlockCountY =
                    ((long)mipHeight + 3L) / 4L;
                expectedAllMipLength = checked(
                    expectedAllMipLength +
                    checked(
                        mipBlockCountX *
                        mipBlockCountY *
                        bytesPerBlock));
                mipWidth = Math.Max(1, mipWidth / 2);
                mipHeight = Math.Max(1, mipHeight / 2);
            }

            if (expectedBaseLevelLength <= 0 ||
                expectedBaseLevelLength > int.MaxValue ||
                expectedAllMipLength <= 0 ||
                expectedAllMipLength > int.MaxValue)
            {
                throw new InvalidOperationException(
                    "Unity Crunch展開後サイズが安全範囲外です。");
            }

            IntPtr nativeBuffer = IntPtr.Zero;
            try
            {
                int nativeSize;
                bool succeeded = DecompressUnityCRN(
                    sourceData,
                    sourceData.Length,
                    out nativeBuffer,
                    out nativeSize);
                if (!succeeded ||
                    nativeBuffer == IntPtr.Zero ||
                    nativeSize != expectedAllMipLength)
                {
                    throw new InvalidOperationException(
                        "Unity Crunchデータを展開できませんでした。");
                }

                byte[] decodedBlocks =
                    new byte[(int)expectedBaseLevelLength];
                Marshal.Copy(
                    nativeBuffer,
                    decodedBlocks,
                    0,
                    decodedBlocks.Length);
                return decodedBlocks;
            }
            finally
            {
                if (nativeBuffer != IntPtr.Zero)
                {
                    // crunchunity.dllはWindows UCRTのmallocで戻り領域を確保する。
                    FreeCrtMemory(nativeBuffer);
                }
            }
        }
    }
}
