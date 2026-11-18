using SkiaSharp;
using StampSign.Core;

namespace StampSign.Pdf;

/// <summary>Renders the visible Russian signature seal as a transparent PNG.</summary>
public static class SignatureStampRenderer
{
    public const int Width = 190;
    public const int Height = 55;

    public static byte[] Render(SignatureInfo signature)
    {
        const int scale = 4;
        const int width = Width * scale;
        const int height = Height * scale;
        var color = new SKColor(76, 64, 210);
        using var bitmap = new SKBitmap(width, height, SKColorType.Rgba8888, SKAlphaType.Premul);
        using var canvas = new SKCanvas(bitmap);
        canvas.Clear(SKColors.Transparent);

        using var border = new SKPaint { Color = color, Style = SKPaintStyle.Stroke, StrokeWidth = 2.4f, IsAntialias = true };
        canvas.DrawRoundRect(new SKRect(2, 2, width - 2, height - 2), 20, 20, border);

        DrawLine(canvas, "ДОКУМЕНТ ПОДПИСАН ЭЛЕКТРОННОЙ ПОДПИСЬЮ", width / 2f, 55, 24.8f, color, true);
        var validity = $"Действителен с {signature.NotBefore.ToLocalTime():dd.MM.yyyy} по {signature.NotAfter.ToLocalTime():dd.MM.yyyy}";
        var lines = new[]
        {
            $"Сертификат {signature.SerialHex}",
            $"Владелец {signature.Owner}",
            validity,
            $"Дата и время подписания {signature.SigningTime?.ToLocalTime().ToString("dd.MM.yyyy HH:mm") ?? "—"}"
        };
        var baselines = new[] { 100f, 130f, 160f, 190f };
        for (var i = 0; i < lines.Length; i++)
            DrawLine(canvas, lines[i], 24, baselines[i], 22.8f, color, false);

        using var image = SKImage.FromBitmap(bitmap);
        using var encoded = image.Encode(SKEncodedImageFormat.Png, 100);
        return encoded.ToArray();
    }

    private static void DrawLine(SKCanvas canvas, string text, float x, float baseline,
        float size, SKColor color, bool centered)
    {
        using var typeface = SKTypeface.FromFamilyName("Arial", SKFontStyle.Normal);
        using var font = new SKFont(typeface, size);
        using var paint = new SKPaint
        {
            Color = color,
            IsAntialias = true,
        };
        var maxWidth = centered ? 720 : 700;
        var measured = font.MeasureText(text, paint);
        if (measured > maxWidth) font.Size *= maxWidth / measured;
        if (centered) x = (760 - font.MeasureText(text, paint)) / 2;
        canvas.DrawText(text, x, baseline, SKTextAlign.Left, font, paint);
    }
}
