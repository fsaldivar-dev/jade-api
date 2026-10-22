import CryptoKit
import Foundation

/// Base64url sin relleno (RFC 7515).
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

/// Clave de firma ES256 del dispositivo. En hardware compatible vive en el Secure Enclave y nunca
/// sale de él; si no, es una clave de software (útil en simulador y pruebas).
public protocol SigningKey: Sendable {
    /// Identificador estable de la clave (`kid`).
    var keyID: String { get }
    /// Clave pública como JWK (`kty`, `crv`, `x`, `y`), para DPoP y para registrar la clave en el servidor.
    var jwk: [String: String] { get }
    /// Firma ES256 (r‖s crudos, 64 bytes) del mensaje.
    func sign(_ message: Data) throws -> Data
}

/// Clave P-256 de CryptoKit; en Secure Enclave cuando está disponible y se pide.
public struct P256SigningKey: SigningKey {
    private enum Backing: Sendable {
        case software(P256.Signing.PrivateKey)
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
    }
    private let backing: Backing
    public let keyID: String

    /// Clave nueva. `preferSecureEnclave` usa el enclave si el dispositivo lo tiene.
    public init(preferSecureEnclave: Bool = true, keyID: String = UUID().uuidString) throws {
        if preferSecureEnclave, SecureEnclave.isAvailable {
            backing = .enclave(try SecureEnclave.P256.Signing.PrivateKey())
        } else {
            backing = .software(P256.Signing.PrivateKey())
        }
        self.keyID = keyID
    }

    /// Clave de software a partir de su representación cruda (por ejemplo leída de un ``KeychainStore``).
    public init(rawRepresentation: Data, keyID: String) throws {
        backing = .software(try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation))
        self.keyID = keyID
    }

    /// Clave del Secure Enclave a partir de su `dataRepresentation` guardada.
    public init(secureEnclaveRepresentation: Data, keyID: String) throws {
        backing = .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: secureEnclaveRepresentation))
        self.keyID = keyID
    }

    /// Lo que se guarda para recuperar la clave. En el enclave es un blob cifrado, no la clave.
    public var persistentRepresentation: (data: Data, isSecureEnclave: Bool) {
        switch backing {
        case .software(let key): (key.rawRepresentation, false)
        case .enclave(let key): (key.dataRepresentation, true)
        }
    }

    public var publicKey: P256.Signing.PublicKey {
        switch backing {
        case .software(let key): key.publicKey
        case .enclave(let key): key.publicKey
        }
    }

    public var isSecureEnclave: Bool { if case .enclave = backing { true } else { false } }

    public var jwk: [String: String] {
        let x963 = publicKey.x963Representation   // 0x04 ‖ X ‖ Y
        let x = x963[1..<33], y = x963[33..<65]
        return ["kty": "EC", "crv": "P-256", "x": Base64URL.encode(Data(x)), "y": Base64URL.encode(Data(y))]
    }

    public func sign(_ message: Data) throws -> Data {
        switch backing {
        case .software(let key): try key.signature(for: message).rawRepresentation
        case .enclave(let key): try key.signature(for: message).rawRepresentation
        }
    }
}

extension P256SigningKey {
    /// Carga la clave del ``KeychainStore`` o crea una nueva y la guarda. Así la identidad del
    /// dispositivo sobrevive a reinicios y la clave sigue sin salir del enclave.
    public static func load(from store: any KeychainStore, key name: String = "jade.dpop", preferSecureEnclave: Bool = true) throws -> P256SigningKey {
        struct Stored: Codable { let data: Data; let enclave: Bool; let keyID: String }
        if let data = try store.read(name), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            if stored.enclave, SecureEnclave.isAvailable, let key = try? P256SigningKey(secureEnclaveRepresentation: stored.data, keyID: stored.keyID) { return key }
            if !stored.enclave, let key = try? P256SigningKey(rawRepresentation: stored.data, keyID: stored.keyID) { return key }
        }
        let fresh = try P256SigningKey(preferSecureEnclave: preferSecureEnclave)
        let representation = fresh.persistentRepresentation
        try store.write(name, try JSONEncoder().encode(Stored(data: representation.data, enclave: representation.isSecureEnclave, keyID: fresh.keyID)))
        return fresh
    }
}

// MARK: - DPoP (RFC 9449)

/// Construye pruebas DPoP: un JWT ES256 por petición que ata el access token a la clave del dispositivo.
/// Un token robado no sirve sin la clave, que puede vivir en el Secure Enclave.
public struct DPoPProof: Sendable {
    public let key: any SigningKey

    public init(key: any SigningKey) { self.key = key }

    /// Prueba para `method` + `url`. `accessToken` añade `ath` (hash del token); `nonce` es el que
    /// mandó el servidor en `DPoP-Nonce`.
    public func make(method: HTTPMethod, url: URL, accessToken: String? = nil, nonce: String? = nil, issuedAt: Date = .now, jti: String = UUID().uuidString) throws -> String {
        var header: [String: Any] = ["typ": "dpop+jwt", "alg": "ES256", "jwk": key.jwk]
        header["kid"] = key.keyID
        var payload: [String: Any] = [
            "jti": jti,
            "htm": method.rawHTTP,
            "htu": Self.htu(url),
            "iat": Int(issuedAt.timeIntervalSince1970),
        ]
        if let accessToken { payload["ath"] = Base64URL.encode(Data(SHA256.hash(data: Data(accessToken.utf8)))) }
        if let nonce { payload["nonce"] = nonce }
        let encodedHeader = Base64URL.encode(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let encodedPayload = Base64URL.encode(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signingInput = Data("\(encodedHeader).\(encodedPayload)".utf8)
        let signature = Base64URL.encode(try key.sign(signingInput))
        return "\(encodedHeader).\(encodedPayload).\(signature)"
    }

    /// `htu`: URL sin query ni fragmento (RFC 9449 §4.2).
    public static func htu(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
}

/// Interceptor DPoP: añade `DPoP: <prueba>` a cada petición y manda el token como
/// `Authorization: DPoP <token>` (en vez de `Bearer`). Si el servidor responde `DPoP-Nonce`
/// (con 400 `use_dpop_nonce` o 401), repite una vez con el nonce.
///
/// Es la pieza central de FAPI 2.0: tokens atados al cliente (*sender-constrained*).
public struct DPoPInterceptor: Interceptor {
    public let proof: DPoPProof
    public let tokens: (any TokenProvider)?
    private let nonces = NonceStore()

    public init(key: any SigningKey, tokens: (any TokenProvider)? = nil) {
        self.proof = DPoPProof(key: key)
        self.tokens = tokens
    }

    public func intercept(_ request: Request, next: Next) async throws -> Response {
        let token = try await tokens?.currentToken()
        var request = request
        if let token { request.headers["Authorization"] = "DPoP \(token)" }
        let nonce = await nonces.nonce(for: request.url.host ?? "")
        request.headers["DPoP"] = try proof.make(method: request.method, url: request.url, accessToken: token, nonce: nonce)
        let response = try await next(request)
        guard let fresh = response.header("DPoP-Nonce") else { return response }
        await nonces.store(fresh, for: request.url.host ?? "")
        guard response.status == 400 || response.status == 401, fresh != nonce else { return response }
        request.headers["DPoP"] = try proof.make(method: request.method, url: request.url, accessToken: token, nonce: fresh)
        return try await next(request)
    }
}

/// Último `DPoP-Nonce` por host.
actor NonceStore {
    private var nonces: [String: String] = [:]
    func nonce(for host: String) -> String? { nonces[host] }
    func store(_ nonce: String, for host: String) { nonces[host] = nonce }
}
