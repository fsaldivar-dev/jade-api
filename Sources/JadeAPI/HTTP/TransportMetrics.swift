import Foundation

/// Lo que el transporte midió al servir una petición: tiempos por fase, bytes y protocolo.
/// Viene en ``Response/metrics`` cuando el transporte las da (`URLSessionClient` y `MockClient`);
/// un `HTTPClient` propio puede rellenarlas con ``init(duration:bytesSent:bytesReceived:protocolName:)``.
/// Son valores de rendimiento, nunca contenido: se pueden mandar a telemetría sin redactar.
public struct TransportMetrics: Sendable, Hashable {
    /// De que la tarea arrancó a que terminó, reintentos de transporte incluidos.
    public var duration: Duration
    /// Resolución DNS, si hubo (nil con conexión reutilizada).
    public var dns: Duration?
    /// Conexión TCP, si hubo.
    public var connect: Duration?
    /// Handshake TLS, si hubo.
    public var tls: Duration?
    /// Del inicio de la petición al primer byte de la respuesta.
    public var timeToFirstByte: Duration?
    public var bytesSent: Int64
    public var bytesReceived: Int64
    /// `http/1.1`, `h2`, `h3`… o `mock`.
    public var protocolName: String?
    /// La conexión ya estaba abierta (keep-alive, h2 multiplexado).
    public var reusedConnection: Bool
    public var redirectCount: Int
    /// IP del servidor, si el transporte la expone.
    public var remoteAddress: String?

    public init(duration: Duration, dns: Duration? = nil, connect: Duration? = nil, tls: Duration? = nil,
                timeToFirstByte: Duration? = nil, bytesSent: Int64 = 0, bytesReceived: Int64 = 0,
                protocolName: String? = nil, reusedConnection: Bool = false, redirectCount: Int = 0, remoteAddress: String? = nil) {
        self.duration = duration
        self.dns = dns
        self.connect = connect
        self.tls = tls
        self.timeToFirstByte = timeToFirstByte
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.protocolName = protocolName
        self.reusedConnection = reusedConnection
        self.redirectCount = redirectCount
        self.remoteAddress = remoteAddress
    }

    /// Métricas de un transporte que no mide fases (mocks, backends propios): solo duración y bytes.
    public init(duration: Duration, bytesSent: Int, bytesReceived: Int, protocolName: String) {
        self.init(duration: duration, bytesSent: Int64(bytesSent), bytesReceived: Int64(bytesReceived), protocolName: protocolName)
    }

    /// Mapea `URLSessionTaskMetrics`. Las fases salen de la última transacción de red (la que respondió).
    public init(_ metrics: URLSessionTaskMetrics) {
        let transactions = metrics.transactionMetrics
        let network = transactions.last { $0.resourceFetchType == .networkLoad } ?? transactions.last
        func span(_ start: Date?, _ end: Date?) -> Duration? {
            guard let start, let end else { return nil }
            return .seconds(end.timeIntervalSince(start))
        }
        self.init(
            duration: .seconds(metrics.taskInterval.duration),
            dns: span(network?.domainLookupStartDate, network?.domainLookupEndDate),
            connect: span(network?.connectStartDate, network?.connectEndDate),
            tls: span(network?.secureConnectionStartDate, network?.secureConnectionEndDate),
            timeToFirstByte: span(network?.requestStartDate, network?.responseStartDate),
            bytesSent: transactions.reduce(0) { $0 + $1.countOfRequestHeaderBytesSent + $1.countOfRequestBodyBytesSent },
            bytesReceived: transactions.reduce(0) { $0 + $1.countOfResponseHeaderBytesReceived + $1.countOfResponseBodyBytesReceived },
            protocolName: network?.networkProtocolName,
            reusedConnection: network?.isReusedConnection ?? false,
            redirectCount: metrics.redirectCount,
            remoteAddress: network?.remoteAddress
        )
    }
}

/// Métricas de un stream: llegan cuando la tarea termina, o sea después de consumir los bytes.
/// `await streaming.metrics.value` espera a ese momento; es `nil` si el transporte no mide.
public final class MetricsFuture: Sendable {
    private struct State { var value: TransportMetrics??; var waiters: [CheckedContinuation<TransportMetrics?, Never>] = [] }
    private let state = Locked(State())

    public init() {}

    /// Ya resuelto: para transportes que no miden, o que miden al instante.
    public convenience init(_ metrics: TransportMetrics?) {
        self.init()
        resolve(metrics)
    }

    /// El transporte lo llama una vez. Llamadas posteriores se ignoran.
    public func resolve(_ metrics: TransportMetrics?) {
        let waiters: [CheckedContinuation<TransportMetrics?, Never>] = state.withLock { state in
            guard state.value == nil else { return [] }
            state.value = .some(metrics)
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume(returning: metrics) }
    }

    public var value: TransportMetrics? {
        get async {
            await withCheckedContinuation { continuation in
                let resolved: TransportMetrics?? = state.withLock { state in
                    if let value = state.value { return value }
                    state.waiters.append(continuation)
                    return nil
                }
                if let resolved { continuation.resume(returning: resolved) }
            }
        }
    }
}

/// Caja con lock, para estado mutable compartido en tipos `Sendable`.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}

extension Duration {
    /// `12.3 ms`, para logs.
    public var millisecondsText: String {
        let ms = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return String(format: "%.1f ms", ms)
    }
}
