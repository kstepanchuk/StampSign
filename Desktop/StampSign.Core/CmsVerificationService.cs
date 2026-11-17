using Org.BouncyCastle.Cms;
using Org.BouncyCastle.X509;

namespace StampSign.Core;

/// <summary>Verifies CMS content and the signer signature without contacting a server.</summary>
public static class CmsVerificationService
{
    public static VerificationResult Verify(SignatureInput input)
    {
        try
        {
            CmsSignedData cms;
            byte[]? content;
            if (input.Mode == SignatureMode.Attached)
            {
                cms = new CmsSignedData(input.Signature);
                content = CmsSignatureReader.GetEmbeddedContent(input.Signature);
                if (content is null)
                    return VerificationResult.Error("В прикреплённой подписи нет вложенного содержимого.");
            }
            else
            {
                if (input.Document is null)
                    return VerificationResult.Error("Для откреплённой подписи требуется исходный документ.");
                cms = new CmsSignedData(new CmsProcessableByteArray(input.Document), input.Signature);
                content = input.Document;
            }

            var signer = cms.GetSignerInfos().GetSigners().Cast<SignerInformation>().FirstOrDefault();
            if (signer is null) return VerificationResult.Error("CMS не содержит подписи подписанта.");
            var certificate = cms.GetCertificates().EnumerateMatches(signer.SignerID).FirstOrDefault();
            if (certificate is null) return VerificationResult.Error("В CMS не найден сертификат подписанта.");

            var signatureValid = signer.Verify(certificate.GetPublicKey());
            var contentMatches = input.Mode != SignatureMode.Attached || input.Document is null ||
                                 input.Document.AsSpan().SequenceEqual(content);
            var notes = new List<string>();
            if (!contentMatches)
                notes.Add("Выбранный PDF не совпадает с содержимым прикреплённой подписи.");
            notes.Add("Проверка доверия к корневому УЦ и отзыва сертификата пока не выполняется.");

            return new VerificationResult(
                contentMatches ? signatureValid ? CheckState.Valid : CheckState.Invalid : CheckState.Invalid,
                signatureValid ? CheckState.Valid : CheckState.Invalid,
                CheckState.Unknown,
                CheckState.Unknown,
                notes);
        }
        catch (Exception ex)
        {
            return VerificationResult.Error($"Проверка CMS не выполнена: {ex.Message}");
        }
    }
}
