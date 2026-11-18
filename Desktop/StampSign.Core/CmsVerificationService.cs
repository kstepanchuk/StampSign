using Org.BouncyCastle.Cms;
using Org.BouncyCastle.Asn1;
using Org.BouncyCastle.Asn1.Pkcs;
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
            var digestMatches = VerifyContentDigest(signer, content);
            var contentMatches = input.Mode != SignatureMode.Attached || input.Document is null ||
                                 input.Document.AsSpan().SequenceEqual(content);
            var notes = new List<string>();
            if (!contentMatches)
                notes.Add("Выбранный PDF не совпадает с содержимым прикреплённой подписи.");
            if (!digestMatches)
                notes.Add("Хэш подписанного содержимого не совпадает с messageDigest CMS.");
            notes.Add("Проверка доверия к корневому УЦ и отзыва сертификата пока не выполняется.");

            var chain = ValidateIncludedChain(cms, certificate, notes);

            return new VerificationResult(
                contentMatches && digestMatches ? signatureValid ? CheckState.Valid : CheckState.Invalid : CheckState.Invalid,
                signatureValid ? CheckState.Valid : CheckState.Invalid,
                CheckState.Unknown,
                chain,
                notes);
        }
        catch (Exception ex)
        {
            return VerificationResult.Error($"Проверка CMS не выполнена: {ex.Message}");
        }
    }

    private static bool VerifyContentDigest(SignerInformation signer, byte[] content)
    {
        var attributes = signer.SignedAttributes?.GetAll(PkcsObjectIdentifiers.Pkcs9AtMessageDigest);
        if (attributes is null || attributes.Count != 1) return false;
        var attribute = Org.BouncyCastle.Asn1.Cms.Attribute.GetInstance(attributes[0]);
        if (attribute.AttrValues.Count != 1) return false;
        var expected = Asn1OctetString.GetInstance(attribute.AttrValues[0]).GetOctets();
        var digestOid = signer.DigestAlgorithmID.Algorithm.Id;
        var actual = Org.BouncyCastle.Security.DigestUtilities.CalculateDigest(digestOid, content);
        return expected.AsSpan().SequenceEqual(actual);
    }

    private static CheckState ValidateIncludedChain(CmsSignedData cms, X509Certificate signer,
        List<string> notes)
    {
        var certificates = cms.GetCertificates().EnumerateMatches(null).ToList();
        var current = signer;
        for (var depth = 0; depth < 8; depth++)
        {
            var candidates = certificates.Where(candidate =>
                candidate.SerialNumber != current.SerialNumber && candidate.SubjectDN.Equivalent(current.IssuerDN)).ToList();
            if (candidates.Count == 0)
            {
                if (current.SubjectDN.Equivalent(current.IssuerDN))
                {
                    try
                    {
                        current.Verify(current.GetPublicKey());
                        notes.Add("Встроенная цепочка подписана до self-signed сертификата; доверие к корню не оценивалось.");
                        return CheckState.Valid;
                    }
                    catch
                    {
                        notes.Add("Self-signed сертификат в цепочке имеет неверную подпись.");
                        return CheckState.Invalid;
                    }
                }
                notes.Add("Не все сертификаты цепочки находятся внутри CMS.");
                return CheckState.Unknown;
            }

            X509Certificate? issuer = null;
            foreach (var candidate in candidates)
            {
                try
                {
                    current.Verify(candidate.GetPublicKey());
                    issuer = candidate;
                    break;
                }
                catch { }
            }
            if (issuer is null)
            {
                notes.Add("Подпись сертификата в цепочке не прошла проверку.");
                return CheckState.Invalid;
            }
            current = issuer;
        }
        notes.Add("Превышена максимальная глубина встроенной цепочки сертификатов.");
        return CheckState.Unsupported;
    }
}
