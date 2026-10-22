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
/// `messages` admite un único consumidor. No reconecta solo: si la conexión cae, el stream termina
/// con error y el llamador decide si abre otra (en la iteración de resiliencia llegará una política).
public final class Socket<Outgoing: Sendable, Incoming: Sendable>: Sendable {
    public let request: Request
    public let messages: AsyncThrowingStream<Incoming, any Error>
    private let connection: any SocketConnection
    private let encodeMessage: @Sendable (Outgoing) throws -> SocketFrame
    private let receiver: Task<Void, Never>

    init(request: Request, connection: any SocketConnection,
         encode: @escaping @Sendable (Outgoing) throws -> SocketFrame,
         decode: @escaping @Sendable (SocketFrame) throws -> Incoming) {
        self.request = request
        self.connection = connection
        self.encodeMessage = encode
        var continuation: AsyncThrowingStream<Incoming, any Error>.Continuation!
        messages = AsyncThrowingStream { continuation = $0 }
        let feed = continuation!
        receiver = Task {
            do {
                while !Task.isCancelled {
                    let frame = try await connection.receive()
                    feed.yield(try decode(frame))
                }
                feed.finish()
            } catch {
                if Self.isNormalClosure(error) { feed.finish() } else { feed.finish(throwing: error) }
            }
        }
        continuation.onTermination = { [receiver] _ in receiver.cancel() }
    }

    public func send(_ message: Outgoing) async throws {
        try await connection.send(try encodeMessage(message))
    }

    public func ping() async throws { try await connection.ping() }

    /// Cierra con código 1000 por defecto. `messages` termina.
    public func close(code: Int = 1000, reason: String? = nil) {
        receiver.cancel()
        connection.close(code: code, reason: reason)
    }

    static func isNormalClosure(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let closed = error as? SocketClosed, closed.code == 1000 || closed.code == 1001 { return true }
        return false
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
