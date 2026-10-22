import CryptoKit
import Foundation
import JadeAPI
import Security
import Testing

@Suite("Nivel 3: pinning de clave pública")
struct PinningTests {

    /// Clave EC P-256 generada en el momento, como SecKey, para calcular pins reales.
    static func makeKey(_ type: CFString = kSecAttrKeyTypeECSECPrimeRandom, bits: Int = 256) throws -> SecKey {
        let attributes: [String: Any] = [kSecAttrKeyType as String: type, kSecAttrKeySizeInBits as String: bits]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(key) else {
            throw error!.takeRetainedValue()
        }
        return publicKey
    }

    @Test("El pin de una clave EC coincide con SHA-256 del SPKI que CryptoKit exporta (x963 → DER)")
    func spkiMatchesCryptoKit() throws {
        let key = try Self.makeKey()
        let pin = try #require(PublicKeyPin.of(key))
        // Referencia independiente: CryptoKit produce el SPKI DER directamente.
        let raw = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        let reference = try P256.Signing.PublicKey(x963Representation: raw).derRepresentation
        #expect(pin.base64 == Data(SHA256.hash(data: reference)).base64EncodedString())
        #expect(pin.description.hasPrefix("sha256/"))
        #expect(PublicKeyPin("sha256/" + pin.base64) == pin)   // el prefijo es opcional al escribirlo
    }

    @Test("RSA 2048 también produce un pin, y una clave de tamaño no soportado no")
    func rsa() throws {
        let rsa = try Self.makeKey(kSecAttrKeyTypeRSA, bits: 2048)
        #expect(PublicKeyPin.of(rsa) != nil)
        let odd = try Self.makeKey(kSecAttrKeyTypeECSECPrimeRandom, bits: 521)
        #expect(PublicKeyPin.of(odd) == nil)
    }

    @Test("La política acepta si alguna clave de la cadena coincide, rechaza si ninguna, y respeta subdominios")
    func policy() {
        let active: PublicKeyPin = "sha256/AAAA"
        let backup: PublicKeyPin = "sha256/BBBB"
        let policy = PinningPolicy(hosts: [
            "api.banco.mx": .init([active, backup]),
            "banco.mx": .init([backup], includesSubdomains: true),
        ])
        #expect(policy.evaluate(host: "api.banco.mx", presented: ["sha256/leaf", active]) == .pinned)
        #expect(policy.evaluate(host: "api.banco.mx", presented: [backup]) == .pinned)          // el de respaldo vale
        #expect(policy.evaluate(host: "api.banco.mx", presented: ["sha256/otra"]) == .rejected("ninguna clave de la cadena de 'api.banco.mx' coincide con los pins"))
        #expect(policy.evaluate(host: "pagos.banco.mx", presented: [backup]) == .pinned)        // subdominio
        #expect(policy.evaluate(host: "otro.com", presented: ["sha256/x"]) == .systemTrust)     // sin pins: sistema
        let strict = PinningPolicy(hosts: [:], unpinnedHosts: .reject)
        #expect(strict.evaluate(host: "otro.com", presented: []) == .rejected("host 'otro.com' sin pins configurados"))
    }

    @Test("Pins caducados dejan de aplicarse: la rotación no deja a los usuarios sin servicio")
    func expiry() {
        let policy = PinningPolicy(hosts: ["api.banco.mx": .init(["sha256/AAAA"], expires: Date(timeIntervalSince1970: 1000))])
        #expect(policy.evaluate(host: "api.banco.mx", presented: ["sha256/otra"], at: Date(timeIntervalSince1970: 999)) != .pinned)
        #expect(policy.evaluate(host: "api.banco.mx", presented: ["sha256/otra"], at: Date(timeIntervalSince1970: 1001)) == .systemTrust)
    }

    @Test("Los pins del Info.plist llegan a la configuración del servicio y el entorno crea un transporte con pinning")
    func fromPlist() throws {
        let environment = try Environment(plist: ["services": ["pagos": [
            "baseURL": "https://pagos.banco.mx",
            "pins": "sha256/AAAA sha256/BBBB",
            "pinsExpire": "2030-01-01T00:00:00Z",
        ]]])
        let pins = try #require(environment.configuration(for: "pagos")?.pins)
        #expect(pins.pins == ["sha256/AAAA", "sha256/BBBB"])
        #expect(pins.expires == ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        let client = try environment.client(for: "pagos")
        let transport = try #require(client.transport as? URLSessionClient)
        #expect(transport.session.delegate is PinnedSessionDelegate)
    }
}
