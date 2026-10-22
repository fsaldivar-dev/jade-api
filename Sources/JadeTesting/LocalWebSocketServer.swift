import Foundation
import Network

/// Servidor WebSocket local para pruebas, sobre Network.framework. Por defecto hace eco; con un
/// `handler` decides la respuesta a cada frame de texto (`nil` = no responder).
///
/// ```swift
/// let server = try await LocalWebSocketServer.start { text in "eco: " + text }
/// let client = AppClient(baseURL: server.baseURL, transport: URLSessionClient())
/// …
/// server.stop()
/// ```
public final class LocalWebSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (String) -> String?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "jade.testing.websocket")
    private let handler: Handler
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    public private(set) var port: UInt16 = 0

    private init(handler: @escaping Handler) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Arranca en un puerto libre y devuelve el servidor listo.
    public static func start(handler: @escaping Handler = { $0 }) async throws -> LocalWebSocketServer {
        let server = try LocalWebSocketServer(handler: handler)
        try await server.run()
        return server
    }

    /// `http://127.0.0.1:puerto`: `AppClient` lo convierte en `ws://` al abrir el socket.
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Resumed()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener.port?.rawValue ?? 0
                    if resumed.first() { continuation.resume() }
                case .failed(let error):
                    if resumed.first() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    private var accepted = 0

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); accepted += 1; lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.remove(connection) }
            if case .cancelled = state { self?.remove(connection) }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .text:
                    let text = String(decoding: data ?? Data(), as: UTF8.self)
                    if let reply = self.handler(text) { self.send(reply, on: connection) }
                case .binary:
                    self.send(data ?? Data(), on: connection)      // los binarios siempre hacen eco
                case .close:
                    connection.cancel()
                    return
                default: break
                }
            }
            self.receive(on: connection)
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func send(_ data: Data, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func remove(_ connection: NWConnection) {
        lock.lock(); connections.removeAll { $0 === connection }; lock.unlock()
    }

    /// Conexiones aceptadas desde el arranque (las caídas cuentan): sirve para afirmar que hubo reconexión.
    public var acceptedConnections: Int { lock.lock(); defer { lock.unlock() }; return accepted }

    /// Corta las conexiones abiertas sin parar el servidor: el cliente ve una caída y puede reconectar al mismo puerto.
    public func dropConnections() {
        lock.lock(); let open = connections; connections = []; lock.unlock()
        open.forEach { $0.cancel() }
    }

    public func stop() {
        lock.lock(); let open = connections; connections = []; lock.unlock()
        open.forEach { $0.cancel() }
        listener.cancel()
    }
}

private final class Resumed: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
