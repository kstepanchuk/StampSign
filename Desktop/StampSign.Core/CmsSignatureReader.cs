using Org.BouncyCastle.Cms;
using Org.BouncyCastle.X509;

namespace StampSign.Core;

/// <summary>Reads the content and signer certificate from attached or detached CMS/CAdES.</summary>
public static class CmsSignatureReader
{
    public static SignatureInput Read(string signaturePath, string? detachedContentPath = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(signaturePath);
        var signature = File.ReadAllBytes(signaturePath);
        var content = detachedContentPath is null ? null : File.ReadAllBytes(detachedContentPath);
        var cms = new CmsSignedData(signature);
        var mode = cms.IsDetachedSignature ? SignatureMode.Detached : SignatureMode.Attached;
        var embedded = GetEmbeddedContent(signature);
        return new SignatureInput(signature, content, mode, embedded);
    }

    public static byte[]? GetEmbeddedContent(ReadOnlySpan<byte> encodedSignature)
    {
        var cms = new CmsSignedData(encodedSignature.ToArray());
        if (cms.SignedContent is null) return null;
        using var content = new MemoryStream();
        cms.SignedContent.Write(content);
        return content.ToArray();
    }

    public static X509Certificate GetSignerCertificate(SignatureInput input)
    {
        CmsSignedData cms;
        if (input.Mode == SignatureMode.Attached)
            cms = new CmsSignedData(input.Signature);
        else
            cms = new CmsSignedData(
                new CmsProcessableByteArray(input.Document ?? throw new InvalidDataException(
                    "Для откреплённой подписи требуется исходный документ.")), input.Signature);

        var signer = cms.GetSignerInfos().GetSigners().Cast<SignerInformation>().FirstOrDefault()
            ?? throw new InvalidDataException("CMS контейнер не содержит SignerInfo.");
        var certificate = cms.GetCertificates().EnumerateMatches(signer.SignerID).FirstOrDefault()
            ?? throw new InvalidDataException("В CMS контейнере не найден сертификат подписанта.");
        return certificate;
    }
}
