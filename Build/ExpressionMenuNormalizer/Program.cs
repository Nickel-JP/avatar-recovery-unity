using System;
using System.Text;

namespace AvatarRecovery.Tools.ExpressionMenuNormalizer
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            Console.OutputEncoding = new UTF8Encoding(false);

            try
            {
                CommandLineOptions options = CommandLineOptions.Parse(args);
                NormalizationResult result = VrcaExpressionMenuNormalizer.Normalize(options);
                Console.Out.WriteLine(ResultJsonSerializer.Serialize(result));
                return (int)ExitCode.Success;
            }
            catch (NormalizerException exception)
            {
                Log.Error(exception.Message);
                if (exception.InnerException != null)
                {
                    Log.Error(exception.InnerException.GetType().FullName + ": " + exception.InnerException.Message);
                }

                return (int)exception.ExitCode;
            }
            catch (Exception exception)
            {
                Log.Error("予期しないエラーが発生しました: " + exception);
                return (int)ExitCode.UnexpectedFailure;
            }
        }
    }
}
