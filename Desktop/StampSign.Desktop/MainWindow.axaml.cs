using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using StampSign.Core;
using StampSign.Pdf;
using System.Globalization;
using Org.BouncyCastle.Asn1.X509;
using StampSign.Desktop.Signing;

namespace StampSign.Desktop;

public sealed partial class MainWindow : Window
{
    private string? pdfPath;
    private string? signaturePath;
    private SignatureInfo? signatureInfo;
    private PdfDocumentInfo? pdfInfo;
    private int pageIndex;
    private Bitmap? pageBitmap;
    private readonly PdfDocumentService pdf = new();
    private readonly CadesSigningHost signingHost = new();
    private readonly PadesSigningHost padesHost = new();

    public MainWindow() => InitializeComponent();

    private async void OpenPdf(object? sender, RoutedEventArgs e)
    {
        var file = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Выберите PDF",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("PDF") { Patterns = ["*.pdf"] }]
        });
        if (file.Count == 0) return;
        pdfPath = file[0].TryGetLocalPath();
        if (pdfPath is null) return;
        signaturePath = null;
        signatureInfo = null;
        pdfInfo = pdf.Open(pdfPath);
        pageIndex = 0;
        SetSigningAvailable(true);
        RenderCurrentPage();
        UpdateSummary();
        await RefreshVerification();
    }

    private async void OpenSignature(object? sender, RoutedEventArgs e)
    {
        var file = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Выберите CMS/CAdES подпись",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("CMS / CAdES") { Patterns = ["*.sig", "*.p7s", "*.p7m", "*.cms"] }]
        });
        if (file.Count == 0) return;
        signaturePath = file[0].TryGetLocalPath();
        if (signaturePath is null) return;
        UpdateSummary();
        await RefreshVerification();
    }

    private void UpdateSummary() => FileSummary.Text = string.Join("   ·   ",
        new[] { pdfPath is null ? null : Path.GetFileName(pdfPath), signaturePath is null ? null : Path.GetFileName(signaturePath) }
            .Where(value => value is not null));

    private async Task RefreshVerification()
    {
        if (signaturePath is null)
        {
            if (pdfPath is null) return;
            try
            {
                var embeddedPades = await pdf.ExtractPadesSignatureAsync(pdfPath);
                if (embeddedPades is null)
                {
                    SignatureDetails.Text = "В PDF нет встроенной PAdES подписи.";
                    VerificationDetails.Text = string.Empty;
                    SaveButton.IsEnabled = false;
                    return;
                }
                var cert = CmsSignatureReader.GetSignerCertificate(embeddedPades);
                var commonName = cert.SubjectDN.GetValueList(X509Name.CN).FirstOrDefault()?.ToString();
                signatureInfo = new SignatureInfo(Convert.ToHexString(cert.SerialNumber.ToByteArrayUnsigned()),
                    commonName ?? cert.SubjectDN.ToString(),
                    new DateTimeOffset(DateTime.SpecifyKind(cert.NotBefore, DateTimeKind.Utc)),
                    new DateTimeOffset(DateTime.SpecifyKind(cert.NotAfter, DateTimeKind.Utc)), null,
                    SignatureMode.Detached);
                var verification = CmsVerificationService.Verify(embeddedPades);
                SignatureDetails.Text = $"Встроенная PAdES подпись\n{signatureInfo.Owner}\nСертификат: {signatureInfo.SerialHex}\n" +
                    $"Действует: {signatureInfo.NotBefore:dd.MM.yyyy} — {signatureInfo.NotAfter:dd.MM.yyyy}";
                VerificationDetails.Text = $"Целостность: {verification.Integrity}\nЭЦП: {verification.Signature}\n" +
                    $"Цепочка: {verification.Chain}\n" + string.Join("\n", verification.Notes);
                SaveButton.IsEnabled = false;
            }
            catch (Exception ex)
            {
                SignatureDetails.Text = "Не удалось прочитать встроенную PAdES подпись.";
                VerificationDetails.Text = ex.Message;
                SaveButton.IsEnabled = false;
            }
            return;
        }
        try
        {
            var input = CmsSignatureReader.Read(signaturePath, pdfPath);
            if (pdfPath is null && input.EmbeddedContent is { Length: > 5 } embedded &&
                embedded.AsSpan(0, 5).SequenceEqual("%PDF-"u8))
            {
                // Keep a recovered document beside the attached signature so it survives
                // application exit and can be opened by the user independently.
                var recoveredPath = Path.Combine(Path.GetDirectoryName(signaturePath)!,
                    Path.GetFileNameWithoutExtension(signaturePath) + ".pdf");
                if (File.Exists(recoveredPath))
                    recoveredPath = Path.Combine(Path.GetDirectoryName(signaturePath)!,
                        Path.GetFileNameWithoutExtension(signaturePath) + $".recovered-{Guid.NewGuid():N}.pdf");
                await File.WriteAllBytesAsync(recoveredPath, embedded);
                pdfPath = recoveredPath;
                pdfInfo = pdf.Open(pdfPath);
                pageIndex = 0;
                SetSigningAvailable(true);
                RenderCurrentPage();
                UpdateSummary();
                input = CmsSignatureReader.Read(signaturePath, pdfPath);
            }
            var cert = CmsSignatureReader.GetSignerCertificate(input);
            var commonName = cert.SubjectDN.GetValueList(X509Name.CN).FirstOrDefault()?.ToString();
            signatureInfo = new SignatureInfo(Convert.ToHexString(cert.SerialNumber.ToByteArrayUnsigned()),
                    commonName ?? cert.SubjectDN.ToString(),
                    new DateTimeOffset(DateTime.SpecifyKind(cert.NotBefore, DateTimeKind.Utc)),
                    new DateTimeOffset(DateTime.SpecifyKind(cert.NotAfter, DateTimeKind.Utc)),
                    null, input.Mode);
            var verification = CmsVerificationService.Verify(input);
            SignatureDetails.Text = $"Режим: {(input.Mode == SignatureMode.Attached ? "прикреплённая" : "откреплённая")}\n" +
                $"Сертификат: {signatureInfo!.SerialHex}\n" +
                $"Владелец: {signatureInfo.Owner}\n" +
                $"Действует: {signatureInfo.NotBefore:dd.MM.yyyy} — {signatureInfo.NotAfter:dd.MM.yyyy}";
            VerificationDetails.Text = $"Целостность: {verification.Integrity}\n" +
                $"ЭЦП: {verification.Signature}\n" + string.Join("\n", verification.Notes);
            SaveButton.IsEnabled = pdfPath is not null && signatureInfo is not null;
            EmptyState.IsVisible = pdfInfo is null;
        }
        catch (Exception ex)
        {
            SignatureDetails.Text = "Не удалось прочитать подпись.";
            VerificationDetails.Text = ex.Message;
            SaveButton.IsEnabled = false;
        }
    }

    private void RenderCurrentPage()
    {
        if (pdfPath is null || pdfInfo is null) return;
        var bytes = pdf.RenderPage(pdfPath, pageIndex);
        using var stream = new MemoryStream(bytes);
        pageBitmap?.Dispose();
        pageBitmap = new Bitmap(stream);
        PagePreview.Source = pageBitmap;
        PageLabel.Text = $"Страница {pageIndex + 1} из {pdfInfo.PageCount}";
        EmptyState.IsVisible = false;
    }

    private void PreviousPage(object? sender, RoutedEventArgs e)
    {
        if (pdfInfo is null || pageIndex <= 0) return;
        pageIndex--;
        RenderCurrentPage();
    }

    private void NextPage(object? sender, RoutedEventArgs e)
    {
        if (pdfInfo is null || pageIndex >= pdfInfo.PageCount - 1) return;
        pageIndex++;
        RenderCurrentPage();
    }

    private async void SaveStampedPdf(object? sender, RoutedEventArgs e)
    {
        if (pdfPath is null || signaturePath is null || signatureInfo is null) return;
        var selected = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Сохранить PDF со штампом",
            SuggestedFileName = Path.GetFileNameWithoutExtension(pdfPath) + ".stamp.pdf",
            FileTypeChoices = [new FilePickerFileType("PDF") { Patterns = ["*.pdf"] }]
        });
        var destination = selected?.TryGetLocalPath();
        if (destination is null) return;

        try
        {
            var x = ParseNumber(XPosition.Text, "X");
            var y = ParseNumber(YPosition.Text, "Y");
            var width = ParseNumber(StampWidth.Text, "Ширина");
            var imagePath = Path.Combine(Path.GetTempPath(), $"StampSign-{Guid.NewGuid():N}.png");
            await File.WriteAllBytesAsync(imagePath, SignatureStampRenderer.Render(signatureInfo));
            var stamped = destination + ".stamped.tmp.pdf";
            try
            {
                await pdf.StampAsync(pdfPath, stamped, imagePath, x, y, width,
                    AllPages.IsChecked == true ? null : pageIndex + 1);
                await pdf.AddEvidenceAttachmentsAsync(stamped, destination, pdfPath, signaturePath);
            }
            finally
            {
                if (File.Exists(stamped)) File.Delete(stamped);
                if (File.Exists(imagePath)) File.Delete(imagePath);
            }
            VerificationDetails.Text = $"Сохранено: {destination}";
        }
        catch (Exception ex)
        {
            VerificationDetails.Text = ex.Message;
        }
    }

    private async void SignPadesPdf(object? sender, RoutedEventArgs e)
    {
        if (pdfPath is null) return;
        var selected = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Сохранить PDF с PAdES подписью",
            SuggestedFileName = Path.GetFileNameWithoutExtension(pdfPath) + ".pades.pdf",
            FileTypeChoices = [new FilePickerFileType("PDF") { Patterns = ["*.pdf"] }]
        });
        var destination = selected?.TryGetLocalPath();
        if (destination is null) return;

        try
        {
            var x = ParseNumber(XPosition.Text, "X");
            var y = ParseNumber(YPosition.Text, "Y");
            var width = ParseNumber(StampWidth.Text, "Ширина");
            SetSigningAvailable(false);
            PadesButton.IsEnabled = false;
            VerificationDetails.Text = "Откроется браузер. Выберите сертификат, затем подтвердите встроенную PAdES подпись в CryptoPro.";
            signatureInfo = await padesHost.SignAsync(pdf, pdfPath, destination, x, y, width,
                AllPages.IsChecked == true ? null : pageIndex + 1);
            pdfPath = destination;
            signaturePath = null;
            pdfInfo = pdf.Open(destination);
            pageIndex = 0;
            RenderCurrentPage();
            UpdateSummary();
            await RefreshVerification();
        }
        catch (Exception ex)
        {
            VerificationDetails.Text = $"PAdES подписание не выполнено: {ex.Message}";
        }
        finally
        {
            SetSigningAvailable(pdfPath is not null);
            PadesButton.IsEnabled = pdfPath is not null;
        }
    }

    private async void CreateCmsSignature(object? sender, RoutedEventArgs e)
    {
        if (pdfPath is null) return;
        var attached = (CmsMode.SelectedItem as ComboBoxItem)?.Tag?.ToString() == "attached";
        var extension = ".sig";
        var suggestedName = attached
            ? Path.GetFileNameWithoutExtension(pdfPath) + ".attached.sig"
            : Path.GetFileNameWithoutExtension(pdfPath) + ".sig";
        var selected = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = attached ? "Сохранить прикреплённую CMS подпись (.sig)" : "Сохранить откреплённую CMS подпись (.sig)",
            SuggestedFileName = suggestedName,
            FileTypeChoices = [new FilePickerFileType(attached ? "Прикреплённая CMS" : "Откреплённая CMS")
                { Patterns = ["*" + extension] }]
        });
        var destination = selected?.TryGetLocalPath();
        if (destination is null) return;
        try
        {
            SetSigningAvailable(false);
            VerificationDetails.Text = "Откроется браузер. Выберите сертификат и подтвердите подпись в CryptoPro.";
            await signingHost.CreateSignatureAsync(pdfPath, destination,
                attached ? CmsSigningMode.Attached : CmsSigningMode.Detached);
            signaturePath = destination;
            await RefreshVerification();
        }
        catch (Exception ex)
        {
            VerificationDetails.Text = $"Подписание не выполнено: {ex.Message}";
        }
        finally
        {
            SetSigningAvailable(pdfPath is not null);
        }
    }

    private void SetSigningAvailable(bool available)
    {
        SigningActionButton.IsEnabled = available;
        CreateSignatureButton.IsEnabled = available;
        PadesButton.IsEnabled = available;
    }

    private static double ParseNumber(string? value, string field)
    {
        if (!double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var result) ||
            !double.IsFinite(result) || result < 0)
            throw new InvalidDataException($"Поле «{field}» должно быть неотрицательным числом.");
        return result;
    }
}
