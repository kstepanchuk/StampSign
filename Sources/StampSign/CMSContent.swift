import Foundation

/// Вложенное содержимое CMS SignedData (attached CAdES/CMS).
/// Возвращает nil для откреплённой подписи.
enum CMSContent {
    static func extract(from data: Data) throws -> Data? {
        var raw = [UInt8](data)
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") {
            let encoded = text.split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix("-----") }.joined()
            guard let decoded = Data(base64Encoded: encoded) else {
                throw SigError.invalid("неверный PEM/Base64")
            }
            raw = [UInt8](decoded)
        }

        let der = DER(d: raw)
        let root = try der.parse(0, raw.count)
        let outer = try der.kids(root)
        guard outer.count >= 2, outer[1].tag == 0xA0,
              let signedData = try der.kids(outer[1]).first else {
            throw SigError.invalid("это не CMS SignedData")
        }
        let fields = try der.kids(signedData)
        guard fields.count >= 3 else { throw SigError.invalid("повреждённый SignedData") }

        // SignedData.encapContentInfo = SEQUENCE { contentType OID, eContent [0] EXPLICIT OCTET STRING OPTIONAL }
        let encapsulated = try der.kids(fields[2])
        guard encapsulated.count >= 2, encapsulated[1].tag == 0xA0,
              let value = try der.kids(encapsulated[1]).first else { return nil }
        return try octets(value, der)
    }

    private static func octets(_ node: TLV, _ der: DER) throws -> Data {
        if node.tag == 0x04 { return Data(der.bytes(node)) }
        guard node.tag == 0x24 else { throw SigError.invalid("eContent не является OCTET STRING") }
        var result = Data()
        for child in try der.kids(node) { result.append(try octets(child, der)) }
        return result
    }
}
