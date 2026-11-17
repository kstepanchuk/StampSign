using System.Diagnostics;
using System.Runtime.InteropServices;

namespace StampSign.Pdf;

internal static class PdfCpuBridge
{
    public static Task StampAsync(string input, string output, string pngStamp, double x, double y,
        double width, int? pageIndex, CancellationToken cancellationToken) => RunAsync(
        ["stamp", input, output, pngStamp, x.ToString("R", System.Globalization.CultureInfo.InvariantCulture),
         y.ToString("R", System.Globalization.CultureInfo.InvariantCulture),
         width.ToString("R", System.Globalization.CultureInfo.InvariantCulture),
         pageIndex?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "all"], cancellationToken);

    public static Task AddAttachmentsAsync(string input, string output, string originalPdf,
        string signature, CancellationToken cancellationToken) =>
        RunAsync(["attach", input, output, originalPdf, signature], cancellationToken);

    public static Task SignPadesAsync(string input, string output, string pngStamp, double x, double y,
        double width, int? pageIndex, string callbackUrl, string signerName, CancellationToken cancellationToken) =>
        RunAsync(["pades", input, output, pngStamp,
            x.ToString("R", System.Globalization.CultureInfo.InvariantCulture),
            y.ToString("R", System.Globalization.CultureInfo.InvariantCulture),
            width.ToString("R", System.Globalization.CultureInfo.InvariantCulture),
            pageIndex?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "all",
            callbackUrl, signerName], cancellationToken);

    private static async Task RunAsync(string[] arguments, CancellationToken cancellationToken)
    {
        var executable = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "stamp-pdf.exe" : "stamp-pdf";
        var path = Path.Combine(AppContext.BaseDirectory, "tools", executable);
        if (!File.Exists(path))
            throw new FileNotFoundException("PDF-модуль StampSign не найден рядом с приложением.", path);

        var start = new ProcessStartInfo(path) { UseShellExecute = false, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Не удалось запустить PDF-модуль.");
        var errorTask = process.StandardError.ReadToEndAsync();
        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            await errorTask;
            throw;
        }
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"PDF-операция завершилась ошибкой: {await errorTask}");
    }
}
