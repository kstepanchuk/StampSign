namespace StampSign.Core;

public enum SignatureMode
{
    Detached,
    Attached
}

public enum CheckState
{
    Unknown,
    Valid,
    Invalid,
    Unsupported
}

public sealed record SignatureInfo(
    string SerialHex,
    string Owner,
    DateTimeOffset NotBefore,
    DateTimeOffset NotAfter,
    DateTimeOffset? SigningTime,
    SignatureMode Mode);

public enum SigningTimeSource
{
    SignedAttribute,
    TimestampToken
}

public sealed record SigningTimeInfo(DateTimeOffset Time, SigningTimeSource Source);

public sealed record VerificationResult(
    CheckState Integrity,
    CheckState Signature,
    CheckState CertificateTime,
    CheckState Chain,
    IReadOnlyList<string> Notes)
{
    public static VerificationResult Error(string message) => new(
        CheckState.Unknown, CheckState.Unknown, CheckState.Unknown, CheckState.Unknown, [message]);
}

public sealed record SignatureInput(
    byte[] Signature,
    byte[]? Document,
    SignatureMode Mode,
    byte[]? EmbeddedContent);
