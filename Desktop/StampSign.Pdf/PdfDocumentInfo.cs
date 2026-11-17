namespace StampSign.Pdf;

public sealed record PdfDocumentInfo(string Path, int PageCount);

/// <summary>Cross-platform PDF rendering and stamping; UI code does not depend on PDFium.</summary>
public sealed class PdfDocumentService
{
    public PdfDocumentInfo Open(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        using var input = File.OpenRead(path);
#pragma warning disable CA1416 // PDFtoImage supports the desktop platforms targeted by this app.
        var pageCount = PDFtoImage.Conversion.GetPageCount(input, leaveOpen: false);
#pragma warning restore CA1416
        if (pageCount < 1) throw new InvalidDataException("В PDF нет страниц.");
        return new PdfDocumentInfo(path, pageCount);
    }

    public byte[] RenderPage(string path, int zeroBasedPage, int dpi = 110)
    {
        var info = Open(path);
        if (zeroBasedPage < 0 || zeroBasedPage >= info.PageCount)
            throw new ArgumentOutOfRangeException(nameof(zeroBasedPage));
        using var input = File.OpenRead(path);
        using var output = new MemoryStream();
#pragma warning disable CA1416 // PDFtoImage supports the desktop platforms targeted by this app.
        PDFtoImage.Conversion.SavePng(output, input, zeroBasedPage,
            options: new PDFtoImage.RenderOptions(Dpi: dpi));
#pragma warning restore CA1416
        return output.ToArray();
    }

    public Task StampAsync(string input, string output, string pngStamp, double x, double y,
        double width, int? pageIndex = null, CancellationToken cancellationToken = default) =>
        PdfCpuBridge.StampAsync(input, output, pngStamp, x, y, width, pageIndex, cancellationToken);

    public Task AddEvidenceAttachmentsAsync(string stampedPdf, string output, string originalPdf,
        string signature, CancellationToken cancellationToken = default) =>
        PdfCpuBridge.AddAttachmentsAsync(stampedPdf, output, originalPdf, signature, cancellationToken);

    public Task SignPadesAsync(string input, string output, string pngStamp, double x, double y, double width,
        int? pageIndex, string callbackUrl, string signerName, CancellationToken cancellationToken = default) =>
        PdfCpuBridge.SignPadesAsync(input, output, pngStamp, x, y, width, pageIndex, callbackUrl, signerName,
            cancellationToken);
}
