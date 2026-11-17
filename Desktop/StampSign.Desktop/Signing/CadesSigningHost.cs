using System.Diagnostics;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace StampSign.Desktop.Signing;

public enum CmsSigningMode
{
    Detached,
    Attached
}

/// <summary>
/// Starts a loopback-only page in the system browser so CryptoPro's browser extension
/// can access the user's private key without exporting it into StampSign.
/// </summary>
public sealed class CadesSigningHost
{
    private const long MaxFileSize = 50 * 1024 * 1024;

    public async Task CreateSignatureAsync(string inputPath, string outputPath, CmsSigningMode mode,
        CancellationToken cancellationToken = default)
    {
        var inputLength = new FileInfo(inputPath).Length;
        if (inputLength > MaxFileSize)
            throw new InvalidDataException("CryptoPro Browser plug-in подписывает файлы до 50 МБ. Уменьшите размер PDF и повторите.");
        var source = await File.ReadAllBytesAsync(inputPath, cancellationToken);

        var nonce = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
        var completion = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pagePath = Path.Combine(AppContext.BaseDirectory, "Signing", "cades-sign.html");
        if (!File.Exists(pagePath)) throw new FileNotFoundException("Не найдена страница подписания.", pagePath);
        var page = await File.ReadAllTextAsync(pagePath, cancellationToken);

        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            Args = [],
            EnvironmentName = "Production"
        });
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = 80 * 1024 * 1024);
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        await using var app = builder.Build();

        app.MapGet($"/{nonce}/", () => Results.Content(page, "text/html; charset=utf-8"));
        app.MapGet($"/{nonce}/source", () => Results.File(source, "application/octet-stream",
            Path.GetFileName(inputPath)));
        app.MapPost($"/{nonce}/complete", async (HttpContext context) =>
        {
            var request = await context.Request.ReadFromJsonAsync<CompletionRequest>(cancellationToken);
            if (string.IsNullOrWhiteSpace(request?.SignatureBase64))
                return Results.BadRequest(new { error = "CMS-подпись не получена." });
            try
            {
                completion.TrySetResult(Convert.FromBase64String(request.SignatureBase64));
                return Results.Ok(new { saved = true });
            }
            catch (FormatException)
            {
                return Results.BadRequest(new { error = "Ответ плагина CryptoPro имеет неверный Base64." });
            }
        });

        app.MapPost($"/{nonce}/cancel", () =>
        {
            completion.TrySetCanceled(cancellationToken);
            return Results.Ok();
        });

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(10));
        try
        {
            await app.StartAsync(timeout.Token);
            var addresses = app.Services.GetRequiredService<IServer>()
                .Features.Get<IServerAddressesFeature>()?.Addresses;
            var baseAddress = addresses?.FirstOrDefault(a => a.StartsWith("http://127.0.0.1:", StringComparison.Ordinal))
                ?? throw new InvalidOperationException("Не удалось открыть локальную страницу подписания.");
            var modeName = mode == CmsSigningMode.Detached ? "detached" : "attached";
            var url = new Uri(new Uri(baseAddress), $"{nonce}/?mode={modeName}");
            if (Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true }) is null)
                throw new InvalidOperationException("Не удалось открыть браузер для CryptoPro.");

            var signature = await completion.Task.WaitAsync(timeout.Token);
            await File.WriteAllBytesAsync(outputPath, signature, cancellationToken);
        }
        finally
        {
            await app.StopAsync(CancellationToken.None);
        }
    }

    private sealed record CompletionRequest(string SignatureBase64);
}
