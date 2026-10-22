/// Verbo HTTP. Los nombres en minúscula permiten `.get`, `.post`, … en `@Api(method:)`.
public enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    case get, post, put, patch, delete, head, options

    /// Representación en mayúsculas para la petición real.
    public var rawHTTP: String { rawValue.uppercased() }

    /// Verbos que se pueden repetir sin efectos acumulados (RFC 9110). Un POST o PATCH solo se
    /// reintenta si la petición lleva `Idempotency-Key`.
    public var isIdempotent: Bool {
        switch self {
        case .get, .head, .options, .put, .delete: true
        case .post, .patch: false
        }
    }

    /// Los verbos que por convención no llevan body: sus parámetros van a la query.
    public var carriesBody: Bool {
        switch self {
        case .post, .put, .patch: true
        case .get, .delete, .head, .options: false
        }
    }
}
