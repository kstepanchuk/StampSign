using System.Diagnostics;
using System.Runtime.InteropServices;
using StampSign.Core;

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

    public static async Task<SignatureInput?> ExtractPadesSignatureAsync(string pdfPath,
        CancellationToken cancellationToken)
    {
        var cmsPath = Path.Combine(Path.GetTempPath(), $"StampSign-{Guid.NewGuid():N}.cms");
        var contentPath = Path.Combine(Path.GetTempPath(), $"StampSign-{Guid.NewGuid():N}.bytes");
        try
        {
            var exitCode = await RunProcessAsync(["extract-pades", pdfPath, cmsPath, contentPath], cancellationToken);
            if (exitCode == 2) return null;
            if (exitCode != 0) throw new InvalidDataException("Не удалось прочитать PAdES подпись из PDF.");
            return new SignatureInput(await File.ReadAllBytesAsync(cmsPath, cancellationToken),
                await File.ReadAllBytesAsync(contentPath, cancellationToken), SignatureMode.Detached, null);
        }
        finally
        {
            if (File.Exists(cmsPath)) File.Delete(cmsPath);
            if (File.Exists(contentPath)) File.Delete(contentPath);
        }
    }

    private static async Task RunAsync(string[] arguments, CancellationToken cancellationToken)
    {
        var exitCode = await RunProcessAsync(arguments, cancellationToken);
        if (exitCode != 0)
            throw new InvalidOperationException("PDF-операция завершилась ошибкой.");
    }

    private static async Task<int> RunProcessAsync(string[] arguments, CancellationToken cancellationToken)
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
        var error = await errorTask;
        if (process.ExitCode != 0 && process.ExitCode != 2)
            throw new InvalidOperationException($"PDF-операция завершилась ошибкой: {error}");
        return process.ExitCode;
    }
}
