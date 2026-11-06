import Foundation
import Security

/// Autenticación de cliente que exige el firmware moderno del Seestar (7.18 en adelante).
/// El telescopio envía un texto de reto (`get_verify_str`) y el cliente responde con la
/// firma SHA1withRSA de ese texto (`verify_client`). La clave privada la aporta el usuario
/// en Ajustes como un archivo PEM; la app no incluye ninguna clave.
enum SeestarAuthError: LocalizedError {
    case noKey
    case badPEM
    case keyCreation(String)
    case signing(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return tr("No hay clave PEM configurada en Ajustes.")
        case .badPEM: return tr("El archivo PEM no es válido.")
        case .keyCreation(let m): return tr("No se pudo cargar la clave: %@", "\(m)")
        case .signing(let m): return tr("No se pudo firmar el reto: %@", "\(m)")
        }
    }
}

struct SeestarSigner {
    let key: SecKey

    init(pemText: String) throws {
        let isPKCS8 = pemText.contains("BEGIN PRIVATE KEY")
        let body = pemText
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard var der = Data(base64Encoded: body) else { throw SeestarAuthError.badPEM }
        if isPKCS8 {
            guard let inner = SeestarSigner.pkcs1FromPKCS8(der) else { throw SeestarAuthError.badPEM }
            der = inner
        }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            let msg = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "desconocido"
            throw SeestarAuthError.keyCreation(msg)
        }
        self.key = key
    }

    init(pemURL: URL) throws {
        let text = try String(contentsOf: pemURL, encoding: .utf8)
        try self.init(pemText: text)
    }

    /// Devuelve la firma en base64, como espera `verify_client`.
    func sign(_ challenge: String) throws -> String {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA1,
            Data(challenge.utf8) as CFData,
            &error
        ) as Data? else {
            let msg = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "desconocido"
            throw SeestarAuthError.signing(msg)
        }
        return sig.base64EncodedString()
    }

    // MARK: - DER mínimo para extraer la clave PKCS#1 de un contenedor PKCS#8

    private static func readLength(_ bytes: [UInt8], _ i: inout Int) -> Int? {
        guard i < bytes.count else { return nil }
        let first = bytes[i]; i += 1
        if first & 0x80 == 0 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, i + count <= bytes.count else { return nil }
        var len = 0
        for _ in 0..<count { len = (len << 8) | Int(bytes[i]); i += 1 }
        return len
    }

    static func pkcs1FromPKCS8(_ data: Data) -> Data? {
        let b = [UInt8](data)
        var i = 0
        // SEQUENCE
        guard b.count > 2, b[i] == 0x30 else { return nil }
        i += 1
        guard readLength(b, &i) != nil else { return nil }
        // INTEGER version
        guard i < b.count, b[i] == 0x02 else { return nil }
        i += 1
        guard let vlen = readLength(b, &i) else { return nil }
        i += vlen
        // SEQUENCE algorithm
        guard i < b.count, b[i] == 0x30 else { return nil }
        i += 1
        guard let alen = readLength(b, &i) else { return nil }
        i += alen
        // OCTET STRING con la clave PKCS#1
        guard i < b.count, b[i] == 0x04 else { return nil }
        i += 1
        guard let klen = readLength(b, &i), i + klen <= b.count else { return nil }
        return Data(b[i..<(i + klen)])
    }
}
