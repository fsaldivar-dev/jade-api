import CryptoKit
import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Resultado de atestar una clave: el servidor lo verifica contra Apple una sola vez.
public struct Attestation: Sendable, Equatable {
    public let keyID: String
    public let attestation: Data
    public init(keyID: String, attestation: Data) { self.keyID = keyID; self.attestation = attestation }
}

/// Lo que App Attest sabe hacer, detrás de un protocolo: `DeviceCheckAttestor` en dispositivos
/// reales; un doble en pruebas y simulador (App Attest no funciona ahí).
public protocol Attestor: Sendable {
    var isSupported: Bool { get }
    /// Genera una clave en hardware y devuelve su id.
    func generateKey() async throws -> String
    /// Atesta la clave con el hash del `challenge` del servidor.
    func attest(keyID: String, clientDataHash: Data) async throws -> Data
    /// Firma el hash de la petición con la clave atestada.
    func assert(keyID: String, clientDataHash: Data) async throws -> Data
}

/// Entrega el challenge que el servidor espera ver dentro de la atestación y de cada aserción.
public protocol ChallengeProvider: Sendable {
    func challenge() async throws -> Data
}

public enum AppAttestError: Error, Equatable, CustomStringConvertible {
    case unsupported
    case keyInvalidated
    public var description: String {
        switch self {
        case .unsupported: "App Attest no está disponible en este dispositivo"
        case .keyInvalidated: "la clave de App Attest fue invalidada; hay que atestar de nuevo"
        }
    }
}

#if canImport(DeviceCheck)
/// App Attest real (`DCAppAttestService`). Solo en dispositivos físicos; en simulador `isSupported` es `false`.
@available(iOS 14, macOS 11, tvOS 15, watchOS 9, *)
public struct DeviceCheckAttestor: Attestor {
    public init() {}
    public var isSupported: Bool { DCAppAttestService.shared.isSupported }
    public func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
    public func attest(keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }
    public func assert(keyID: String, clientDataHash: Data) async throws -> Data {
        do { return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash) }
        catch let error as DCError where error.code == .invalidKey { throw AppAttestError.keyInvalidated }
    }
}
#endif

/// Interceptor App Attest: la primera vez atesta la clave (header `X-App-Attestation`), y en cada
/// petición manda una aserción (`X-App-Assertion`) sobre el hash de la petición y el challenge.
///
/// El servidor verifica la atestación contra Apple una vez y después cada aserción con la clave
/// pública que guardó; así solo tu app, sin modificar y en un dispositivo real, puede llamar.
///
/// Headers: `X-App-Attest-Key-ID`, `X-App-Attestation` (solo la primera vez), `X-App-Assertion`,
/// `X-App-Challenge`. El `clientDataHash` es SHA-256 de `método + ruta + Content-Digest + challenge`.
public struct AppAttestInterceptor: Interceptor {
    public let attestor: any Attestor
    public let challenges: any ChallengeProvider
    public let store: any KeychainStore
    private let state = AttestState()

    public init(attestor: any Attestor, challenges: any ChallengeProvider, store: any KeychainStore) {
        self.attestor = attestor
        self.challenges = challenges
        self.store = store
    }

    public func intercept(_ request: Request, next: Next) async throws -> Response {
        guard attestor.isSupported else { throw AppAttestError.unsupported }
        let challenge = try await challenges.challenge()
        var request = request
        let keyID: String
        let attested: Bool
        if let existing = try await state.keyID(from: store) {
            keyID = existing; attested = true
        } else {
            keyID = try await attestor.generateKey(); attested = false
        }
        let hash = Self.clientDataHash(request: request, challenge: challenge)
        if !attested {
            let attestation = try await attestor.attest(keyID: keyID, clientDataHash: Data(SHA256.hash(data: challenge)))
            request.headers["X-App-Attestation"] = attestation.base64EncodedString()
        }
        do {
            request.headers["X-App-Assertion"] = try await attestor.assert(keyID: keyID, clientDataHash: hash).base64EncodedString()
        } catch AppAttestError.keyInvalidated {
            try await state.forget(in: store)
            throw AppAttestError.keyInvalidated
        }
        request.headers["X-App-Attest-Key-ID"] = keyID
        request.headers["X-App-Challenge"] = challenge.base64EncodedString()
        let response = try await next(request)
        if !attested, response.isSuccess { try await state.remember(keyID, in: store) }
        return response
    }

    public static func clientDataHash(request: Request, challenge: Data) -> Data {
        let digest = request.headers["Content-Digest"] ?? "sha-256=:\(Data(SHA256.hash(data: request.body ?? Data())).base64EncodedString()):"
        var material = Data("\(request.method.rawHTTP)\n\(request.path)\n\(digest)\n".utf8)
        material.append(challenge)
        return Data(SHA256.hash(data: material))
    }
}

actor AttestState {
    private var cachedKeyID: String?
    private let key = "jade.appattest.key"

    func keyID(from store: any KeychainStore) throws -> String? {
        if let cachedKeyID { return cachedKeyID }
        guard let data = try store.read(key) else { return nil }
        cachedKeyID = String(decoding: data, as: UTF8.self)
        return cachedKeyID
    }

    func remember(_ keyID: String, in store: any KeychainStore) throws {
        try store.write(key, Data(keyID.utf8))
        cachedKeyID = keyID
    }

    func forget(in store: any KeychainStore) throws {
        try store.delete(key)
        cachedKeyID = nil
    }
}
