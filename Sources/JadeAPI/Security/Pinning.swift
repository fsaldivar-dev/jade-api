import CryptoKit
import Foundation
import Security

/// Pin de clave pública: `sha256/<base64 del SubjectPublicKeyInfo>`, el formato de HPKP y de la
/// mayoría de herramientas (`openssl x509 -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`).
public struct PublicKeyPin: Sendable, Hashable, ExpressibleByStringLiteral {
    public let base64: String

    public init(_ pin: String) {
        base64 = pin.hasPrefix("sha256/") ? String(pin.dropFirst("sha256/".count)) : pin
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var description: String { "sha256/\(base64)" }

    /// Pin de una clave pública (`SecKey`): SHA-256 del SPKI en DER.
    public static func of(_ key: SecKey) -> PublicKeyPin? {
        guard let spki = SPKI.encode(key) else { return nil }
        return PublicKeyPin(Data(SHA256.hash(data: spki)).base64EncodedString())
    }

    /// Pin del certificado (su clave pública).
    public static func of(_ certificate: SecCertificate) -> PublicKeyPin? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        return of(key)
    }
}

/// Pins por host, con respaldo y caducidad. Siempre configura al menos dos pins por host (el activo y
/// uno de respaldo que no esté desplegado) y una fecha de caducidad: si no, una rotación de certificado
/// deja a los usuarios sin servicio hasta que actualicen la app.
public struct PinningPolicy: Sendable {
    public struct HostPins: Sendable {
        public var pins: Set<PublicKeyPin>
        /// Pasada esta fecha, el pinning deja de aplicarse (se confía en el sistema) en vez de romper la app.
        public var expires: Date?
        /// Aplica también a subdominios.
        public var includesSubdomains: Bool

        public init(_ pins: [PublicKeyPin], expires: Date? = nil, includesSubdomains: Bool = false) {
            self.pins = Set(pins)
            self.expires = expires
            self.includesSubdomains = includesSubdomains
        }
    }

    public var hosts: [String: HostPins]
    /// Qué hacer con un host sin pins: confiar en el sistema (por defecto) o rechazar.
    public var unpinnedHosts: UnpinnedPolicy
    public enum UnpinnedPolicy: Sendable { case trustSystem, reject }

    public init(hosts: [String: HostPins], unpinnedHosts: UnpinnedPolicy = .trustSystem) {
        self.hosts = hosts
        self.unpinnedHosts = unpinnedHosts
    }

    public func pins(for host: String, at date: Date = .now) -> HostPins? {
        let lowered = host.lowercased()
        let match = hosts[lowered] ?? hosts.first { entry in
            entry.value.includesSubdomains && lowered.hasSuffix("." + entry.key.lowercased())
        }?.value
        guard let match else { return nil }
        if let expires = match.expires, expires <= date { return nil }   // caducado: confiar en el sistema
        return match
    }

    public enum Decision: Sendable, Equatable { case pinned, systemTrust, rejected(String) }

    /// Decide a partir de los pins de la cadena presentada (hoja e intermedios).
    public func evaluate(host: String, presented: [PublicKeyPin], at date: Date = .now) -> Decision {
        guard let expected = pins(for: host, at: date) else {
            return unpinnedHosts == .reject ? .rejected("host '\(host)' sin pins configurados") : .systemTrust
        }
        if expected.pins.isDisjoint(with: presented) {
            return .rejected("ninguna clave de la cadena de '\(host)' coincide con los pins")
        }
        return .pinned
    }
}

/// Delegado de `URLSession` que valida la cadena del servidor con el sistema y después con los pins.
public final class PinnedSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    public let policy: PinningPolicy

    public init(policy: PinningPolicy) { self.policy = policy }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let host = challenge.protectionSpace.host
        // 1. Validación estándar del sistema (cadena, caducidad, nombre).
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { return (.cancelAuthenticationChallenge, nil) }
        // 2. Pins contra cualquier clave de la cadena.
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let presented = chain.compactMap(PublicKeyPin.of)
        switch policy.evaluate(host: host, presented: presented) {
        case .pinned, .systemTrust: return (.useCredential, URLCredential(trust: trust))
        case .rejected: return (.cancelAuthenticationChallenge, nil)
        }
    }
}

extension URLSessionClient {
    /// Transporte con pinning de clave pública. Crea una `URLSession` propia con el delegado.
    public static func pinned(_ policy: PinningPolicy, configuration: URLSessionConfiguration = .default) -> URLSessionClient {
        URLSessionClient(session: URLSession(configuration: configuration, delegate: PinnedSessionDelegate(policy: policy), delegateQueue: nil))
    }
}

/// Codificación SubjectPublicKeyInfo (DER) de una clave, para calcular el pin como lo hacen HPKP,
/// TrustKit y Alamofire: cabecera ASN.1 por tipo y tamaño + bytes de la clave.
enum SPKI {
    static func encode(_ key: SecKey) -> Data? {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let type = attributes[kSecAttrKeyType as String] as? String,
              let size = attributes[kSecAttrKeySizeInBits as String] as? Int,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        let header: [UInt8]
        switch (type, size) {
        case (String(kSecAttrKeyTypeRSA), 2048):
            header = [0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00]
        case (String(kSecAttrKeyTypeRSA), 4096):
            header = [0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00]
        case (String(kSecAttrKeyTypeECSECPrimeRandom), 256):
            header = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        case (String(kSecAttrKeyTypeECSECPrimeRandom), 384):
            header = [0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00]
        default:
            return nil
        }
        return Data(header) + raw
    }
}
