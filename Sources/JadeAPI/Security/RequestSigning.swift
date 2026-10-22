import CryptoKit
import Foundation

/// Firma HTTP según RFC 9421 (HTTP Message Signatures) con `Content-Digest` (RFC 9530).
///
/// Firma método, URI destino, el hash del body, la fecha y un nonce con la clave del dispositivo;
/// el servidor verifica integridad, autenticidad y que la petición no se repita. Es lo que piden
/// Open Banking UK y los perfiles de pagos; con la clave en el Secure Enclave, nadie puede firmar
/// desde otro sitio.
///
/// Headers producidos:
/// ```
/// Content-Digest: sha-256=:<base64>:
/// Signature-Input: jade=("@method" "@target-uri" "content-digest");created=1700000000;keyid="k1";alg="ecdsa-p256-sha256";nonce="…"
/// Signature: jade=:<base64 de ES256 sobre la base de firma>:
/// ```
public struct SignedRequestInterceptor: Interceptor {
    public let key: any SigningKey
    public let label: String
    /// Headers adicionales a cubrir con la firma, en minúsculas (p. ej. `["authorization", "idempotency-key"]`).
    public let coveredHeaders: [String]
    public let now: @Sendable () -> Date

    public init(key: any SigningKey, label: String = "jade", coveredHeaders: [String] = [], now: @escaping @Sendable () -> Date = { .now }) {
        self.key = key
        self.label = label
        self.coveredHeaders = coveredHeaders.map { $0.lowercased() }
        self.now = now
    }

    public func intercept(_ request: Request, next: Next) async throws -> Response {
        try await next(try sign(request))
    }

    /// Añade `Content-Digest`, `Signature-Input` y `Signature`.
    public func sign(_ request: Request, nonce: String = UUID().uuidString) throws -> Request {
        var request = request
        let digest = "sha-256=:\(Data(SHA256.hash(data: request.body ?? Data())).base64EncodedString()):"
        request.headers["Content-Digest"] = digest

        var components = ["@method", "@target-uri", "content-digest"]
        for name in coveredHeaders where request.headers.keys.contains(where: { $0.lowercased() == name }) {
            components.append(name)
        }
        let created = Int(now().timeIntervalSince1970)
        let identifiers = components.map { "\"\($0)\"" }.joined(separator: " ")
        let parameters = "(\(identifiers));created=\(created);keyid=\"\(key.keyID)\";alg=\"ecdsa-p256-sha256\";nonce=\"\(nonce)\""

        let base = Self.signatureBase(request: request, components: components, parameters: parameters)
        let signature = try key.sign(Data(base.utf8))
        request.headers["Signature-Input"] = "\(label)=\(parameters)"
        request.headers["Signature"] = "\(label)=:\(signature.base64EncodedString()):"
        return request
    }

    /// Base de firma RFC 9421 §2.5: una línea por componente y la línea `@signature-params`.
    public static func signatureBase(request: Request, components: [String], parameters: String) -> String {
        var lines: [String] = []
        for component in components {
            let value: String
            switch component {
            case "@method": value = request.method.rawHTTP
            case "@target-uri": value = request.url.absoluteString
            case "@authority": value = request.url.host ?? ""
            case "@path": value = request.url.path.isEmpty ? "/" : request.url.path
            default: value = request.headers.first { $0.key.lowercased() == component }?.value.trimmingCharacters(in: .whitespaces) ?? ""
            }
            lines.append("\"\(component)\": \(value)")
        }
        lines.append("\"@signature-params\": \(parameters)")
        return lines.joined(separator: "\n")
    }
}
