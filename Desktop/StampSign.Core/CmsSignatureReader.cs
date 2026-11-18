using Org.BouncyCastle.Cms;
using Org.BouncyCastle.Asn1;
using Org.BouncyCastle.Asn1.Pkcs;
using Org.BouncyCastle.Tsp;
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
        var cms = CreateCms(input);
        var signer = cms.GetSignerInfos().GetSigners().Cast<SignerInformation>().FirstOrDefault()
            ?? throw new InvalidDataException("CMS контейнер не содержит SignerInfo.");
        var certificate = cms.GetCertificates().EnumerateMatches(signer.SignerID).FirstOrDefault()
            ?? throw new InvalidDataException("В CMS контейнере не найден сертификат подписанта.");
        return certificate;
    }

    public static SigningTimeInfo? GetSigningTime(SignatureInput input)
    {
        var cms = CreateCms(input);
        var signer = cms.GetSignerInfos().GetSigners().Cast<SignerInformation>().FirstOrDefault();
        if (signer is null) return null;

        // An RFC 3161 signature timestamp, when present, is more informative than
        // the signer's self-asserted signingTime attribute.
        var timestampAttributes = signer.UnsignedAttributes?.GetAll(
            new DerObjectIdentifier("1.2.840.113549.1.9.16.2.14"));
        if (timestampAttributes is { Count: 1 })
        {
            try
            {
                var attribute = Org.BouncyCastle.Asn1.Cms.Attribute.GetInstance(timestampAttributes[0]);
                if (attribute.AttrValues.Count == 1)
                {
                    var timestampCms = new CmsSignedData(attribute.AttrValues[0].ToAsn1Object().GetEncoded());
                    var token = new TimeStampToken(timestampCms);
                    return new SigningTimeInfo(ToUtc(token.TimeStampInfo.GenTime), SigningTimeSource.TimestampToken);
                }
            }
            catch
            {
                // A malformed or unsupported timestamp must not hide the ordinary
                // signingTime attribute or prevent verification of the CMS signature.
            }
        }

        var signedAttributes = signer.SignedAttributes?.GetAll(PkcsObjectIdentifiers.Pkcs9AtSigningTime);
        if (signedAttributes is not { Count: 1 }) return null;
        var signingTime = Org.BouncyCastle.Asn1.Cms.Attribute.GetInstance(signedAttributes[0]);
        if (signingTime.AttrValues.Count != 1) return null;
        var date = Org.BouncyCastle.Asn1.Cms.Time.GetInstance(signingTime.AttrValues[0]).ToDateTime();
        return new SigningTimeInfo(ToUtc(date), SigningTimeSource.SignedAttribute);
    }

    private static CmsSignedData CreateCms(SignatureInput input) => input.Mode == SignatureMode.Attached
        ? new CmsSignedData(input.Signature)
        : new CmsSignedData(
            new CmsProcessableByteArray(input.Document ?? throw new InvalidDataException(
                "Для откреплённой подписи требуется исходный документ.")), input.Signature);

    private static DateTimeOffset ToUtc(DateTime value) => new DateTimeOffset(value).ToUniversalTime();
}
