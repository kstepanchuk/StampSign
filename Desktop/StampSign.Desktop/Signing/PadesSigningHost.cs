using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using StampSign.Core;
using StampSign.Pdf;

namespace StampSign.Desktop.Signing;

/// <summary>Coordinates pdfcpu's ByteRange callback with CryptoPro in the user's browser.</summary>
public sealed class PadesSigningHost
{
    private const long MaxRequestBytes = 80 * 1024 * 1024;

    public async Task<SignatureInfo> SignAsync(PdfDocumentService pdf, string inputPath, string outputPath,
        double x, double y, double width, int? pageIndex, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(pdf);
        if (new FileInfo(inputPath).Length > 50 * 1024 * 1024)
            throw new InvalidDataException("CryptoPro Browser plug-in подписывает файлы до 50 МБ.");

        var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
        var certificateTask = new TaskCompletionSource<CertificateInfo>(TaskCreationOptions.RunContinuationsAsynchronously);
        PendingSignature? pending = null;
        var pendingLock = new object();
        var pagePath = Path.Combine(AppContext.BaseDirectory, "Signing", "cades-sign.html");
        var page = await File.ReadAllTextAsync(pagePath, cancellationToken);

        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { Args = [], EnvironmentName = "Production" });
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = MaxRequestBytes);
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        await using var app = builder.Build();

        app.MapGet($"/{nonce}/", () => Results.Content(page, "text/html; charset=utf-8"));
        app.MapPost($"/{nonce}/pades/certificate", async (HttpContext context) =>
        {
            var cert = await context.Request.ReadFromJsonAsync<CertificateInfo>(cancellationToken);
            if (cert is null || string.IsNullOrWhiteSpace(cert.SerialHex) || string.IsNullOrWhiteSpace(cert.Subject))
                return Results.BadRequest(new { error = "Не удалось прочитать сертификат подписанта." });
            certificateTask.TrySetResult(cert);
            return Results.Ok();
        });
        app.MapPost($"/{nonce}/pades/sign-data", async (HttpContext context) =>
        {
            using var buffer = new MemoryStream();
            await context.Request.Body.CopyToAsync(buffer, cancellationToken);
            var request = new PendingSignature(Guid.NewGuid().ToString("N"), buffer.ToArray());
            lock (pendingLock) pending = request;
            try
            {
                var cms = await request.Completion.Task.WaitAsync(cancellationToken);
                return Results.Bytes(cms, "application/pkcs7-signature");
            }
            finally
            {
                lock (pendingLock)
                    if (ReferenceEquals(pending, request)) pending = null;
            }
        });
        app.MapGet($"/{nonce}/pades/pending", () =>
        {
            lock (pendingLock)
                return pending is null
                    ? Results.NoContent()
                    : Results.Json(new { id = pending.Id, length = pending.Data.Length });
        });
        app.MapGet($"/{nonce}/pades/pending/{{id}}/data", (string id) =>
        {
            lock (pendingLock)
                return pending is not null && pending.Id == id
                    ? Results.Bytes(pending.Data, "application/octet-stream")
                    : Results.NotFound();
        });
        app.MapPost($"/{nonce}/pades/complete/{{id}}", async (string id, HttpContext context) =>
        {
            var result = await context.Request.ReadFromJsonAsync<SignatureResponse>(cancellationToken);
            if (string.IsNullOrWhiteSpace(result?.SignatureBase64))
                return Results.BadRequest(new { error = "CryptoPro не вернул CMS." });
            lock (pendingLock)
            {
                if (pending is null || pending.Id != id) return Results.NotFound();
                try
                {
                    pending.Completion.TrySetResult(Convert.FromBase64String(result.SignatureBase64));
                    return Results.Ok();
                }
                catch (FormatException)
                {
                    return Results.BadRequest(new { error = "CryptoPro вернул повреждённую CMS подпись." });
                }
            }
        });

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(10));
        string? tempStamp = null;
        string? tempPdf = null;
        try
        {
            await app.StartAsync(timeout.Token);
            var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()?.Addresses
                .FirstOrDefault(a => a.StartsWith("http://127.0.0.1:", StringComparison.Ordinal))
                ?? throw new InvalidOperationException("Не удалось открыть локальную PAdES сессию.");
            var baseUrl = new Uri(address);
            if (Process.Start(new ProcessStartInfo(new Uri(baseUrl, $"{nonce}/?mode=pades").AbsoluteUri)
                { UseShellExecute = true }) is null)
                throw new InvalidOperationException("Не удалось открыть браузер CryptoPro.");

            var cert = await certificateTask.Task.WaitAsync(timeout.Token);
            var signatureInfo = new SignatureInfo(cert.SerialHex, OwnerName(cert.Subject),
                cert.NotBefore, cert.NotAfter, DateTimeOffset.Now, SignatureMode.Detached);
            tempStamp = Path.Combine(Path.GetTempPath(), $"StampSign-{Guid.NewGuid():N}.png");
            var destinationDirectory = Path.GetDirectoryName(Path.GetFullPath(outputPath))
                ?? throw new InvalidDataException("Не удалось определить папку сохранения PDF.");
            tempPdf = Path.Combine(destinationDirectory, $".StampSign-{Guid.NewGuid():N}.signed.tmp.pdf");
            await File.WriteAllBytesAsync(tempStamp, SignatureStampRenderer.Render(signatureInfo), timeout.Token);

            var callbackUrl = new Uri(baseUrl, $"{nonce}/pades/sign-data").AbsoluteUri;
            await pdf.SignPadesAsync(inputPath, tempPdf, tempStamp, x, y, width, pageIndex, callbackUrl, cert.Subject,
                timeout.Token);
            File.Move(tempPdf, outputPath, overwrite: true);
            return signatureInfo;
        }
        finally
        {
            if (tempStamp is not null && File.Exists(tempStamp)) File.Delete(tempStamp);
            if (tempPdf is not null && File.Exists(tempPdf)) File.Delete(tempPdf);
            await app.StopAsync(CancellationToken.None);
        }
    }

    private static string OwnerName(string subject)
    {
        var match = Regex.Match(subject, @"(?:^|,\s*)CN=([^,]+)", RegexOptions.IgnoreCase);
        return match.Success ? match.Groups[1].Value : subject;
    }

    private sealed record CertificateInfo(string Thumbprint, string Subject, string SerialHex,
        DateTimeOffset NotBefore, DateTimeOffset NotAfter);
    private sealed record SignatureResponse(string SignatureBase64);
    private sealed record PendingSignature(string Id, byte[] Data)
    {
        public TaskCompletionSource<byte[]> Completion { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
}
