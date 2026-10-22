import Foundation

/// Política de reintento a nivel HTTP. Reintenta solo lo que tiene sentido reintentar:
/// errores de transporte, 5xx, 408 y 429. Nunca 4xx de negocio ni errores de decodificación.
public struct RetryPolicy: Sendable, Hashable {
    public enum Backoff: Sendable, Hashable {
        case none
        case constant(Duration)
        /// `initial`, multiplicado por `factor` en cada intento, hasta `max`.
        case exponential(Duration, factor: Double = 2, max: Duration = .seconds(30))
    }

    public var attempts: Int
    public var backoff: Backoff
    /// Si el servidor manda `Retry-After` (segundos), se respeta en lugar del backoff.
    public var honorsRetryAfter: Bool

    public init(attempts: Int, backoff: Backoff = .none, honorsRetryAfter: Bool = true) {
        self.attempts = max(1, attempts)
        self.backoff = backoff
        self.honorsRetryAfter = honorsRetryAfter
    }

    public static func shouldRetry(status: Int) -> Bool {
        status >= 500 || status == 408 || status == 429
    }

    func delay(forAttempt attempt: Int) -> Duration { backoff.delay(forAttempt: attempt) }
}

extension RetryPolicy.Backoff {
    /// Espera antes del intento `attempt` (1 = primer reintento).
    public func delay(forAttempt attempt: Int) -> Duration {
        switch self {
        case .none: .zero
        case .constant(let duration): duration
        case .exponential(let initial, let factor, let maximum):
            min(initial * pow(factor, Double(max(attempt, 1) - 1)), maximum)
        }
    }
}

/// Opciones de una petición, declaradas sobre el endpoint o el repositorio y aplicadas por el
/// cliente justo antes del transporte: timeout, caché en memoria, reintento y deduplicación.
public struct RequestOptions: Sendable, Hashable {
    /// Tiempo máximo de la petición. Se aplica al `URLRequest` y se vigila también en el cliente.
    public var timeout: Duration?
    /// Las respuestas 2xx se guardan en memoria por verbo + URL durante este tiempo.
    public var cache: Duration?
    public var retry: RetryPolicy?
    /// Peticiones idénticas en vuelo comparten una sola respuesta.
    public var singleFlight: Bool
    /// Reconexión y keep-alive de un `@Socket`.
    public var socket: SocketPolicy?

    public init(timeout: Duration? = nil, cache: Duration? = nil, retry: RetryPolicy? = nil, singleFlight: Bool = false, socket: SocketPolicy? = nil) {
        self.timeout = timeout
        self.cache = cache
        self.retry = retry
        self.singleFlight = singleFlight
        self.socket = socket
    }

    public static let none = RequestOptions()

    /// Las del endpoint ganan sobre las del repositorio, campo a campo.
    public func merging(over base: RequestOptions) -> RequestOptions {
        RequestOptions(timeout: timeout ?? base.timeout, cache: cache ?? base.cache,
                       retry: retry ?? base.retry, singleFlight: singleFlight || base.singleFlight,
                       socket: socket ?? base.socket)
    }
}

extension Duration {
    static func * (lhs: Duration, rhs: Double) -> Duration {
        let seconds = Double(lhs.components.seconds) + Double(lhs.components.attoseconds) / 1e18
        return .seconds(seconds * rhs)
    }
}
