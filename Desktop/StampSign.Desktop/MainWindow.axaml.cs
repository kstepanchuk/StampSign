using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Input;
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
    private int stampPageIndex;
    private Bitmap? pageBitmap;
    private Bitmap? stampBitmap;
    private StampDragMode? stampDragMode;
    private Avalonia.Point dragStartPoint;
    private StampPlacement dragStartPlacement;
    private double stampX = 20;
    private double stampY = 20;
    private double stampWidth = 190;
    private bool syncingPlacementFields;
    private readonly PdfDocumentService pdf = new();
    private readonly CadesSigningHost signingHost = new();
    private readonly PadesSigningHost padesHost = new();

    private enum StampDragMode { Move, Resize }
    private readonly record struct StampPlacement(double X, double Y, double Width);
    private readonly record struct PageGeometry(double Scale, double Left, double Top, double PageWidth, double PageHeight);

    public MainWindow()
    {
        InitializeComponent();
        DragDrop.SetAllowDrop(this, true);
        DragDrop.AddDragOverHandler(this, OnDragOver);
        DragDrop.AddDropHandler(this, OnDrop);
    }

    public async Task OpenFiles(IEnumerable<string> paths)
    {
        var files = paths.Where(path => !string.IsNullOrWhiteSpace(path) && File.Exists(path)).ToArray();
        var droppedPdf = files.FirstOrDefault(path => Path.GetExtension(path).Equals(".pdf", StringComparison.OrdinalIgnoreCase));
        var droppedSignature = files.FirstOrDefault(path => IsSignatureFile(path));
        if (droppedPdf is null && droppedSignature is null) return;

        try
        {
            if (droppedPdf is not null)
            {
                pdfPath = droppedPdf;
                signaturePath = null;
                SetSignatureInfo(null);
                pdfInfo = pdf.Open(pdfPath);
                pageIndex = 0;
                stampPageIndex = pageIndex;
                SetSigningAvailable(true);
                RenderCurrentPage();
                SetPlacement(20, 20, 190);
            }
            if (droppedSignature is not null) signaturePath = droppedSignature;
            UpdateSummary();
            await RefreshVerification();
        }
        catch (Exception ex)
        {
            VerificationDetails.Text = $"Не удалось открыть файл: {ex.Message}";
        }
    }

    private static bool IsSignatureFile(string path) => Path.GetExtension(path).ToLowerInvariant() is
        ".sig" or ".p7s" or ".p7m" or ".cms";

    private static void OnDragOver(object? sender, DragEventArgs e) =>
        e.DragEffects = e.DataTransfer.Formats.Contains(DataFormat.File)
            ? DragDropEffects.Copy
            : DragDropEffects.None;

    private void OnDrop(object? sender, DragEventArgs e)
    {
        var files = e.DataTransfer.TryGetFiles();
        if (files is null) return;
        var paths = files.Select(file => file.Path.LocalPath).ToArray();
        _ = OpenFiles(paths);
        e.DragEffects = DragDropEffects.Copy;
    }

    private async void OpenPdf(object? sender, RoutedEventArgs e)
    {
        var file = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Выберите PDF",
            AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("PDF") { Patterns = ["*.pdf"] }]
        });
        if (file.Count == 0) return;
        var path = file[0].TryGetLocalPath();
        if (path is not null) await OpenFiles([path]);
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
        var path = file[0].TryGetLocalPath();
        if (path is not null) await OpenFiles([path]);
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
                var signingTime = CmsSignatureReader.GetSigningTime(embeddedPades);
                var commonName = cert.SubjectDN.GetValueList(X509Name.CN).FirstOrDefault()?.ToString();
                SetSignatureInfo(new SignatureInfo(Convert.ToHexString(cert.SerialNumber.ToByteArrayUnsigned()),
                    commonName ?? cert.SubjectDN.ToString(), ToUtc(cert.NotBefore), ToUtc(cert.NotAfter), signingTime?.Time,
                    SignatureMode.Detached));
                var verification = CmsVerificationService.Verify(embeddedPades);
                SignatureDetails.Text = $"Встроенная PAdES подпись\n{signatureInfo.Owner}\nСертификат: {signatureInfo.SerialHex}\n" +
                    $"Действует: {signatureInfo.NotBefore.ToLocalTime():dd.MM.yyyy} — {signatureInfo.NotAfter.ToLocalTime():dd.MM.yyyy}\n" +
                    SigningTimeLine(signingTime);
                VerificationDetails.Text = $"Целостность: {verification.Integrity}\nЭЦП: {verification.Signature}\n" +
                    $"Сертификат в указанное время: {verification.CertificateTime}\nЦепочка: {verification.Chain}\n" +
                    string.Join("\n", verification.Notes);
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
            if (input.Mode == SignatureMode.Detached && pdfPath is null)
            {
                SetSignatureInfo(null);
                SignatureDetails.Text = "Откреплённая подпись (.sig)";
                VerificationDetails.Text = "Для проверки откреплённой подписи откройте исходный PDF или перетащите оба файла в окно.";
                SaveButton.IsEnabled = false;
                return;
            }
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
                stampPageIndex = pageIndex;
                SetSigningAvailable(true);
                RenderCurrentPage();
                SetPlacement(20, 20, 190);
                UpdateSummary();
                input = CmsSignatureReader.Read(signaturePath, pdfPath);
            }
            var cert = CmsSignatureReader.GetSignerCertificate(input);
            var signingTime = CmsSignatureReader.GetSigningTime(input);
            var commonName = cert.SubjectDN.GetValueList(X509Name.CN).FirstOrDefault()?.ToString();
            SetSignatureInfo(new SignatureInfo(Convert.ToHexString(cert.SerialNumber.ToByteArrayUnsigned()),
                    commonName ?? cert.SubjectDN.ToString(),
                    ToUtc(cert.NotBefore), ToUtc(cert.NotAfter), signingTime?.Time, input.Mode));
            var verification = CmsVerificationService.Verify(input);
            SignatureDetails.Text = $"Режим: {(input.Mode == SignatureMode.Attached ? "прикреплённая" : "откреплённая")}\n" +
                $"Сертификат: {signatureInfo!.SerialHex}\n" +
                $"Владелец: {signatureInfo.Owner}\n" +
                $"Действует: {signatureInfo.NotBefore.ToLocalTime():dd.MM.yyyy} — {signatureInfo.NotAfter.ToLocalTime():dd.MM.yyyy}\n" +
                SigningTimeLine(signingTime);
            VerificationDetails.Text = $"Целостность: {verification.Integrity}\n" +
                $"Сертификат в указанное время: {verification.CertificateTime}\n" +
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
        ClampPlacement();
        SyncPlacementFields();
        RenderStampPreview();
        UpdateStampPlacementControls();
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
            var x = stampX;
            var y = stampY;
            var width = stampWidth;
            var imagePath = Path.Combine(Path.GetTempPath(), $"StampSign-{Guid.NewGuid():N}.png");
            await File.WriteAllBytesAsync(imagePath, SignatureStampRenderer.Render(signatureInfo));
            var stamped = destination + ".stamped.tmp.pdf";
            try
            {
                await pdf.StampAsync(pdfPath, stamped, imagePath, x, y, width,
                    AllPages.IsChecked == true ? null : stampPageIndex + 1);
                if (EmbedEvidence.IsChecked == true)
                    await pdf.AddEvidenceAttachmentsAsync(stamped, destination, pdfPath, signaturePath);
                else
                    File.Move(stamped, destination, overwrite: true);
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
            var x = stampX;
            var y = stampY;
            var width = stampWidth;
            SetSigningAvailable(false);
            PadesButton.IsEnabled = false;
            VerificationDetails.Text = "Откроется браузер. Выберите сертификат, затем подтвердите встроенную PAdES подпись в CryptoPro.";
            SetSignatureInfo(await padesHost.SignAsync(pdf, pdfPath, destination, x, y, width,
                AllPages.IsChecked == true ? null : stampPageIndex + 1));
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

    private void SetSignatureInfo(SignatureInfo? value)
    {
        signatureInfo = value;
        stampBitmap?.Dispose();
        stampBitmap = null;
        if (value is not null)
        {
            using var stream = new MemoryStream(SignatureStampRenderer.Render(value));
            stampBitmap = new Bitmap(stream);
        }
        RenderStampPreview();
    }

    private void RenderStampPreview()
    {
        if (signatureInfo is null || stampBitmap is null || pageBitmap is null || pdfInfo is null ||
            (!AllPages.IsChecked.GetValueOrDefault() && stampPageIndex != pageIndex) ||
            StampOverlay.Bounds.Width <= 0 || StampOverlay.Bounds.Height <= 0 || !TryGetPageGeometry(out var geometry))
        {
            StampPreviewImage.IsVisible = false;
            StampSelection.IsVisible = false;
            StampResizeHandle.IsVisible = false;
            UpdateStampPlacementControls();
            return;
        }

        var previewWidth = stampWidth * geometry.Scale;
        var previewHeight = stampWidth * SignatureStampRenderer.Height / SignatureStampRenderer.Width * geometry.Scale;
        var left = geometry.Left + stampX * geometry.Scale;
        var top = geometry.Top + (geometry.PageHeight - stampY - stampWidth * SignatureStampRenderer.Height /
            SignatureStampRenderer.Width) * geometry.Scale;

        StampPreviewImage.Source = stampBitmap;
        StampPreviewImage.Width = previewWidth;
        StampPreviewImage.Height = previewHeight;
        Canvas.SetLeft(StampPreviewImage, left);
        Canvas.SetTop(StampPreviewImage, top);

        StampSelection.Width = previewWidth;
        StampSelection.Height = previewHeight;
        Canvas.SetLeft(StampSelection, left);
        Canvas.SetTop(StampSelection, top);
        Canvas.SetLeft(StampResizeHandle, left + previewWidth - StampResizeHandle.Width / 2);
        Canvas.SetTop(StampResizeHandle, top + previewHeight - StampResizeHandle.Height / 2);

        StampPreviewImage.IsVisible = true;
        StampSelection.IsVisible = true;
        StampResizeHandle.IsVisible = true;
        UpdateStampPlacementControls();
    }

    private bool TryGetPageGeometry(out PageGeometry geometry)
    {
        geometry = default;
        if (pageBitmap is null) return false;
        const double renderDpi = 110;
        var pointsPerPixel = 72d / renderDpi;
        var pageWidth = pageBitmap.PixelSize.Width * pointsPerPixel;
        var pageHeight = pageBitmap.PixelSize.Height * pointsPerPixel;
        if (pageWidth <= 0 || pageHeight <= 0) return false;
        var scale = Math.Min(StampOverlay.Bounds.Width / pageWidth, StampOverlay.Bounds.Height / pageHeight);
        if (!double.IsFinite(scale) || scale <= 0) return false;
        geometry = new PageGeometry(scale,
            (StampOverlay.Bounds.Width - pageWidth * scale) / 2,
            (StampOverlay.Bounds.Height - pageHeight * scale) / 2,
            pageWidth, pageHeight);
        return true;
    }

    private void StampOverlaySizeChanged(object? sender, SizeChangedEventArgs e) => RenderStampPreview();

    private void PlacementFieldChanged(object? sender, TextChangedEventArgs e)
    {
        if (syncingPlacementFields || pageBitmap is null) return;
        if (TryParsePlacementField(XPosition.Text, out var x)) stampX = x;
        if (TryParsePlacementField(YPosition.Text, out var y)) stampY = y;
        if (TryParsePlacementField(StampWidth.Text, out var width)) stampWidth = width;
        ClampPlacement();
        stampPageIndex = pageIndex;
        RenderStampPreview();
    }

    private static bool TryParsePlacementField(string? text, out double value) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out value) && double.IsFinite(value);

    private void SetPlacement(double x, double y, double width)
    {
        stampX = x;
        stampY = y;
        stampWidth = width;
        ClampPlacement();
        stampPageIndex = pageIndex;
        syncingPlacementFields = true;
        SyncPlacementFields();
        syncingPlacementFields = false;
        RenderStampPreview();
    }

    private void SyncPlacementFields()
    {
        var wasSyncing = syncingPlacementFields;
        syncingPlacementFields = true;
        XPosition.Text = stampX.ToString("0.#", CultureInfo.InvariantCulture);
        YPosition.Text = stampY.ToString("0.#", CultureInfo.InvariantCulture);
        StampWidth.Text = stampWidth.ToString("0.#", CultureInfo.InvariantCulture);
        syncingPlacementFields = wasSyncing;
    }

    private void ClampPlacement()
    {
        if (!TryGetPageGeometry(out var geometry)) return;
        var maxWidth = Math.Max(1, Math.Min(geometry.PageWidth,
            geometry.PageHeight * SignatureStampRenderer.Width / SignatureStampRenderer.Height));
        stampWidth = Math.Clamp(stampWidth, Math.Min(80, maxWidth), maxWidth);
        var height = stampWidth * SignatureStampRenderer.Height / SignatureStampRenderer.Width;
        stampX = Math.Clamp(stampX, 0, Math.Max(0, geometry.PageWidth - stampWidth));
        stampY = Math.Clamp(stampY, 0, Math.Max(0, geometry.PageHeight - height));
    }

    private void StampMovePointerPressed(object? sender, PointerPressedEventArgs e) => BeginStampDrag(StampDragMode.Move, e);
    private void StampResizePointerPressed(object? sender, PointerPressedEventArgs e) => BeginStampDrag(StampDragMode.Resize, e);

    private void BeginStampDrag(StampDragMode mode, PointerPressedEventArgs e)
    {
        if (signatureInfo is null || pageBitmap is null || !TryGetPageGeometry(out _)) return;
        if (!AllPages.IsChecked.GetValueOrDefault()) stampPageIndex = pageIndex;
        stampDragMode = mode;
        dragStartPoint = e.GetPosition(StampOverlay);
        dragStartPlacement = new StampPlacement(stampX, stampY, stampWidth);
        e.Pointer.Capture(StampOverlay);
        StampOverlay.Focus();
        UpdateStampPlacementControls();
        e.Handled = true;
    }

    private void StampPointerMoved(object? sender, PointerEventArgs e)
    {
        if (stampDragMode is null || !TryGetPageGeometry(out var geometry)) return;
        var point = e.GetPosition(StampOverlay);
        var dx = (point.X - dragStartPoint.X) / geometry.Scale;
        var dy = (point.Y - dragStartPoint.Y) / geometry.Scale;
        var x = dragStartPlacement.X;
        var y = dragStartPlacement.Y;
        var width = dragStartPlacement.Width;
        if (stampDragMode == StampDragMode.Move)
        {
            x += dx;
            y -= dy;
        }
        else
        {
            width += dx;
            var oldHeight = dragStartPlacement.Width * SignatureStampRenderer.Height / SignatureStampRenderer.Width;
            var newHeight = width * SignatureStampRenderer.Height / SignatureStampRenderer.Width;
            y += oldHeight - newHeight;
        }
        (x, y, width) = SnapPlacement(x, y, width, geometry, e.KeyModifiers.HasFlag(KeyModifiers.Alt));
        SetPlacement(x, y, width);
        e.Handled = true;
    }

    private void StampPointerReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (stampDragMode is null) return;
        stampDragMode = null;
        e.Pointer.Capture(null);
        e.Handled = true;
    }

    private static (double X, double Y, double Width) SnapPlacement(double x, double y, double width,
        PageGeometry geometry, bool disabled)
    {
        var height = width * SignatureStampRenderer.Height / SignatureStampRenderer.Width;
        var maxX = Math.Max(0, geometry.PageWidth - width);
        var maxY = Math.Max(0, geometry.PageHeight - height);
        x = Math.Clamp(x, 0, maxX);
        y = Math.Clamp(y, 0, maxY);
        if (disabled) return (x, y, width);
        const double tolerance = 6;
        const double margin = 20;
        var xTargets = new[] { margin, maxX / 2, Math.Max(0, maxX - margin) };
        var yTargets = new[] { margin, Math.Max(0, maxY - margin) };
        foreach (var target in xTargets)
            if (Math.Abs(x - target) < tolerance) { x = target; break; }
        foreach (var target in yTargets)
            if (Math.Abs(y - target) < tolerance) { y = target; break; }
        return (x, y, width);
    }

    private void StampOverlayKeyDown(object? sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Left: SetPlacement(stampX - 1, stampY, stampWidth); break;
            case Key.Right: SetPlacement(stampX + 1, stampY, stampWidth); break;
            case Key.Up: SetPlacement(stampX, stampY + 1, stampWidth); break;
            case Key.Down: SetPlacement(stampX, stampY - 1, stampWidth); break;
            default: return;
        }
        e.Handled = true;
    }

    private void AllPagesChanged(object? sender, RoutedEventArgs e) => RenderStampPreview();

    private void PlaceStampOnCurrentPage(object? sender, RoutedEventArgs e)
    {
        stampPageIndex = pageIndex;
        RenderStampPreview();
    }

    private void PlaceBottomLeft(object? sender, RoutedEventArgs e) => ApplyPreset(center: false, top: false, right: false);
    private void PlaceBottomCenter(object? sender, RoutedEventArgs e) => ApplyPreset(center: true, top: false, right: false);
    private void PlaceBottomRight(object? sender, RoutedEventArgs e) => ApplyPreset(center: false, top: false, right: true);
    private void PlaceTopRight(object? sender, RoutedEventArgs e) => ApplyPreset(center: false, top: true, right: true);

    private void ApplyPreset(bool center, bool top, bool right)
    {
        if (!TryGetPageGeometry(out var geometry)) return;
        var height = stampWidth * SignatureStampRenderer.Height / SignatureStampRenderer.Width;
        var x = center ? (geometry.PageWidth - stampWidth) / 2 : right ? geometry.PageWidth - stampWidth - 20 : 20;
        var y = top ? geometry.PageHeight - height - 20 : 20;
        SetPlacement(x, y, stampWidth);
    }

    private void UpdateStampPlacementControls() =>
        PlaceStampOnPageButton.IsVisible = signatureInfo is not null && !AllPages.IsChecked.GetValueOrDefault() &&
                                           stampPageIndex != pageIndex;

    private static string SigningTimeLine(SigningTimeInfo? signingTime) => signingTime is null
        ? "Время подписания в CMS не указано."
        : $"Время подписания: {signingTime.Time:dd.MM.yyyy HH:mm:ss} UTC";

    private static DateTimeOffset ToUtc(DateTime value) => new DateTimeOffset(value).ToUniversalTime();

}
