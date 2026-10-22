import Foundation

/// Un frame WebSocket.
public enum SocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// Conexión WebSocket abierta que el transporte entrega. `URLSessionClient` la implementa con
/// `URLSessionWebSocketTask`; un transporte propio puede implementarla con lo que quiera.
public protocol SocketConnection: Sendable {
    func send(_ frame: SocketFrame) async throws
    /// Siguiente frame. Lanza cuando la conexión se cierra o falla.
    func receive() async throws -> SocketFrame
    func ping() async throws
    func close(code: Int, reason: String?)
}

/// Transporte capaz de abrir WebSockets.
public protocol SocketClient: HTTPClient {
    /// Abre la conexión y espera el handshake; lanza si el servidor lo rechaza.
    func connect(_ request: Request) async throws -> any SocketConnection
}

/// Política de resiliencia de un `@Socket`. Sin `reconnect`, una caída termina `messages` con error.
public struct SocketPolicy: Sendable, Hashable {
    /// Espera entre intentos de reconexión. `nil` = no reconectar.
    public var reconnect: RetryPolicy.Backoff?
    /// Intentos seguidos sin éxito antes de rendirse. `nil` = sin límite.
    public var maxReconnects: Int?
    /// Cada cuánto se manda un ping. Un ping fallido cuenta como caída y entra la política.
    public var keepAlive: Duration?

    public init(reconnect: RetryPolicy.Backoff? = nil, maxReconnects: Int? = nil, keepAlive: Duration? = nil) {
        self.reconnect = reconnect
        self.maxReconnects = maxReconnects
        self.keepAlive = keepAlive
    }

    public static let none = SocketPolicy()
}

/// Lo que le pasa a la conexión por debajo de `messages`. Útil para re-suscribirse al reconectar
/// (`.connected(attempt:)` con `attempt > 0`) y para mostrar estado en la UI.
public enum SocketEvent: Sendable {
    /// Conexión abierta. `attempt` es 0 la primera vez y crece con cada reconexión.
    case connected(attempt: Int)
    /// La conexión cayó; si hay política, sigue `.reconnecting`.
    case disconnected(any Error)
    /// Se va a reintentar tras `after`.
    case reconnecting(attempt: Int, after: Duration)
    /// Cerrado del todo: por `close()`, por cierre normal del servidor, o porque la política se rindió.
    case closed(code: Int)
}

/// `send` sin conexión abierta. Escucha `.connected` en `events` y reenvía si te importa ese mensaje.
public struct SocketDisconnected: Error, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String { "WebSocket sin conexión: reconectando o cerrado" }
}

/// Un WebSocket tipado. Se obtiene de un requisito `@Socket("/ruta")` que devuelve
/// `Socket<Saliente, Entrante>`:
///
/// - `String` viaja como frames de texto; `Data` como binarios; cualquier otro tipo `Codable`, como JSON en texto.
///
/// ```swift
/// let chat = try await rooms.chat(room: "general")      // Socket<Outgoing, Incoming>
/// try await chat.send(.text("hola"))
/// for try await message in chat.messages { … }         // termina al cerrar; lanza si la conexión falla
/// chat.close()
/// ```
///
/// `messages` y `events` admiten un único consumidor cada uno. Sin política, no reconecta: si la
/// conexión cae, `messages` termina con error y el llamador decide. Con
/// `@Socket("/ruta", reconnect: .exponential(.seconds(1), max: .seconds(30)), keepAlive: .seconds(30))`
/// las caídas no terminan `messages`: `events` avisa (`.disconnected`, `.reconnecting`, `.connected`),
/// cada intento vuelve a pasar el handshake por los interceptores (token fresco), y `send` mientras
/// tanto lanza ``SocketDisconnected``. No reconecta ante cierre normal (1000, 1001), `close()`,
/// errores de protocolo o de política (1002, 1003, 1007–1010, 4xxx) ni handshakes rechazados con 4xx
/// salvo 408 y 429.
public final class Socket<Outgoing: Sendable, Incoming: Sendable>: Sendable {
    public typealias Connector = @Sendable () async throws -> any SocketConnection

    public let request: Request
    public let policy: SocketPolicy
    public let messages: AsyncThrowingStream<Incoming, any Error>
    public let events: AsyncStream<SocketEvent>

    private struct State {
        var connection: any SocketConnection
        var isConnected = true
        var closedByUser = false
    }
    private let state: Locked<State>
    private let connector: Connector
    private let encodeMessage: @Sendable (Outgoing) throws -> SocketFrame
    private let receiver: Locked<Task<Void, Never>?> = Locked(nil)
    private let keepAlive: Locked<Task<Void, Never>?> = Locked(nil)
    private let emit: AsyncStream<SocketEvent>.Continuation

    init(request: Request, connection: any SocketConnection, policy: SocketPolicy = .none,
         connector: @escaping Connector = { throw SocketDisconnected() },
         encode: @escaping @Sendable (Outgoing) throws -> SocketFrame,
         decode: @escaping @Sendable (SocketFrame) throws -> Incoming) {
        self.request = request
        self.policy = policy
        self.connector = connector
        self.encodeMessage = encode
        self.state = Locked(State(connection: connection))
        var feed: AsyncThrowingStream<Incoming, any Error>.Continuation!
        messages = AsyncThrowingStream { feed = $0 }
        var eventsContinuation: AsyncStream<SocketEvent>.Continuation!
        events = AsyncStream { eventsContinuation = $0 }
        emit = eventsContinuation
        let messagesFeed = feed!
        receiver.withLock { $0 = Task { [self] in await self.run(feed: messagesFeed, decode: decode) } }
        messagesFeed.onTermination = { [weak self] _ in self?.receiver.withLock { $0 }?.cancel() }
        emit.yield(.connected(attempt: 0))
        startKeepAlive()
    }

    public var isConnected: Bool { state.withLock { $0.isConnected && !$0.closedByUser } }

    public func send(_ message: Outgoing) async throws {
        let connection: any SocketConnection = try state.withLock { state in
            guard state.isConnected, !state.closedByUser else { throw SocketDisconnected() }
            return state.connection
        }
        try await connection.send(try encodeMessage(message))
    }

    public func ping() async throws { try await current().ping() }

    /// Cierra con código 1000 por defecto. `messages` y `events` terminan; no se reconecta.
    public func close(code: Int = 1000, reason: String? = nil) {
        let connection: any SocketConnection = state.withLock { state in
            state.closedByUser = true
            state.isConnected = false
            return state.connection
        }
        keepAlive.withLock { $0 }?.cancel()
        receiver.withLock { $0 }?.cancel()
        connection.close(code: code, reason: reason)
        emit.yield(.closed(code: code))
        emit.finish()
    }

    /// Cierra la conexión actual y deja que la política abra otra: lo que hace una app al volver de
    /// segundo plano o cuando `NWPathMonitor` avisa de que cambió la red. Sin política equivale a una
    /// caída: `messages` termina con error. Después de `close()` no hace nada.
    public func reconnect() {
        guard let connection = try? current() else { return }
        connection.close(code: 1006, reason: "reconnect")   // receive() falla y el bucle entra por la política
    }

    private func current() throws -> any SocketConnection {
        try state.withLock { state in
            guard state.isConnected, !state.closedByUser else { throw SocketDisconnected() }
            return state.connection
        }
    }

    // MARK: Bucle de recepción y reconexión

    private func run(feed: AsyncThrowingStream<Incoming, any Error>.Continuation, decode: @escaping @Sendable (SocketFrame) throws -> Incoming) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let connection = try current()
                let frame = try await connection.receive()
                feed.yield(try decode(frame))
            } catch {
                if Task.isCancelled || state.withLock({ $0.closedByUser }) { feed.finish(); return }
                if Self.isNormalClosure(error) {
                    finishAll(feed, code: (error as? SocketClosed)?.code ?? 1000, error: nil)
                    return
                }
                guard let backoff = policy.reconnect, Self.shouldReconnect(after: error) else {
                    finishAll(feed, code: (error as? SocketClosed)?.code ?? 1006, error: error)
                    return
                }
                state.withLock { $0.isConnected = false }
                emit.yield(.disconnected(error))
                guard await reconnect(backoff: backoff, attempt: &attempt, lastError: error, feed: feed) else { return }
            }
        }
        feed.finish()
    }

    /// Reintenta hasta conectar (true) o rendirse (false, con `messages` ya terminado).
    private func reconnect(backoff: RetryPolicy.Backoff, attempt: inout Int, lastError: any Error,
                           feed: AsyncThrowingStream<Incoming, any Error>.Continuation) async -> Bool {
        var failures = 0
        var lastError = lastError
        while !Task.isCancelled {
            failures += 1
            if let limit = policy.maxReconnects, failures > limit {
                finishAll(feed, code: 1006, error: lastError)
                return false
            }
            attempt += 1
            let delay = backoff.delay(forAttempt: failures)
            emit.yield(.reconnecting(attempt: attempt, after: delay))
            if delay > .zero, (try? await Task.sleep(for: delay)) == nil { feed.finish(); return false }
            do {
                let connection = try await connector()
                let stale: Bool = state.withLock { state in
                    if state.closedByUser { return true }
                    state.connection = connection
                    state.isConnected = true
                    return false
                }
                if stale { connection.close(code: 1000, reason: nil); feed.finish(); return false }
                emit.yield(.connected(attempt: attempt))
                return true
            } catch {
                lastError = error
                if case HTTPError.status(let code, _) = error, !RetryPolicy.shouldRetry(status: code) {
                    finishAll(feed, code: 1008, error: error)      // el servidor nos rechaza: no insistir
                    return false
                }
            }
        }
        feed.finish()
        return false
    }

    private func finishAll(_ feed: AsyncThrowingStream<Incoming, any Error>.Continuation, code: Int, error: (any Error)?) {
        state.withLock { $0.isConnected = false }
        keepAlive.withLock { $0 }?.cancel()
        emit.yield(.closed(code: code))
        emit.finish()
        if let error { feed.finish(throwing: error) } else { feed.finish() }
    }

    private func startKeepAlive() {
        guard let interval = policy.keepAlive else { return }
        keepAlive.withLock { $0 = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: interval)) != nil, let self else { return }
                guard let connection = try? self.current() else { continue }
                if (try? await connection.ping()) == nil, self.isConnected {
                    connection.close(code: 1006, reason: "keep-alive")   // receive() falla y entra la política
                }
            }
        } }
    }

    static func isNormalClosure(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let closed = error as? SocketClosed, closed.code == 1000 || closed.code == 1001 { return true }
        return false
    }

    /// Caídas de red y cierres anormales sí; errores de protocolo, de política y rechazos del servidor no.
    public static func shouldReconnect(after error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let closed = error as? SocketClosed {
            switch closed.code {
            case 1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 4000...4999: return false
            default: return true
            }
        }
        if case HTTPError.status(let code, _) = error { return RetryPolicy.shouldRetry(status: code) }
        return true
    }
}

/// El servidor o nosotros cerramos la conexión.
public struct SocketClosed: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int
    public let reason: String?
    public init(code: Int, reason: String?) { self.code = code; self.reason = reason }
    public var description: String { "WebSocket cerrado (\(code))\(reason.map { ": " + $0 } ?? "")" }
}

// MARK: - Codificación por tipo

enum SocketCoding {
    static func encoder<Outgoing: Encodable & Sendable>(for type: Outgoing.Type, json: JSONEncoder) -> @Sendable (Outgoing) throws -> SocketFrame {
        if Outgoing.self == String.self { return { .text($0 as! String) } }
        if Outgoing.self == Data.self { return { .binary($0 as! Data) } }
        return { message in .text(String(decoding: try json.encode(message), as: UTF8.self)) }
    }

    static func decoder<Incoming: Decodable & Sendable>(for type: Incoming.Type, json: JSONDecoder) -> @Sendable (SocketFrame) throws -> Incoming {
        if Incoming.self == String.self {
            return { frame in
                switch frame { case .text(let text): text as! Incoming; case .binary(let data): String(decoding: data, as: UTF8.self) as! Incoming }
            }
        }
        if Incoming.self == Data.self {
            return { frame in
                switch frame { case .text(let text): Data(text.utf8) as! Incoming; case .binary(let data): data as! Incoming }
            }
        }
        return { frame in
            switch frame {
            case .text(let text): try json.decode(Incoming.self, from: Data(text.utf8))
            case .binary(let data): try json.decode(Incoming.self, from: data)
            }
        }
    }
}
